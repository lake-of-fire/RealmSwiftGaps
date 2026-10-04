import Foundation
import RealmSwift

extension Object: @unchecked Sendable { }

public enum RealmBackgroundActorError: Error {
    case unableToResolveObject
    case cachedRealmEvictedDuringOpen
    case realmFileChangedDuringOpen
}

// Instance-scoped suspension points for deterministic cache lifecycle tests.
enum RealmCacheOpenEvent: Hashable, Sendable {
    case openedBeforePublication
    case joinedPendingOpen
    case waiterResolvedPendingOpen
}

// Captured-admission tests suspend after the real open, before its identity is
// handed to a mutation or another actor. Production installs no observation.
enum RealmStorageAdmissionObservation {
    @TaskLocal static var didOpenRealm: (@Sendable () async -> Void)? = nil
}

@globalActor
public actor RealmBackgroundActor: CachedRealmsActor {
    public static let shared = RealmBackgroundActor()

    public init() { }

    init(openObserver: @escaping @Sendable (RealmCacheOpenEvent) async -> Void) {
        self.openObserver = openObserver
    }

    private var openObserver: (@Sendable (RealmCacheOpenEvent) async -> Void)?
    
    public var cachedRealms = [String: RealmSwift.Realm]()
    // Realm's async actor-bound initializer suspends while the file/group is
    // opened.  A second caller can therefore enter this actor before the
    // first open has populated `cachedRealms`.  Keep the in-flight open on
    // the actor so startup callers share one initialization instead of
    // concurrently opening the same in-memory group.
    private var pendingRealmOpens = [String: Task<String, Error>]()
    
    public func getCachedRealm(key: String) async -> Realm? {
        return cachedRealms[key]
    }
    
    public func setCachedRealm(_ realm: Realm, key: String) async {
        cachedRealms[key] = realm
    }

    public func cachedRealm(
        for configuration: Realm.Configuration
    ) async throws -> RealmSwift.Realm {
        let key = realmCacheKey(for: configuration)
        if let cachedRealm = cachedRealms[key] {
            return cachedRealm
        }

        // A missing file may appear while its first open is suspended,
        // changing the completed cache key. Coalesce that first creation by
        // path, but keep existing-file opens keyed by resource ID so a file
        // replaced during an open does not share the old file's Realm.
        let pendingKey = realmCacheKey(
            for: configuration, includingFileResourceIdentifier: false
        )
        if let pendingOpen = pendingRealmOpens[key]
            ?? pendingRealmOpens[pendingKey] {
            if let openObserver {
                await openObserver(.joinedPendingOpen)
            }
            let openedKey = try await pendingOpen.value
            if let openObserver {
                await openObserver(.waiterResolvedPendingOpen)
            }
            return try realmForCompletedOpen(key: openedKey, configuration: configuration)
        }

        let opensMissingFile = configuration.fileURL.map {
            !FileManager.default.fileExists(atPath: $0.standardizedFileURL.path)
        } ?? false
        let openKey = opensMissingFile ? pendingKey : key

        // Publish on the owning actor. A completed Task retains only a key,
        // never a live Realm that can outlast eviction or file replacement.
        let pendingOpen = Task { () throws -> String in
            let realm = try await RealmSwift.Realm(configuration: configuration, actor: self)
            if let openObserver {
                await openObserver(.openedBeforePublication)
            }
            // First creation changes the identity, but an existing file must
            // still match the identity captured before the suspended open.
            let openedKey = realmCacheKey(for: configuration)
            guard opensMissingFile || openedKey == key else {
                throw RealmBackgroundActorError.realmFileChangedDuringOpen
            }
            if cachedRealms[openedKey] == nil {
                cachedRealms[openedKey] = realm
            }
            return openedKey
        }
        pendingRealmOpens[openKey] = pendingOpen
        defer { pendingRealmOpens.removeValue(forKey: openKey) }

        let openedKey = try await pendingOpen.value
        return try realmForCompletedOpen(key: openedKey, configuration: configuration)
    }

    public func cachedRealm(
        for configuration: Realm.Configuration,
        storageAdmission: RealmStorageAdmission
    ) async throws -> Realm {
        try Task.checkCancellation()
        try storageAdmission.admitCreation(configuration: configuration) {
            realmCacheKey(for: configuration)
        }
        let realm = try await cachedRealm(for: configuration)
        if let didOpenRealm = RealmStorageAdmissionObservation.didOpenRealm { await didOpenRealm() }
        guard storageAdmission.matchesCurrentStorageIdentity({ realmCacheKey(for: configuration) }) else {
            throw RealmBackgroundActorError.realmFileChangedDuringOpen
        }
        return realm
    }

    /// Read actors may prepare the captured store without receiving a Realm
    /// belonging to this writer actor. They open their own instance afterward.
    public func prepareStorage(
        for configuration: Realm.Configuration,
        storageAdmission: RealmStorageAdmission
    ) async throws {
        _ = try await cachedRealm(for: configuration, storageAdmission: storageAdmission)
    }

    private func realmForCompletedOpen(key: String, configuration: Realm.Configuration) throws -> Realm {
        // Another actor turn can replace the file or evict the cache between
        // publication and a waiter's resumption. Revalidate without suspension
        // before resolving and returning the actor-owned Realm.
        guard realmCacheKey(for: configuration) == key else {
            throw RealmBackgroundActorError.realmFileChangedDuringOpen
        }
        guard let realm = cachedRealms[key] else {
            throw RealmBackgroundActorError.cachedRealmEvictedDuringOpen
        }
        return realm
    }

    /// Releases an explicitly scoped Realm when its configuration is no longer
    /// needed. Production configurations remain cached for the actor lifetime,
    /// while callers that create transient configurations can bound their file
    /// descriptor usage. Call after users and pending opens/writes have quiesced,
    /// before replacing its file. This does not close independently held Realms
    /// or coordinate another actor/process. An active transaction is never evicted.
    @discardableResult
    public func removeCachedRealm(for configuration: Realm.Configuration) -> Bool {
        let key = realmCacheKey(for: configuration)
        guard let realm = cachedRealms[key], !realm.isInWriteTransaction else { return false }
        cachedRealms.removeValue(forKey: key)
        realm.invalidate()
        return true
    }

    public func run(_ operation: @escaping () async throws -> Void) async {
        do {
            try await operation()
        } catch {
            print("Realm operation failed: \(error.localizedDescription)")
        }
    }
    
    public func write(configuration: Realm.Configuration, operation: @escaping (Realm) throws -> Void) async throws {
        let realm = try await cachedRealm(for: configuration)
        try await write(in: realm, operation: operation)
    }

    func write(in realm: Realm, operation: (Realm) throws -> Void) async throws {
        try await realm.asyncWritePreservingOwnership { try operation(realm) }
    }

    public func write<T: ThreadConfined>(_ reference: ThreadSafeReference<T>, configuration: Realm.Configuration, operation: @escaping (Realm, T) throws -> Void) async throws {
        let realm = try await cachedRealm(for: configuration)
        try await write(in: realm) { realm in
            guard let resolvedObject = realm.resolve(reference) else {
                throw RealmBackgroundActorError.unableToResolveObject
            }
            try operation(realm, resolvedObject)
        }
    }
}
