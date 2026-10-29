import XCTest
import RealmSwift
@testable import RealmSwiftGaps

@objc(RealmOwnedWriteBehaviorTestRow)
private final class OwnedWriteRow: Object {
    @Persisted(primaryKey: true) var id = ""
    @Persisted var value = ""
    override class func shouldIncludeInDefaultSchema() -> Bool { false }
}

private actor OwnedWriteBlocker {
    private var realm: Realm?

    func open(_ configuration: Realm.Configuration) async throws {
        realm = try await Realm(configuration: configuration, actor: self)
    }

    func begin() throws {
        try realm?.beginWrite()
    }

    func release() {
        if let realm, realm.isInWriteTransaction { realm.cancelWrite() }
    }
}

@MainActor
final class RealmOwnedWriteBehaviorTests: XCTestCase {
    private enum FixtureError: Error { case bodyFailure }

    private func realm() async throws -> Realm {
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [OwnedWriteRow.self]
        return try await Realm(configuration: configuration, actor: MainActor.shared)
    }

    private func row(_ id: String, _ value: String) -> OwnedWriteRow {
        let object = OwnedWriteRow()
        object.id = id
        object.value = value
        return object
    }

    private enum StaticWriteVariant: CaseIterable {
        case realm, reference, references
    }

    private func staticAsyncWriteOwnsTransaction(_ variant: StaticWriteVariant, cancel: Bool) async throws {
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [OwnedWriteRow.self]
        let settled = expectation(description: "async helper queued or returned")
        let operation = Task { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            let original = OwnedWriteRow()
            original.id = "original"; original.value = "committed"
            try realm.write { realm.add(original) }
            let reference = ThreadSafeReference(to: original)
            try realm.beginWrite()
            defer { if realm.isInWriteTransaction { realm.cancelWrite() } }
            original.value = "other owner's uncommitted value"
            var submitted = false
            var completed = false
            var bodyRan = false
            let task = Task { @RealmBackgroundActor in
                defer {
                    completed = true
                    if !submitted { settled.fulfill() }
                }
                try await RealmWriteSubmissionObservation.$willSubmit.withValue({
                    submitted = true; settled.fulfill()
                }) {
                    switch variant {
                    case .realm:
                        try await Realm.asyncWrite(configuration: configuration) { current in
                            bodyRan = true
                            current.object(ofType: OwnedWriteRow.self, forPrimaryKey: "original")?.value = "independent"
                        }
                    case .reference:
                        try await Realm.asyncWrite(reference, configuration: configuration) { _, object in
                            bodyRan = true; object.value = "independent"
                        }
                    case .references:
                        try await Realm.asyncWrite([reference], configuration: configuration) { _, object in
                            bodyRan = true; object.value = "independent"
                        }
                    }
                }
            }
            await fulfillment(of: [settled], timeout: 5)
            XCTAssertFalse(completed, "An async helper must wait for its own transaction")
            XCTAssertFalse(bodyRan, "It must never join another task's transaction")
            XCTAssertTrue(realm.isInWriteTransaction)
            if cancel {
                task.cancel()
                do { try await task.value; XCTFail("Expected queued cancellation") }
                catch is CancellationError { }
                XCTAssertTrue(realm.isInWriteTransaction)
                XCTAssertEqual(original.value, "other owner's uncommitted value")
            }
            realm.cancelWrite()
            if !cancel { try await task.value }
            XCTAssertEqual(original.value, cancel ? "committed" : "independent")
            XCTAssertFalse(realm.isInWriteTransaction)
        }
        let result = await operation.result
        _ = await RealmBackgroundActor.shared.removeCachedRealm(for: configuration)
        try result.get()
    }

    func testStaticAsyncWriteVariantsNeverJoinAnotherTaskTransaction() async throws {
        for variant in StaticWriteVariant.allCases {
            try await staticAsyncWriteOwnsTransaction(variant, cancel: false)
        }
    }

    func testStaticAsyncWriteCancellationPreservesOtherOwner() async throws {
        for variant in StaticWriteVariant.allCases {
            try await staticAsyncWriteOwnsTransaction(variant, cancel: true)
        }
    }

    func testFireAndForgetVariantsWaitForTheirOwnTransaction() async throws {
        for usesReference in [false, true] {
            var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
            configuration.objectTypes = [OwnedWriteRow.self]
            let queued = expectation(description: "background helper queued")
            let ran = expectation(description: "background helper committed body")
            try await Task { @RealmBackgroundActor in
                let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
                let original = OwnedWriteRow()
                original.id = "original"; original.value = "committed"
                try realm.write { realm.add(original) }
                try realm.beginWrite()
                defer { if realm.isInWriteTransaction { realm.cancelWrite() } }
                original.value = "uncommitted other owner"
                var bodyRan = false
                RealmWriteSubmissionObservation.$willSubmit.withValue({ queued.fulfill() }) {
                    if usesReference {
                        Realm.writeAsync(original, configuration: configuration) { _, object in
                            bodyRan = true; object.value = "independent"; ran.fulfill()
                        }
                    } else {
                        Realm.writeAsync(configuration: configuration) { current in
                            bodyRan = true
                            current.object(ofType: OwnedWriteRow.self, forPrimaryKey: "original")?.value = "independent"
                            ran.fulfill()
                        }
                    }
                }
                await fulfillment(of: [queued], timeout: 5)
                XCTAssertFalse(bodyRan)
                XCTAssertTrue(realm.isInWriteTransaction)
                XCTAssertEqual(original.value, "uncommitted other owner")
                realm.cancelWrite()
                await fulfillment(of: [ran], timeout: 5)
                // Drain the writer's durable commit by queuing another owned
                // transaction; the body observation alone precedes settlement.
                try await realm.asyncWritePreservingOwnership { }
                XCTAssertEqual(original.value, "independent")
                XCTAssertFalse(realm.isInWriteTransaction)
            }.value
            _ = await RealmBackgroundActor.shared.removeCachedRealm(for: configuration)
        }
    }

    func testOrdinarySuccessCommitsAndReturnsResult() async throws {
        let realm = try await realm()
        let result = try await realm.asyncWritePreservingOwnership {
            realm.add(row("original", "durable"))
            return "result"
        }
        XCTAssertEqual(result, "result")
        XCTAssertFalse(realm.isInWriteTransaction)
        XCTAssertEqual(realm.object(ofType: OwnedWriteRow.self, forPrimaryKey: "original")?.value, "durable")
    }

    func testBodyErrorRollsBackOnlyAdmittedWrite() async throws {
        let realm = try await realm()
        do {
            try await realm.asyncWritePreservingOwnership {
                realm.add(row("original", "must roll back"))
                throw FixtureError.bodyFailure
            }
            XCTFail("Expected body failure")
        } catch FixtureError.bodyFailure { }
        XCTAssertFalse(realm.isInWriteTransaction)
        XCTAssertTrue(realm.objects(OwnedWriteRow.self).isEmpty)
    }

    func testCancellationInsideBodyRollsBackAdmittedWrite() async throws {
        let realm = try await realm()
        let task = Task { @MainActor in
            try await realm.asyncWritePreservingOwnership {
                realm.add(self.row("original", "must roll back"))
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        do { try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        XCTAssertFalse(realm.isInWriteTransaction)
        XCTAssertTrue(realm.objects(OwnedWriteRow.self).isEmpty)
    }

    func testQueuedCancellationPreservesExistingTransaction() async throws {
        let realm = try await realm()
        try realm.beginWrite()
        defer { if realm.isInWriteTransaction { realm.cancelWrite() } }
        realm.add(row("other-owner", "still open"))
        let submitted = expectation(description: "begin ticket submitted")
        let task = Task { @MainActor in
            try await RealmWriteSubmissionObservation.$willSubmit.withValue({ submitted.fulfill() }) {
                try await realm.asyncWritePreservingOwnership {
                    realm.add(self.row("cancelled", "must never run"))
                }
            }
        }
        await fulfillment(of: [submitted], timeout: 3)
        task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        XCTAssertTrue(realm.isInWriteTransaction)
        XCTAssertNil(realm.object(ofType: OwnedWriteRow.self, forPrimaryKey: "cancelled"))
        XCTAssertEqual(realm.object(ofType: OwnedWriteRow.self, forPrimaryKey: "other-owner")?.value, "still open")
        try realm.commitWrite()
    }

    func testCancellationAfterCommitSubmissionAwaitsDurableResult() async throws {
        let realm = try await realm()
        let task = Task { @MainActor in
            try await RealmWriteCommitObservation.$didSubmit.withValue({
                withUnsafeCurrentTask { $0?.cancel() }
            }) {
                try await realm.asyncWritePreservingOwnership {
                    realm.add(self.row("original", "durable"))
                    return "durable result"
                }
            }
        }
        let result = try await task.value
        XCTAssertEqual(result, "durable result")
        XCTAssertFalse(realm.isInWriteTransaction)
        XCTAssertEqual(realm.object(ofType: OwnedWriteRow.self, forPrimaryKey: "original")?.value, "durable")
    }

    func testContendedCancellationWaitsForNativeWriteRequestToSettle() async throws {
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [OwnedWriteRow.self]
        let realm = try await Realm(configuration: configuration, actor: MainActor.shared)
        let blocker = OwnedWriteBlocker()
        try await blocker.open(configuration)
        try await blocker.begin()
        let submitted = expectation(description: "native begin submitted")
        let cancelled = expectation(description: "queued cancellation observed")
        var completed = false
        let task = Task { @MainActor in
            defer { completed = true }
            try await RealmWriteSubmissionObservation.$willSubmit.withValue({ submitted.fulfill() }) {
                try await RealmWriteCancellationObservation.$didCancelBeforeAdmission.withValue({ cancelled.fulfill() }) {
                    try await realm.asyncWritePreservingOwnership {
                        realm.add(self.row("cancelled", "must never run"))
                    }
                }
            }
        }
        await fulfillment(of: [submitted], timeout: 3)
        XCTAssertTrue(realm.isPerformingAsynchronousWriteOperations,
                      "The native engine must have a mutex request behind the other Realm")
        task.cancel()
        await fulfillment(of: [cancelled], timeout: 3)
        XCTAssertFalse(completed,
                       "Cancellation must not report a drained writer while its native lock request is pending")
        await blocker.release()
        do { try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        XCTAssertFalse(realm.isInWriteTransaction)
        XCTAssertFalse(realm.isPerformingAsynchronousWriteOperations)
        XCTAssertNil(realm.object(ofType: OwnedWriteRow.self, forPrimaryKey: "cancelled"))
    }

    func testContendedCancellationPreservesFollowingWriter() async throws {
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [OwnedWriteRow.self]
        let realm = try await Realm(configuration: configuration, actor: MainActor.shared)
        let blocker = OwnedWriteBlocker()
        try await blocker.open(configuration)
        try await blocker.begin()
        let submitted = expectation(description: "cancelled writer submitted")
        let followingSubmitted = expectation(description: "following writer submitted")
        let cancelled = expectation(description: "queued cancellation observed")
        let task = Task { @MainActor in
            try await RealmWriteSubmissionObservation.$willSubmit.withValue({ submitted.fulfill() }) {
                try await RealmWriteCancellationObservation.$didCancelBeforeAdmission.withValue({ cancelled.fulfill() }) {
                    try await realm.asyncWritePreservingOwnership {
                        realm.add(self.row("cancelled", "must never run"))
                    }
                }
            }
        }
        await fulfillment(of: [submitted], timeout: 3)
        let following = Task { @MainActor in
            try await RealmWriteSubmissionObservation.$willSubmit.withValue({ followingSubmitted.fulfill() }) {
                try await realm.asyncWritePreservingOwnership {
                    realm.add(self.row("following", "durable"))
                    return "following result"
                }
            }
        }
        await fulfillment(of: [followingSubmitted], timeout: 3)
        task.cancel()
        await fulfillment(of: [cancelled], timeout: 3)
        await blocker.release()
        do { try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        let result = try await following.value
        XCTAssertEqual(result, "following result")
        XCTAssertFalse(realm.isInWriteTransaction)
        XCTAssertNil(realm.object(ofType: OwnedWriteRow.self, forPrimaryKey: "cancelled"))
        XCTAssertEqual(realm.object(ofType: OwnedWriteRow.self, forPrimaryKey: "following")?.value, "durable")
    }

    private enum Outcome { case success, error, cancellation }

    private func synchronousCommitPreservesSuccessor(_ outcome: Outcome) async throws {
        let realm = try await realm()
        var successorStarted = false
        var observerFailure: Error?
        let token = realm.observe { _, observedRealm in
            guard !successorStarted,
                  observedRealm.object(ofType: OwnedWriteRow.self, forPrimaryKey: "original") != nil else { return }
            successorStarted = true
            do {
                try observedRealm.beginWrite()
                observedRealm.add(self.row("successor", "uncommitted successor"))
            } catch { observerFailure = error }
        }
        defer {
            token.invalidate()
            if realm.isInWriteTransaction { realm.cancelWrite() }
        }
        let task = Task { @MainActor in
            try await realm.asyncWritePreservingOwnership {
                realm.add(self.row("original", "synchronously committed"))
                try realm.commitWrite()
                XCTAssertTrue(successorStarted, "Native notification must create the successor before commitWrite returns")
                XCTAssertNil(observerFailure)
                XCTAssertTrue(realm.isInWriteTransaction)
                switch outcome {
                case .success: return "committed result"
                case .error: throw FixtureError.bodyFailure
                case .cancellation:
                    withUnsafeCurrentTask { $0?.cancel() }
                    return "committed result"
                }
            }
        }
        switch outcome {
        case .success, .cancellation:
            let result = try await task.value
            XCTAssertEqual(result, "committed result")
        case .error:
            do { _ = try await task.value; XCTFail("Expected body error") }
            catch FixtureError.bodyFailure { }
        }
        XCTAssertTrue(realm.isInWriteTransaction, "The wrapper must neither commit nor roll back the notification's successor")
        XCTAssertEqual(realm.object(ofType: OwnedWriteRow.self, forPrimaryKey: "successor")?.value, "uncommitted successor")
        realm.cancelWrite()
        XCTAssertNil(realm.object(ofType: OwnedWriteRow.self, forPrimaryKey: "successor"))
        XCTAssertEqual(realm.object(ofType: OwnedWriteRow.self, forPrimaryKey: "original")?.value, "synchronously committed")
    }

    func testSynchronousCommitSuccessDoesNotCommitSuccessor() async throws {
        try await synchronousCommitPreservesSuccessor(.success)
    }

    func testSynchronousCommitThenErrorDoesNotRollbackSuccessor() async throws {
        try await synchronousCommitPreservesSuccessor(.error)
    }

    func testSynchronousCommitThenCancellationDoesNotRollbackSuccessor() async throws {
        try await synchronousCommitPreservesSuccessor(.cancellation)
    }
}
