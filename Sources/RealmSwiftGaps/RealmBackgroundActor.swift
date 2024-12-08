import Foundation
import Realm
import RealmSwift

extension RealmSwiftObject: @unchecked Sendable { }

public enum RealmBackgroundActorError: Error {
    case unableToResolveObject
}

@globalActor
public actor RealmBackgroundActor {
    public static var shared = RealmBackgroundActor()
    public static var preWarmCacheCallback: ((RealmBackgroundActor) async throws -> Void)?

    public init() { }
    
    private var cachedRealms = [String: RealmSwift.Realm]()
    
    public func cachedRealm(for configuration: Realm.Configuration, preWarmIfNeeded: Bool = true) async -> RealmSwift.Realm? {
        let key = configuration.fileURL?.deletingPathExtension().lastPathComponent ?? ""
        if let cachedRealm = cachedRealms[key] {
            return cachedRealm
        }
        if preWarmIfNeeded, let preWarmCacheCallback = Self.preWarmCacheCallback {
            try? await preWarmCacheCallback(self)
            Self.preWarmCacheCallback = nil
        }
        return cachedRealms[key]
    }
    
    public func setCachedRealm(_ realm: RealmSwift.Realm, for configuration: Realm.Configuration) {
        let key = configuration.fileURL?.deletingPathExtension().lastPathComponent ?? ""
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
        var realm = await cachedRealm(for: configuration)
        if realm == nil {
            realm = try await Realm(configuration: configuration, actor: self)
        }
        guard let realm else {
            debugPrint("Could not initiate Realm", configuration)
            return
        }
        try await realm.asyncWrite {
            try operation(realm)
        }
    }
    
    public func write<T: ThreadConfined>(_ reference: ThreadSafeReference<T>, configuration: Realm.Configuration, operation: @escaping (Realm, T) throws -> Void) async throws {
        var realm = await cachedRealm(for: configuration)
        if realm == nil {
            realm = try await Realm(configuration: configuration, actor: self)
        }
        guard let realm else {
            debugPrint("Could not initiate Realm", configuration)
            return
        }
        guard let resolvedObject = realm.resolve(reference) else { throw RealmBackgroundActorError.unableToResolveObject }
        
        try await realm.asyncWrite {
            try operation(realm, resolvedObject)
        }
    }
}
