import Foundation
import RealmSwift
import XCTest
@testable import RealmSwiftGaps

private actor OwnedWritePortBarrier {
    nonisolated let entered = XCTestExpectation(description: "Original write is held")
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func hold() async {
        entered.fulfill()
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private enum OwnedWritePortContext {
    @TaskLocal static var value = "unset"
}

private enum OwnedWritePortEntry: CaseIterable, Equatable, Sendable {
    case actorConfiguration, actorReference
    case staticConfiguration, staticReference, staticReferences
    case scheduledConfiguration, scheduledReference
}

// Keeps a generic, non-Sendable result on its original Realm actor.
private final class OwnedWritePortResult {
    let object: OwnedWritePortFixture
    init(_ object: OwnedWritePortFixture) { self.object = object }
}

private actor OwnedWritePortActor {
    func genericResult(_ configuration: Realm.Configuration) async throws -> (Int, Bool, String) {
        let realm = try await Realm(configuration: configuration, actor: self)
        let caller = withUnsafeCurrentTask { $0?.hashValue }
        let result: OwnedWritePortResult = try await realm.asyncWritePreservingOwnership {
            let object = OwnedWritePortFixture()
            object.value = 42
            realm.add(object)
            return OwnedWritePortResult(object)
        }
        return (result.object.value, caller == withUnsafeCurrentTask { $0?.hashValue }, OwnedWritePortContext.value)
    }

    func synchronousCommitThenCancel(_ configuration: Realm.Configuration) async throws -> Int {
        let realm = try await Realm(configuration: configuration, actor: self)
        let result = try await realm.asyncWritePreservingOwnership {
            let object = OwnedWritePortFixture()
            object.value = 73
            realm.add(object)
            try realm.commitWrite()
            withUnsafeCurrentTask { $0?.cancel() }
            return object.value
        }
        XCTAssertFalse(realm.isInWriteTransaction)
        return result
    }

    func cancellationDuringBody(_ configuration: Realm.Configuration) async throws -> Bool {
        let realm = try await Realm(configuration: configuration, actor: self)
        do {
            try await realm.asyncWritePreservingOwnership {
                realm.add(OwnedWritePortFixture())
                withUnsafeCurrentTask { $0?.cancel() }
            }
            XCTFail("Uncommitted cancellation must throw")
        } catch is CancellationError { }
        return realm.objects(OwnedWritePortFixture.self).isEmpty && !realm.isInWriteTransaction
    }

    func synchronousCommitWithNotificationSuccessor(_ configuration: Realm.Configuration) async throws -> (Int, Bool, Int?, Int?) {
        let realm = try await Realm(configuration: configuration, actor: self)
        var armed = false
        var openedSuccessor = false
        var notificationError: Error?
        let token = realm.observe { notification, observed in
            guard notification == .didChange, armed, !openedSuccessor else { return }
            armed = false
            do {
                try observed.beginWrite()
                let object = OwnedWritePortFixture()
                object.id = "notification-successor"
                object.value = 88
                observed.add(object)
                openedSuccessor = true
            } catch { notificationError = error }
        }
        defer {
            token.invalidate()
            if realm.isInWriteTransaction { realm.cancelWrite() }
        }
        let result = try await realm.asyncWritePreservingOwnership {
            let original = OwnedWritePortFixture()
            original.value = 87
            realm.add(original)
            armed = true
            try realm.commitWrite()
            return original.value
        }
        if let notificationError { throw notificationError }
        let successorStillOpen = openedSuccessor && realm.isInWriteTransaction
        let original = realm.object(ofType: OwnedWritePortFixture.self, forPrimaryKey: "fixture")?.value
        if realm.isInWriteTransaction { realm.cancelWrite() }
        let successorAfterRollback = realm.object(ofType: OwnedWritePortFixture.self, forPrimaryKey: "notification-successor")?.value
        return (result, successorStillOpen, original, successorAfterRollback)
    }
}

final class RealmOwnedWritePortTests: XCTestCase {
    func testGenericResultStaysOnItsActorAndOriginalTask() async throws {
        let actor = OwnedWritePortActor()
        let report = try await OwnedWritePortContext.$value.withValue("original-context") {
            try await actor.genericResult(Self.configuration())
        }
        XCTAssertEqual(report.0, 42)
        XCTAssertTrue(report.1)
        XCTAssertEqual(report.2, "original-context")
    }

    func testSynchronousCommitRetainsSuccessAfterCallerCancels() async throws {
        let actor = OwnedWritePortActor()
        let task = Task { try await actor.synchronousCommitThenCancel(Self.configuration()) }
        let result = try await task.value
        XCTAssertEqual(result, 73)
        XCTAssertTrue(task.isCancelled)
    }

    func testCancellationDuringBodyRollsBackOnlyItsOwnWrite() async throws {
        let actor = OwnedWritePortActor()
        let task = Task { try await actor.cancellationDuringBody(Self.configuration()) }
        let rolledBack = try await task.value
        XCTAssertTrue(rolledBack)
    }

    func testSynchronousCommitPreservesNotificationOwnedSuccessor() async throws {
        let report = try await OwnedWritePortActor().synchronousCommitWithNotificationSuccessor(Self.configuration())
        XCTAssertEqual(report.0, 87)
        XCTAssertTrue(report.1)
        XCTAssertEqual(report.2, 87)
        XCTAssertNil(report.3)
    }

    @RealmBackgroundActor
    func testAllIndependentHelpersCancelOnlyTheirQueuedTicket() async throws {
        for entry in OwnedWritePortEntry.allCases {
            let configuration = Self.configuration()
            let actor = RealmBackgroundActor.shared
            let realm = try await actor.cachedRealm(for: configuration)
            try realm.write { realm.add(OwnedWritePortFixture()) }
            let reference = ThreadSafeReference(to: realm.objects(OwnedWritePortFixture.self).first!)
            let source = realm.objects(OwnedWritePortFixture.self).first!
            let ownerGate = OwnedWritePortBarrier()
            let owner = Task { @RealmBackgroundActor in
                try realm.beginWrite()
                await ownerGate.hold()
                let stillOwned = realm.isInWriteTransaction
                if stillOwned { realm.cancelWrite() }
                return stillOwned
            }
            addTeardownBlock { @RealmBackgroundActor in
                await ownerGate.release()
                _ = await owner.result
                Self.releaseCache(configuration)
            }
            await fulfillment(of: [ownerGate.entered], timeout: 5)
            let submitted = XCTestExpectation(description: "Independent ticket submitted")
            let settled = XCTestExpectation(description: "Cancelled independent ticket settled")
            let handle: Task<Void, Error>
            if entry == .scheduledConfiguration {
                handle = RealmWriteSubmissionObservation.$willSubmit.withValue({ submitted.fulfill() }) {
                    Realm.writeAsync(configuration: configuration) { _ in XCTFail("Cancelled scheduled write ran") }
                }
            } else if entry == .scheduledReference {
                handle = RealmWriteSubmissionObservation.$willSubmit.withValue({ submitted.fulfill() }) {
                    Realm.writeAsync(source, configuration: configuration) { _, _ in XCTFail("Cancelled scheduled reference ran") }
                }
            } else {
                handle = Task { @RealmBackgroundActor in
                    defer { settled.fulfill() }
                    try await RealmWriteSubmissionObservation.$willSubmit.withValue({ submitted.fulfill() }) {
                        switch entry {
                        case .actorConfiguration:
                            try await actor.write(configuration: configuration) { _ in XCTFail("Cancelled configuration write ran") }
                        case .actorReference:
                            try await actor.write(reference, configuration: configuration) { _, _ in XCTFail("Cancelled reference write ran") }
                        case .staticConfiguration:
                            try await Realm.asyncWrite(configuration: configuration) { _ in XCTFail("Cancelled convenience write ran") }
                        case .staticReference:
                            try await Realm.asyncWrite(reference, configuration: configuration) { _, _ in XCTFail("Cancelled convenience reference ran") }
                        case .staticReferences:
                            try await Realm.asyncWrite([reference], configuration: configuration) { _, _ in XCTFail("Cancelled convenience array ran") }
                        case .scheduledConfiguration, .scheduledReference:
                            XCTFail("Scheduled entries use their own cancellable handles")
                        }
                    }
                }
            }
            // The scheduled helpers preserve their independent task identity.
            // Their handle, rather than the submitting task, owns cancellation.
            addTeardownBlock {
                handle.cancel()
                await ownerGate.release()
                _ = await handle.result
            }
            await fulfillment(of: [submitted], timeout: 5)
            handle.cancel()
            if entry != .scheduledConfiguration && entry != .scheduledReference {
                await fulfillment(of: [settled], timeout: 5)
            }
            switch await handle.result {
            case .success: XCTFail("Cancelled queued ticket succeeded: \(entry)")
            case .failure(let error): XCTAssertTrue(error is CancellationError)
            }
            XCTAssertTrue(realm.isInWriteTransaction)
            await ownerGate.release()
            let ownerStillOwned = try await owner.value
            XCTAssertTrue(ownerStillOwned)
            try await actor.write(configuration: configuration) { realm in
                realm.objects(OwnedWritePortFixture.self).first?.value = 99
            }
            XCTAssertEqual(realm.objects(OwnedWritePortFixture.self).first?.value, 99)
            Self.releaseCache(configuration)
        }
    }

    @RealmBackgroundActor
    func testCancellationAfterAsyncCommitSubmissionReturnsDurableSuccess() async throws {
        let configuration = Self.configuration()
        let actor = RealmBackgroundActor.shared
        addTeardownBlock { @RealmBackgroundActor in Self.releaseCache(configuration) }
        let task = Task { @RealmBackgroundActor in
            try await RealmWriteCommitObservation.$didSubmit.withValue({ withUnsafeCurrentTask { $0?.cancel() } }) {
                try await actor.write(configuration: configuration) { realm in
                    let object = OwnedWritePortFixture()
                    object.value = 51
                    realm.add(object)
                }
            }
        }
        addTeardownBlock { _ = await task.result }
        try await task.value
        XCTAssertTrue(task.isCancelled)
        let realm = try await actor.cachedRealm(for: configuration)
        XCTAssertFalse(realm.isInWriteTransaction)
        XCTAssertEqual(realm.objects(OwnedWritePortFixture.self).first?.value, 51)
    }

    @RealmBackgroundActor
    func testDeletedReferencesKeepActorErrorAndConvenienceNoOpContracts() async throws {
        let configuration = Self.configuration()
        let actor = RealmBackgroundActor.shared
        let realm = try await actor.cachedRealm(for: configuration)
        addTeardownBlock { @RealmBackgroundActor in Self.releaseCache(configuration) }
        let object = OwnedWritePortFixture()
        try realm.write { realm.add(object) }
        let actorReference = ThreadSafeReference(to: object)
        let singleReference = ThreadSafeReference(to: object)
        let arrayReference = ThreadSafeReference(to: object)
        let scheduled = Realm.writeAsync(object, configuration: configuration) { _, _ in XCTFail("Deleted scheduled reference ran") }
        addTeardownBlock { _ = await scheduled.result }
        // No suspension before deletion: the scheduled actor task has not run.
        try realm.write { realm.delete(object) }
        do {
            try await actor.write(actorReference, configuration: configuration) { _, _ in XCTFail("Deleted actor reference ran") }
            XCTFail("Actor write must retain its unresolved-reference error")
        } catch RealmBackgroundActorError.unableToResolveObject { }
        try await Realm.asyncWrite(singleReference, configuration: configuration) { _, _ in XCTFail("Deleted convenience reference ran") }
        try await Realm.asyncWrite([arrayReference], configuration: configuration) { _, _ in XCTFail("Deleted convenience array ran") }
        try await scheduled.value
        XCTAssertFalse(realm.isInWriteTransaction)
    }

    @RealmBackgroundActor
    func testExplicitWriteIfNeededStillJoinsOwnedTransaction() async throws {
        let configuration = Self.configuration()
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        addTeardownBlock { @RealmBackgroundActor in Self.releaseCache(configuration) }
        try realm.beginWrite()
        defer { if realm.isInWriteTransaction { realm.cancelWrite() } }
        try realm.writeIfNeeded { realm.add(OwnedWritePortFixture()) }
        XCTAssertTrue(realm.isInWriteTransaction)
        realm.cancelWrite()
        XCTAssertTrue(realm.objects(OwnedWritePortFixture.self).isEmpty)
    }

    @RealmBackgroundActor
    func testReferenceArraySkipsDeletedObjectsAndWritesItsLiveMembers() async throws {
        let configuration = Self.configuration()
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        addTeardownBlock { @RealmBackgroundActor in Self.releaseCache(configuration) }
        let deleted = OwnedWritePortFixture()
        deleted.id = "deleted"
        let live = OwnedWritePortFixture()
        live.id = "live"
        try realm.write { realm.add([deleted, live]) }
        let references = [ThreadSafeReference(to: deleted), ThreadSafeReference(to: live)]
        try realm.write { realm.delete(deleted) }
        var invoked = [String]()
        try await Realm.asyncWrite(references, configuration: configuration) { _, object in
            invoked.append(object.id)
            object.value = 63
        }
        XCTAssertEqual(invoked, ["live"])
        XCTAssertEqual(realm.object(ofType: OwnedWritePortFixture.self, forPrimaryKey: "live")?.value, 63)
        XCTAssertFalse(realm.isInWriteTransaction)
    }

    private static func configuration() -> Realm.Configuration {
        Realm.Configuration(inMemoryIdentifier: "owned-port-\(UUID())", objectTypes: [OwnedWritePortFixture.self])
    }

    @RealmBackgroundActor
    private static func releaseCache(_ configuration: Realm.Configuration) {
        let actor = RealmBackgroundActor.shared
        let keys = actor.cachedRealms.keys.filter {
            actor.cachedRealms[$0]?.configuration.inMemoryIdentifier == configuration.inMemoryIdentifier
        }
        for key in keys {
            guard actor.cachedRealms[key]?.isInWriteTransaction == false else { continue }
            actor.cachedRealms.removeValue(forKey: key)?.invalidate()
        }
    }
}

@objc(RealmSwiftGapsOwnedWritePortFixture)
private final class OwnedWritePortFixture: Object, @unchecked Sendable {
    @Persisted(primaryKey: true) var id = "fixture"
    @Persisted var value = 0
    override class func shouldIncludeInDefaultSchema() -> Bool { false }
}
