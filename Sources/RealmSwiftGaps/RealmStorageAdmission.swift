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

