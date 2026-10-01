import Foundation
import RealmSwift
import XCTest
@testable import RealmSwiftGaps

@objc(RealmSwiftGapsOpenFenceObject)
private final class RealmOpenFenceObject: Object, @unchecked Sendable {
    @Persisted(primaryKey: true) var id = ""
}

private actor RealmOpenFenceSpecializedCache: CachedRealmsActor {
    private var realms = [String: Realm]()
    private(set) var openCount = 0

    func getCachedRealm(key: String) async -> Realm? { realms[key] }
    func setCachedRealm(_ realm: Realm, key: String) async { realms[key] = realm }

    func cachedRealm(for configuration: Realm.Configuration) async throws -> Realm {
        openCount += 1
        return try await Realm(configuration: configuration, actor: self)
    }
}

private extension CachedRealmsActor where Self: Actor {
    func realmThroughPortConvenienceAccessor(
        for configuration: Realm.Configuration
    ) async throws -> Realm {
        try await cachedRealm(for: configuration)
    }
}

private actor RealmOpenFenceSuspendedDefaultCache: CachedRealmsActor {
    nonisolated let publicationObserved = XCTestExpectation(
        description: "Default opener reached publication"
    )

    private var realms = [String: Realm]()
    private var lookupCount = 0
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func getCachedRealm(key: String) async -> Realm? {
        lookupCount += 1
        if lookupCount == 2, !released {
            publicationObserved.fulfill()
            await withCheckedContinuation { continuation = $0 }
        }
        return realms[key]
    }

    func setCachedRealm(_ realm: Realm, key: String) async {
        realms[key] = realm
    }

    func releasePublication() {
        released = true
        continuation?.resume()
        continuation = nil
    }

    func identifiers(
        for configuration: Realm.Configuration
    ) async throws -> [String] {
        let realm = try await cachedRealm(for: configuration)
        return realm.objects(RealmOpenFenceObject.self).map(\.id).sorted()
    }

    func cachedRealmCount() -> Int { realms.count }
}

private actor RealmOpenFenceBarrier {
    nonisolated let publicationObserved = XCTestExpectation(
        description: "Realm open reached publication"
    )
    nonisolated let joinObserved = XCTestExpectation(
        description: "Caller joined pending open"
    )
    nonisolated let waiterReturnObserved = XCTestExpectation(
        description: "Waiter resolved pending open"
    )

    private let suspendPublication: Bool
    private let suspendWaiterReturn: Bool
    private var eventCounts = [RealmCacheOpenEvent: Int]()
    private var releasedEvents = Set<RealmCacheOpenEvent>()
    private var suspensions =
        [RealmCacheOpenEvent: [CheckedContinuation<Void, Never>]]()

    init(
        suspendPublication: Bool = true,
        suspendWaiterReturn: Bool = false
    ) {
        self.suspendPublication = suspendPublication
        self.suspendWaiterReturn = suspendWaiterReturn
    }

    func observe(_ event: RealmCacheOpenEvent) async {
        eventCounts[event, default: 0] += 1
        if eventCounts[event] == 1 {
            switch event {
            case .openedBeforePublication:
                publicationObserved.fulfill()
            case .joinedPendingOpen:
                joinObserved.fulfill()
            case .waiterResolvedPendingOpen:
                waiterReturnObserved.fulfill()
            }
        }
        guard !releasedEvents.contains(event) else { return }
        switch event {
        case .openedBeforePublication where suspendPublication:
            await withCheckedContinuation {
                suspensions[event, default: []].append($0)
            }
        case .waiterResolvedPendingOpen where suspendWaiterReturn:
            await withCheckedContinuation {
                suspensions[event, default: []].append($0)
            }
        default:
            break
        }
    }

    func releasePublication() {
        release(.openedBeforePublication)
    }

    func releaseWaiter() {
        release(.waiterResolvedPendingOpen)
    }

    func releaseAll() {
        releasePublication()
        releaseWaiter()
    }

    func count(_ event: RealmCacheOpenEvent) -> Int {
        eventCounts[event, default: 0]
    }

    private func release(_ event: RealmCacheOpenEvent) {
        releasedEvents.insert(event)
        for continuation in suspensions.removeValue(forKey: event) ?? [] {
            continuation.resume()
        }
    }
}

private extension RealmBackgroundActor {
    func openFenceIdentifiers(
        for configuration: Realm.Configuration
    ) async throws -> [String] {
        let realm = try await cachedRealm(for: configuration)
        return realm.objects(RealmOpenFenceObject.self).map(\.id).sorted()
    }

    func createOpenFenceFixture(
        for configuration: Realm.Configuration,
        identifier: String
    ) async throws {
        let realm = try await Realm(configuration: configuration, actor: self)
        let object = RealmOpenFenceObject()
        object.id = identifier
        try realm.write { realm.add(object) }
        realm.invalidate()
    }

    func openFenceCachedRealmCount() -> Int {
        cachedRealms.count
    }
}

final class RealmOpenFencingPortTests: XCTestCase {
    private func diskConfigurations() throws -> (
        current: Realm.Configuration,
        replacement: Realm.Configuration
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "realm-open-fencing-port-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        var current = Realm.Configuration(
            fileURL: directory.appendingPathComponent("current.realm")
        )
        current.objectTypes = [RealmOpenFenceObject.self]
        var replacement = current
        replacement.fileURL = directory.appendingPathComponent("replacement.realm")
        return (current, replacement)
    }

    private func replaceFile(
        current: Realm.Configuration,
        replacement: Realm.Configuration
    ) throws {
        let currentURL = try XCTUnwrap(current.fileURL)
        let replacementURL = try XCTUnwrap(replacement.fileURL)
        try FileManager.default.moveItem(
            at: currentURL,
            to: currentURL.deletingLastPathComponent()
                .appendingPathComponent("retired.realm")
        )
        try FileManager.default.moveItem(
            at: replacementURL,
            to: currentURL
        )
    }

    private func assertFileChanged(
        _ task: Task<[String], Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await task.value
            XCTFail(
                "A Realm from the replaced file was returned",
                file: file,
                line: line
            )
        } catch RealmBackgroundActorError.realmFileChangedDuringOpen {
        } catch {
            XCTFail(
                "Unexpected cache open error: \(error)",
                file: file,
                line: line
            )
        }
    }

    func testConvenienceAccessorDispatchesThroughSpecializedActorOpener() async throws {
        let cache = RealmOpenFenceSpecializedCache()
        var configuration = Realm.Configuration()
        configuration.inMemoryIdentifier = "dispatch-\(UUID().uuidString)"
        configuration.objectTypes = [RealmOpenFenceObject.self]

        _ = try await cache.realmThroughPortConvenienceAccessor(
            for: configuration
        )

        XCTAssertEqual(await cache.openCount, 1)
    }

    func testMissingFileCreationCoalescesWaiterUnderCreatedIdentity() async throws {
        let configurations = try diskConfigurations()
        let barrier = RealmOpenFenceBarrier()
        defer { Task { await barrier.releaseAll() } }
        let cache = RealmBackgroundActor {
            await barrier.observe($0)
        }

        let missingKey = await cache.realmCacheKey(
            for: configurations.current
        )
        let owner = Task {
            try await cache.openFenceIdentifiers(
                for: configurations.current
            )
        }
        await fulfillment(
            of: [barrier.publicationObserved],
            timeout: 5
        )
        let createdKey = await cache.realmCacheKey(
            for: configurations.current
        )
        let waiter = Task {
            try await cache.openFenceIdentifiers(
                for: configurations.current
            )
        }
        await fulfillment(of: [barrier.joinObserved], timeout: 5)
        await barrier.releasePublication()

        XCTAssertEqual(try await owner.value, [])
        XCTAssertEqual(try await waiter.value, [])
        XCTAssertNotEqual(missingKey, createdKey)
        XCTAssertEqual(
            await barrier.count(.openedBeforePublication),
            1
        )
        XCTAssertEqual(await cache.openFenceCachedRealmCount(), 1)
        XCTAssertTrue(
            await cache.removeCachedRealm(for: configurations.current)
        )
    }

    func testSuspendedExistingFileOpenRejectsReplacementForOwnerAndWaiter() async throws {
        let configurations = try diskConfigurations()
        let fixtureActor = RealmBackgroundActor()
        try await fixtureActor.createOpenFenceFixture(
            for: configurations.current,
            identifier: "original"
        )
        try await fixtureActor.createOpenFenceFixture(
            for: configurations.replacement,
            identifier: "replacement"
        )

        let barrier = RealmOpenFenceBarrier()
        defer { Task { await barrier.releaseAll() } }
        let cache = RealmBackgroundActor {
            await barrier.observe($0)
        }
        let originalKey = await cache.realmCacheKey(
            for: configurations.current
        )
        let owner = Task {
            try await cache.openFenceIdentifiers(
                for: configurations.current
            )
        }
        await fulfillment(
            of: [barrier.publicationObserved],
            timeout: 5
        )
        let waiter = Task {
            try await cache.openFenceIdentifiers(
                for: configurations.current
            )
        }
        await fulfillment(of: [barrier.joinObserved], timeout: 5)

        try replaceFile(
            current: configurations.current,
            replacement: configurations.replacement
        )
        let replacementKey = await cache.realmCacheKey(
            for: configurations.current
        )
        await barrier.releasePublication()

        await assertFileChanged(owner)
        await assertFileChanged(waiter)
        XCTAssertNotEqual(originalKey, replacementKey)
        XCTAssertEqual(await cache.openFenceCachedRealmCount(), 0)

        let successor = try await cache.openFenceIdentifiers(
            for: configurations.current
        )
        XCTAssertEqual(successor, ["replacement"])
        XCTAssertTrue(
            await cache.removeCachedRealm(for: configurations.current)
        )
    }

    func testPendingWaiterCannotRetainRealmAfterScopedEviction() async throws {
        let configurations = try diskConfigurations()
        let barrier = RealmOpenFenceBarrier(
            suspendWaiterReturn: true
        )
        defer { Task { await barrier.releaseAll() } }
        let cache = RealmBackgroundActor {
            await barrier.observe($0)
        }

        let owner = Task {
            try await cache.openFenceIdentifiers(
                for: configurations.current
            )
        }
        await fulfillment(
            of: [barrier.publicationObserved],
            timeout: 5
        )
        let waiter = Task {
            try await cache.openFenceIdentifiers(
                for: configurations.current
            )
        }
        await fulfillment(of: [barrier.joinObserved], timeout: 5)
        await barrier.releasePublication()
        _ = try await owner.value
        await fulfillment(
            of: [barrier.waiterReturnObserved],
            timeout: 5
        )

        XCTAssertTrue(
            await cache.removeCachedRealm(for: configurations.current)
        )
        await barrier.releaseWaiter()

        do {
            _ = try await waiter.value
            XCTFail("A completed pending task retained an evicted Realm")
        } catch RealmBackgroundActorError.cachedRealmEvictedDuringOpen {
        }
    }

    func testDefaultProtocolOpenerRejectsReplacementAcrossSuspendedCacheLookup() async throws {
        let configurations = try diskConfigurations()
        let fixtureActor = RealmBackgroundActor()
        try await fixtureActor.createOpenFenceFixture(
            for: configurations.current,
            identifier: "original"
        )
        try await fixtureActor.createOpenFenceFixture(
            for: configurations.replacement,
            identifier: "replacement"
        )

        let cache = RealmOpenFenceSuspendedDefaultCache()
        defer { Task { await cache.releasePublication() } }
        let owner = Task {
            try await cache.identifiers(
                for: configurations.current
            )
        }
        await fulfillment(
            of: [cache.publicationObserved],
            timeout: 5
        )

        try replaceFile(
            current: configurations.current,
            replacement: configurations.replacement
        )
        await cache.releasePublication()

        await assertFileChanged(owner)
        XCTAssertEqual(await cache.cachedRealmCount(), 0)
        XCTAssertEqual(
            try await cache.identifiers(
                for: configurations.current
            ),
            ["replacement"]
        )
    }

    func testActiveVersionLimitParticipatesInConfigurationIdentity() async {
        let cache = RealmOpenFenceSpecializedCache()
        var baseline = Realm.Configuration()
        baseline.inMemoryIdentifier =
            "active-version-key-\(UUID().uuidString)"
        baseline.objectTypes = [RealmOpenFenceObject.self]
        var limited = baseline
        limited.maximumNumberOfActiveVersions = 10

        XCTAssertNotEqual(
            await cache.realmCacheKey(for: baseline),
            await cache.realmCacheKey(for: limited)
        )
    }
}
