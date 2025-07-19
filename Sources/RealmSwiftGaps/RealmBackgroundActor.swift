import Foundation
import Realm
import RealmSwift

extension RealmSwiftObject: @unchecked Sendable { }

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

    public func run(_ operation: @escaping () async throws -> Void) async {
        do {
            try await operation()
        } catch {
            print("Realm operation failed: \(error.localizedDescription)")
        }
    }
    
    public func write(configuration: Realm.Configuration, operation: @escaping (Realm) throws -> Void) async throws {
        let realm = try await cachedRealm(for: configuration)
        try await realm.asyncWrite {
            try operation(realm)
        }
    }
    
    public func write<T: ThreadConfined>(_ reference: ThreadSafeReference<T>, configuration: Realm.Configuration, operation: @escaping (Realm, T) throws -> Void) async throws {
        let realm = try await cachedRealm(for: configuration)
        guard let resolvedObject = realm.resolve(reference) else { throw RealmBackgroundActorError.unableToResolveObject }
        
        try await realm.asyncWrite {
            try operation(realm, resolvedObject)
        }
    }
}
