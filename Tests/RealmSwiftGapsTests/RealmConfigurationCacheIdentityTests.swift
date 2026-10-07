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
    func testActiveVersionAuthoritySurvivesNativeConfigurationRoundTrip() async throws {
        let actor = RealmBackgroundActor.shared
        let limits: [UInt?] = [nil, 0, UInt.max, 10]
        for limit in limits {
            var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
            configuration.objectTypes = [ConfigurationCacheIdentityFixture.self]
            configuration.maximumNumberOfActiveVersions = limit
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
