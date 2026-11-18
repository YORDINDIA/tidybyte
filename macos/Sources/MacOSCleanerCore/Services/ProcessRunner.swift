import Darwin
import Foundation
import os

struct ProcessResult: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    /// True when a stream exceeded the capture cap, so the output is a
    /// prefix of the real output and must not be treated as complete.
    let truncated: Bool

    init(exitCode: Int32, stdout: String, stderr: String, truncated: Bool = false) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.truncated = truncated
    }
}

enum ProcessRunner {
    /// Per-stream cap for captured output. Output beyond this is still drained
    /// (so the child never blocks on a full pipe buffer) but discarded, with a
    /// truncation note appended so callers know the output is incomplete.
    static let maxCapturedBytesPerStream = 1_048_576
    static let readChunkSize = 16_384
    static let truncationNote = "\n[ProcessRunner: output exceeded \(maxCapturedBytesPerStream) bytes; only the first portion is captured]"

    static func run(_ command: URL, arguments: [String], timeout: TimeInterval) async -> ProcessResult {
        if Task.isCancelled {
            return ProcessResult(exitCode: 1, stdout: "", stderr: "Cancelled.")
        }
        let process = Process()
        process.executableURL = command
        process.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // A child must never read the caller's stdin: the MCP server speaks JSON-RPC on it.
        process.standardInput = FileHandle.nullDevice

        let handle = ProcessExecutionHandle(process: process, stdoutPipe: stdoutPipe, stderrPipe: stderrPipe)
        let drains = PipeDrains(
            stdout: handle.stdoutPipe.fileHandleForReading,
            stderr: handle.stderrPipe.fileHandleForReading
        )
        drains.start()

        let startErrorBox = OSAllocatedUnfairLock<String?>(initialState: nil)
        let exitCode = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
                process.terminationHandler = { completedProcess in
                    continuation.resume(returning: completedProcess.terminationStatus)
                }

                guard handle.beginStart() else {
                    startErrorBox.withLock { $0 = "Cancelled." }
                    continuation.resume(returning: 1)
                    return
                }

                do {
                    try process.run()
                    handle.scheduleTimeout(seconds: timeout)
                } catch {
                    startErrorBox.withLock { $0 = error.localizedDescription }
                    handle.markExited()
                    continuation.resume(returning: 1)
                    return
                }
            }
        } onCancel: {
            handle.cancelAndTerminate(graceSeconds: 2)
        }

        handle.cancelTimers()

        if let startError = startErrorBox.withLock({ $0 }) {
            closePipes(of: handle)
            _ = await drains.waitAsync(seconds: 2)
            return ProcessResult(exitCode: 1, stdout: "", stderr: startError)
        }
        return await collectDrains(drains, didTimeOut: handle.didTimeOut, exitCode: exitCode, timeout: timeout)
    }

    private static func closePipes(of handle: ProcessExecutionHandle) {
        try? handle.stdoutPipe.fileHandleForReading.close()
        try? handle.stderrPipe.fileHandleForReading.close()
        try? handle.stdoutPipe.fileHandleForWriting.close()
        try? handle.stderrPipe.fileHandleForWriting.close()
    }

    /// Text with valid UTF-8 kept intact. Each invalid byte sequence becomes U+FFFD,
    /// so a bad byte never empties the whole output.
    static func readableText(_ data: Data) -> String {
        // The lossy decode is the point here, so the failable initializer is not wanted.
        // swiftlint:disable:next optional_data_string_conversion
        String(decoding: data, as: UTF8.self)
    }

    /// Every process below `pid`, found breadth-first through parent links.
    static func descendantPIDs(of pid: pid_t) -> [pid_t] {
        var found: [pid_t] = []
        var pending: [pid_t] = [pid]
        while let parent = pending.popLast() {
            let children = childPIDs(of: parent)
            found += children
            pending += children
        }
        return found
    }

    /// Direct children of `pid`, from libproc. Empty when none are listed or the call fails.
    static func childPIDs(of pid: pid_t) -> [pid_t] {
        let capacity = 256
        var buffer = [pid_t](repeating: 0, count: capacity)
        let returned = proc_listchildpids(pid, &buffer, Int32(capacity * MemoryLayout<pid_t>.size))
        guard returned > 0 else { return [] }
        // proc_listchildpids returns the number of pids, not a byte count.
        let count = min(Int(returned), capacity)
        return buffer.prefix(count).filter { $0 > 0 }
    }

    /// Bounded post-exit drain collection: a forked grandchild can inherit the
    /// pipe and hold it open long past the direct child's exit — the timeout
    /// only kills the direct child. Wait up to a grace window so the call
    /// returns on time with the bytes captured so far, marked truncated.
    private static func collectDrains(
        _ drains: PipeDrains, didTimeOut: Bool, exitCode: Int32, timeout: TimeInterval
    ) async -> ProcessResult {
        let finishedInTime = await drains.waitAsync(seconds: 5)
        let drained = drains.results()
        // Lossy decoding: non-UTF-8 output keeps its readable parts instead of becoming "".
        var stdoutStr = Self.readableText(drained.stdout.data)
        let stderrStr = Self.readableText(drained.stderr.data)
        var truncated = drained.stdout.capped || drained.stderr.capped
        if !finishedInTime {
            truncated = true
            stdoutStr += truncationNote
        }
        if didTimeOut {
            return ProcessResult(
                exitCode: 124, stdout: stdoutStr,
                stderr: "Command timed out after \(Int(timeout)) seconds.",
                truncated: truncated)
        }
        return ProcessResult(exitCode: exitCode, stdout: stdoutStr, stderr: stderrStr, truncated: truncated)
    }
}

private struct DrainedOutput: Sendable {
    var data = Data()
    var capped = false
}

/// Reads a pipe until EOF in small chunks so a full buffer never blocks the
/// child. Captures at most `maxCapturedBytesPerStream` bytes and keeps
/// discarding the rest, appending a truncation note when output was cut.
private func drain(_ fileHandle: FileHandle) -> DrainedOutput {
    var output = DrainedOutput()
    while let chunk = try? fileHandle.read(upToCount: ProcessRunner.readChunkSize), !chunk.isEmpty {
        if output.data.count >= ProcessRunner.maxCapturedBytesPerStream {
            output.capped = true
            continue
        }
        let remaining = ProcessRunner.maxCapturedBytesPerStream - output.data.count
        output.data.append(chunk.prefix(remaining))
        if chunk.count > remaining {
            output.capped = true
        }
    }
    if output.capped {
        output.data.append(Data(ProcessRunner.truncationNote.utf8))
    }
    return output
}

/// Wraps DispatchWorkItem for lock-protected Sendable transfer in Swift 6 closures.
private struct WorkBox: @unchecked Sendable {
    let item: DispatchWorkItem
}

/// Runs both pipe drains on a dedicated GCD queue and suspends cleanly without
/// blocking Swift cooperative-pool threads.
private final class PipeDrains: @unchecked Sendable {
    private struct State: @unchecked Sendable {
        var stdout: DrainedOutput?
        var stderr: DrainedOutput?
        var finishedCount = 0
        var waiter: CheckedContinuation<Bool, Never>?
        var waitTimeoutWork: WorkBox?
    }

    private let queue = DispatchQueue(label: AppIdentity.bundleIdentifier + ".process-drain", attributes: .concurrent)
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let stdoutHandle: FileHandle
    private let stderrHandle: FileHandle

    init(stdout: FileHandle, stderr: FileHandle) {
        self.stdoutHandle = stdout
        self.stderrHandle = stderr
    }

    func start() {
        queue.async { [self] in
            let out = drain(stdoutHandle)
            publishDrain(stdout: out)
        }
        queue.async { [self] in
            let err = drain(stderrHandle)
            publishDrain(stderr: err)
        }
    }

    private func publishDrain(stdout: DrainedOutput? = nil, stderr: DrainedOutput? = nil) {
        let continuationToResume: CheckedContinuation<Bool, Never>? = state.withLock { st in
            if let stdout { st.stdout = stdout }
            if let stderr { st.stderr = stderr }
            st.finishedCount += 1
            guard st.finishedCount >= 2, let waiter = st.waiter else { return nil }
            st.waitTimeoutWork?.item.cancel()
            st.waitTimeoutWork = nil
            st.waiter = nil
            return waiter
        }
        continuationToResume?.resume(returning: true)
    }

    /// Suspends up to `seconds` for both drains to reach EOF.
    func waitAsync(seconds: TimeInterval) async -> Bool {
        if state.withLock({ $0.finishedCount >= 2 }) {
            return true
        }
        return await withCheckedContinuation { continuation in
            let timeoutBox = WorkBox(item: DispatchWorkItem { [weak self] in
                let waiter = self?.state.withLock { st -> CheckedContinuation<Bool, Never>? in
                    guard let pending = st.waiter else { return nil }
                    st.waitTimeoutWork = nil
                    st.waiter = nil
                    return pending
                }
                waiter?.resume(returning: false)
            })
            let immediate: CheckedContinuation<Bool, Never>? = state.withLock { st in
                if st.finishedCount >= 2 {
                    return continuation
                }
                st.waiter = continuation
                st.waitTimeoutWork = timeoutBox
                queue.asyncAfter(deadline: .now() + seconds, execute: timeoutBox.item)
                return nil
            }
            immediate?.resume(returning: true)
        }
    }

    /// Published drain outputs (empty for a drain that has not hit EOF yet).
    func results() -> (stdout: DrainedOutput, stderr: DrainedOutput) {
        state.withLock { st in
            (st.stdout ?? DrainedOutput(), st.stderr ?? DrainedOutput())
        }
    }
}

/// Thread-safe handle coordinating process lifecycle, timeouts, and cooperative cancellation on GCD.
private final class ProcessExecutionHandle: @unchecked Sendable {
    private struct LifecycleState: @unchecked Sendable {
        var didTimeOut = false
        var cancelled = false
        var started = false
        var exited = false
        var timeoutWork: WorkBox?
        var killWork: WorkBox?
    }

    let process: Process
    let stdoutPipe: Pipe
    let stderrPipe: Pipe
    private let queue = DispatchQueue(label: AppIdentity.bundleIdentifier + ".process-control")
    private let stateLock = OSAllocatedUnfairLock(initialState: LifecycleState())

    var didTimeOut: Bool {
        stateLock.withLock { $0.didTimeOut }
    }

    init(process: Process, stdoutPipe: Pipe, stderrPipe: Pipe) {
        self.process = process
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
    }

    func beginStart() -> Bool {
        stateLock.withLock { st in
            if st.cancelled {
                st.exited = true
                return false
            }
            st.started = true
            return true
        }
    }

    func markExited() {
        stateLock.withLock { $0.exited = true }
    }

    func scheduleTimeout(seconds: TimeInterval) {
        let workBox = WorkBox(item: DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.stateLock.withLock { $0.didTimeOut = true }
            self.terminateProcessTree(graceSeconds: 5)
        })
        let shouldSchedule = stateLock.withLock { st -> Bool in
            guard !st.exited, !st.cancelled else { return false }
            st.timeoutWork = workBox
            return true
        }
        if shouldSchedule {
            queue.asyncAfter(deadline: .now() + seconds, execute: workBox.item)
        }
    }

    func cancelAndTerminate(graceSeconds: TimeInterval) {
        let shouldTerminate = stateLock.withLock { st -> Bool in
            st.cancelled = true
            return st.started && !st.exited
        }
        if shouldTerminate {
            terminateProcessTree(graceSeconds: graceSeconds)
        }
    }

    func cancelTimers() {
        let (tWork, kWork) = stateLock.withLock { st -> (WorkBox?, WorkBox?) in
            st.exited = true
            let works = (st.timeoutWork, st.killWork)
            st.timeoutWork = nil
            st.killWork = nil
            return works
        }
        tWork?.item.cancel()
        kWork?.item.cancel()
    }

    private func terminateProcessTree(graceSeconds: TimeInterval) {
        let pid = process.processIdentifier
        guard pid > 0, process.isRunning else { return }
        let workers = ProcessRunner.descendantPIDs(of: pid)
        for worker in workers where worker > 0 {
            _ = Darwin.kill(worker, SIGTERM)
        }
        process.terminate()

        let killBox = WorkBox(item: DispatchWorkItem { [weak self] in
            guard let self, self.process.isRunning else { return }
            let remaining = ProcessRunner.descendantPIDs(of: pid)
            for worker in remaining where worker > 0 {
                _ = Darwin.kill(worker, SIGKILL)
            }
            if self.process.isRunning {
                _ = Darwin.kill(pid, SIGKILL)
            }
        })
        let shouldScheduleKill = stateLock.withLock { st -> Bool in
            guard !st.exited else { return false }
            st.killWork?.item.cancel()
            st.killWork = killBox
            return true
        }
        if shouldScheduleKill {
            queue.asyncAfter(deadline: .now() + graceSeconds, execute: killBox.item)
        }
    }
}
