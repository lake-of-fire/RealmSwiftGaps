import Foundation
import RealmSwift
import Realm.Private

/// Execution protection for an actual owned write, independent of the task
/// that requested it. Acquisition happens before any SDK begin ticket; release
/// happens only after rollback or asynchronous commit settlement.
public struct RealmWriteExecutionLease: Sendable {
    public let checkpoint: @Sendable () throws -> Void
    public let installInterruptionHandler: @Sendable (@escaping @Sendable () -> Void) -> Void
    public let release: @Sendable () -> Void

    public init(
        checkpoint: @escaping @Sendable () throws -> Void,
        installInterruptionHandler: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void,
        release: @escaping @Sendable () -> Void
    ) {
        self.checkpoint = checkpoint
        self.installInterruptionHandler = installInterruptionHandler
        self.release = release
    }
}

/// An execution policy inherited by short and long-lived child tasks. Each
/// write acquires a fresh lease; no retired per-attempt lease is inherited.
public enum RealmWriteExecutionProtection {
    public typealias Acquisition = @Sendable () async throws -> RealmWriteExecutionLease
    public typealias SynchronousAcquisition = @Sendable () throws -> RealmWriteExecutionLease
    @TaskLocal public static var acquire: Acquisition? = nil
    @TaskLocal public static var synchronousAcquisition: SynchronousAcquisition? = nil

    private final class DefaultAcquisition: @unchecked Sendable {
        let lock = NSLock()
        var value: SynchronousAcquisition?
    }
    private static let defaultAcquisition = DefaultAcquisition()

    /// Install at application startup, before creating background workers.
    /// The host supplies its platform execution API; this package stays usable
    /// by extensions and non-UIKit clients with their existing execution owner.
    public static func installDefaultSynchronousAcquisition(
        _ acquisition: @escaping SynchronousAcquisition
    ) {
        defaultAcquisition.lock.withLock { defaultAcquisition.value = acquisition }
    }

    /// Also protects synchronous file-lock scopes. This must not perform an
    /// actor hop: callers may already hold an account or database fence.
    public static func acquireSynchronousLease() throws -> RealmWriteExecutionLease? {
        let acquisition = synchronousAcquisition
            ?? defaultAcquisition.lock.withLock { defaultAcquisition.value }
        return try acquisition?()
    }

    static func acquireLease() async throws -> RealmWriteExecutionLease? {
        if let acquire { return try await acquire() }
        return try acquireSynchronousLease()
    }

    /// Writable SDK initialization can create, migrate, compact, and lock a
    /// Realm before the first explicit transaction. Use the synchronous host
    /// policy so admission introduces no actor hop inside a caller's fence.
    /// Retain execution until the native initializer has settled on its owner.
    public static func openRealm<A: Actor>(
        configuration: Realm.Configuration,
        actor: isolated A
    ) async throws -> Realm {
        try Task.checkCancellation()
        let execution = configuration.readOnly ? nil : try acquireSynchronousLease()
        defer { execution?.release() }
        try execution?.checkpoint()
        let realm = try await Realm(configuration: configuration, actor: actor)
        try execution?.checkpoint()
        try Task.checkCancellation()
        return realm
    }

    public static func openRealm(configuration: Realm.Configuration) throws -> Realm {
        let execution = configuration.readOnly ? nil : try acquireSynchronousLease()
        defer { execution?.release() }
        try execution?.checkpoint()
        let realm = try Realm(configuration: configuration)
        try execution?.checkpoint()
        return realm
    }
}

// Task-scoped fixture observation at the SDK submission boundary. An observer
// may enqueue a turn on the owning actor, but must not suspend this caller:
// The writer queues its SDK begin ticket before its first suspension on that actor.
// Realm's isPerformingAsynchronousWriteOperations does not expose queued writes
// behind a synchronous transaction. No observer is installed in normal use.
enum RealmWriteSubmissionObservation {
    @TaskLocal static var willSubmit: (@Sendable () -> Void)? = nil
}

// A synchronous fixture hook after commit submission, before durable settlement.
// It never changes the production write path or introduces an actor suspension.
enum RealmWriteCommitObservation {
    @TaskLocal static var didSubmit: (@Sendable () -> Void)? = nil
}

#if DEBUG
/// Test-only observation of the real owned-write lifecycle. Callbacks are
/// synchronous and TaskLocal so tests observe the same commit bridge used by
/// production writes without adding a suspension or global mutable hook.
public enum RealmWriteLifecycleObservation {
    @TaskLocal public static var didAdmit: (@Sendable () -> Void)? = nil
    @TaskLocal public static var didStartBody: (@Sendable () -> Void)? = nil
    @TaskLocal public static var didSubmitCommit: (@Sendable () -> Void)? = nil
    @TaskLocal public static var didSettle: (@Sendable () -> Void)? = nil
}
#endif

// This unchecked carrier never transfers a Realm or closure to another task.
// It carries non-Sendable values through an isolated call on the Realm owner.
private struct RealmWriteUnchecked<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

// Realm 20.0.5 queues a notify-only begin ticket through Realm.Private. SDK
// asyncWrite cancellation can resume a queued waiter and then cancel another
// caller's open transaction. Track admission independently and cancel only our
// begin ticket. Review this private SDK contract whenever Realm is upgraded;
// do not modify the installed SDK or create a detached mutation task.
private enum RealmOwnedWriteBridge {
    static func perform<Result>(
        actor: isolated any Actor,
        realm: RealmWriteUnchecked<Realm>,
        operation: RealmWriteUnchecked<() throws -> Result>,
        inheritedExecutionLease: RealmWriteExecutionLease? = nil
    ) async throws -> RealmWriteUnchecked<Result> {
        let realm = realm.value
        try Task.checkCancellation()
        let ownedExecutionLease: RealmWriteExecutionLease?
        let executionLease: RealmWriteExecutionLease?
        if let inheritedExecutionLease {
            ownedExecutionLease = nil
            executionLease = inheritedExecutionLease
        } else {
            ownedExecutionLease = try await RealmWriteExecutionProtection.acquireLease()
            executionLease = ownedExecutionLease
        }
        defer { ownedExecutionLease?.release() }
        try executionLease?.checkpoint()
        try await admit(actor: actor, realm: realm, executionLease: executionLease)
#if DEBUG
        RealmWriteLifecycleObservation.didAdmit?()
#endif
        let completion = try performAdmittedOperation(
            in: realm, executionCheckpoint: executionLease?.checkpoint,
            operation: operation.value
        )
        if completion.needsCommit {
            // Cancellation after commit submission cannot undo the commit.
            // Never cancel its completion callback: success means durable state.
            let error: Swift.Error? = await withCheckedContinuation { continuation in
                realm.commitAsyncWrite(allowGrouping: false) { error in
                    continuation.resume(returning: error)
                }
                RealmWriteCommitObservation.didSubmit?()
#if DEBUG
                RealmWriteLifecycleObservation.didSubmitCommit?()
#endif
            }
#if DEBUG
            RealmWriteLifecycleObservation.didSettle?()
#endif
            if let error { throw error }
        }
        return RealmWriteUnchecked(completion.value)
    }

    private static func admit(
        actor: isolated any Actor, realm: Realm,
        executionLease: RealmWriteExecutionLease? = nil
    ) async throws {
        try Task.checkCancellation()
        try executionLease?.checkpoint()
        RealmWriteSubmissionObservation.willSubmit?()
        let signal = RealmWriteAdmissionSignal()
        executionLease?.installInterruptionHandler { signal.cancel() }
        try executionLease?.checkpoint()
        let begin = ObjectiveCSupport.convert(object: realm).beginAsyncWrite()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                signal.wait(continuation)
                begin.wait { signal.admit() }
            }
        } onCancel: {
            signal.cancel()
        }

        // No actor suspension between admission snapshot and SDK cancellation:
        // complete(true) itself calls the wait callback, which must not be
        // mistaken for admission. Only actual admission grants rollback rights.
        let admitted = signal.disarmAndTakeAdmission()
        if !admitted {
            begin.complete(true)
            throw CancellationError()
        }
    }

    static func performHoldingReadLock<Result>(
        actor: isolated any Actor,
        realm: RealmWriteUnchecked<Realm>,
        source: RealmWriteUnchecked<Realm>,
        operation: RealmWriteUnchecked<() throws -> Result>
    ) async throws -> RealmWriteUnchecked<Result> {
        let destination = realm.value
        let source = source.value
        let nativeSource = ObjectiveCSupport.convert(object: source)
        let nativeDestination = ObjectiveCSupport.convert(object: destination)
        guard let sourceActor = nativeSource.actor as? any Actor,
              let destinationActor = nativeDestination.actor as? any Actor,
              (sourceActor as AnyObject) === (destinationActor as AnyObject),
              (sourceActor as AnyObject) === (actor as AnyObject) else {
            throw RealmReadLockWriteError.differentOwningActors
        }
        let sourceConfiguration = source.configuration
        let destinationConfiguration = destination.configuration
        let sameMemory = sourceConfiguration.inMemoryIdentifier != nil
            && sourceConfiguration.inMemoryIdentifier == destinationConfiguration.inMemoryIdentifier
        let sameFile = sourceConfiguration.inMemoryIdentifier == nil
            && destinationConfiguration.inMemoryIdentifier == nil
            && sourceConfiguration.fileURL?.standardizedFileURL.resolvingSymlinksInPath()
                == destinationConfiguration.fileURL?.standardizedFileURL.resolvingSymlinksInPath()
        guard nativeSource !== nativeDestination, !sameMemory, !sameFile else {
            throw RealmReadLockWriteError.identicalStore
        }
        // Acquire before the source lock. The destination reuses this exact
        // lease, so there is no MainActor admission hop while that lock is held.
        try Task.checkCancellation()
        let executionLease = try await RealmWriteExecutionProtection.acquireLease()
        defer { executionLease?.release() }
        try executionLease?.checkpoint()
        try await admit(actor: actor, realm: source, executionLease: executionLease)
        // Unlike the single-writer witness, this one spans destination admission.
        // The source is deliberately read-only, and its physical writer lock is
        // retained until the destination settles. Never commit this transaction.
        let sourceVersion = ObjectiveCSupport.convert(object: source.freeze())
        func stillOwnsSource() -> Bool {
            source.isInWriteTransaction
                && ObjectiveCSupport.convert(object: source.freeze()) === sourceVersion
        }
        defer {
            if stillOwnsSource() { source.cancelWrite() }
        }
        return try await perform(
            actor: actor,
            realm: realm,
            operation: RealmWriteUnchecked {
                guard stillOwnsSource() else {
                    throw RealmReadLockWriteError.sourceOwnershipLost
                }
                return try operation.value()
            },
            inheritedExecutionLease: executionLease
        )
    }

    /// No frozen Realm escapes this synchronous boundary or remains pinned
    /// across asynchronous commit settlement. The SDK caches a frozen native
    /// Realm for each committed version while a strong reference retains it.
    /// A synchronous commit advances that version, even when its notification
    /// opens a successor write before commitWrite() returns. The mutable
    /// isInWriteTransaction flag alone cannot prove we still own that write.
    /// The native version-witness tests must verify this pinned SDK contract;
    /// review it alongside the private begin-ticket contract on SDK upgrades.
    private static func performAdmittedOperation<Result>(
        in realm: Realm,
        executionCheckpoint: (@Sendable () throws -> Void)?,
        operation: () throws -> Result
    ) throws -> (value: Result, needsCommit: Bool) {
        let admittedVersion = ObjectiveCSupport.convert(object: realm.freeze())
        func stillOwnsOpenWrite() -> Bool {
            realm.isInWriteTransaction
                && ObjectiveCSupport.convert(object: realm.freeze()) === admittedVersion
        }
        do {
            try Task.checkCancellation()
            try executionCheckpoint?()
#if DEBUG
            RealmWriteLifecycleObservation.didStartBody?()
#endif
            let result = try operation()
            let needsCommit = stillOwnsOpenWrite()
            // Once a caller committed synchronously, neither cancellation nor
            // automatic settlement may touch a notification's successor write.
            if needsCommit {
                try Task.checkCancellation()
                try executionCheckpoint?()
            }
            return (result, needsCommit)
        } catch {
            if stillOwnsOpenWrite() { realm.cancelWrite() }
            throw error
        }
    }
}

public enum RealmReadLockWriteError: Error {
    case differentOwningActors
    case identicalStore
    case sourceOwnershipLost
}

public extension Realm {
    /// Acquires a read-only source writer lock before this destination's owned
    /// writer admission. Both stores must belong to the same actor and be
    /// physically distinct. The synchronous body may read the source and mutate
    /// the destination; it must not mutate or settle the source transaction.
    /// No account/publication fence may be held while calling this method.
    /// The source lock is rolled back after destination settlement. Cancellation
    /// never rolls back a foreign writer or reclassifies a durable destination
    /// commit as failure. All other writers must preserve source → destination
    /// ordering when acquiring both stores.
#if compiler(>=6)
    @discardableResult
    func asyncWritePreservingOwnership<Result>(
        holdingReadLockIn source: Realm,
        _isolation actor: isolated any Actor = #isolation,
        _ operation: () throws -> Result
    ) async throws -> Result {
        try await withoutActuallyEscaping(operation) { operation in
            try await RealmOwnedWriteBridge.performHoldingReadLock(
                actor: actor,
                realm: RealmWriteUnchecked(self),
                source: RealmWriteUnchecked(source),
                operation: RealmWriteUnchecked(operation)
            ).value
        }
    }
#else
    @discardableResult
    @_unsafeInheritExecutor
    func asyncWritePreservingOwnership<Result>(
        holdingReadLockIn source: Realm,
        _ operation: () throws -> Result
    ) async throws -> Result {
        guard let owner = ObjectiveCSupport.convert(object: self).actor as? any Actor else {
            throw RealmReadLockWriteError.differentOwningActors
        }
        return try await withoutActuallyEscaping(operation) { operation in
            try await RealmOwnedWriteBridge.performHoldingReadLock(
                actor: owner,
                realm: RealmWriteUnchecked(self),
                source: RealmWriteUnchecked(source),
                operation: RealmWriteUnchecked(operation)
            ).value
        }
    }
#endif

    /// Call from this Realm's owning actor, as required by Realm.asyncWrite.
    /// Queues an independent transaction on that actor in the calling task.
    /// The operation and its result stay on that actor; task-local
    /// values, cancellation and priority remain those of the structured caller.
    /// Cancellation before admission cancels only this request. Once admitted,
    /// cancellation or an operation error rolls back this transaction. After
    /// commit submission, the call awaits durable settlement even if cancelled.
    /// Synchronous commits are supported, including notification callbacks that
    /// open another write. The body must not cancel and replace its admitted
    /// transaction itself; signal failure by throwing instead.
#if compiler(>=6)
    @discardableResult
    func asyncWritePreservingOwnership<Result>(
        _isolation actor: isolated any Actor = #isolation,
        _ operation: () throws -> Result
    ) async throws -> Result {
        guard ObjectiveCSupport.convert(object: self).actor != nil else {
            fatalError("asyncWritePreservingOwnership requires an actor-isolated Realm")
        }
        return try await withoutActuallyEscaping(operation) { operation in
            try await RealmOwnedWriteBridge.perform(
                actor: actor,
                realm: RealmWriteUnchecked(self),
                operation: RealmWriteUnchecked(operation)
            ).value
        }
    }
#else
    @discardableResult
    @_unsafeInheritExecutor
    func asyncWritePreservingOwnership<Result>(
        _ operation: () throws -> Result
    ) async throws -> Result {
        guard let owner = ObjectiveCSupport.convert(object: self).actor as? any Actor else {
            fatalError("asyncWritePreservingOwnership requires an actor-isolated Realm")
        }
        return try await withoutActuallyEscaping(operation) { operation in
            try await RealmOwnedWriteBridge.perform(
                actor: owner,
                realm: RealmWriteUnchecked(self),
                operation: RealmWriteUnchecked(operation)
            ).value
        }
    }
#endif
}
