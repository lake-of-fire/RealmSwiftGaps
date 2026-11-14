# Realm cache identity

A cache key represents the file resource and effective open configuration, including schema, object types, read-only access, version limits and encryption. Existing-file opens retain that identity across suspension. Publication, joined waiters and read-only cache hits reject a file replaced at the configured path.

Pending opens retain a cache key rather than a live Realm. Eviction can therefore release a transient configuration without a completed task retaining its handle. Eviction requires quiescent callers and refuses an active write transaction; it does not close independently held Realms or coordinate another process.

Captured storage admission owns first creation. It reserves the inode with exclusive creation and advances its identity only for that inode. An external file, a read-only configuration or a seeded open cannot silently adopt the pending creation.

Execution protection is a separate boundary. Opens and writes retain the host lease until native storage work settles. Cancellation before write admission removes only that submission or waits for its already-requested native lock before rollback. A submitted commit retains ownership until its durable completion. Synchronous helpers never borrow another caller's open transaction.

The private native begin-ticket and frozen-version contracts are pinned to Realm 20.0.5 and require qualification before an SDK upgrade. Deterministic observation hooks and their consuming fixtures are DEBUG-only.
