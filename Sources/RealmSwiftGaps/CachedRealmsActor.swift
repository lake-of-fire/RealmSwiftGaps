import CryptoKit
import Foundation
import RealmSwift

public protocol CachedRealmsActor: AnyObject {
    func getCachedRealm(key: String) async -> Realm?
    func setCachedRealm(_ realm: Realm, key: String) async
}

public extension CachedRealmsActor where Self: Actor {
    func realmCacheKey(for configuration: Realm.Configuration) -> String {
        let storageIdentity: String
        if let inMemoryIdentifier = configuration.inMemoryIdentifier {
            storageIdentity = "memory:\(inMemoryIdentifier)"
        } else if let fileURL = configuration.fileURL {
            let standardizedURL = fileURL.standardizedFileURL
            let resourceIdentifier = (try? standardizedURL.resourceValues(
                forKeys: [.fileResourceIdentifierKey]
            ).fileResourceIdentifier).map { String(describing: $0) }
                ?? "missing"
            storageIdentity = "file:\(standardizedURL.path):\(resourceIdentifier)"
        } else {
            storageIdentity = "file:"
        }
        let objectTypes = (configuration.objectTypes ?? [])
            .map { "\($0.className()):\(String(reflecting: $0))" }
            .sorted()
            .joined(separator: ",")
        let encryptionFingerprint = configuration.encryptionKey.map {
            SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()
        } ?? "none"
        return [
            storageIdentity,
            "schema:\(configuration.schemaVersion)",
            "readOnly:\(configuration.readOnly)",
            "deleteIfMigrationNeeded:\(configuration.deleteRealmIfMigrationNeeded)",
            "seed:\(configuration.seedFilePath?.standardizedFileURL.path ?? "none")",
            "encryption:\(encryptionFingerprint)",
            "objects:\(objectTypes)",
        ].joined(separator: "|")
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
        await getCachedRealm(key: realmCacheKey(for: configuration))
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
        await setCachedRealm(realm, key: realmCacheKey(for: configuration))
    }
}
