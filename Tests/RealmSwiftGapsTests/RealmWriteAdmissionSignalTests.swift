import Dispatch
import XCTest
@testable import RealmSwiftGaps

/// Exercises the production signal without Realm, a simulator, sleeps or actor
/// scheduling guesses. SDK/transaction behavior remains covered by the owning
/// Realm tests; a signal-only pass cannot qualify the private SDK bridge.
// Each test uses only local signal state. Nonisolated entry points and a
// static helper avoid transferring XCTestCase across actor boundaries during
// SwiftPM discovery, without unchecked Sendable conformance on the test case.
@MainActor
final class RealmWriteAdmissionSignalTests: XCTestCase {
    private enum Event {
        case registerWaiter, admit, cancel
    }

    nonisolated private static func admitted(after events: [Event]) async -> Bool {
        let signal = RealmWriteAdmissionSignal()
        await withCheckedContinuation { continuation in
            for event in events {
                switch event {
                case .registerWaiter: signal.wait(continuation)
                case .admit: signal.admit()
                case .cancel: signal.cancel()
                }
            }
        }
        return signal.disarmAndTakeAdmission()
    }

    nonisolated func testAdmissionBeforeAndAfterWaiterRegistration() async {
        for events: [Event] in [
            [.admit, .registerWaiter],
            [.registerWaiter, .admit],
        ] {
            let ownsTransaction = await Self.admitted(after: events)
            XCTAssertTrue(ownsTransaction)
        }
    }

    nonisolated func testCancellationBeforeAndAfterWaiterRegistrationDoesNotGrantOwnership() async {
        for events: [Event] in [
            [.cancel, .registerWaiter],
            [.registerWaiter, .cancel],
        ] {
            let ownsTransaction = await Self.admitted(after: events)
            XCTAssertFalse(ownsTransaction)
        }
    }

    nonisolated func testEveryRegistrationAdmissionCancellationOrderPreservesActualAdmission() async {
        // Cancellation wakes the caller, but actual admission before the owner
        // resumes still grants rollback rights. Cancellation is not ownership.
        for events: [Event] in [
            [.registerWaiter, .admit, .cancel],
            [.registerWaiter, .cancel, .admit],
            [.admit, .registerWaiter, .cancel],
            [.admit, .cancel, .registerWaiter],
            [.cancel, .registerWaiter, .admit],
            [.cancel, .admit, .registerWaiter],
        ] {
            let ownsTransaction = await Self.admitted(after: events)
            XCTAssertTrue(ownsTransaction)
        }
    }

    nonisolated func testDisarmRejectsSyntheticSDKCallbackAfterQueuedCancellation() async {
        let signal = RealmWriteAdmissionSignal()
        await withCheckedContinuation { continuation in
            signal.wait(continuation)
            signal.cancel()
        }
        XCTAssertFalse(signal.disarmAndTakeAdmission())
        // begin.complete(true) invokes the same SDK callback as admission.
        // It must not manufacture ownership after the actor disarms the signal.
        signal.admit()
        signal.cancel()
        XCTAssertFalse(signal.disarmAndTakeAdmission())
    }

    nonisolated func testDisarmPreservesAdmissionDespiteLateCancellationAndCallbacks() async {
        let signal = RealmWriteAdmissionSignal()
        await withCheckedContinuation { continuation in
            signal.wait(continuation)
            signal.admit()
        }
        XCTAssertTrue(signal.disarmAndTakeAdmission())
        signal.cancel()
        signal.admit()
        XCTAssertTrue(signal.disarmAndTakeAdmission())
    }

    nonisolated func testRepeatedEventsResumeRegisteredContinuationOnlyOnce() async {
        let ownsTransaction = await Self.admitted(after: [
            .registerWaiter, .cancel, .cancel, .admit, .admit, .cancel,
        ])
        XCTAssertTrue(ownsTransaction)
    }

    nonisolated func testRepeatedEventsBeforeRegistrationStillSettleWaiter() async {
        let ownsTransaction = await Self.admitted(after: [
            .cancel, .cancel, .admit, .admit, .registerWaiter, .cancel,
        ])
        XCTAssertTrue(ownsTransaction)
    }

    nonisolated func testConcurrentAdmissionAndCancellationPreserveOwnershipAndResumeOnce() async {
        for _ in 0..<64 {
            let signal = RealmWriteAdmissionSignal()
            await withCheckedContinuation { continuation in
                signal.wait(continuation)
                DispatchQueue.concurrentPerform(iterations: 2) { index in
                    if index == 0 { signal.admit() } else { signal.cancel() }
                }
            }
            // Both callbacks completed before the actor takes its snapshot.
            XCTAssertTrue(signal.disarmAndTakeAdmission())
        }
    }
}
