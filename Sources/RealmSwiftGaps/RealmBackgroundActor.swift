import Foundation
import RealmSwift

extension Object: @unchecked Sendable { }

public enum RealmBackgroundActorError: Error {
    case unableToResolveObject
}

@globalActor
public actor RealmBackgroundActor: CachedRealmsActor {
    public static let shared = RealmBackgroundActor()

    public init() { }
    
    public var cachedRealms = [String: RealmSwift.Realm]()
    // Realm's async actor-bound initializer suspends while the file/group is
    // opened.  A second caller can therefore enter this actor before the
    // first open has populated `cachedRealms`.  Keep the in-flight open on
    // the actor so startup callers share one initialization instead of
    // concurrently opening the same in-memory group.
    private var pendingRealmOpens = [String: Task<RealmSwift.Realm, Error>]()
    
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
            return try await pendingOpen.value
        }

        let opensMissingFile = configuration.fileURL.map {
            !FileManager.default.fileExists(atPath: $0.standardizedFileURL.path)
        } ?? false
        let openKey = opensMissingFile ? pendingKey : key

        let pendingOpen = Task {
            try await RealmSwift.Realm(configuration: configuration, actor: self)
        }
        pendingRealmOpens[openKey] = pendingOpen
        defer { pendingRealmOpens.removeValue(forKey: openKey) }

        let realm = try await pendingOpen.value
        // Opening a new disk Realm creates its file, changing the resource ID
        // used by realmCacheKey. Store under the identity future lookups and
        // explicit eviction will actually use.
        let openedKey = realmCacheKey(for: configuration)
        if let cachedRealm = cachedRealms[openedKey] {
            return cachedRealm
        }
        cachedRealms[openedKey] = realm
        return realm
    }

    /// Releases an explicitly scoped Realm when its configuration is no longer
    /// needed. Production configurations remain cached for the actor lifetime,
    /// while callers that create transient configurations can bound their file
    /// descriptor usage.
    public func removeCachedRealm(for configuration: Realm.Configuration) {
        let key = realmCacheKey(for: configuration)
        cachedRealms.removeValue(forKey: key)?.invalidate()
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
        try realm.writeIfNeeded {
            try operation(realm)
        }
    }
    
    public func write<T: ThreadConfined>(_ reference: ThreadSafeReference<T>, configuration: Realm.Configuration, operation: @escaping (Realm, T) throws -> Void) async throws {
        let realm = try await cachedRealm(for: configuration)
        guard let resolvedObject = realm.resolve(reference) else { throw RealmBackgroundActorError.unableToResolveObject }
        
        try realm.writeIfNeeded {
            try operation(realm, resolvedObject)
        }
    }
}
