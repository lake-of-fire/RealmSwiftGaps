import XCTest
import RealmSwift
@testable import RealmSwiftGaps

private actor TestRealmCache: CachedRealmsActor {
    private var realms = [String: Realm]()

    func getCachedRealm(key: String) async -> Realm? { realms[key] }
    func setCachedRealm(_ realm: Realm, key: String) async { realms[key] = realm }
}

final class FirstCachedRealmObject: Object {
    @Persisted(primaryKey: true) var id = ""
}

final class SecondCachedRealmObject: Object {
    @Persisted(primaryKey: true) var id = ""
}

final class RealmSwiftGapsTests: XCTestCase {
    func testRealmCacheKeysUseStandardizedFullPathsAndSeparateMemoryNamespace() async {
        let cache = TestRealmCache()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let firstURL = root.appendingPathComponent("first/shared.realm")
        let secondURL = root.appendingPathComponent("second/shared.realm")
        let first = Realm.Configuration(fileURL: firstURL)
        let equivalentFirst = Realm.Configuration(fileURL: root.appendingPathComponent("first/../first/shared.realm"))
        let second = Realm.Configuration(fileURL: secondURL)
        var memory = Realm.Configuration()
        memory.inMemoryIdentifier = "shared.realm"

        let firstKey = await cache.realmCacheKey(for: first)
        let equivalentFirstKey = await cache.realmCacheKey(for: equivalentFirst)
        let secondKey = await cache.realmCacheKey(for: second)
        let memoryKey = await cache.realmCacheKey(for: memory)

        XCTAssertEqual(firstKey, equivalentFirstKey)
        XCTAssertNotEqual(firstKey, secondKey)
        XCTAssertTrue(firstKey.hasPrefix(
            "file:\(firstURL.standardizedFileURL.path):"
        ))
        XCTAssertTrue(memoryKey.hasPrefix("memory:shared.realm|"))
    }

    func testRealmCacheKeysFenceConfigurationAuthority() async {
        let cache = TestRealmCache()
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("realm-cache-\(UUID().uuidString).realm")
        var baseline = Realm.Configuration(fileURL: fileURL)
        baseline.objectTypes = [FirstCachedRealmObject.self]
        var revisedSchema = baseline
        revisedSchema.schemaVersion += 1
        var readOnly = baseline
        readOnly.readOnly = true
        var revisedObjects = baseline
        revisedObjects.objectTypes = [SecondCachedRealmObject.self]
        var encrypted = baseline
        encrypted.encryptionKey = Data(repeating: 7, count: 64)

        let baselineKey = await cache.realmCacheKey(for: baseline)
        let keys = [
            await cache.realmCacheKey(for: revisedSchema),
            await cache.realmCacheKey(for: readOnly),
            await cache.realmCacheKey(for: revisedObjects),
            await cache.realmCacheKey(for: encrypted),
        ]

        XCTAssertTrue(keys.allSatisfy { $0 != baselineKey })
    }

    func testRealmBackgroundActorCoalescesConcurrentInitialOpens() async throws {
        let identifier = "concurrent-open-\(UUID().uuidString)"
        var configuration = Realm.Configuration()
        configuration.inMemoryIdentifier = identifier
        configuration.objectTypes = [FirstCachedRealmObject.self]

        let realms = try await withThrowingTaskGroup(of: Realm.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    try await RealmBackgroundActor.shared.cachedRealm(
                        for: configuration
                    )
                }
            }

            var opened = [Realm]()
            for try await realm in group {
                opened.append(realm)
            }
            return opened
        }

        XCTAssertEqual(realms.count, 12)
        XCTAssertEqual(
            Set(realms.compactMap { $0.configuration.inMemoryIdentifier }),
            Set([identifier])
        )
        await RealmBackgroundActor.shared.removeCachedRealm(for: configuration)
    }

    func testNewDiskRealmCanBeFoundAndEvictedAfterItsFileAppears() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("realm-cache-\(UUID().uuidString).realm")
        var configuration = Realm.Configuration(fileURL: fileURL)
        configuration.objectTypes = [FirstCachedRealmObject.self]
        let actor = RealmBackgroundActor.shared

        _ = try await actor.cachedRealm(for: configuration)
        let currentKey = await actor.realmCacheKey(for: configuration)
        let cached = await actor.getCachedRealm(key: currentKey)
        XCTAssertNotNil(cached)

        await actor.removeCachedRealm(for: configuration)
        let evicted = await actor.getCachedRealm(key: currentKey)
        XCTAssertNil(evicted)
    }

    func testPendingDiskRealmIdentitySurvivesFileCreation() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("realm-pending-\(UUID().uuidString).realm")
        var configuration = Realm.Configuration(fileURL: fileURL)
        configuration.objectTypes = [FirstCachedRealmObject.self]
        let actor = RealmBackgroundActor.shared
        let pendingBefore = await actor.realmCacheKey(
            for: configuration, includingFileResourceIdentifier: false
        )
        let completedBefore = await actor.realmCacheKey(for: configuration)

        _ = try await actor.cachedRealm(for: configuration)

        let pendingAfter = await actor.realmCacheKey(
            for: configuration, includingFileResourceIdentifier: false
        )
        let completedAfter = await actor.realmCacheKey(for: configuration)
        XCTAssertEqual(pendingBefore, pendingAfter)
        XCTAssertNotEqual(completedBefore, completedAfter)
        await actor.removeCachedRealm(for: configuration)
    }

}
