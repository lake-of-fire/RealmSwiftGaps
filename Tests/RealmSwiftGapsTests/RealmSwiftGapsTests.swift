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
}
