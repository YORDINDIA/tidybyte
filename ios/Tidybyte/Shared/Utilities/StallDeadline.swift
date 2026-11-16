import Foundation

/// Stall limit shared by the iCloud video load and the Live Photo still
/// download. A load fails only after this long with no progress, so a slow
/// download that keeps moving completes.
enum LoadStall {
    static let limit: TimeInterval = 20

    /// Monotonic seconds for `StallDeadline`. Uptime, not wall time, so a clock change cannot fake a stall.
    static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
}

/// The deadline of a load that is still making progress. Pure: the caller
/// passes the time, so tests can feed fake timestamps.
struct StallDeadline: Sendable {
    let limit: TimeInterval
    private(set) var lastProgress: TimeInterval

    init(limit: TimeInterval, startedAt now: TimeInterval) {
        self.limit = limit
        self.lastProgress = now
    }

    /// Progress moves the deadline forward. A late, older timestamp cannot move it back.
    mutating func recordProgress(at now: TimeInterval) {
        lastProgress = max(lastProgress, now)
    }

    /// Seconds left before the load counts as stalled. Zero means stalled.
    func remaining(at now: TimeInterval) -> TimeInterval {
        max(0, lastProgress + limit - now)
    }
}

/// Holds a `StallDeadline` behind an actor. Progress callbacks run on
/// arbitrary queues, so they only hop into this actor.
actor StallWatch {
    private var deadline: StallDeadline

    init(limit: TimeInterval = LoadStall.limit) {
        deadline = StallDeadline(limit: limit, startedAt: LoadStall.now())
    }

    func recordProgress(at now: TimeInterval) {
        deadline.recordProgress(at: now)
    }

    func remaining() -> TimeInterval {
        deadline.remaining(at: LoadStall.now())
    }
}

/// Calls `onStall` once the watch runs out of time. Cancel the returned task to stop it.
func watchForStall(_ watch: StallWatch, onStall: @escaping @Sendable () -> Void) -> Task<Void, Never> {
    Task {
        while !Task.isCancelled {
            let remaining = await watch.remaining()
            if remaining <= 0 {
                onStall()
                return
            }
            try? await Task.sleep(for: .seconds(remaining))
        }
    }
}

/// A value that callbacks on other queues read or write. PhotoKit completion
/// and cancel paths run on arbitrary queues, so every access takes the lock.
/// Never call PhotoKit while holding it: a synchronous callback would re-enter it.
final class LockedValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withValue<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
