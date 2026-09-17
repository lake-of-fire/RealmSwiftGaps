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
    
    public func getCachedRealm(key: String) async -> Realm? {
        return cachedRealms[key]
    }
    
    public func setCachedRealm(_ realm: Realm, key: String) async {
        cachedRealms[key] = realm
    }

    /// Releases an explicitly scoped Realm when its configuration is no longer
    /// needed. Production configurations remain cached for the actor lifetime,
    /// while callers that create transient configurations can bound their file
    /// descriptor usage.
    public func removeCachedRealm(for configuration: Realm.Configuration) {
        cachedRealms.removeValue(forKey: realmCacheKey(for: configuration))?.invalidate()
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
