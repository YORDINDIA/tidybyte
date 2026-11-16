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

        var startError: String?
        var timeoutTask: Task<Void, Never>?

        // Drain stdout and stderr concurrently WHILE the process runs. Reading
        // the pipes only after the process exits deadlocks the child once a
        // 64 KB pipe buffer fills, which previously forced a kill via timeout.
        // Each drain blocks on FileHandle.read until EOF, so they run on a
        // dedicated GCD queue — parking Swift cooperative-pool threads on
        // blocking pipe reads starved the timeout task and unrelated scan work.
        let drains = PipeDrains(
            stdout: handle.stdoutPipe.fileHandleForReading,
            stderr: handle.stderrPipe.fileHandleForReading)
        drains.start()

        let exitCode = await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
            process.terminationHandler = { p in
                continuation.resume(returning: p.terminationStatus)
            }

            do {
                try process.run()
            } catch {
                startError = error.localizedDescription
                continuation.resume(returning: 1)
                return
            }

            timeoutTask = Task { [handle] in
                try? await Task.sleep(for: .seconds(timeout))
                guard handle.process.isRunning else { return }
                handle.markTimedOut()
                let pid = handle.process.processIdentifier
                // Forked workers are not children of the launched process once it
                // exits, so the tree is captured and killed before the launched process
                // is signalled. Otherwise a worker can outlive `run`.
                let workers = Self.descendantPIDs(of: pid)
                for worker in workers { kill(worker, SIGKILL) }
                handle.process.terminate()
                // A child that ignores SIGTERM would keep the continuation parked forever.
                try? await Task.sleep(for: .seconds(5))
                if handle.process.isRunning {
                    kill(pid, SIGKILL)
                }
            }
        }

        timeoutTask?.cancel()

        if let startError {
            // The process never started, so the pipes will never reach EOF on
            // their own. Closing BOTH ends unblocks the drain tasks: the read-end
            // close makes any pending read fail, and dropping the write end
            // guarantees no reader can block forever waiting for data.
            try? handle.stdoutPipe.fileHandleForReading.close()
            try? handle.stderrPipe.fileHandleForReading.close()
            try? handle.stdoutPipe.fileHandleForWriting.close()
            try? handle.stderrPipe.fileHandleForWriting.close()
            drains.wait(seconds: 2)
            return ProcessResult(exitCode: 1, stdout: "", stderr: startError)
        }
        return await collectDrains(drains, didTimeOut: handle.didTimeOut, exitCode: exitCode, timeout: timeout)
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
        let finishedInTime = drains.wait(seconds: 5)
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

/// Runs both pipe drains on a dedicated GCD queue and bounds how long the
/// caller waits for them after the process exits.
private final class PipeDrains: @unchecked Sendable {
    private struct State {
        var stdout: DrainedOutput?
        var stderr: DrainedOutput?
        var finishedCount = 0
    }

    private let queue = DispatchQueue(label: AppIdentity.bundleIdentifier + ".process-drain", attributes: .concurrent)
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let semaphore = DispatchSemaphore(value: 0)
    private let stdoutHandle: FileHandle
    private let stderrHandle: FileHandle

    init(stdout: FileHandle, stderr: FileHandle) {
        self.stdoutHandle = stdout
        self.stderrHandle = stderr
    }

    func start() {
        queue.async { [self] in
            let out = drain(stdoutHandle)
            state.withLock { $0.stdout = out; $0.finishedCount += 1 }
            semaphore.signal()
        }
        queue.async { [self] in
            let err = drain(stderrHandle)
            state.withLock { $0.stderr = err; $0.finishedCount += 1 }
            semaphore.signal()
        }
    }

    /// Waits up to `seconds` for both drains to reach EOF. Returns false when
    /// the wait expired with a drain still blocked (grandchild holding the
    /// pipe): the caller then gets EMPTY output for that stream plus the
    /// truncation note, because a drain publishes its buffer only at EOF. The
    /// still-blocked drain keeps running on its GCD thread and finishes
    /// whenever the last pipe writer exits — it never blocks the caller or
    /// the cooperative pool. Returning on time beats hanging forever on a
    /// forked child that inherited the pipe.
    func wait(seconds: TimeInterval) -> Bool {
        let deadline = DispatchTime.now() + seconds
        while state.withLock({ $0.finishedCount }) < 2 {
            if semaphore.wait(timeout: .now() + 0.05) == .success {
                continue
            }
            if DispatchTime.now() >= deadline {
                return false
            }
        }
        return true
    }

    /// Published drain outputs (empty for a drain that has not hit EOF yet —
    /// its bytes are still local to the drain loop until then).
    func results() -> (stdout: DrainedOutput, stderr: DrainedOutput) {
        state.withLock { st in
            (st.stdout ?? DrainedOutput(), st.stderr ?? DrainedOutput())
        }
    }
}

/// Thread-safe handle for process execution state.
/// Uses `OSAllocatedUnfairLock` for safe concurrent access to the timeout flag.
private struct ProcessExecutionHandle: Sendable {
    let process: Process
    let stdoutPipe: Pipe
    let stderrPipe: Pipe
    private let stateLock = OSAllocatedUnfairLock(initialState: false)

    var didTimeOut: Bool {
        stateLock.withLock { $0 }
    }

    init(process: Process, stdoutPipe: Pipe, stderrPipe: Pipe) {
        self.process = process
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
    }

    func markTimedOut() {
        stateLock.withLock { $0 = true }
    }
}
