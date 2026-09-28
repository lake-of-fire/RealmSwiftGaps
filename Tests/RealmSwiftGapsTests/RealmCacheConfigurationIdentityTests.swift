import Foundation
import RealmSwift
import XCTest
@testable import RealmSwiftGaps

private actor ConfigurationIdentityRealmCache: @preconcurrency CachedRealmsActor {
    private var realms = [String: Realm]()
    private var storeCount = 0

    func getCachedRealm(key: String) async -> Realm? { realms[key] }
    func setCachedRealm(_ realm: Realm, key: String) async {
        realms[key] = realm
        storeCount += 1
    }

    func cacheRejectsDifferentSchema() async throws -> Bool {
        var configuration = Realm.Configuration()
        configuration.inMemoryIdentifier = UUID().uuidString
        configuration.objectTypes = [FirstConfigurationIdentityObject.self]
        let original = try await cachedRealm(for: configuration)
        let repeated = try await cachedRealm(for: configuration)
        var revised = configuration
        revised.schemaVersion += 1
        let mismatched = await existingCachedRealm(for: revised)
        // Realm is a struct; its Equatable implementation compares the wrapped
        // native Realm. Also prove the actor cache was not populated twice.
        return original == repeated && mismatched == nil && storeCount == 1
    }
}

@objc(RealmSwiftGapsFirstConfigurationIdentityObject)
private final class FirstConfigurationIdentityObject: Object, @unchecked Sendable {
    @Persisted(primaryKey: true) var id = ""
}

@objc(RealmSwiftGapsSecondConfigurationIdentityObject)
private final class SecondConfigurationIdentityObject: Object, @unchecked Sendable {
    @Persisted(primaryKey: true) var id = ""
}

final class RealmCacheConfigurationIdentityTests: XCTestCase {
    func testStandardizedPathsAndMemoryNamespace() {
        let cache = ConfigurationIdentityRealmCache()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = Realm.Configuration(fileURL: root.appendingPathComponent("first/shared.realm"))
        let equivalent = Realm.Configuration(fileURL: root.appendingPathComponent("first/../first/shared.realm"))
        let second = Realm.Configuration(fileURL: root.appendingPathComponent("second/shared.realm"))
        var memory = Realm.Configuration()
        memory.inMemoryIdentifier = "shared.realm"

        let firstKey = cache.realmCacheKey(for: first)
        let equivalentKey = cache.realmCacheKey(for: equivalent)
        let secondKey = cache.realmCacheKey(for: second)
        let memoryKey = cache.realmCacheKey(for: memory)
        XCTAssertEqual(firstKey, equivalentKey)
        XCTAssertNotEqual(firstKey, secondKey)
        XCTAssertNotEqual(firstKey, memoryKey)
    }

    func testConfigurationChangesCannotReuseCacheIdentity() {
        let cache = ConfigurationIdentityRealmCache()
        var baseline = Realm.Configuration()
        baseline.inMemoryIdentifier = UUID().uuidString
        baseline.objectTypes = [FirstConfigurationIdentityObject.self]
        var schema = baseline
        schema.schemaVersion += 1
        var readOnly = baseline
        readOnly.readOnly = true
        var objects = baseline
        objects.objectTypes = [SecondConfigurationIdentityObject.self]
        var encrypted = baseline
        encrypted.encryptionKey = Data(repeating: 7, count: 64)
        var deleteOnMigration = baseline
        deleteOnMigration.deleteRealmIfMigrationNeeded = true
        var seeded = baseline
        seeded.seedFilePath = FileManager.default.temporaryDirectory.appendingPathComponent("seed.realm")

        let baselineKey = cache.realmCacheKey(for: baseline)
        for configuration in [schema, readOnly, objects, encrypted, deleteOnMigration, seeded] {
            let key = cache.realmCacheKey(for: configuration)
            XCTAssertNotEqual(key, baselineKey)
        }
        var otherEncryption = encrypted
        otherEncryption.encryptionKey = Data(repeating: 8, count: 64)
        let encryptedKey = cache.realmCacheKey(for: encrypted)
        let otherEncryptedKey = cache.realmCacheKey(for: otherEncryption)
        XCTAssertNotEqual(encryptedKey, otherEncryptedKey)
    }

    func testExplicitObjectOrderIsIrrelevantButAutomaticSchemaIsDistinct() {
        let cache = ConfigurationIdentityRealmCache()
        var automatic = Realm.Configuration()
        automatic.inMemoryIdentifier = UUID().uuidString
        automatic.objectTypes = nil
        var empty = automatic
        empty.objectTypes = []
        var firstOrder = automatic
        firstOrder.objectTypes = [FirstConfigurationIdentityObject.self, SecondConfigurationIdentityObject.self]
        var secondOrder = automatic
        secondOrder.objectTypes = [SecondConfigurationIdentityObject.self, FirstConfigurationIdentityObject.self]

        let automaticKey = cache.realmCacheKey(for: automatic)
        let emptyKey = cache.realmCacheKey(for: empty)
        let firstKey = cache.realmCacheKey(for: firstOrder)
        let secondKey = cache.realmCacheKey(for: secondOrder)
        XCTAssertNotEqual(automaticKey, emptyKey)
        XCTAssertNotEqual(automaticKey, firstKey)
        XCTAssertEqual(firstKey, secondKey)
    }

    func testEquivalentSeedPathsHaveSameIdentity() {
        let cache = ConfigurationIdentityRealmCache()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var first = Realm.Configuration()
        first.inMemoryIdentifier = UUID().uuidString
        first.seedFilePath = root.appendingPathComponent("seeds/initial.realm")
        var second = first
        second.seedFilePath = root.appendingPathComponent("seeds/../seeds/initial.realm")
        let firstKey = cache.realmCacheKey(for: first)
        let secondKey = cache.realmCacheKey(for: second)
        XCTAssertEqual(firstKey, secondKey)
    }

    func testReplacingFileAtSamePathChangesIdentity() throws {
        let cache = ConfigurationIdentityRealmCache()
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("reader.realm")
        let configuration = Realm.Configuration(fileURL: fileURL)
        let missingKey = cache.realmCacheKey(for: configuration)
        // No Realm is opened here: this exercises filesystem identity, not migration.
        try Data([1]).write(to: fileURL)
        XCTAssertNotNil(try fileURL.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier)
        let firstKey = cache.realmCacheKey(for: configuration)
        // Retain the original inode at another path to avoid inode-reuse ambiguity.
        try manager.moveItem(at: fileURL, to: root.appendingPathComponent("previous.realm"))
        try Data([2]).write(to: fileURL)
        let replacementKey = cache.realmCacheKey(for: configuration)
        XCTAssertNotEqual(missingKey, firstKey)
        XCTAssertNotEqual(firstKey, replacementKey)
    }

    func testCachedRealmRejectsDifferentSchemaWithoutOpeningIt() async throws {
        let cache = ConfigurationIdentityRealmCache()
        let rejected = try await cache.cacheRejectsDifferentSchema()
        XCTAssertTrue(rejected)
    }
}
