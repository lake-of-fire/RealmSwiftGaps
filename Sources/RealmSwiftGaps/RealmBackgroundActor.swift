import Foundation
import RealmSwift
import Realm.Private

extension Object: @unchecked Sendable { }

public enum RealmBackgroundActorError: Error {
    case unableToResolveObject
    case cachedRealmEvictedDuringOpen
    case realmFileChangedDuringOpen
}

// Instance-scoped suspension points for deterministic cache lifecycle tests.
enum RealmCacheOpenEvent: Hashable, Sendable {
    case openedBeforePublication
    case joinedPendingOpen
    case waiterResolvedPendingOpen
}

// Task-scoped fixture observation at the SDK submission boundary. An observer
// may enqueue a turn on the owning actor, but must not suspend this caller:
// The writer queues its SDK begin ticket before its first suspension on that actor.
// Realm's isPerformingAsynchronousWriteOperations does not expose queued writes
// behind a synchronous transaction. No observer is installed in normal use.
enum RealmWriteSubmissionObservation {
    @TaskLocal static var willSubmit: (@Sendable () -> Void)? = nil
}

// Only this signal crosses executors. Realm and transaction ownership stay on
// the Realm owning actor. SDK completion means admission unless the actor has
// disarmed the signal before cancelling the SDK ticket.
final class RealmWriteAdmissionSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var admitted = false
    private var cancelled = false
    private var disarmed = false

    func wait(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        if admitted || cancelled {
            lock.unlock()
            continuation.resume()
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func admit() {
        lock.lock()
        guard !disarmed else {
            lock.unlock()
            return
        }
        admitted = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }

    func disarmAndTakeAdmission() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        disarmed = true
        return admitted
    }
}

// A synchronous fixture hook after commit submission, before durable settlement.
// It never changes the production write path or introduces an actor suspension.
enum RealmWriteCommitObservation {
    @TaskLocal static var didSubmit: (@Sendable () -> Void)? = nil
}

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
        operation: RealmWriteUnchecked<() throws -> Result>
    ) async throws -> RealmWriteUnchecked<Result> {
        let realm = realm.value
        try Task.checkCancellation()
        RealmWriteSubmissionObservation.willSubmit?()
        let signal = RealmWriteAdmissionSignal()
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
        let result: Result
        do {
            try Task.checkCancellation()
            result = try operation.value()
            // Some callers commit synchronously while holding their account or
            // runtime publication fence. Cancellation cannot revoke that durable
            // result; rollback is possible only while our transaction is open.
            if realm.isInWriteTransaction { try Task.checkCancellation() }
        } catch {
            if realm.isInWriteTransaction { realm.cancelWrite() }
            throw error
        }
        if realm.isInWriteTransaction {
            // Cancellation after commit submission cannot undo the commit.
            // Never cancel its completion callback: success means durable state.
            let error: Swift.Error? = await withCheckedContinuation { continuation in
                realm.commitAsyncWrite(allowGrouping: false) { error in
                    continuation.resume(returning: error)
                }
                RealmWriteCommitObservation.didSubmit?()
            }
            if let error { throw error }
        }
        return RealmWriteUnchecked(result)
    }
}

@globalActor
public actor RealmBackgroundActor: CachedRealmsActor {
    public static let shared = RealmBackgroundActor()

    public init() { }

    init(openObserver: @escaping @Sendable (RealmCacheOpenEvent) async -> Void) {
        self.openObserver = openObserver
    }

    private var openObserver: (@Sendable (RealmCacheOpenEvent) async -> Void)?
    
    public var cachedRealms = [String: RealmSwift.Realm]()
    // Realm's async actor-bound initializer suspends while the file/group is
    // opened.  A second caller can therefore enter this actor before the
    // first open has populated `cachedRealms`.  Keep the in-flight open on
    // the actor so startup callers share one initialization instead of
    // concurrently opening the same in-memory group.
    private var pendingRealmOpens = [String: Task<String, Error>]()
    
    public func getCachedRealm(key: String) async -> Realm? {
        return cachedRealms[key]
    }
    
    public func setCachedRealm(_ realm: Realm, key: String) async {
        cachedRealms[key] = realm
    }

    public func cachedRealm(
        for configuration: Realm.Configuration
    ) async throws -> RealmSwift.Realm {
        let key = realmCacheKey(for: configuration)
        if let cachedRealm = cachedRealms[key] {
            return cachedRealm
        }

        // A missing file may appear while its first open is suspended,
        // changing the completed cache key. Coalesce that first creation by
        // path, but keep existing-file opens keyed by resource ID so a file
        // replaced during an open does not share the old file's Realm.
        let pendingKey = realmCacheKey(
            for: configuration, includingFileResourceIdentifier: false
        )
        if let pendingOpen = pendingRealmOpens[key]
            ?? pendingRealmOpens[pendingKey] {
            if let openObserver {
                await openObserver(.joinedPendingOpen)
            }
            let openedKey = try await pendingOpen.value
            if let openObserver {
                await openObserver(.waiterResolvedPendingOpen)
            }
            return try realmForCompletedOpen(key: openedKey, configuration: configuration)
        }

        let opensMissingFile = configuration.fileURL.map {
            !FileManager.default.fileExists(atPath: $0.standardizedFileURL.path)
        } ?? false
        let openKey = opensMissingFile ? pendingKey : key

        // Publish on the owning actor. A completed Task retains only a key,
        // never a live Realm that can outlast eviction or file replacement.
        let pendingOpen = Task { () throws -> String in
            let realm = try await RealmSwift.Realm(configuration: configuration, actor: self)
            if let openObserver {
                await openObserver(.openedBeforePublication)
            }
            // First creation changes the identity, but an existing file must
            // still match the identity captured before the suspended open.
            let openedKey = realmCacheKey(for: configuration)
            guard opensMissingFile || openedKey == key else {
                throw RealmBackgroundActorError.realmFileChangedDuringOpen
            }
            if cachedRealms[openedKey] == nil {
                cachedRealms[openedKey] = realm
            }
            return openedKey
        }
        pendingRealmOpens[openKey] = pendingOpen
        defer { pendingRealmOpens.removeValue(forKey: openKey) }

        let openedKey = try await pendingOpen.value
        return try realmForCompletedOpen(key: openedKey, configuration: configuration)
    }

    private func realmForCompletedOpen(key: String, configuration: Realm.Configuration) throws -> Realm {
        // Another actor turn can replace the file or evict the cache between
        // publication and a waiter's resumption. Revalidate without suspension
        // before resolving and returning the actor-owned Realm.
        guard realmCacheKey(for: configuration) == key else {
            throw RealmBackgroundActorError.realmFileChangedDuringOpen
        }
        guard let realm = cachedRealms[key] else {
            throw RealmBackgroundActorError.cachedRealmEvictedDuringOpen
        }
        return realm
    }

    /// Releases an explicitly scoped Realm when its configuration is no longer
    /// needed. Production configurations remain cached for the actor lifetime,
    /// while callers that create transient configurations can bound their file
    /// descriptor usage. Call after users and pending opens/writes have quiesced,
    /// before replacing its file. This does not close independently held Realms
    /// or coordinate another actor/process. An active transaction is never evicted.
    @discardableResult
    public func removeCachedRealm(for configuration: Realm.Configuration) -> Bool {
        let key = realmCacheKey(for: configuration)
        guard let realm = cachedRealms[key], !realm.isInWriteTransaction else { return false }
        cachedRealms.removeValue(forKey: key)
        realm.invalidate()
        return true
    }

    public func run(_ operation: @escaping () async throws -> Void) async {
        do {
            try await operation()
        } catch {
            print("Realm operation failed: \(error.localizedDescription)")
        }
    }
    
    public func write(configuration: Realm.Configuration, operation: @escaping (Realm) throws -> Void) async throws {
        let realm = try await cachedRealm(for: configuration)
        try await write(in: realm, operation: operation)
    }

    func write(in realm: Realm, operation: (Realm) throws -> Void) async throws {
        try await realm.asyncWritePreservingOwnership { try operation(realm) }
    }

    public func write<T: ThreadConfined>(_ reference: ThreadSafeReference<T>, configuration: Realm.Configuration, operation: @escaping (Realm, T) throws -> Void) async throws {
        let realm = try await cachedRealm(for: configuration)
        try await write(in: realm) { realm in
            guard let resolvedObject = realm.resolve(reference) else {
                throw RealmBackgroundActorError.unableToResolveObject
            }
            try operation(realm, resolvedObject)
        }
    }
}

public extension Realm {
    /// Call from this Realm's owning actor, as required by Realm.asyncWrite.
    /// Queues an independent transaction on that actor in the calling task.
    /// The operation and its result stay on that actor; task-local
    /// values, cancellation and priority remain those of the structured caller.
    /// Cancellation before admission cancels only this request. Once admitted,
    /// cancellation or an operation error rolls back this transaction. After
    /// commit submission, the call awaits durable settlement even if cancelled.
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
