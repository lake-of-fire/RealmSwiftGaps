import Foundation
import RealmSwift
import Realm

public protocol CachedRealmsActor: AnyObject {
    func getCachedRealm(key: String) async -> Realm?
    func setCachedRealm(_ realm: Realm, key: String) async
}

public extension CachedRealmsActor where Self: Actor {
    @inline(__always)
    private func cachedRealmKey(for configuration: Realm.Configuration) -> String {
        if let inMemoryIdentifier = configuration.inMemoryIdentifier {
            return "memory:\(inMemoryIdentifier)"
        }
        return "file:\(configuration.fileURL?.deletingPathExtension().lastPathComponent ?? "")"
    }

    @inlinable
    func cachedRealm(for configuration: Realm.Configuration) async throws -> Realm {
        if let cachedRealm = await existingCachedRealm(for: configuration) {
            return cachedRealm
        }
       
        let realm = try await Realm(configuration: configuration, actor: self)
        return await setCachedRealmIfNeeded(realm, for: configuration)
    }
    
    @inline(__always)
    public func existingCachedRealm(for configuration: Realm.Configuration) async -> Realm? {
        let key = cachedRealmKey(for: configuration)
        return await getCachedRealm(key: key)
    }
    
    @inline(__always)
    public func setCachedRealmIfNeeded(_ realm: Realm, for configuration: Realm.Configuration) async -> Realm {
        if let cachedRealm = await existingCachedRealm(for: configuration) {
            return cachedRealm
        } else {
            await setCachedRealm(realm, for: configuration)
            return realm
        }
    }

    @inline(__always)
    public func setCachedRealm(_ realm: Realm, for configuration: Realm.Configuration) async {
        let key = cachedRealmKey(for: configuration)
        await setCachedRealm(realm, key: key)
    }
}
