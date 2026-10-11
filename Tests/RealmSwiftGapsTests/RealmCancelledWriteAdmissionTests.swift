import Foundation
import RealmSwift
import XCTest
@testable import RealmSwiftGaps

private actor CancelledWriteStartGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        await withCheckedContinuation { continuation in
            if released { continuation.resume() }
            else { self.continuation = continuation }
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

final class RealmCancelledWriteAdmissionTests: XCTestCase {
    func testCancelledActorWriteDoesNotMutateAnExistingRealm() async throws {
        let actor = RealmBackgroundActor()
        let configuration = configuration()
        try await actor.seedCancellationFixture(configuration)
        let gate = CancelledWriteStartGate()
        let task = Task {
            await gate.wait()
            try await actor.write(configuration: configuration) { realm in
                realm.objects(CancelledWriteFixture.self).first?.value = "unexpected"
            }
        }
        task.cancel()
        await gate.release()
        do {
            try await task.value
            XCTFail("Cancelled caller must not be admitted")
        } catch is CancellationError { }
        let value = try await actor.cancellationFixtureValue(configuration)
        XCTAssertEqual(value, "original")
    }

    func testCancelledReferenceWriteDoesNotConsumeOrMutateItsObject() async throws {
        let actor = RealmBackgroundActor()
        let configuration = configuration()
        try await actor.seedCancellationFixture(configuration)
        let reference = try await actor.cancellationFixtureReference(configuration)
        let gate = CancelledWriteStartGate()
        let task = Task {
            await gate.wait()
            try await actor.write(reference, configuration: configuration) { _, object in
                object.value = "unexpected"
            }
        }
        task.cancel()
        await gate.release()
        do {
            try await task.value
            XCTFail("Cancelled reference caller must not be admitted")
        } catch is CancellationError { }
        // A cancelled submission did not resolve the single-use reference.
        try await actor.write(reference, configuration: configuration) { _, object in
            object.value = "successor"
        }
        let value = try await actor.cancellationFixtureValue(configuration)
        XCTAssertEqual(value, "successor")
    }

    func testCancelledConvenienceWriteDoesNotInvokeMutation() async throws {
        let configuration = configuration()
        let actor = RealmBackgroundActor.shared
        try await actor.seedCancellationFixture(configuration)
        let gate = CancelledWriteStartGate()
        let task = Task {
            await gate.wait()
            try await Realm.asyncWrite(configuration: configuration) { realm in
                realm.objects(CancelledWriteFixture.self).first?.value = "unexpected"
            }
        }
        task.cancel()
        await gate.release()
        do {
            try await task.value
            XCTFail("Cancelled convenience caller must not be admitted")
        } catch is CancellationError { }
        let value = try await actor.cancellationFixtureValue(configuration)
        XCTAssertEqual(value, "original")
        await actor.releaseCancellationFixtureCache(configuration)
    }

    private func configuration() -> Realm.Configuration {
        var configuration = Realm.Configuration()
        configuration.inMemoryIdentifier = "cancelled-write-\(UUID())"
        configuration.objectTypes = [CancelledWriteFixture.self]
        return configuration
    }
}

private extension RealmBackgroundActor {
    func seedCancellationFixture(_ configuration: Realm.Configuration) async throws {
        let realm = try await cachedRealm(for: configuration)
        try realm.write { realm.add(CancelledWriteFixture()) }
    }

    func cancellationFixtureValue(_ configuration: Realm.Configuration) async throws -> String? {
        let realm = try await cachedRealm(for: configuration)
        return realm.objects(CancelledWriteFixture.self).first?.value
    }

    func cancellationFixtureReference(_ configuration: Realm.Configuration) async throws -> ThreadSafeReference<CancelledWriteFixture> {
        let realm = try await cachedRealm(for: configuration)
        return ThreadSafeReference(to: try XCTUnwrap(realm.objects(CancelledWriteFixture.self).first))
    }

    func releaseCancellationFixtureCache(_ configuration: Realm.Configuration) {
        let keys = cachedRealms.keys.filter {
            cachedRealms[$0]?.configuration.inMemoryIdentifier == configuration.inMemoryIdentifier
        }
        for key in keys { cachedRealms.removeValue(forKey: key)?.invalidate() }
    }
}

@objc(RealmSwiftGapsCancelledWriteAdmissionFixture)
private final class CancelledWriteFixture: Object, @unchecked Sendable {
    @Persisted(primaryKey: true) var id = "fixture"
    @Persisted var value = "original"
    override class func shouldIncludeInDefaultSchema() -> Bool { false }
}
