import XCTest
import RealmSwift
@testable import RealmSwiftGaps

private actor TestRealmCache: CachedRealmsActor {
    private var realms = [String: Realm]()

    func getCachedRealm(key: String) async -> Realm? { realms[key] }
    func setCachedRealm(_ realm: Realm, key: String) async { realms[key] = realm }
}

private actor SpecializedRealmCache: CachedRealmsActor {
    private var realms = [String: Realm]()
    private(set) var openCount = 0

    func getCachedRealm(key: String) async -> Realm? { realms[key] }
    func setCachedRealm(_ realm: Realm, key: String) async { realms[key] = realm }

    func cachedRealm(for configuration: Realm.Configuration) async throws -> Realm {
        openCount += 1
        return try await Realm(configuration: configuration, actor: self)
    }
}

private actor SuspendedDefaultRealmCache: CachedRealmsActor {
    nonisolated let publicationObserved = XCTestExpectation(description: "Default opener reached publication")
    private var realms = [String: Realm]()
    private var lookupCount = 0
    private var publicationContinuation: CheckedContinuation<Void, Never>?
    private var released = false

    func getCachedRealm(key: String) async -> Realm? {
        lookupCount += 1
        if lookupCount == 2, !released {
            publicationObserved.fulfill()
            await withCheckedContinuation { publicationContinuation = $0 }
        }
        return realms[key]
    }

    func setCachedRealm(_ realm: Realm, key: String) async { realms[key] = realm }

    func releasePublication() {
        released = true
        publicationContinuation?.resume()
        publicationContinuation = nil
    }

    func cachedObjectIdentifiers(for configuration: Realm.Configuration) async throws -> [String] {
        let realm = try await cachedRealm(for: configuration)
        return realm.objects(FirstCachedRealmObject.self).map(\.id).sorted()
    }

    func cachedRealmCount() -> Int { realms.count }
}

private extension CachedRealmsActor where Self: Actor {
    // Mirrors readerRealm/sharedRealm, which invoke the opener from another
    // constrained protocol extension rather than on a concrete actor type.
    func realmThroughConvenienceAccessor(
        for configuration: Realm.Configuration
    ) async throws -> Realm {
        try await cachedRealm(for: configuration)
    }
}

final class FirstCachedRealmObject: Object {
    @Persisted(primaryKey: true) var id = ""
}

final class SecondCachedRealmObject: Object {
    @Persisted(primaryKey: true) var id = ""
}

private actor RealmOpenBarrier {
    nonisolated let publicationObserved = XCTestExpectation(description: "Realm open reached publication")
    nonisolated let joinObserved = XCTestExpectation(description: "Caller joined pending open")
    nonisolated let waiterReturnObserved = XCTestExpectation(description: "Waiter resolved pending open")
    private let suspendPublication: Bool
    private let suspendWaiterReturn: Bool
    private var eventCounts = [RealmCacheOpenEvent: Int]()
    private var releasedEvents = Set<RealmCacheOpenEvent>()
    private var suspensions = [RealmCacheOpenEvent: [CheckedContinuation<Void, Never>]]()

    init(suspendPublication: Bool = true, suspendWaiterReturn: Bool = false) {
        self.suspendPublication = suspendPublication
        self.suspendWaiterReturn = suspendWaiterReturn
    }

    func observe(_ event: RealmCacheOpenEvent) async {
        eventCounts[event, default: 0] += 1
        if eventCounts[event] == 1 {
            switch event {
            case .openedBeforePublication: publicationObserved.fulfill()
            case .joinedPendingOpen: joinObserved.fulfill()
            case .waiterResolvedPendingOpen: waiterReturnObserved.fulfill()
            }
        }
        guard !releasedEvents.contains(event) else { return }
        switch event {
        case .openedBeforePublication where suspendPublication:
            await withCheckedContinuation { suspensions[event, default: []].append($0) }
        case .waiterResolvedPendingOpen where suspendWaiterReturn:
            await withCheckedContinuation { suspensions[event, default: []].append($0) }
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

    private func release(_ event: RealmCacheOpenEvent) {
        releasedEvents.insert(event)
        for continuation in suspensions.removeValue(forKey: event) ?? [] {
            continuation.resume()
        }
    }

    func count(_ event: RealmCacheOpenEvent) -> Int { eventCounts[event, default: 0] }
}

private extension RealmBackgroundActor {
    // Read values on the owning actor; tests never carry a live Realm through Task results.
    func cachedObjectIdentifiers(for configuration: Realm.Configuration) async throws -> [String] {
        let realm = try await cachedRealm(for: configuration)
        return realm.objects(FirstCachedRealmObject.self).map(\.id).sorted()
    }

    func createFixture(for configuration: Realm.Configuration, identifier: String) async throws {
        let realm = try await Realm(configuration: configuration, actor: self)
        let object = FirstCachedRealmObject()
        object.id = identifier
        try realm.write { realm.add(object) }
        realm.invalidate()
    }

    func cachedRealmCount() -> Int { cachedRealms.count }

    func tryEvictionDuringWrite(for configuration: Realm.Configuration) async throws -> Bool {
        let realm = try await cachedRealm(for: configuration)
        try realm.beginWrite()
        defer { realm.cancelWrite() }
        return removeCachedRealm(for: configuration)
    }
}

final class RealmSwiftGapsTests: XCTestCase {
    private func diskConfigurations() throws -> (current: Realm.Configuration, replacement: Realm.Configuration) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("realm-open-fencing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var current = Realm.Configuration(fileURL: directory.appendingPathComponent("current.realm"))
        current.objectTypes = [FirstCachedRealmObject.self]
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
        // Preserve the old file in this test's unique directory rather than deleting it.
        try FileManager.default.moveItem(
            at: currentURL,
            to: currentURL.deletingLastPathComponent().appendingPathComponent("retired.realm")
        )
        try FileManager.default.moveItem(at: replacementURL, to: currentURL)
    }

    private func assertFileChanged(_ task: Task<[String], Error>) async {
        do {
            _ = try await task.value
            XCTFail("A Realm from the replaced file was returned")
        } catch RealmBackgroundActorError.realmFileChangedDuringOpen {
            // Expected: neither the opener nor a joined waiter may return the old file.
        } catch {
            XCTFail("Unexpected cache open error: \(error)")
        }
    }

    func test_suspendedExistingFileOpen_rejectsReplacementForOwnerAndWaiter() async throws {
        let configurations = try diskConfigurations()
        let fixtureActor = RealmBackgroundActor()
        try await fixtureActor.createFixture(for: configurations.current, identifier: "original")
        try await fixtureActor.createFixture(for: configurations.replacement, identifier: "replacement")
        let barrier = RealmOpenBarrier()
        defer { Task { await barrier.releaseAll() } }
        let cache = RealmBackgroundActor { await barrier.observe($0) }
        let originalKey = await cache.realmCacheKey(for: configurations.current)
        let owner = Task { try await cache.cachedObjectIdentifiers(for: configurations.current) }
        await fulfillment(of: [barrier.publicationObserved], timeout: 5)
        let waiter = Task { try await cache.cachedObjectIdentifiers(for: configurations.current) }
        await fulfillment(of: [barrier.joinObserved], timeout: 5)

        try replaceFile(current: configurations.current, replacement: configurations.replacement)
        let replacementKey = await cache.realmCacheKey(for: configurations.current)
        await barrier.releasePublication()

        await assertFileChanged(owner)
        await assertFileChanged(waiter)
        XCTAssertNotEqual(originalKey, replacementKey)
        let cacheCount = await cache.cachedRealmCount()
        XCTAssertEqual(cacheCount, 0)
        let staleRealm = await cache.getCachedRealm(key: replacementKey)
        XCTAssertNil(staleRealm)

        // Rejection must clear the failed in-flight owner, not strand the
        // replacement's fresh open or make it return the old file's contents.
        let successorIdentifiers = try await cache.cachedObjectIdentifiers(for: configurations.current)
        XCTAssertEqual(successorIdentifiers, ["replacement"])
        let successorCacheCount = await cache.cachedRealmCount()
        XCTAssertEqual(successorCacheCount, 1)
        let removed = await cache.removeCachedRealm(for: configurations.current)
        XCTAssertTrue(removed)
    }

    func test_pendingWaiter_revalidatesFileAfterPublication() async throws {
        let configurations = try diskConfigurations()
        let fixtureActor = RealmBackgroundActor()
        try await fixtureActor.createFixture(for: configurations.current, identifier: "original")
        try await fixtureActor.createFixture(for: configurations.replacement, identifier: "replacement")
        let barrier = RealmOpenBarrier(suspendWaiterReturn: true)
        defer { Task { await barrier.releaseAll() } }
        let cache = RealmBackgroundActor { await barrier.observe($0) }
        let owner = Task { try await cache.cachedObjectIdentifiers(for: configurations.current) }
        await fulfillment(of: [barrier.publicationObserved], timeout: 5)
        let waiter = Task { try await cache.cachedObjectIdentifiers(for: configurations.current) }
        await fulfillment(of: [barrier.joinObserved], timeout: 5)
        await barrier.releasePublication()
        let identifiers = try await owner.value
        XCTAssertEqual(identifiers, ["original"])
        await fulfillment(of: [barrier.waiterReturnObserved], timeout: 5)

        // Inject eviction at the waiter boundary after the owner has finished.
        // The waiter must still validate its completed task's old identity.
        let removed = await cache.removeCachedRealm(for: configurations.current)
        XCTAssertTrue(removed)
        try replaceFile(current: configurations.current, replacement: configurations.replacement)
        await barrier.releaseWaiter()

        await assertFileChanged(waiter)
        let cacheCount = await cache.cachedRealmCount()
        XCTAssertEqual(cacheCount, 0)
    }

    func test_defaultOpener_rejectsReplacementAcrossSuspendedCacheLookup() async throws {
        let configurations = try diskConfigurations()
        let fixtureActor = RealmBackgroundActor()
        try await fixtureActor.createFixture(for: configurations.current, identifier: "original")
        try await fixtureActor.createFixture(for: configurations.replacement, identifier: "replacement")
        let cache = SuspendedDefaultRealmCache()
        defer { Task { await cache.releasePublication() } }
        let owner = Task { try await cache.cachedObjectIdentifiers(for: configurations.current) }
        await fulfillment(of: [cache.publicationObserved], timeout: 5)
        try replaceFile(current: configurations.current, replacement: configurations.replacement)
        await cache.releasePublication()

        await assertFileChanged(owner)
        let cacheCount = await cache.cachedRealmCount()
        XCTAssertEqual(cacheCount, 0)
        let successorIdentifiers = try await cache.cachedObjectIdentifiers(for: configurations.current)
        XCTAssertEqual(successorIdentifiers, ["replacement"])
    }

    func test_missingFileCreation_coalescesWaiterAfterFileAppears() async throws {
        let configurations = try diskConfigurations()
        let barrier = RealmOpenBarrier()
        defer { Task { await barrier.releaseAll() } }
        let cache = RealmBackgroundActor { await barrier.observe($0) }
        let missingKey = await cache.realmCacheKey(for: configurations.current)
        let owner = Task { try await cache.cachedObjectIdentifiers(for: configurations.current) }
        await fulfillment(of: [barrier.publicationObserved], timeout: 5)
        let createdKey = await cache.realmCacheKey(for: configurations.current)
        let waiter = Task { try await cache.cachedObjectIdentifiers(for: configurations.current) }
        await fulfillment(of: [barrier.joinObserved], timeout: 5)
        await barrier.releasePublication()

        let ownerIdentifiers = try await owner.value
        let waiterIdentifiers = try await waiter.value
        XCTAssertEqual(ownerIdentifiers, [])
        XCTAssertEqual(waiterIdentifiers, [])
        XCTAssertNotEqual(missingKey, createdKey)
        let openCount = await barrier.count(.openedBeforePublication)
        let cacheCount = await cache.cachedRealmCount()
        XCTAssertEqual(openCount, 1)
        XCTAssertEqual(cacheCount, 1)
        let removed = await cache.removeCachedRealm(for: configurations.current)
        XCTAssertTrue(removed)
    }

    func test_pendingWaiter_doesNotRetainRealmAfterEviction() async throws {
        let configurations = try diskConfigurations()
        let barrier = RealmOpenBarrier(suspendWaiterReturn: true)
        defer { Task { await barrier.releaseAll() } }
        let cache = RealmBackgroundActor { await barrier.observe($0) }
        let owner = Task { try await cache.cachedObjectIdentifiers(for: configurations.current) }
        await fulfillment(of: [barrier.publicationObserved], timeout: 5)
        let waiter = Task { try await cache.cachedObjectIdentifiers(for: configurations.current) }
        await fulfillment(of: [barrier.joinObserved], timeout: 5)
        await barrier.releasePublication()
        _ = try await owner.value
        await fulfillment(of: [barrier.waiterReturnObserved], timeout: 5)
        let removed = await cache.removeCachedRealm(for: configurations.current)
        XCTAssertTrue(removed)
        await barrier.releaseWaiter()

        do {
            _ = try await waiter.value
            XCTFail("A completed task retained the evicted Realm")
        } catch RealmBackgroundActorError.cachedRealmEvictedDuringOpen {
            // Expected: a completed Task result cannot bypass scoped eviction.
        }
    }

    func test_scopedEviction_preservesActiveWriteTransaction() async throws {
        var configuration = Realm.Configuration()
        configuration.inMemoryIdentifier = "active-write-\(UUID().uuidString)"
        configuration.objectTypes = [FirstCachedRealmObject.self]
        let cache = RealmBackgroundActor()

        let removedDuringWrite = try await cache.tryEvictionDuringWrite(for: configuration)
        XCTAssertFalse(removedDuringWrite)
        let cacheCount = await cache.cachedRealmCount()
        XCTAssertEqual(cacheCount, 1)
        let removedAfterWrite = await cache.removeCachedRealm(for: configuration)
        XCTAssertTrue(removedAfterWrite)
    }

    func testConvenienceAccessorUsesSpecializedActorOpener() async throws {
        let cache = SpecializedRealmCache()
        var configuration = Realm.Configuration()
        configuration.inMemoryIdentifier = "dispatch-\(UUID().uuidString)"
        configuration.objectTypes = [FirstCachedRealmObject.self]

        _ = try await cache.realmThroughConvenienceAccessor(for: configuration)

        let openCount = await cache.openCount
        XCTAssertEqual(openCount, 1)
    }

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

    func testRealmCacheKeysSeparateAutomaticAndEmptySchemasAndActiveVersionLimits() async {
        let cache = TestRealmCache()
        var automatic = Realm.Configuration()
        automatic.inMemoryIdentifier = "configuration-options-\(UUID().uuidString)"
        automatic.objectTypes = nil
        var empty = automatic
        empty.objectTypes = []
        var limited = automatic
        limited.maximumNumberOfActiveVersions = 10

        let automaticKey = await cache.realmCacheKey(for: automatic)
        let emptyKey = await cache.realmCacheKey(for: empty)
        let limitedKey = await cache.realmCacheKey(for: limited)
        XCTAssertNotEqual(automaticKey, emptyKey)
        XCTAssertNotEqual(automaticKey, limitedKey)
        XCTAssertNotEqual(emptyKey, limitedKey)
    }

    func testRealmBackgroundActorCoalescesConcurrentInitialOpens() async throws {
        let identifier = "concurrent-open-\(UUID().uuidString)"
        var configuration = Realm.Configuration()
        configuration.inMemoryIdentifier = identifier
        configuration.objectTypes = [FirstCachedRealmObject.self]

        let realms = try await withThrowingTaskGroup(of: Realm.self) { group in
            for index in 0..<12 {
                group.addTask {
                    if index.isMultiple(of: 2) {
                        return try await RealmBackgroundActor.shared
                            .realmThroughConvenienceAccessor(for: configuration)
                    }
                    return try await RealmBackgroundActor.shared.cachedRealm(
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
        if let first = realms.first {
            XCTAssertTrue(realms.allSatisfy { $0 == first })
        }
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
