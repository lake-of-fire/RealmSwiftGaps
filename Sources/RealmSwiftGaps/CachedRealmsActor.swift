import Foundation
import RealmSwift

public protocol CachedRealmsActor: AnyObject {
    var cachedRealms: [String: Realm] { get set }
}

public extension CachedRealmsActor where Self: Actor {
    func cachedRealm(for configuration: Realm.Configuration) async throws -> Realm {
        let key = configuration.fileURL?.deletingPathExtension().lastPathComponent ?? ""
        if let cachedRealm = cachedRealms[key] {
            return cachedRealm
        }
       
        let realm = try await Realm(configuration: configuration, actor: self)
        setCachedRealm(realm, for: configuration)
        return realm
    }
    
    public func setCachedRealm(_ realm: Realm, for configuration: Realm.Configuration) {
        let key = configuration.fileURL?.deletingPathExtension().lastPathComponent ?? ""
        cachedRealms[key] = realm
    }
}
