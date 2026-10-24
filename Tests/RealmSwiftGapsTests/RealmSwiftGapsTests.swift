import Foundation
import XCTest
import RealmSwift
@testable import RealmSwiftGaps

private struct CacheIdentityResults: Sendable {
    let equivalentPathReusesRealm: Bool
    let differentDirectoriesUseDifferentRealms: Bool
    let memoryUsesSeparateRealm: Bool
    let existingProbesReuseOpenedRealms: Bool
    let cacheEntryCount: Int
}

private actor TestRealmCache: CachedRealmsActor {
    private var realms = [String: Realm]()

    func getCachedRealm(key: String) async -> Realm? {
        realms[key]
    }

    func setCachedRealm(_ realm: Realm, key: String) async {
        realms[key] = realm
    }

    func exerciseStorageNamespaces(in root: URL) async throws -> CacheIdentityResults {
        defer { realms.removeAll() }
        let manager = FileManager.default
        let firstDirectory = root.appendingPathComponent("first", isDirectory: true)
        let secondDirectory = root.appendingPathComponent("second", isDirectory: true)
        try manager.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
        try manager.createDirectory(at: secondDirectory, withIntermediateDirectories: true)

        // Use the same basename in both directories and the memory namespace,
        // but isolate this test from other concurrently running memory Realms.
        let name = "shared-\(UUID().uuidString).realm"
        let firstURL = firstDirectory.appendingPathComponent(name)
        let secondURL = secondDirectory.appendingPathComponent(name)
        var firstConfiguration = Realm.Configuration(fileURL: firstURL)
        firstConfiguration.objectTypes = [StringPrimaryKeyObject.self]
        var equivalentConfiguration = firstConfiguration
        equivalentConfiguration.fileURL = root.appendingPathComponent("first/../first/\(name)")
        var secondConfiguration = firstConfiguration
        secondConfiguration.fileURL = secondURL
        var memoryConfiguration = firstConfiguration
        memoryConfiguration.inMemoryIdentifier = name

        // Every handle is opened, cached and inspected on its actual owner.
        // No externally opened Realm is adopted under a different configuration.
        let firstRealm = try await cachedRealm(for: firstConfiguration)
        let equivalentRealm = try await cachedRealm(for: equivalentConfiguration)
        let secondRealm = try await cachedRealm(for: secondConfiguration)
        let memoryRealm = try await cachedRealm(for: memoryConfiguration)
        let existingFirst = await existingCachedRealm(for: equivalentConfiguration)
        let existingSecond = await existingCachedRealm(for: secondConfiguration)
        let existingMemory = await existingCachedRealm(for: memoryConfiguration)

        return CacheIdentityResults(
            equivalentPathReusesRealm: firstRealm == equivalentRealm,
            differentDirectoriesUseDifferentRealms: firstRealm != secondRealm,
            memoryUsesSeparateRealm: memoryRealm != firstRealm && memoryRealm != secondRealm,
            existingProbesReuseOpenedRealms:
                existingFirst == firstRealm && existingSecond == secondRealm && existingMemory == memoryRealm,
            cacheEntryCount: realms.count
        )
    }
}

final class RealmSwiftGapsTests: XCTestCase {
    func testURLPersistableValue_roundTripsAbsoluteString() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/path?q=reader#section"))

        XCTAssertEqual(url.persistableValue, "https://example.com/path?q=reader#section")
        XCTAssertEqual(URL(persistedValue: url.persistableValue), url)
    }

    func testURLPersistedValue_emptyStringUsesAboutBlank() throws {
        XCTAssertEqual(URL(persistedValue: ""), URL(string: "about:blank"))
        XCTAssertEqual(URL._rlmDefaultValue(), URL(string: "about:blank"))
    }

    func testObjectPrimaryKeyValue_supportsStringAndUUIDPrimaryKeys() throws {
        let stringObject = StringPrimaryKeyObject()
        stringObject.id = "reader"

        let uuid = UUID()
        let uuidObject = UUIDPrimaryKeyObject()
        uuidObject.id = uuid

        XCTAssertEqual(stringObject.primaryKeyValue, "reader")
        XCTAssertEqual(uuidObject.primaryKeyValue, uuid.uuidString)
        XCTAssertTrue(stringObject.isSameObjectByPrimaryKey(as: StringPrimaryKeyObject(value: ["id": "reader"])))
        XCTAssertFalse(stringObject.isSameObjectByPrimaryKey(as: StringPrimaryKeyObject(value: ["id": "other"])))
    }

    func testRealmCache_separatesFullFilePathsAndInMemoryNamespace() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let cache = TestRealmCache()
        let result = try await cache.exerciseStorageNamespaces(in: root)
        XCTAssertTrue(result.equivalentPathReusesRealm)
        XCTAssertTrue(result.differentDirectoriesUseDifferentRealms)
        XCTAssertTrue(result.memoryUsesSeparateRealm)
        XCTAssertTrue(result.existingProbesReuseOpenedRealms)
        XCTAssertEqual(result.cacheEntryCount, 3)
    }
}

@objc(RealmSwiftGapsStringPrimaryKeyObject)
private final class StringPrimaryKeyObject: Object, @unchecked Sendable {
    @Persisted(primaryKey: true) var id = ""
}

@objc(RealmSwiftGapsUUIDPrimaryKeyObject)
private final class UUIDPrimaryKeyObject: Object, @unchecked Sendable {
    @Persisted(primaryKey: true) var id = UUID()
}
