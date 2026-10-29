import CryptoKit
import Foundation
import RealmSwift
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A captured store boundary. Only its owning admission may advance a missing
/// file to the identity of a file it exclusively creates. Overlapping captures
/// may share that pending owner; an externally appearing file is
/// never adopted. The scope stays stable for publications belonging to that
/// submission, even when creation gives the store its resource identifier.
public final class RealmStorageAdmission: @unchecked Sendable {
    // Weak membership lasts only as long as an operation retains its owner.
    // Prune dead/completed entries on capture; owners are never reused for a
    // newly missing path. This coordinates capture, not Realm writes or opens.
    private final class PendingCreation {
        weak var owner: RealmStorageAdmission?
        init(_ owner: RealmStorageAdmission) { self.owner = owner }
    }
    // All registry state is protected by this lock. The immutable static owner
    // also makes the synchronization boundary explicit to Swift concurrency.
    private final class PendingCreationRegistry: @unchecked Sendable {
        private let lock = NSLock()
        private var pendingCreations = [String: PendingCreation]()

        func capture(
            configuration: Realm.Configuration,
            currentStorageIdentity: () -> String
        ) -> RealmStorageAdmission {
            lock.lock()
            defer { lock.unlock() }
            pendingCreations = pendingCreations.filter { $0.value.owner?.pendingCreationKey != nil }
            let key = currentStorageIdentity()
            if let owner = pendingCreations[key]?.owner,
               owner.canSharePendingCreation(currentStorageIdentity) {
                return owner
            }
            // Recompute after checking the owner: it may have exclusively created
            // the file while capture waited for its lock. Never relabel that owner.
            let admission = RealmStorageAdmission(configuration: configuration,
                storageIdentity: currentStorageIdentity())
            if admission.canSharePendingCreation(currentStorageIdentity),
               let pendingKey = admission.pendingCreationKey {
                pendingCreations[pendingKey] = PendingCreation(admission)
            }
            return admission
        }
    }
    private static let pendingCreationRegistry = PendingCreationRegistry()

    static func capture(
        configuration: Realm.Configuration,
        currentStorageIdentity: () -> String
    ) -> RealmStorageAdmission {
        pendingCreationRegistry.capture(configuration: configuration,
            currentStorageIdentity: currentStorageIdentity)
    }

    private var pendingCreationKey: String? {
        lock.lock()
        defer { lock.unlock() }
        return requiresCreation ? storageIdentity : nil
    }

    private func canSharePendingCreation(_ currentStorageIdentity: () -> String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return requiresCreation && storageIdentity == currentStorageIdentity()
    }

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

// Realm is intentionally non-Sendable. Making the cache itself an Actor also
// isolates its protocol requirements and default implementations to that owner;
// an extension-only `Self: Actor` constraint does not isolate async requirements.
public protocol CachedRealmsActor: Actor {
    // Storage primitives for the actor's opener. Application callers must use
    // cachedRealm(for:) or the read-only existingCachedRealm(for:) lookup.
    // A key passed to the setter must belong to that actual open; it must not
    // be recomputed from an arbitrary previously opened Realm's current path.
    func getCachedRealm(key: String) async -> Realm?
    func setCachedRealm(_ realm: Realm, key: String) async
    // Convenience accessors in constrained protocol extensions must dispatch
    // to the actor's opener, including its in-flight initialization boundary.
    func cachedRealm(for configuration: Realm.Configuration) async throws -> Realm
}

public extension CachedRealmsActor {
    nonisolated func captureStorageAdmission(for configuration: Realm.Configuration) -> RealmStorageAdmission {
        RealmStorageAdmission.capture(configuration: configuration) {
            realmCacheKey(for: configuration)
        }
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
        // Realm maps nil/zero to the unlimited native value when opening, then
        // returns UInt.max in realm.configuration. Keep equivalent authority
        // identical across that round trip while preserving finite limits.
        let activeVersionLimit = configuration.maximumNumberOfActiveVersions ?? 0
        let normalizedActiveVersionLimit = activeVersionLimit == 0 ? UInt.max : activeVersionLimit
        return [
            storageIdentity,
            "schema:\(configuration.schemaVersion)",
            "readOnly:\(configuration.readOnly)",
            "activeVersions:\(normalizedActiveVersionLimit)",
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
    
    /// A read-only cache hit is bound to the identity captured before lookup.
    /// A conforming actor may suspend in getCachedRealm; do not return its old
    /// result after the file at the same configured path has been replaced.
    /// Rejection is a cache miss, not permission to evict or invalidate the
    /// old Realm, which may still be owned by another operation.
    func existingCachedRealm(for configuration: Realm.Configuration) async -> Realm? {
        let key = realmCacheKey(for: configuration)
        let realm = await getCachedRealm(key: key)
        guard realmCacheKey(for: configuration) == key else { return nil }
        return realm
    }

    // A live Realm does not expose the file identity which admitted its open.
    // Synthesizing a key from its path now can silently relabel an old instance
    // as a replacement store. Preserve compiler diagnostics for old clients,
    // rather than keep a second unfenced publication path beside the opener.
    @available(*, unavailable, message: "Use cachedRealm(for:). A supplied Realm cannot be safely adopted under a newly computed storage identity.")
    func setCachedRealmIfNeeded(_ realm: Realm, for configuration: Realm.Configuration) async -> Realm {
        fatalError("Unavailable Realm cache adoption API")
    }

    @available(*, unavailable, message: "Use cachedRealm(for:). A supplied Realm cannot be safely adopted under a newly computed storage identity.")
    func setCachedRealm(_ realm: Realm, for configuration: Realm.Configuration) async {
        fatalError("Unavailable Realm cache adoption API")
    }
}
