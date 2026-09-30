# Cache-open identity boundary

This source-only refinement follows RealmSwiftGaps #5. Existing-file opens
retain the original configuration/resource identity through the asynchronous
Realm initializer. Publication and each joined return reject a changed file;
pending tasks retain only a cache key, not a live Realm. The protocol's default
opener also retains its admitted key across suspending cache accessors.

Automatic schema discovery, an explicit empty schema, and differing active
version limits no longer share a configuration key. Scoped eviction refuses an
active transaction and documents its quiescence precondition.

The package's existing XCTest source now includes deterministic actor-owned
open/publication barriers, replacement rejection for owner and waiter, a fresh
replacement successor, post-publication waiter replacement/eviction, missing-file
creation coalescing, default-opener publication, option-key separation, and
active-transaction preservation. All barriers are instance scoped; no mutable
global test hook or Reader test UI was introduced.

## Evidence limits

No tests, builds, syntax checks or test discovery were run for this refinement.
Apple/Realm typechecking and runtime qualification are deferred to the batch.
Historical #5 results do not qualify these changed sources.

First creation intentionally permits a missing-file-to-created-file identity
transition. Pathname checks alone do not establish which file Realm opened if
an external process replaces that first-created file during initialization.
Replacing a Realm file requires caller quiescence, including independently held
Realms, pending operations and other processes. This is a cache-publication
fence, not a filesystem replacement protocol or account lease.

This repair does not identify the historical `staleAuthority` predicate or
demonstrate that its scheduling latency disappeared. No schema, CloudKit,
release policy or production data was changed.
