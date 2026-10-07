import Foundation
import RealmSwift
import XCTest
@testable import RealmSwiftGaps

@objc(GapsConfigurationCacheIdentityFixture)
private final class ConfigurationCacheIdentityFixture: Object {
    @Persisted(primaryKey: true) var id = "identity"
    override class func shouldIncludeInDefaultSchema() -> Bool { false }
}

final class RealmConfigurationCacheIdentityTests: XCTestCase {
    @RealmBackgroundActor
    func testUnlimitedAliasesRetainCachedWriterAndAdmissionAfterRoundTrip() async throws {
        let actor = RealmBackgroundActor.shared
        var base = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        base.objectTypes = [ConfigurationCacheIdentityFixture.self]
        let fixtureConfiguration = base
        addTeardownBlock {
            await Task { @RealmBackgroundActor in
                _ = await RealmBackgroundActor.shared.removeCachedRealm(for: fixtureConfiguration)
            }.value
        }
        let realm = try await actor.cachedRealm(for: base)
        let key = actor.realmCacheKey(for: base)
        for limit: UInt? in [nil, 0, UInt.max] {
            var alias = realm.configuration
            alias.maximumNumberOfActiveVersions = limit
            XCTAssertEqual(actor.realmCacheKey(for: alias), key)
            let retained = try await actor.cachedRealm(for: alias)
            XCTAssertTrue(ObjectiveCSupport.convert(object: retained)
                === ObjectiveCSupport.convert(object: realm))
            try await retained.asyncWritePreservingOwnership {
                let row = ConfigurationCacheIdentityFixture()
                row.id = String(describing: limit)
                retained.add(row)
            }
        }
        XCTAssertEqual(realm.objects(ConfigurationCacheIdentityFixture.self).count, 3)
        var finite = base
        finite.maximumNumberOfActiveVersions = 10
        XCTAssertNotEqual(actor.realmCacheKey(for: finite), key)
        _ = await actor.removeCachedRealm(for: base)
    }

    @RealmBackgroundActor
    func testActiveVersionAuthoritySurvivesNativeConfigurationRoundTrip() async throws {
        let actor = RealmBackgroundActor.shared
        let limits: [UInt?] = [nil, 0, UInt.max, 10]
        for limit in limits {
            var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
            configuration.objectTypes = [ConfigurationCacheIdentityFixture.self]
            configuration.maximumNumberOfActiveVersions = limit
            let fixtureConfiguration = configuration
            addTeardownBlock {
                await Task { @RealmBackgroundActor in
                    _ = await RealmBackgroundActor.shared.removeCachedRealm(for: fixtureConfiguration)
                }.value
            }
            let originalKey = actor.realmCacheKey(for: configuration)
            let realm = try await actor.cachedRealm(for: configuration)
            let restoredKey = actor.realmCacheKey(for: realm.configuration)
            XCTAssertEqual(originalKey, restoredKey, "Native configuration must preserve storage authority for limit \(String(describing: limit))")
            var differentLimit = realm.configuration
            differentLimit.maximumNumberOfActiveVersions = limit == 10 ? 11 : 10
            XCTAssertNotEqual(originalKey, actor.realmCacheKey(for: differentLimit))
            _ = await actor.removeCachedRealm(for: configuration)
        }
    }
}
