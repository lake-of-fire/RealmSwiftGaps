import Foundation
import RealmSwift
import XCTest
@testable import RealmSwiftGaps

// Keep this private fixture out of the composed application's default schema.
@objc(ManabiRealmCacheLookupBoundaryObject20261005)
private final class CacheLookupBoundaryObject: Object {
    @Persisted(primaryKey: true) var id = ""

    override class func shouldIncludeInDefaultSchema() -> Bool { false }
}

private final class OpenMigrationLeaseProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var acquisitions = 0
    private var releases = 0
    private var expired = false
    private var migrationProtection = [Bool]()

    func acquire() -> RealmWriteExecutionLease {
        lock.withLock { active += 1; acquisitions += 1 }
        return RealmWriteExecutionLease(
            checkpoint: { if self.lock.withLock({ self.expired }) { throw CancellationError() } },
            installInterruptionHandler: { _ in },
            release: { self.lock.withLock { self.active -= 1; self.releases += 1 } })
    }

    func recordMigration() {
        lock.withLock { migrationProtection.append(active == 1 && releases == 0) }
    }

    func expire() { lock.withLock { expired = true } }

    func assertSettled(file: StaticString = #filePath, line: UInt = #line) {
        lock.withLock {
            XCTAssertEqual(migrationProtection, [true], file: file, line: line)
            XCTAssertEqual(acquisitions, 1, file: file, line: line)
            XCTAssertEqual(releases, 1, file: file, line: line)
            XCTAssertEqual(active, 0, file: file, line: line)
        }
    }
}

private actor SuspendedLookupCache: CachedRealmsActor {
    nonisolated let lookupCaptured = XCTestExpectation(description: "Cache captured lookup result")
    private var realms = [String: Realm]()
    private var shouldSuspendLookup = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func getCachedRealm(key: String) async -> Realm? {
        // A conformer may capture its cache hit before a real asynchronous
        // collaborator finishes. Return that exact captured value after release.
        let result = realms[key]
        if shouldSuspendLookup {
            shouldSuspendLookup = false
            lookupCaptured.fulfill()
            if !released {
                await withCheckedContinuation { continuation = $0 }
            }
        }
        return result
    }

    func setCachedRealm(_ realm: Realm, key: String) async { realms[key] = realm }

    func armLookup() { shouldSuspendLookup = true }

    func open(configuration: Realm.Configuration) async throws {
        _ = try await cachedRealm(for: configuration)
    }

    func releaseLookup() {
        released = true
        continuation?.resume()
        continuation = nil
    }

    func seed(_ identifier: String, configuration: Realm.Configuration) async throws {
        let realm = try await cachedRealm(for: configuration)
        try realm.write {
            let object = CacheLookupBoundaryObject()
            object.id = identifier
            realm.add(object)
        }
    }

    func lookupIdentifiers(configuration: Realm.Configuration) async -> [String]? {
        guard let realm = await existingCachedRealm(for: configuration) else { return nil }
        return realm.objects(CacheLookupBoundaryObject.self).map(\.id).sorted()
    }

    func retainedIdentifiers(key: String) -> [String]? {
        realms[key]?.objects(CacheLookupBoundaryObject.self).map(\.id).sorted()
    }

    func count() -> Int { realms.count }

    func releaseAll() {
        releaseLookup()
        for realm in realms.values { realm.invalidate() }
        realms.removeAll()
    }
}

/// Real Realm files and captured asynchronous cache reads. No supplied Realm
/// is adopted through a configuration-only setter, and no live Realm leaves
/// its actor. These require the native Realm package, not a Linux stand-in.
@MainActor
final class RealmCacheLookupBoundaryTests: XCTestCase {
    private func configuration(at url: URL) -> Realm.Configuration {
        var configuration = Realm.Configuration(fileURL: url)
        configuration.objectTypes = [CacheLookupBoundaryObject.self]
        return configuration
    }

    private func withFixture(
        _ body: (URL, SuspendedLookupCache, Realm.Configuration) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RealmCacheLookupBoundary-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cache = SuspendedLookupCache()
        let configuration = configuration(at: root.appendingPathComponent("original.realm"))
        do {
            try await body(root, cache, configuration)
        } catch {
            await cache.releaseAll()
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        await cache.releaseAll()
        try FileManager.default.removeItem(at: root)
    }

    func testDeniedExecutionPreventsDefaultCacheOpenFromCreatingRealm() async throws {
        try await withFixture { _, cache, configuration in
            do {
                try await RealmWriteExecutionProtection.$synchronousAcquisition.withValue({ throw CancellationError() }) {
                    try await cache.open(configuration: configuration)
                }
                XCTFail("Denied execution must reject the writable SDK open")
            } catch is CancellationError {}
            XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(configuration.fileURL).path))
            let count = await cache.count()
            XCTAssertEqual(count, 0)
        }
    }

    private func migrationConfiguration(
        from configuration: Realm.Configuration, probe: OpenMigrationLeaseProbe
    ) throws -> Realm.Configuration {
        try autoreleasepool {
            let realm = try Realm(configuration: configuration)
            try realm.write {
                let object = CacheLookupBoundaryObject()
                object.id = "before-migration"
                realm.add(object)
            }
            realm.invalidate()
        }
        var migrated = configuration
        migrated.schemaVersion = configuration.schemaVersion + 1
        migrated.migrationBlock = { migration, _ in
            probe.recordMigration()
            migration.enumerateObjects(ofType: CacheLookupBoundaryObject.className()) { _, object in
                object?["id"] = "after-migration"
            }
        }
        return migrated
    }

    func testSynchronousOpenRetainsExecutionThroughRealMigrationAndReleasesAfterward() async throws {
        try await withFixture { _, _, configuration in
            let probe = OpenMigrationLeaseProbe()
            let migrated = try self.migrationConfiguration(from: configuration, probe: probe)
            try RealmWriteExecutionProtection.$synchronousAcquisition.withValue({ probe.acquire() }) {
                let realm = try RealmWriteExecutionProtection.openRealm(configuration: migrated)
                XCTAssertEqual(realm.objects(CacheLookupBoundaryObject.self).first?.id, "after-migration")
                probe.assertSettled()
                realm.invalidate()
            }
        }
    }

    func testActorCacheOpenRetainsExecutionThroughRealMigrationAndReleasesAfterward() async throws {
        try await withFixture { _, cache, configuration in
            let probe = OpenMigrationLeaseProbe()
            let migrated = try self.migrationConfiguration(from: configuration, probe: probe)
            try await RealmWriteExecutionProtection.$synchronousAcquisition.withValue({ probe.acquire() }) {
                try await cache.open(configuration: migrated)
                probe.assertSettled()
                let identifiers = await cache.lookupIdentifiers(configuration: migrated)
                XCTAssertEqual(identifiers, ["after-migration"])
            }
        }
    }

    func testExecutionExpirationDuringMigrationSettlesWithoutPublishingCacheAndAllowsRetry() async throws {
        try await withFixture { _, cache, configuration in
            let probe = OpenMigrationLeaseProbe()
            var migrated = try self.migrationConfiguration(from: configuration, probe: probe)
            let migration = migrated.migrationBlock
            migrated.migrationBlock = { migrationContext, version in
                migration?(migrationContext, version)
                probe.expire()
            }
            do {
                try await RealmWriteExecutionProtection.$synchronousAcquisition.withValue({ probe.acquire() }) {
                    try await cache.open(configuration: migrated)
                }
                XCTFail("Expired execution must not publish the opened Realm")
            } catch is CancellationError {}
            probe.assertSettled()
            let count = await cache.count()
            XCTAssertEqual(count, 0)
            try await cache.open(configuration: migrated)
            let identifiers = await cache.lookupIdentifiers(configuration: migrated)
            XCTAssertEqual(identifiers, ["after-migration"], "Native migration settled before protection ended")
        }
    }

    func testDeniedExecutionPreventsSharedWriterOpenFromCreatingRealm() async throws {
        try await withFixture { _, _, configuration in
            do {
                try await RealmWriteExecutionProtection.$synchronousAcquisition.withValue({ throw CancellationError() }) {
                    try await RealmBackgroundActor.shared.write(configuration: configuration) { _ in
                        XCTFail("Denied execution must not enter the writer body")
                    }
                }
                XCTFail("Denied execution must reject the writer")
            } catch is CancellationError {}
            XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(configuration.fileURL).path))
            _ = await RealmBackgroundActor.shared.removeCachedRealm(for: configuration)
        }
    }

    func testMissingReadOnlyLookupDoesNotOpenOrCreateARealm() async throws {
        try await withFixture { _, cache, configuration in
            let identifiers = await cache.lookupIdentifiers(configuration: configuration)
            let count = await cache.count()
            XCTAssertNil(identifiers)
            XCTAssertEqual(count, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(configuration.fileURL).path))
        }
    }

    func testCurrentCachedRealmRemainsReadableWithoutAnotherInsertion() async throws {
        try await withFixture { _, cache, configuration in
            try await cache.seed("original", configuration: configuration)
            let identifiers = await cache.lookupIdentifiers(configuration: configuration)
            let count = await cache.count()
            XCTAssertEqual(identifiers, ["original"])
            XCTAssertEqual(count, 1)
        }
    }

    func testSamePathReplacementDuringLookupReturnsMissWithoutInvalidatingOldOwner() async throws {
        try await withFixture { root, cache, configuration in
            try await cache.seed("original", configuration: configuration)
            let originalKey = cache.realmCacheKey(for: configuration)
            let originalURL = try XCTUnwrap(configuration.fileURL)
            let replacementURL = root.appendingPathComponent("replacement.realm")
            let replacementCache = SuspendedLookupCache()
            do {
                try await replacementCache.seed("replacement", configuration: self.configuration(at: replacementURL))
            } catch {
                await replacementCache.releaseAll()
                throw error
            }
            await replacementCache.releaseAll()
            let replacementBytes = try Data(contentsOf: replacementURL)

            await cache.armLookup()
            let lookup = Task { await cache.lookupIdentifiers(configuration: configuration) }
            let observed = await XCTWaiter.fulfillment(of: [cache.lookupCaptured], timeout: 5)
            XCTAssertEqual(observed, .completed)
            do {
                try FileManager.default.moveItem(at: originalURL, to: root.appendingPathComponent("retained-original.realm"))
                try FileManager.default.moveItem(at: replacementURL, to: originalURL)
                XCTAssertNotEqual(cache.realmCacheKey(for: configuration), originalKey,
                    "This native fixture must actually replace the filesystem resource identity")
            } catch {
                await cache.releaseLookup()
                _ = await lookup.value
                throw error
            }
            await cache.releaseLookup()
            let result = await lookup.value
            XCTAssertNil(result, "The original Realm must not be returned as a hit for its replacement path")
            let retained = await cache.retainedIdentifiers(key: originalKey)
            let count = await cache.count()
            XCTAssertEqual(retained, ["original"], "A stale lookup must not invalidate another owner's Realm")
            XCTAssertEqual(count, 1, "Lookup is read-only; it must not publish or evict a cache entry")
            XCTAssertEqual(try Data(contentsOf: originalURL), replacementBytes)
        }
    }

    func testDisappearedPathDuringLookupReturnsMissAndRetainsOriginalOwner() async throws {
        try await withFixture { root, cache, configuration in
            try await cache.seed("original", configuration: configuration)
            let originalKey = cache.realmCacheKey(for: configuration)
            await cache.armLookup()
            let lookup = Task { await cache.lookupIdentifiers(configuration: configuration) }
            let observed = await XCTWaiter.fulfillment(of: [cache.lookupCaptured], timeout: 5)
            XCTAssertEqual(observed, .completed)
            do {
                try FileManager.default.moveItem(at: try XCTUnwrap(configuration.fileURL),
                    to: root.appendingPathComponent("retained-original.realm"))
                XCTAssertNotEqual(cache.realmCacheKey(for: configuration), originalKey)
            } catch {
                await cache.releaseLookup()
                _ = await lookup.value
                throw error
            }
            await cache.releaseLookup()
            let result = await lookup.value
            let retained = await cache.retainedIdentifiers(key: originalKey)
            XCTAssertNil(result)
            XCTAssertEqual(retained, ["original"])
            XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(configuration.fileURL).path))
        }
    }

    func testUnrelatedFileReplacementDoesNotWithdrawCurrentCacheHit() async throws {
        try await withFixture { root, cache, configuration in
            try await cache.seed("original", configuration: configuration)
            let originalKey = cache.realmCacheKey(for: configuration)
            let unrelated = root.appendingPathComponent("unrelated.txt")
            try Data("before".utf8).write(to: unrelated)
            await cache.armLookup()
            let lookup = Task { await cache.lookupIdentifiers(configuration: configuration) }
            let observed = await XCTWaiter.fulfillment(of: [cache.lookupCaptured], timeout: 5)
            XCTAssertEqual(observed, .completed)
            do {
                try Data("after".utf8).write(to: unrelated, options: .atomic)
            } catch {
                await cache.releaseLookup()
                _ = await lookup.value
                throw error
            }
            await cache.releaseLookup()
            let result = await lookup.value
            XCTAssertEqual(result, ["original"])
            XCTAssertEqual(cache.realmCacheKey(for: configuration), originalKey)
        }
    }

    func testInMemoryCacheLookupDoesNotDependOnUnrelatedDiskState() async throws {
        try await withFixture { root, cache, _ in
            var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
            configuration.objectTypes = [CacheLookupBoundaryObject.self]
            try await cache.seed("memory", configuration: configuration)
            let originalKey = cache.realmCacheKey(for: configuration)
            let unrelated = root.appendingPathComponent("unrelated.realm")
            try Data("unrelated".utf8).write(to: unrelated)
            let result = await cache.lookupIdentifiers(configuration: configuration)
            XCTAssertEqual(result, ["memory"])
            XCTAssertEqual(cache.realmCacheKey(for: configuration), originalKey)
        }
    }
}
