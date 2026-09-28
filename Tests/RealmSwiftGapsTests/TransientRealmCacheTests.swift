import Foundation
import RealmSwift
import XCTest
@testable import RealmSwiftGaps

final class TransientRealmCacheTests: XCTestCase {
    func testReleaseIsScopedAndInvalidatesOnlyItsObjects() async throws {
        let actor = RealmBackgroundActor()
        let result = try await actor.exerciseScopedRelease()
        XCTAssertTrue(result.removed)
        XCTAssertTrue(result.selectedObjectInvalidated)
        XCTAssertTrue(result.otherObjectValid)
        XCTAssertEqual(result.remainingCount, 1)
    }

    func testRepeatedReleaseAndMissingEntryAreNoOps() async throws {
        let actor = RealmBackgroundActor()
        let result = try await actor.exerciseRepeatedRelease()
        XCTAssertEqual(result, [false, true, false])
    }

    func testReleaseDuringWriteDoesNotCancelTransactionOrEvictCache() async throws {
        let actor = RealmBackgroundActor()
        let result = try await actor.exerciseWriteRefusal()
        XCTAssertFalse(result.removed)
        XCTAssertTrue(result.transactionStayedOpen)
        XCTAssertEqual(result.persistedValue, "committed")
        XCTAssertEqual(result.cachedCount, 1)
    }

    func testReleasedFileRealmCanBeReopenedWithoutDeletingItsData() async throws {
        let actor = RealmBackgroundActor()
        let result = try await actor.exerciseFileReopen()
        XCTAssertTrue(result.removed)
        XCTAssertEqual(result.countAfterRemoval, 0)
        XCTAssertEqual(result.reopenedValue, "retained")
        XCTAssertEqual(result.countAfterReopen, 1)
    }

    func testDifferentConfigurationCannotReleaseCurrentRealm() async throws {
        let actor = RealmBackgroundActor()
        let result = try await actor.exerciseConfigurationMismatch()
        XCTAssertFalse(result.removed)
        XCTAssertEqual(result.cachedCount, 1)
        XCTAssertTrue(result.objectValid)
    }
}

private extension RealmBackgroundActor {
    func makeTransientConfiguration() -> Realm.Configuration {
        var configuration = Realm.Configuration()
        configuration.inMemoryIdentifier = UUID().uuidString
        configuration.objectTypes = [TransientCacheObject.self]
        return configuration
    }

    func exerciseScopedRelease() async throws -> (
        removed: Bool, selectedObjectInvalidated: Bool, otherObjectValid: Bool, remainingCount: Int
    ) {
        let firstConfiguration = makeTransientConfiguration()
        let secondConfiguration = makeTransientConfiguration()
        let first = try await cachedRealm(for: firstConfiguration)
        let second = try await cachedRealm(for: secondConfiguration)
        let selectedObject = TransientCacheObject()
        let otherObject = TransientCacheObject()
        try first.write { first.add(selectedObject) }
        try second.write { second.add(otherObject) }
        let removed = removeCachedRealm(for: firstConfiguration)
        return (removed, selectedObject.isInvalidated, !otherObject.isInvalidated, cachedRealms.count)
    }

    func exerciseRepeatedRelease() async throws -> [Bool] {
        let configuration = makeTransientConfiguration()
        let missing = removeCachedRealm(for: configuration)
        _ = try await cachedRealm(for: configuration)
        let removed = removeCachedRealm(for: configuration)
        return [missing, removed, removeCachedRealm(for: configuration)]
    }

    func exerciseWriteRefusal() async throws -> (
        removed: Bool, transactionStayedOpen: Bool, persistedValue: String?, cachedCount: Int
    ) {
        let configuration = makeTransientConfiguration()
        let realm = try await cachedRealm(for: configuration)
        var removed = true
        var transactionStayedOpen = false
        try realm.write {
            let object = TransientCacheObject()
            object.value = "committed"
            realm.add(object)
            removed = removeCachedRealm(for: configuration)
            transactionStayedOpen = realm.isInWriteTransaction
        }
        return (removed, transactionStayedOpen, realm.objects(TransientCacheObject.self).first?.value, cachedRealms.count)
    }

    func exerciseFileReopen() async throws -> (
        removed: Bool, countAfterRemoval: Int, reopenedValue: String?, countAfterReopen: Int
    ) {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("TransientRealmCache-\(UUID().uuidString)")
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: directory) }
        var configuration = Realm.Configuration(fileURL: directory.appendingPathComponent("cache.realm"))
        configuration.objectTypes = [TransientCacheObject.self]
        let realm = try await cachedRealm(for: configuration)
        try realm.write {
            let object = TransientCacheObject()
            object.value = "retained"
            realm.add(object)
        }
        let removed = removeCachedRealm(for: configuration)
        let countAfterRemoval = cachedRealms.count
        let reopened = try await cachedRealm(for: configuration)
        let value = reopened.objects(TransientCacheObject.self).first?.value
        let countAfterReopen = cachedRealms.count
        // Explicitly release this isolated fixture before its directory cleanup.
        removeCachedRealm(for: configuration)
        return (removed, countAfterRemoval, value, countAfterReopen)
    }

    func exerciseConfigurationMismatch() async throws -> (removed: Bool, cachedCount: Int, objectValid: Bool) {
        let configuration = makeTransientConfiguration()
        let realm = try await cachedRealm(for: configuration)
        let object = TransientCacheObject()
        try realm.write { realm.add(object) }
        var different = configuration
        different.schemaVersion += 1
        let removed = removeCachedRealm(for: different)
        return (removed, cachedRealms.count, !object.isInvalidated)
    }
}

@objc(RealmSwiftGapsTransientCacheObject)
private final class TransientCacheObject: Object, @unchecked Sendable {
    @Persisted(primaryKey: true) var id = UUID().uuidString
    @Persisted var value = ""
}
