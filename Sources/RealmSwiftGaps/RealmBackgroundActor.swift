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
    
    @inline(__always)
    public func getCachedRealm(key: String) async -> RealmSwift.Realm? {
        return cachedRealms[key]
    }
    
    @inline(__always)
    public func setCachedRealm(_ realm: RealmSwift.Realm, key: String) async {
        cachedRealms[key] = realm
    }

    @inline(__always)
    public func run(_ operation: @escaping () async throws -> Void) async {
        do {
            try await operation()
        } catch {
            print("Realm operation failed: \(error.localizedDescription)")
        }
    }
    
    @inline(__always)
    public func write(configuration: Realm.Configuration, operation: @escaping (RealmSwift.Realm) throws -> Void) async throws {
        let realm = try await cachedRealm(for: configuration)
        try await realm.asyncWrite {
            try operation(realm)
        }
    }
    
    @inline(__always)
    public func write<T: ThreadConfined>(_ reference: ThreadSafeReference<T>, configuration: Realm.Configuration, operation: @escaping (RealmSwift.Realm, T) throws -> Void) async throws {
        let realm = try await cachedRealm(for: configuration)
        guard let resolvedObject = realm.resolve(reference) else { throw RealmBackgroundActorError.unableToResolveObject }
        
        try await realm.asyncWrite {
            try operation(realm, resolvedObject)
        }
    }
}
