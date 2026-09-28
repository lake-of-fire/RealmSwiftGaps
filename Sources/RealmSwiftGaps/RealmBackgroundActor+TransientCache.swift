import RealmSwift

public extension RealmBackgroundActor {
    /// Releases one transient cached configuration without clearing other Realms.
    ///
    /// Call only after the configuration's users and pending opens/writes have
    /// quiesced, and before replacing/deleting its file. Invalidation also
    /// invalidates objects obtained from this actor's cached Realm. It does not
    /// close independently held Realms or coordinate another actor/process.
    /// Configuration identity is evaluated now; a replacement file or different
    /// schema is not permission to invalidate an earlier configuration's cache.
    ///
    /// - Returns: `true` if the matching cached Realm was removed. A missing
    ///   entry or an active write returns `false` without changing the cache.
    ///   In particular, cleanup never cancels an in-flight transaction.
    @discardableResult
    func removeCachedRealm(for configuration: Realm.Configuration) -> Bool {
        let key = realmCacheKey(for: configuration)
        guard let realm = cachedRealms[key], !realm.isInWriteTransaction else {
            return false
        }
        cachedRealms.removeValue(forKey: key)
        realm.invalidate()
        return true
    }
}
