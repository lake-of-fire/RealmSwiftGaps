# Cache actor and execution-receipt follow-up — October 5, 2026

## Preserving the live composition

RealmSwiftGaps #13 (`f806bc1a007038703d1bc2141f39f3c6ec8a08a6`) was integrated into #12's development branch while this reassessment continued. This successor is based on that exact commit and preserves both the cache adoption restrictions and the synchronous-commit/notification writer repair. It does not update the protected package target or Reader root.

## Additional production finding: the protocol did not require an actor

`CachedRealmsActor` inherited only `AnyObject`. Putting default implementations in an extension constrained by `Self: Actor` did not make the asynchronous protocol requirements actor-isolated. Actual Apple compilation consequently reported non-Sendable Realm transfers at those requirements and default cache calls.

The protocol now inherits `Actor`, and the redundant extension constraint is removed. Cache requirements and defaults belong to their actor by construction. There is no new task, actor instance, queue, global state, detached operation or unchecked Sendable conformance on Realm. Nonisolated storage-key/admission capture methods remain explicitly nonisolated.

This strengthens the public conformer contract: arbitrary non-actor classes can no longer claim to implement an actor cache. Together with #13's unavailable configuration-only adoption overloads, it requires downstream source compatibility checking. The package's concrete RealmBackgroundActor and the native fixture are actors; the discovered Lake consumer is also an actor. Indexed code search is not a full selected-graph compatibility audit.

### Compiler evidence

Using the same complete production source and an explicit non-Sendable Realm compiler collaborator, the pre-constraint source fails strict-complete-concurrency/warnings-as-errors module compilation in Swift 5 and Swift 6 modes. The actor-constrained source and the canonical actor consumer compile in both modes. No native Realm behavior is attributed to that model.

The committed API runner now supports `--non-sendable-realm`. Both the original availability-only surface and the stricter non-Sendable actor surface complete all six expected consumer outcomes locally. The older availability fixture intentionally made its Realm value Sendable to isolate overload availability; it did not establish the actor-isolation property. The new stricter run closes that compiler-test gap rather than silently relabeling the earlier result.

Current production blob: `2ce0f0ecc30d8c10d793bfb552e090656cbf8635`.
Current compiler runner blob: `f819b08525a7a1f9e6b3b4fcadcac05b4a0eef27`.
Native six-method test blob remains unchanged: `d789fb2ae73f9fb233e50992cf6f1ae8b28ad7ac`.

## First actual Apple result and the separate workflow failure

The initial #13 native Release invocation actually compiled the complete production package and executed **all six XCTest methods successfully**, with process exit 0, on Apple Swift 6.1.2 / Xcode 16.4 / arm64 macOS. It resolved RealmSwift 20.0.5 (`ca03df491ec5e4bb8af0bca1e9957d08c10ec2da`) and Realm Core 20.1.5 (`b4192c46305570577c4d08df790fddec5ab3aa04`). Checkout: `ad8e4c8837073626e276a42c1a900727f773b94a`.

Its following receipt step failed because SwiftPM produced only the separate, empty Swift Testing XML file, not the assumed `results.xml` for XCTest. The job is therefore failed, not all-green CI. The six actual native passes remain recorded by their individual start/pass events and the owning XCTest suite result. They qualify only the original #13 inputs, not this later actor-constraint successor.

Retained artifact: `11369400766`, run `37369076053`, SHA-256 `7d393ac59ce2fa13f1d04ec5a48549b8b5e45cce3eb95569365f1cb6cae1c64b`. Downloaded archive verified; the complete native log SHA-256 is `58fd8c3ac0b4080f0fc8dff67bc59adfb55a07006208d121d2b3f3065ef901c6`. The original failure and warnings are retained. No warning-free whole-package or application qualification is claimed.

Initial compiler CI run `37369076078` succeeded on Swift 6.4 in both Swift language modes. Artifact `11368958303`, SHA-256 `98cc8681b360727fceec3a45f0ff2a6a80cc30889e450e8cfddbf0d55dd1f927`, contains the exact original #13 production bytes and six expected consumer results. That is compiler-only evidence, separate from Apple execution.

## Receipt repair and stronger negative controls

`Tests/Compiler/check_cache_native_receipt.py` validates individual XCTest start/terminal events, the enclosing owning suite, its six-method summary and the native process exit. A secondary zero-test Swift Testing result, a summary alone, missing/duplicate identities, skips, incomplete events, unexpected exceptions and terminated processes cannot pass.

Seventeen Python parser-contract tests pass locally. They are tests of evidence parsing, not seventeen native application tests. The parser also successfully reconciles the retained initial native Release log; this does not change the failed historical workflow's status.

The workflow explicitly disables shell errexit around native commands long enough to retain the real exit status before re-enabling it. A failing build/test or expected negative control can no longer omit its process receipt because the runner shell exited early.

The corrected native workflow performs two separately retained phases per configuration: the revised six-method suite, then the exact original cache source from `93ac0cfa` with the identical native tests and all other production inputs unchanged. The latter must fail precisely the same-path-replacement and disappeared-path methods while the four controls pass. Each phase has independent logs/status/receipt; no anticipated result is declared here. These tests run against actual Apple Realm, not the compiler collaborators.

## Remaining boundaries

Native compilation/execution of the final actor-constrained successor and complete Reader compatibility/discovery remain separate gates until actual receipts exist. No Realm creation policy, write ownership implementation, schema, sync receipt, account generation, UI, signing, production data or release flag is changed. This is not a performance measurement or application Release pass. Reader #286 remains the sole continuation and must retain the broader source-specific acceptance requirements.
