import Foundation

// Only this signal crosses executors. Realm and transaction ownership stay on
// the Realm owning actor. SDK completion means admission unless the actor has
// disarmed the signal before cancelling the SDK ticket.
final class RealmWriteAdmissionSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var admitted = false
    private var cancelled = false
    private var disarmed = false

    func wait(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        if admitted || cancelled {
            lock.unlock()
            continuation.resume()
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func admit() {
        lock.lock()
        guard !disarmed else {
            lock.unlock()
            return
        }
        admitted = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }

    func disarmAndTakeAdmission() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        disarmed = true
        return admitted
    }
}
