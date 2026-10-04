import CryptoKit
import Foundation
import RealmSwift
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A captured store boundary. Only its owning admission may advance a missing
/// file to the identity of a file it exclusively creates; an appearing file is
/// never adopted. The scope stays stable for publications belonging to that
/// submission, even when creation gives the store its resource identifier.
public final class RealmStorageAdmission: @unchecked Sendable {
    public let scopeIdentity: String
    private let lock = NSLock()
    private var storageIdentity: String
    private var requiresCreation: Bool

    init(configuration: Realm.Configuration, storageIdentity: String) {
        self.storageIdentity = storageIdentity
        requiresCreation = configuration.inMemoryIdentifier == nil
            && configuration.fileURL.map { !FileManager.default.fileExists(atPath: $0.path) } == true
        scopeIdentity = requiresCreation ? storageIdentity + "|creation:\(UUID())" : storageIdentity
    }

    public func matches(_ currentStorageIdentity: String) -> Bool {
        matchesCurrentStorageIdentity { currentStorageIdentity }
    }

    /// Compute the filesystem identity under the same boundary as owned
    /// creation, so a concurrent reader cannot compare the pre-creation path
    /// identity with the post-creation admission state (or vice versa).
    public func matchesCurrentStorageIdentity(_ currentStorageIdentity: () -> String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storageIdentity == currentStorageIdentity()
    }

    func admitCreation(
        configuration: Realm.Configuration,
        currentStorageIdentity: () -> String
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard storageIdentity == currentStorageIdentity() else {
            throw RealmBackgroundActorError.realmFileChangedDuringOpen
        }
        guard requiresCreation, let fileURL = configuration.fileURL else { return }
        // The callers using this admission are writable, unseeded stores.
        // Do not silently change the semantics of a read-only or seeded open.
        guard !configuration.readOnly, configuration.seedFilePath == nil else {
            throw RealmBackgroundActorError.realmFileChangedDuringOpen
        }
        // Reserve the actual inode before the async Realm open can suspend.
        // Realm initializes an empty file. O_EXCL rejects even a file which
        // appears between the identity check and this exclusive creation.
        let descriptor = fileURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return open(path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
        }
        guard descriptor >= 0 else {
            let errorNumber = errno
            if errorNumber == EEXIST { throw RealmBackgroundActorError.realmFileChangedDuringOpen }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorNumber),
                          userInfo: [NSFilePathErrorKey: fileURL.path])
        }
        defer { close(descriptor) }
        let createdIdentity = currentStorageIdentity()
        var descriptorStatus = stat()
        var pathStatus = stat()
        let pathStatusResult = fileURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &pathStatus)
        }
        guard fstat(descriptor, &descriptorStatus) == 0, pathStatusResult == 0,
              descriptorStatus.st_dev == pathStatus.st_dev,
              descriptorStatus.st_ino == pathStatus.st_ino,
              currentStorageIdentity() == createdIdentity else {
            throw RealmBackgroundActorError.realmFileChangedDuringOpen
        }
        storageIdentity = createdIdentity
        requiresCreation = false
    }
}

public protocol CachedRealmsActor: AnyObject {
    func getCachedRealm(key: String) async -> Realm?
    func setCachedRealm(_ realm: Realm, key: String) async
    // Convenience accessors in constrained protocol extensions must dispatch
    // to the actor's opener, including its in-flight initialization boundary.
    func cachedRealm(for configuration: Realm.Configuration) async throws -> Realm
}

public extension CachedRealmsActor where Self: Actor {
    nonisolated func captureStorageAdmission(for configuration: Realm.Configuration) -> RealmStorageAdmission {
        RealmStorageAdmission(configuration: configuration, storageIdentity: realmCacheKey(for: configuration))
    }

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
