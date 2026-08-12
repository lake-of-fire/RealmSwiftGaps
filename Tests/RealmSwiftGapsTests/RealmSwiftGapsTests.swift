import XCTest
import RealmSwift
@testable import RealmSwiftGaps

private actor TestRealmCache: @preconcurrency CachedRealmsActor {
    private var realms = [String: Realm]()

    func getCachedRealm(key: String) async -> Realm? {
        realms[key]
    }

    func setCachedRealm(_ realm: Realm, key: String) async {
        realms[key] = realm
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

    @MainActor
    func testRealmCache_separatesFullFilePathsAndInMemoryNamespace() async throws {
        let cache = TestRealmCache()
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let firstFileConfiguration = Realm.Configuration(
            fileURL: root.appendingPathComponent("first/shared.realm")
        )
        let equivalentFirstFileConfiguration = Realm.Configuration(
            fileURL: root.appendingPathComponent("first/../first/shared.realm")
        )
        let secondFileConfiguration = Realm.Configuration(
            fileURL: root.appendingPathComponent("second/shared.realm")
        )
        var memoryConfiguration = Realm.Configuration()
        memoryConfiguration.inMemoryIdentifier = "shared.realm"

        let firstRealm = try await Realm(configuration: inMemoryConfiguration(named: "first"))
        let secondRealm = try await Realm(configuration: inMemoryConfiguration(named: "second"))
        let memoryRealm = try await Realm(configuration: inMemoryConfiguration(named: "memory"))

        await cache.setCachedRealm(firstRealm, for: firstFileConfiguration)
        await cache.setCachedRealm(secondRealm, for: secondFileConfiguration)
        await cache.setCachedRealm(memoryRealm, for: memoryConfiguration)

        let equivalentFirstResult = await cache.existingCachedRealm(for: equivalentFirstFileConfiguration)
        let cachedSecondResult = await cache.existingCachedRealm(for: secondFileConfiguration)
        let cachedMemoryResult = await cache.existingCachedRealm(for: memoryConfiguration)
        let equivalentFirstRealm = try XCTUnwrap(equivalentFirstResult)
        let cachedSecondRealm = try XCTUnwrap(cachedSecondResult)
        let cachedMemoryRealm = try XCTUnwrap(cachedMemoryResult)

        XCTAssertEqual(
            equivalentFirstRealm.configuration.inMemoryIdentifier,
            firstRealm.configuration.inMemoryIdentifier
        )
        XCTAssertEqual(
            cachedSecondRealm.configuration.inMemoryIdentifier,
            secondRealm.configuration.inMemoryIdentifier
        )
        XCTAssertEqual(
            cachedMemoryRealm.configuration.inMemoryIdentifier,
            memoryRealm.configuration.inMemoryIdentifier
        )
    }

    private func inMemoryConfiguration(named name: String) -> Realm.Configuration {
        var configuration = Realm.Configuration()
        configuration.inMemoryIdentifier = "RealmSwiftGapsTests.\(name).\(UUID().uuidString)"
        return configuration
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
