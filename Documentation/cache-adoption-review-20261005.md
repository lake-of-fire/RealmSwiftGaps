# Cache lookup and adoption boundary reassessment — October 5, 2026

## Source boundary

This change is based on Reader #286's selected RealmSwiftGaps `93ac0cfa15e336946713e398ea2b1af7b6258543`, the head of #12. Inspected Reader head: `190cc19fc0e26db11c94b7cc630d5eb0771eabcf`. The separate synchronous-commit/notification writer fix is preserved unchanged. No Reader pin, writer implementation, schema, storage-admission creation policy or release gate is changed here.

The older Lake #103 finding is merged, and newer Lake #107 source already includes initialization, deletion and metadata selection fencing. This review did not reapply their older source. Current file-manager read/import and publication paths were reviewed as adjacent boundaries, but this patch makes no claim to close every storage-lifetime path in those larger adapters.

## Finding 1: a delayed read-only cache lookup can return a replaced store

The canonical default opener checks its storage key around suspended cache operations. `existingCachedRealm(for:)` did not: it computed the key and immediately returned the awaited `getCachedRealm` result.

A conforming actor can capture a cached Realm, suspend for another collaborator, then return that captured Realm after the file at the configured path has been replaced or removed. Calling a read-only convenience method does not make the returned store identity current.

The revised method captures its original key, awaits the same cache lookup, then recomputes and compares identity before returning. A mismatch returns nil. It neither opens a replacement nor invalidates/evicts the original Realm, which another operation may still own.

This is a source-level asynchronous ordering defect with authored actual-Realm regression histories. Native execution is not inferred from the source proof or from compiler-only tests. No historical user incident is attributed to it.

## Finding 2: configuration-only adoption bypasses the opener's identity proof

`setCachedRealm(_:for:)` computed a current key for any supplied live Realm. `setCachedRealmIfNeeded(_:for:)` additionally suspended while checking an existing entry and could then publish the supplied Realm under a newly recomputed key. Neither API knew the resource identity which admitted that Realm's original open. Comparing the Realm's configuration with the supplied configuration cannot recover that missing proof after same-path file replacement.

Both configuration-based convenience overloads are now unavailable with an actionable compiler diagnostic directing callers to `cachedRealm(for:)`. This is an intentional source-level API restriction, not a source-compatible no-op. The keyed protocol primitives remain available to concrete opener implementations; their contract is documented. This does not claim to eliminate every possible misuse of those low-level primitives or to supply a linearizable cache protocol for arbitrary asynchronous conformers.

The existing canonical opener remains a protocol requirement, preserving specialized dispatch and first-open coalescing. The read-only convenience lookup remains public. There is no new cache, queue, lock, lease or alternative Realm-adoption framework.

Repository code search across Reader, Common, Core, BigSync, Lake and RealmSwiftGaps found the convenience declarations but no application adoption call. That search covers indexed default branches, not every selected private branch or downstream consumer. A complete consuming-app build must confirm compatibility before landing. This API-level hazard is not evidence that a current application call is exploiting it.

## Executed compiler contracts

`Tests/Compiler/run_cache_api_contract.py` compiles the complete exact cache source and three actual public-API consumers in Swift 5 and Swift 6 modes. Explicit compiler-surface RealmSwift and CryptoKit modules provide declarations only; no Realm transactions, storage, hashing or filesystem identity behavior is simulated as a pass.

| Consumer | Exact original source | Revised source |
| --- | --- | --- |
| Canonical opener and read-only lookup | Compiles in both modes | Compiles in both modes |
| Configuration-based setCachedRealm | Compiles in both modes | Rejected as unavailable in both modes |
| Configuration-based setCachedRealmIfNeeded | Compiles in both modes | Rejected as unavailable in both modes |

Six expected compiler outcomes were verified for each source with Swift 6.2.1 on Linux x86_64, then repeated through the committed runner. The revised complete source and all consumer invocations use warnings-as-errors. The exact original source emits three pre-existing redundant-public warnings inside its public extension: the first strict baseline-module failure is retained, and the subsequent baseline module build does not promote those warnings. The original file is not rewritten. Its consumers still use warnings-as-errors. These are compiler-contract checks, not twelve native behavioral tests.

Complete native test and changed production files also passed frontend parsing with DEBUG enabled. Parsing does not resolve the Apple SDK or typecheck Realm macros.

### Exact local identities

- Original source Git blob: `c936904ebe7297e0540b0b55c39df512efc03cd3`.
- Revised source Git blob: `6954c4c90933b31de92ce90e22b1c33cd048598d`.
- Native test Git blob: `d789fb2ae73f9fb233e50992cf6f1ae8b28ad7ac`.
- Compiler runner Git blob: `32425fa4c00795e11a8d0d942e2bd19df16bdbe1`.
- Revised runner receipt SHA-256: `1ffa9815d603e31d33f6011a496e898d2a84d7fecefafe4d72aa9b2053f46660`.
- Original runner receipt SHA-256: `633972a6cbfc3b431638d1c3167128396f2c0deae314ffc7566a86a0596b9bce`.

Reproduce into a new directory; the runner refuses to overwrite evidence:

```sh
python3 Tests/Compiler/run_cache_api_contract.py --results-dir /absolute/task-owned/cache-fixed
python3 Tests/Compiler/run_cache_api_contract.py --source /absolute/original/CachedRealmsActor.swift \
  --expect-legacy --results-dir /absolute/task-owned/cache-original
```

## Native behavioral inventory — authored, not yet qualified at publication

The complete `RealmCacheLookupBoundaryTests.swift` uses actual actor-confined Realm files, explicit schemas and a uniquely named Objective-C test model excluded from the default schema. Only the asynchronous cache lookup is held. It does not substitute a fake Realm or transfer a live Realm between actors.

Six required methods:

1. `testMissingReadOnlyLookupDoesNotOpenOrCreateARealm`
2. `testCurrentCachedRealmRemainsReadableWithoutAnotherInsertion`
3. `testSamePathReplacementDuringLookupReturnsMissWithoutInvalidatingOldOwner`
4. `testDisappearedPathDuringLookupReturnsMissAndRetainsOriginalOwner`
5. `testUnrelatedFileReplacementDoesNotWithdrawCurrentCacheHit`
6. `testInMemoryCacheLookupDoesNotDependOnUnrelatedDiskState`

The replacement histories assert that the actual file resource identity changes, the obsolete result is rejected, the original owner remains readable, and no replacement bytes or cache entries are modified. Gates are released and tasks joined on error paths. Missing lookup must not create a Realm; unrelated file changes must not cause false misses.

The native workflow copies complete production sources and the complete six-method test file into an isolated package, pins real RealmSwift 20.0.5 in its temporary manifest, retains actual resolved dependencies/compiler/source hashes and requires all six identities without skips in each configuration. At this document's publication, no result is anticipated. It runs no UI, signing, CloudKit, performance or application Release acceptance. The compiler-only workflow remains explicitly separate.

## Integration and remaining limits

Reader #286 is the sole current continuation. This component branch is stacked on #12 to avoid replacing that independently reviewed writer repair. Root selection must preserve concurrent pins, add the new vendor test file to the real Reader target and both required-method inventories, reconcile source fingerprints, and verify Xcode discovery plus affected native behavior. Package test discovery is not root discovery.

Authentic distributed Reader 3.11/build-327 provenance, genuine second-account evidence and owner-deferred Mac UI/signed/performance/application Release remain separate. Neither an unavailable API nor a cache-key comparison grants mutation authority, certifies a power-loss/cross-process replacement protocol, qualifies the whole app or authorizes release.
