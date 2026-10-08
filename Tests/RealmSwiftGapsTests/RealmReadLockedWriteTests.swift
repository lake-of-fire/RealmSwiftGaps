import XCTest
import RealmSwift
@testable import RealmSwiftGaps

@objc(ManabiRealmReadLockedWriteFixtureRow)
private final class ReadLockedWriteRow: Object {
    override class func shouldIncludeInDefaultSchema() -> Bool { false }
    @Persisted(primaryKey: true) var id = ""
    @Persisted var value = 0
}

private final class ReadLockSubmissionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

private actor ReadLockedWriteFixture {
    private var submissions = 0
    private var heldRealm: Realm?
    private var releaseSubmission = 0
    private var commitPredecessor = false

    private func realms() async throws -> (Realm, Realm) {
        var sourceConfiguration = Realm.Configuration(inMemoryIdentifier: "read-source-\(UUID())")
        sourceConfiguration.objectTypes = [ReadLockedWriteRow.self]
        var targetConfiguration = Realm.Configuration(inMemoryIdentifier: "read-target-\(UUID())")
        targetConfiguration.objectTypes = [ReadLockedWriteRow.self]
        return (
            try await Realm(configuration: sourceConfiguration, actor: self),
            try await Realm(configuration: targetConfiguration, actor: self)
        )
    }

    private func add(_ id: String, value: Int, to realm: Realm) {
        let row = ReadLockedWriteRow()
        row.id = id
        row.value = value
        realm.add(row)
    }

    func queuedOwner(sourceOwner: Bool, commitPredecessor: Bool) async throws {
        let (source, target) = try await realms()
        let predecessor = sourceOwner ? source : target
        try predecessor.beginWrite()
        add("predecessor", value: 17, to: predecessor)
        heldRealm = predecessor
        releaseSubmission = sourceOwner ? 1 : 2
        self.commitPredecessor = commitPredecessor
        let watchdog = Task {
            do { try await Task.sleep(nanoseconds: 5_000_000_000) }
            catch { return }
            self.releaseTimedOutPredecessor()
        }
        defer {
            watchdog.cancel()
            if source.isInWriteTransaction { source.cancelWrite() }
            if target.isInWriteTransaction { target.cancelWrite() }
        }
        let result = try await RealmWriteSubmissionObservation.$willSubmit.withValue({
            // The observer enqueues settlement on the owner actor. It cannot
            // execute until the native begin ticket has been submitted.
            Task { await self.settleAfterSubmission() }
        }) {
            try await target.asyncWritePreservingOwnership(holdingReadLockIn: source) {
                XCTAssertTrue(source.isInWriteTransaction)
                XCTAssertTrue(target.isInWriteTransaction)
                XCTAssertEqual(predecessor.object(ofType: ReadLockedWriteRow.self,
                    forPrimaryKey: "predecessor")?.value, commitPredecessor ? 17 : nil)
                self.add("publication", value: 29, to: target)
                return 29
            }
        }
        XCTAssertEqual(result, 29)
        XCTAssertFalse(source.isInWriteTransaction)
        XCTAssertFalse(target.isInWriteTransaction)
        XCTAssertEqual(source.objects(ReadLockedWriteRow.self).count,
            sourceOwner && commitPredecessor ? 1 : 0)
        XCTAssertEqual(target.object(ofType: ReadLockedWriteRow.self,
            forPrimaryKey: "publication")?.value, 29)
    }

    private func releaseTimedOutPredecessor() {
        guard submissions < releaseSubmission, let realm = heldRealm else { return }
        XCTFail("Read-locked writer did not submit the expected native admission")
        if realm.isInWriteTransaction { realm.cancelWrite() }
    }

    private func settleAfterSubmission() {
        submissions += 1
        guard submissions == releaseSubmission, let realm = heldRealm else { return }
        do {
            if commitPredecessor { try realm.commitWrite() } else { realm.cancelWrite() }
        } catch { XCTFail("Predecessor settlement failed: \(error)") }
    }

    func cancellation(sourceOwner: Bool) async throws {
        let (source, target) = try await realms()
        let predecessor = sourceOwner ? source : target
        defer {
            if source.isInWriteTransaction { source.cancelWrite() }
            if target.isInWriteTransaction { target.cancelWrite() }
        }
        try predecessor.beginWrite()
        add("foreign", value: 41, to: predecessor)
        let calls = ReadLockSubmissionCounter()
        var ran = false
        do {
            try await RealmWriteSubmissionObservation.$willSubmit.withValue({
                if calls.next() == (sourceOwner ? 1 : 2) {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }) {
                try await target.asyncWritePreservingOwnership(holdingReadLockIn: source) {
                    ran = true
                }
            }
            XCTFail("Queued cancellation unexpectedly succeeded")
        } catch is CancellationError { }
        XCTAssertFalse(ran)
        XCTAssertTrue(predecessor.isInWriteTransaction)
        XCTAssertEqual(predecessor.object(ofType: ReadLockedWriteRow.self,
            forPrimaryKey: "foreign")?.value, 41)
        if !sourceOwner { XCTAssertFalse(source.isInWriteTransaction) }
        predecessor.cancelWrite()
        XCTAssertTrue(source.objects(ReadLockedWriteRow.self).isEmpty)
        XCTAssertTrue(target.objects(ReadLockedWriteRow.self).isEmpty)
    }

    func sameStoreRejected() async throws {
        let (source, _) = try await realms()
        do {
            try await source.asyncWritePreservingOwnership(holdingReadLockIn: source) { XCTFail("Alias admitted") }
            XCTFail("Alias was not rejected")
        } catch RealmReadLockWriteError.identicalStore { }
        XCTAssertFalse(source.isInWriteTransaction)
    }

    func synchronousCommitPreservesSuccessor() async throws {
        let (source, target) = try await realms()
        var armed = false
        var opened = false
        let token = target.observe { change, realm in
            guard change == .didChange, armed, !opened else { return }
            armed = false
            do {
                try realm.beginWrite()
                let row = ReadLockedWriteRow()
                row.id = "successor"
                row.value = 88
                realm.add(row)
                opened = true
            } catch { XCTFail("Notification successor failed: \(error)") }
        }
        defer {
            token.invalidate()
            if target.isInWriteTransaction { target.cancelWrite() }
        }
        let result = try await target.asyncWritePreservingOwnership(holdingReadLockIn: source) {
            self.add("publication", value: 87, to: target)
            armed = true
            try target.commitWrite()
            withUnsafeCurrentTask { $0?.cancel() }
            return 87
        }
        XCTAssertEqual(result, 87)
        XCTAssertTrue(opened)
        XCTAssertTrue(target.isInWriteTransaction)
        XCTAssertFalse(source.isInWriteTransaction)
        XCTAssertEqual(target.object(ofType: ReadLockedWriteRow.self, forPrimaryKey: "successor")?.value, 88)
        target.cancelWrite()
        XCTAssertNil(target.object(ofType: ReadLockedWriteRow.self, forPrimaryKey: "successor"))
        XCTAssertEqual(target.object(ofType: ReadLockedWriteRow.self, forPrimaryKey: "publication")?.value, 87)
        XCTAssertTrue(source.objects(ReadLockedWriteRow.self).isEmpty)
    }
}

final class RealmReadLockedWriteTests: XCTestCase {
    func testForeignSourceRollbackPreserved() async throws {
        try await ReadLockedWriteFixture().queuedOwner(sourceOwner: true, commitPredecessor: false)
    }
    func testForeignSourceCommitObserved() async throws {
        try await ReadLockedWriteFixture().queuedOwner(sourceOwner: true, commitPredecessor: true)
    }
    func testForeignDestinationRollbackPreserved() async throws {
        try await ReadLockedWriteFixture().queuedOwner(sourceOwner: false, commitPredecessor: false)
    }
    func testForeignDestinationCommitObserved() async throws {
        try await ReadLockedWriteFixture().queuedOwner(sourceOwner: false, commitPredecessor: true)
    }
    func testCancellationWaitingForSourcePreservesForeignOwner() async throws {
        // Cancellation belongs to a child task, never XCTest's calling task.
        try await Task { try await ReadLockedWriteFixture().cancellation(sourceOwner: true) }.value
    }
    func testCancellationWaitingForDestinationReleasesOnlyOwnedSource() async throws {
        try await Task { try await ReadLockedWriteFixture().cancellation(sourceOwner: false) }.value
    }
    func testIdenticalSourceAndDestinationRejectedBeforeAdmission() async throws {
        try await ReadLockedWriteFixture().sameStoreRejected()
    }
    func testSynchronousDestinationCommitPreservesNotificationSuccessorAfterCancellation() async throws {
        try await Task { try await ReadLockedWriteFixture().synchronousCommitPreservesSuccessor() }.value
    }
}
