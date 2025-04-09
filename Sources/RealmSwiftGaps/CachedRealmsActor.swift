import Foundation
import RealmSwift

public protocol CachedRealmsActor: AnyObject {
    var cachedRealms: [String: Realm] { get set }
    func cachedRealm(for configuration: Realm.Configuration) async throws -> Realm
}

// Reference implementation:
//public func cachedRealm(for configuration: Realm.Configuration) async throws -> Realm {
//    if let cachedRealm = existingCachedRealm(for: configuration) {
//        return cachedRealm
//    }
//    let realm = try await Realm(configuration: configuration, actor: self)
//    return setCachedRealmIfNeeded(realm, for: configuration)
//}

public extension CachedRealmsActor where Self: Actor {
    public func existingCachedRealm(for configuration: Realm.Configuration) -> Realm? {
        let key = configuration.fileURL?.deletingPathExtension().lastPathComponent ?? ""
        return cachedRealms[key]
    }
    
    public func setCachedRealmIfNeeded(_ realm: Realm, for configuration: Realm.Configuration) -> Realm {
        if let cachedRealm = existingCachedRealm(for: configuration) {
            return cachedRealm
        } else {
            setCachedRealm(realm, for: configuration)
            return realm
        }
    }

    public func setCachedRealm(_ realm: Realm, for configuration: Realm.Configuration) {
        let key = configuration.fileURL?.deletingPathExtension().lastPathComponent ?? ""
        cachedRealms[key] = realm
    }
}
