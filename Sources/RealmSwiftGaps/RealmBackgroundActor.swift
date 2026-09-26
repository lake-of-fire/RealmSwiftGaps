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

        if let pendingOpen = pendingRealmOpens[key] {
            return try await pendingOpen.value
        }

        let pendingOpen = Task {
            try await RealmSwift.Realm(configuration: configuration, actor: self)
        }
        pendingRealmOpens[key] = pendingOpen
        defer { pendingRealmOpens.removeValue(forKey: key) }

        let realm = try await pendingOpen.value
        if let cachedRealm = cachedRealms[key] {
            return cachedRealm
        }
        cachedRealms[key] = realm
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
