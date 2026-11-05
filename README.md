# RealmSwiftGaps

Actor-owned Realm caches, captured storage admission and queued asynchronous writes.

Use `CachedRealmsActor.cachedRealm(for:)` to open and publish a Realm on its owning
actor. Custom caches must keep their Realm handles actor-local. The old
configuration-only adoption methods are unavailable: a supplied handle cannot
prove which file identity admitted its original open.

Capture `captureStorageAdmission(for:)` before suspending work whose result belongs
to a particular store, and pass that admission to `cachedRealm(for:storageAdmission:)`
or `prepareStorage(for:storageAdmission:)`. An admission for a missing writable,
unseeded file may exclusively create it; it cannot adopt a file created by an
unrelated operation.

## Replacing a file

Cache keys and suspended-open checks detect changes in filesystem identity. They
do not coordinate file replacement or close Realm handles held elsewhere. Realm
Core shares its native coordinator by path while a handle remains alive, so opening
the same path again can still return the old store.

Before replacing or deleting a Realm file, quiesce all users and pending opens and
writes, release the matching cache entry while the original file identity is still
present, and release independently retained Realms, objects and results on every
actor. `RealmBackgroundActor.removeCachedRealm(for:)` releases only that actor's
matching entry and refuses an active write. Custom caches must implement their own
scoped retirement. Reopen only after old users have settled. An existing-only probe
that races replacement returns `nil`; it does not retire the old cache entry.

## Write ownership and SDK verification

`asyncWritePreservingOwnership` queues an independent transaction in the calling
task on the Realm's owning actor. Cancellation before admission cancels only that
request; cancellation or a thrown error during the owned write rolls it back. Once
commit is submitted, the call awaits durable settlement. A body that commits
synchronously is supported; signal failure by throwing rather than cancelling and
replacing the admitted transaction yourself. `writeIfNeeded` remains for callers
intentionally joining their current transaction.

The ownership bridge uses `Realm.Private` begin tickets and native frozen-version
identity. Review those SDK contracts and run the ownership regressions whenever
updating Realm. The retained resolution selects Realm Swift 20.0.5 / Core 20.1.5;
Core 20.1.5 fixes the S2 comparator compilation failure with the current Xcode C++
standard library. This package's lockfile does not pin a consuming application's
resolution, which needs its own compatibility verification.

Run the package's native XCTest suite in both Debug and Release. It covers queued
write ownership, cancellation, durable commits, file admission and cache fencing.
