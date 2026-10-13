import Foundation
import RealmSwift
import XCTest
@testable import RealmSwiftGaps

@objc(CapturedRealmStoreFixture20261013)
private final class CapturedRealmStoreFixture: Object {
    @Persisted(primaryKey: true) var id = "fixture"
    override class func shouldIncludeInDefaultSchema() -> Bool { false }
}

final class RealmStorageAdmissionTests: XCTestCase {
    @RealmBackgroundActor
    func testCapturedCreationKeepsScopeAndResolvesOneStore() async throws {
        let configuration = try makeConfiguration()
        defer { try? Realm.deleteFiles(for: configuration) }
        let actor = RealmBackgroundActor()
        let admission = actor.captureStorageAdmission(for: configuration)
        let scope = admission.scopeIdentity
        let first = try await actor.cachedRealm(for: configuration, storageAdmission: admission)
        let second = try await actor.cachedRealm(for: configuration, storageAdmission: admission)
        XCTAssertTrue(first === second)
        XCTAssertEqual(admission.scopeIdentity, scope)
        XCTAssertTrue(admission.matchesCurrentStorageIdentity { actor.realmCacheKey(for: configuration) })
    }

    @RealmBackgroundActor
    func testExternallyCreatedStoreCannotInheritMissingFileAdmission() async throws {
        let configuration = try makeConfiguration()
        defer { try? Realm.deleteFiles(for: configuration) }
        let actor = RealmBackgroundActor()
        let admission = actor.captureStorageAdmission(for: configuration)
        try autoreleasepool {
            let external = try Realm(configuration: configuration)
            try external.write { external.add(CapturedRealmStoreFixture()) }
        }
        XCTAssertFalse(admission.matchesCurrentStorageIdentity { actor.realmCacheKey(for: configuration) })
        do {
            _ = try await actor.cachedRealm(for: configuration, storageAdmission: admission)
            XCTFail("An external store inherited the captured creation")
        } catch RealmBackgroundActorError.realmFileChangedDuringOpen { }
    }

    @RealmBackgroundActor
    func testOverlappingMissingFileCapturesShareOnlyTheirOwnCreation() throws {
        let configuration = try makeConfiguration()
        defer { try? Realm.deleteFiles(for: configuration) }
        let actor = RealmBackgroundActor()
        let first = actor.captureStorageAdmission(for: configuration)
        let second = actor.captureStorageAdmission(for: configuration)
        XCTAssertTrue(first === second)
        let other = try makeConfiguration()
        defer { try? Realm.deleteFiles(for: other) }
        XCTAssertNotEqual(first.scopeIdentity, actor.captureStorageAdmission(for: other).scopeIdentity)
    }

    private func makeConfiguration() throws -> Realm.Configuration {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("captured-store-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = Realm.Configuration()
        configuration.fileURL = directory.appendingPathComponent("reader.realm")
        configuration.objectTypes = [CapturedRealmStoreFixture.self]
        return configuration
    }
}
