import Foundation

/// Thread-safe, resume-exactly-once wrapper around a `CheckedContinuation`.
///
/// PhotoKit / AVFoundation completion handlers can fire on arbitrary threads and,
/// for some requests, more than once (e.g. `PHImageManager` delivers a degraded
/// placeholder followed by the full result). Resuming a `CheckedContinuation`
/// twice traps, and never resuming it hangs the awaiting task forever. This box
/// guarantees a single resume and runs an optional cleanup hook (used to cancel
/// the in-flight request and any timeout) on the first resume.
final class ContinuationResumer<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    private var continuation: CheckedContinuation<T, Never>?

    /// Invoked exactly once, on the first `resume(_:)`. Set this after creating
    /// the resumer to cancel the underlying request and/or timeout task. Not
    /// `@Sendable` so it can capture thread-safe-but-non-`Sendable` request
    /// managers (e.g. `PHImageManager`); the box itself is `@unchecked Sendable`.
    var onResume: (() -> Void)?

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    /// Resumes the continuation with `value` if it has not already been resumed.
    /// Subsequent calls are no-ops. Returns true only for the call that resumed,
    /// so a caller can tell which of two racing outcomes was delivered.
    @discardableResult
    func resume(_ value: sending T) -> Bool {
        lock.lock()
        guard !resumed, let continuation else {
            lock.unlock()
            return false
        }
        resumed = true
        self.continuation = nil
        let cleanup = onResume
        onResume = nil
        lock.unlock()

        cleanup?()
        continuation.resume(returning: value)
        return true
    }
}

/// Carries a task's cancellation to a request whose resumer is made inside
/// `withCheckedContinuation`'s closure. The cancel can arrive before the
/// action is installed; `install` then runs the action at once.
final class CancelRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var action: (() -> Void)?

    var isCancelled: Bool { lock.withLock { cancelled } }

    func install(_ action: @escaping () -> Void) {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            action()
            return
        }
        self.action = action
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let action = self.action
        self.action = nil
        lock.unlock()
        action?()
    }
}

/// `withCheckedContinuation` that also answers task cancellation: when the
/// calling task is cancelled, the action given to `relay.install` runs once.
/// Without this, a card swiped away or a cell scrolled off kept its PhotoKit
/// request (and any iCloud download) running to the end.
/// Runs on the caller's actor, like `withCheckedContinuation`, so `body` never
/// crosses an isolation boundary.
@discardableResult
func withCancellableContinuation<T>(
    isolation: isolated (any Actor)? = #isolation,
    _ body: (CheckedContinuation<T, Never>, CancelRelay) -> Void
) async -> T {
    let relay = CancelRelay()
    return await withTaskCancellationHandler {
        await withCheckedContinuation { body($0, relay) }
    } onCancel: {
        relay.cancel()
    }
}

/// The id of a PhotoKit request that another thread can cancel before the call
/// that starts it has returned. A cancel that comes first is applied as soon
/// as `started` records the id, so the request never runs on unobserved.
final class PendingRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var id: Int32?
    private var cancelled = false
    private let cancelRequest: (Int32) -> Void

    /// `cancelRequest` calls PhotoKit, so it never runs while `lock` is held.
    init(cancel cancelRequest: @escaping (Int32) -> Void) {
        self.cancelRequest = cancelRequest
    }

    func started(_ id: Int32) {
        let cancelNow = lock.withLock {
            self.id = id
            return cancelled
        }
        if cancelNow { cancelRequest(id) }
    }

    func cancel() {
        let id = lock.withLock {
            cancelled = true
            return self.id
        }
        if let id { cancelRequest(id) }
    }
}

/// Throwing counterpart of `ContinuationResumer`, for `withCheckedThrowingContinuation`.
final class ThrowingContinuationResumer<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    private var continuation: CheckedContinuation<T, Error>?

    var onResume: (() -> Void)?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    private func take() -> CheckedContinuation<T, Error>? {
        lock.lock()
        guard !resumed, let continuation else {
            lock.unlock()
            return nil
        }
        resumed = true
        self.continuation = nil
        let cleanup = onResume
        onResume = nil
        lock.unlock()
        cleanup?()
        return continuation
    }

    func resume(returning value: sending T) {
        take()?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        take()?.resume(throwing: error)
    }
}
