# Owned Realm write boundary — October 4, 2026

## Decision

Keep the current original-actor/original-task writer architecture. Do not add a
second transaction queue, detached mutation task, adapter-specific writer or new
sync journal. The recent failures distinguish **being resumed** from **owning an
admitted transaction**. That distinction belongs in the shared Realm boundary,
not in each Unmark, note, archive or BigSync call site.

This review is stacked on RealmSwiftGaps #9, commit
`cac6eb96fcd6a645d8d1329079a72f7bab41f929`. Its production algorithm is retained
without modification. The source extraction was checked against the original
`RealmBackgroundActor.swift` Git blob
`a45995ab3b428b3a9dd78b633ea5e856240ea3bd`.

## Separate responsibilities

- `RealmBackgroundActor.swift`: cached Realm lifetime and convenience entries.
- `RealmOwnedWrite.swift`: the public owned-write API and private SDK bridge;
  this is the single upgrade-review surface for `Realm.Private`.
- `RealmWriteAdmissionSignal.swift`: Foundation-only cross-executor signal.
  It never touches a Realm, invokes the mutation, or commits/rolls back anything.

All existing method signatures, actor isolation, task-local observation hooks,
SDK calls, closure/result carriers and transaction/cancellation checks remain
unchanged. This is not a second proposed repair competing with #9.

## Invariants which must survive later refactors

| Boundary | Cancellation / settlement rule |
| --- | --- |
| Waiting for the SDK ticket | Wake the original caller; do not infer ownership from the Realm's current transaction flag. |
| Caller resumes without admission | Disarm the signal before cancelling only the queued SDK ticket. Never roll back another owner. |
| Actual admission before caller resumption | Admission remains true even if cancellation woke the caller first. The caller must roll back its own transaction. |
| Synchronous commit inside the operation | Preserve the already-durable result after cancellation. Do not reopen or undo it. |
| Async commit already submitted | Await durable settlement; cancellation cannot revoke the submitted commit or its completion callback. |

The subtle case is cancellation followed by admission before the original actor
resumes. Making cancellation and admission mutually exclusive would leak an
admitted transaction. Conversely, a callback produced by cancelling the SDK
ticket after disarming must not manufacture admission.

The pinned SDK sources independently reviewed were
`realm/realm-swift@v20.0.5`, `RealmSwift/Realm.swift` (`asyncWrite`) and
`Realm/RLMAsyncTask.mm` (`RLMAsyncWriteTask.wait` / `complete`). The private task
uses the same waiter callback for actual completion and cancellation. Its
callback is invoked outside its own mutex. Do not replace it with a public
callback bridge without proving the original task/actor/lifetime contract.

Source links:
- https://github.com/realm/realm-swift/blob/v20.0.5/RealmSwift/Realm.swift
- https://github.com/realm/realm-swift/blob/v20.0.5/Realm/RLMAsyncTask.mm
- https://github.com/lake-of-fire/RealmSwiftGaps/pull/9

## Verification scope

`bash Scripts/test-write-admission.sh` copies the exact production signal and
its XCTest file into a temporary dependency-free package. It does not implement
a second model, stub Realm, change installed dependencies, or access app data.
The temporary directory is removed on exit.

Eight tests passed on Linux with Swift 6.2.1. They cover waiter registration on
either side of admission/cancellation, all six registration/admission/cancellation
orders, synthetic callbacks after disarming, late cancellation, repeated signals
and 64 concurrent admission/cancellation pairs. This is a signal-only result:
it does **not** qualify Realm admission, rollback, durability, SDK behavior,
Apple actor/executor behavior, the full package, or the composed application.

The existing native tests in #9 remain required, particularly queued cancellation
behind an independent owner, rollback isolation, original task/context, generic
non-Sendable results and post-submission durable completion. New source and test
files also require native discovery/inventory reconciliation wherever the Reader
qualification runner uses an explicit file or method inventory rather than Swift
Package discovery. No native test, full build or application result is claimed.

## Further SDK and strict-concurrency review

The pinned Swift SDK's `dependencies.list` selects Realm Core v20.1.5. Review of
that tag's `src/realm/object-store/shared_realm.cpp` confirms the boundary beneath
the Swift adapter: `run_writes` begins the transaction, delivers the notify-only
callback, and returns with the admitted transaction awaiting its owner. Cancelling
a queued begin removes that ticket; cancelling a queued commit instead removes
only its completion callback. The latter is not rollback. This supports retaining
admission-specific rollback and awaiting durable settlement after submission,
not introducing another task/queue or cancelling the commit notification.

Source: https://github.com/realm/realm-core/blob/v20.1.5/src/realm/object-store/shared_realm.cpp
Reviewed blob: `db7048ecb979d68aa94f6b95e92c8c8ec7caa8a6`.
This is pinned-source review, not execution of the C++ or native Realm boundary.

A stronger Swift 6 language-mode/warnings-as-errors probe of the original eight
tests failed during generated XCTest discovery, before any test ran. Their
actor-isolated async instance methods unnecessarily transferred XCTestCase across
that discovery boundary. The original default-mode pass above remains historical;
this failure is not a Realm writer failure or an application compiler result.

The tests now use nonisolated entry points and a static nonisolated helper. All
signal state is local to the method. The test case gains no unchecked Sendable
conformance; every original method name, assertion, event ordering and concurrent
iteration count remains. Production signal and SDK bridge source are unchanged.

The revised eight tests pass with Linux Swift 6.2.1 in strict Swift 6 unoptimized
and optimized configurations. Removing only the production signal's disarm guard
in a separate negative-control copy gives seven passes and one expected assertion
failure at `testDisarmRejectsSyntheticSDKCallbackAfterQueuedCancellation`, with
identical test bytes. Repeated configurations do not add unique tests. None of
these results qualify native admission, transaction rollback/durability, Apple
actor scheduling, the full package or the application.

The runner keeps its tools-version 5.9 manifest, bounds compilation to one job,
and forwards additional Swift test flags. Reproduce the strict probe with:

```sh
bash Scripts/test-write-admission.sh -Xswiftc -swift-version -Xswiftc 6 -Xswiftc -warnings-as-errors
```

Add `--configuration release` for the optimized portable harness only, not
application Release qualification. Required native owner/cancellation/durability
coverage and Reader source/method discovery remain unchanged and outstanding.

## Integration

Review/merge #9 before this stacked extraction, or preserve both commits in the
chosen composition. BigSync #96 and Common #246/Core #425 already migrate call
sites to the same public API. No additional BigSync writer layer is justified by
this review. Reader #286 must deliberately select the resulting helper commit
and run its composed acceptance batch; this PR changes no parent submodule pins.
Keep draft until that verification. No release authorization or production data
mutation is included.
