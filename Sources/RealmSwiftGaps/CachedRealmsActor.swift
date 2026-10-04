import CryptoKit
import Foundation
import RealmSwift

public protocol CachedRealmsActor: AnyObject {
    func getCachedRealm(key: String) async -> Realm?
    func setCachedRealm(_ realm: Realm, key: String) async
    // Convenience accessors in constrained protocol extensions must dispatch
    // to the actor's opener, including its in-flight initialization boundary.
    func cachedRealm(for configuration: Realm.Configuration) async throws -> Realm
}

public extension CachedRealmsActor where Self: Actor {
    nonisolated func realmCacheKey(
        for configuration: Realm.Configuration,
        includingFileResourceIdentifier: Bool = true
    ) -> String {
        let storageIdentity: String
        if let inMemoryIdentifier = configuration.inMemoryIdentifier {
            storageIdentity = "memory:\(inMemoryIdentifier)"
        } else if let fileURL = configuration.fileURL {
            let standardizedURL = fileURL.standardizedFileURL
            let resourceIdentifier = includingFileResourceIdentifier
                ? (try? standardizedURL.resourceValues(
                    forKeys: [.fileResourceIdentifierKey]
                ).fileResourceIdentifier).map { String(describing: $0) }
                    ?? "missing"
                : "pending"
            storageIdentity = "file:\(standardizedURL.path):\(resourceIdentifier)"
        } else {
            storageIdentity = "file:"
        }
        // Automatic discovery and an explicit empty schema are different opens.
        let objectTypes = configuration.objectTypes.map { types in
            "explicit:" + types
                .map { "\($0.className()):\(String(reflecting: $0))" }
                .sorted()
                .joined(separator: ",")
        } ?? "all"
        let encryptionFingerprint = configuration.encryptionKey.map {
            SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()
        } ?? "none"
        return [
            storageIdentity,
            "schema:\(configuration.schemaVersion)",
            "readOnly:\(configuration.readOnly)",
            "activeVersions:\(configuration.maximumNumberOfActiveVersions.map(String.init) ?? "default")",
            "deleteIfMigrationNeeded:\(configuration.deleteRealmIfMigrationNeeded)",
            "seed:\(configuration.seedFilePath?.standardizedFileURL.path ?? "none")",
            "encryption:\(encryptionFingerprint)",
            "objects:\(objectTypes)",
        ].joined(separator: "|")
    }

    func cachedRealm(for configuration: Realm.Configuration) async throws -> Realm {
        let originalKey = realmCacheKey(for: configuration)
        let opensMissingFile = configuration.fileURL.map {
            !FileManager.default.fileExists(atPath: $0.standardizedFileURL.path)
        } ?? false
        if let cachedRealm = await getCachedRealm(key: originalKey) {
            guard realmCacheKey(for: configuration) == originalKey else {
                throw RealmBackgroundActorError.realmFileChangedDuringOpen
            }
            return cachedRealm
        }

        let realm = try await Realm(configuration: configuration, actor: self)
        let openedKey = realmCacheKey(for: configuration)
        guard opensMissingFile || openedKey == originalKey else {
            throw RealmBackgroundActorError.realmFileChangedDuringOpen
        }
        // Default conformers can suspend in their cache accessors too. Keep
        // the admitted key across those awaits, rather than recomputing a new
        // identity and publishing an old Realm under the replacement's key.
        let existingRealm = await getCachedRealm(key: openedKey)
        guard realmCacheKey(for: configuration) == openedKey else {
            throw RealmBackgroundActorError.realmFileChangedDuringOpen
        }
        if let existingRealm { return existingRealm }
        await setCachedRealm(realm, key: openedKey)
        guard realmCacheKey(for: configuration) == openedKey else {
            throw RealmBackgroundActorError.realmFileChangedDuringOpen
        }
        return realm
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
