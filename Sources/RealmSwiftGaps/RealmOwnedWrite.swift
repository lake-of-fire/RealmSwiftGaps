import Foundation
import RealmSwift
import Realm.Private

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
