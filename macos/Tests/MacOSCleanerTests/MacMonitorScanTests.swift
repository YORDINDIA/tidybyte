import Foundation
@testable import MacOSCleanerCore
@testable import MacOSCleanerMCPLibrary
import XCTest

/// Regression tests for the mac-monitor audit: MCP argument strictness, the
/// undo policy, and the check_finding identity check.
final class MacMonitorScanTests: XCTestCase {
    private func handle(_ kit: MCPKit, _ request: sending [String: Any]) async throws -> [String: Any] {
        let response = await kit.handle(request: request)
        return try XCTUnwrap(response).payload
    }

    private static func toolCall(id: String, name: String, arguments: [String: Any] = [:]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "method": "tools/call", "params": ["name": name, "arguments": arguments]]
    }

    private func toolResult(_ response: [String: Any]) throws -> (isError: Bool, text: String) {
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        return (result["isError"] as? Bool ?? false, text)
    }

    private func makeTempRoot(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // MARK: - Undo policy

    /// An undo record whose inverse is moveToTrash removes its artifact with
    /// removeItem. Neither the dry run nor a confirmed call may run it over MCP.
    func testUndoThatRemovesAnArtifactIsRefusedAndTheFileSurvives() async throws {
        let root = try makeTempRoot("MCP-PermanentUndo")
        defer { try? FileManager.default.removeItem(at: root) }
        let artifact = root.appendingPathComponent("alias-copy.bin")
        try Data("keep me".utf8).write(to: artifact)

        let store = try SQLiteStore.inMemory()
        try await store.saveUndoRecord(UndoRecord(
            id: "undo-permanent-1", operationLogID: "op-permanent-0001", inverseAction: .moveToTrash,
            restoreURL: artifact, trashURL: nil, validUntil: nil, status: .available
        ))
        let kit = MCPKit(store: store)

        for confirm in [false, true] {
            let result = try toolResult(await handle(kit, Self.toolCall(id: "u", name: "undo", arguments: [
                "operation_log_id": "op-permanent-0001", "confirm": confirm
            ])))
            XCTAssertTrue(result.isError, "undo confirm=\(confirm) must be refused")
            XCTAssertTrue(result.text.contains("Tidybyte app"), "Expected the app guidance, got: \(result.text)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.path), "The artifact must not be removed")
    }

    /// A short id that matches two operations must not restore both.
    func testAmbiguousShortUndoIDRestoresNothing() async throws {
        let store = try SQLiteStore.inMemory()
        for (index, operation) in ["op-ambig-A-000001", "op-ambig-B-000002"].enumerated() {
            try await store.saveUndoRecord(UndoRecord(
                id: "undo-ambig-\(index)", operationLogID: operation, inverseAction: .restore,
                restoreURL: nil, trashURL: nil, validUntil: nil, status: .available
            ))
        }
        let kit = MCPKit(store: store)
        let result = try toolResult(await handle(kit, Self.toolCall(id: "u", name: "undo", arguments: [
            "operation_log_id": "op-ambig", "confirm": true
        ])))
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("more than one"), "Expected the ambiguity error, got: \(result.text)")
    }

    // MARK: - Strict arguments

    /// A present argument of the wrong type must fail. Read as absent, a
    /// string action_ids or a string paths value would widen the action.
    func testMalformedArgumentsAreRejectedNotReadAsAbsent() async throws {
        let kit = try MCPKit(store: SQLiteStore.inMemory())
        try await expectRefused(kit, tool: "execute", naming: "action_ids", Self.toolCall(
            id: "a1", name: "execute", arguments: ["action_ids": "abcdefgh", "confirm": true]))
        try await expectRefused(kit, tool: "execute", naming: "confirm", Self.toolCall(
            id: "a2", name: "execute", arguments: ["confirm": "true"]))
        try await expectRefused(kit, tool: "execute", naming: "confirm", Self.toolCall(
            id: "a3", name: "execute", arguments: ["confirm": 1]))
        try await expectRefused(kit, tool: "scan", naming: "paths", Self.toolCall(
            id: "a4", name: "scan", arguments: ["paths": "/"]))
        try await expectRefused(kit, tool: "scan", naming: "paths", Self.toolCall(
            id: "a5", name: "scan", arguments: ["paths": [""]]))
        try await expectRefused(kit, tool: "scan", naming: "duplicate_strategy", Self.toolCall(
            id: "a6", name: "scan", arguments: ["duplicate_strategy": "delete_everything"]))
        try await expectRefused(kit, tool: "list_findings", naming: "limit", Self.toolCall(
            id: "a7", name: "list_findings", arguments: ["limit": "ten"]))
    }

    private func expectRefused(_ kit: MCPKit, tool: String, naming argument: String,
                               _ request: sending [String: Any]) async throws {
        let result = try toolResult(await handle(kit, request))
        XCTAssertTrue(result.isError, "\(tool) must refuse the malformed \(argument)")
        XCTAssertTrue(result.text.contains(argument), "Expected \(argument) named in: \(result.text)")
    }

    // MARK: - check_finding identity

    /// Re-verification must notice a same-size rewrite and a deleted member.
    func testCheckFindingReportsChangedAndMissingMembers() async throws {
        let root = try makeTempRoot("MCP-CheckFinding")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("one.bin")
        let second = root.appendingPathComponent("two.bin")
        let payload = Data("duplicate contents for the check-finding test".utf8)
        try payload.write(to: first)
        try payload.write(to: second)

        let kit = try MCPKit(store: SQLiteStore.inMemory())
        _ = try await handle(kit, Self.toolCall(id: "s", name: "scan", arguments: ["paths": [root.path]]))
        let scan = await kit.lastScan
        let findingID = try XCTUnwrap(
            scan?.outcome.findings.first { $0.category == .duplicate }?.id,
            "The fixture must produce a duplicate finding"
        )
        let check = { (id: String) async throws -> String in
            try self.toolResult(await self.handle(kit, Self.toolCall(id: "c", name: "check_finding", arguments: [
                "finding_id": id
            ]))).text
        }

        let untouched = try await check(findingID)
        XCTAssertTrue(untouched.contains("byte-identical"), "Got: \(untouched)")
        XCTAssertTrue(untouched.contains("safe to execute"), "Got: \(untouched)")

        // Same size, different bytes: the hash check must catch it.
        try Data(repeating: 0x41, count: payload.count).write(to: first)
        let rewritten = try await check(findingID)
        XCTAssertTrue(rewritten.contains("Changed since the scan"), "Got: \(rewritten)")
        XCTAssertTrue(rewritten.contains("Re-scan before executing"), "Got: \(rewritten)")

        try FileManager.default.removeItem(at: second)
        let deleted = try await check(findingID)
        XCTAssertTrue(deleted.contains("Missing since the scan"), "Got: \(deleted)")
    }
}

/// Monitor time units checked against the live kernel. Every read is of this
/// test process (its own pid), so nothing outside the test is touched.
final class MacMonitorTimeUnitTests: XCTestCase {
    /// Spins the CPU for `seconds` of wall time; the result keeps the loop live.
    private func spin(seconds: TimeInterval) -> UInt64 {
        var sink: UInt64 = 0
        let start = Date()
        while Date().timeIntervalSince(start) < seconds { sink &+= 1 }
        return sink
    }

    /// This process's CPU time from the POSIX process clock, in seconds.
    private func processCPUSeconds() -> Double {
        var spec = timespec()
        clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &spec)
        return Double(spec.tv_sec) + Double(spec.tv_nsec) / 1_000_000_000
    }

    /// Rusage CPU times are mach ticks. Read as nanoseconds they came out 42x
    /// too low on Apple silicon. The rusage delta must match the process clock
    /// delta, which does not depend on how loaded the machine is.
    func testUsageReportCPUTimeMatchesTheProcessClock() throws {
        let clock0 = processCPUSeconds()
        let before = try XCTUnwrap(LibProc.usageReport(pid: getpid()))
        let sink = spin(seconds: 0.5)
        let after = try XCTUnwrap(LibProc.usageReport(pid: getpid()))
        let clock1 = processCPUSeconds()
        let rusageCPU = after.cpuTimeSeconds - before.cpuTimeSeconds
        let clockCPU = clock1 - clock0
        XCTAssertGreaterThan(sink, 0)
        XCTAssertGreaterThan(clockCPU, 0.1, "the spin must use CPU")
        XCTAssertEqual(rusageCPU, clockCPU, accuracy: max(0.05, clockCPU * 0.25),
                       "rusage \(rusageCPU) s vs process clock \(clockCPU) s")
    }

    /// The one-shot reading (CLI status, MCP monitor tools) must span a real
    /// second. Back-to-back ticks leave only milliseconds, which inflates every rate.
    func testOneShotSnapshotSpansARealInterval() async throws {
        let snapshot = await MonitorCLI.oneShot(includesSlowProbes: false)
        XCTAssertGreaterThanOrEqual(snapshot.interval, 0.9, "interval \(snapshot.interval) s")
    }

    /// p_starttime is wall-clock. The fallback date must be near now for a
    /// process that started seconds ago, not about a boot interval in the future.
    func testProcessStartDateFromPStartTimeIsWallClock() throws {
        let entry = try XCTUnwrap(ProcessProbe.kernelProcessTable().first { pid_t($0.kp_proc.p_pid) == getpid() })
        let started = try XCTUnwrap(ProcessProbe.date(fromTimeInterval: entry.kp_proc.p_starttime))
        XCTAssertLessThan(abs(started.timeIntervalSinceNow), 3600, "start date \(started)")
    }

    /// The mach start time must not drift by the sleep time, which the boot
    /// date plus mach time did. The test process started seconds ago.
    func testUsageReportStartDateIsWallClock() throws {
        let report = try XCTUnwrap(LibProc.usageReport(pid: getpid()))
        let started = try XCTUnwrap(report.startedAt)
        XCTAssertLessThan(abs(started.timeIntervalSinceNow), 3600, "start date \(started)")
    }
}

/// Signals reach only the process the user confirmed. The test signals a
/// `sleep` child it spawned, never this test process or a user process.
final class MacMonitorProcessActionTests: XCTestCase {
    func testQuitRefusesAMismatchedOrMissingStartTime() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { if child.isRunning { child.terminate() } }
        let pid = child.processIdentifier
        let started = try XCTUnwrap(LibProc.usageReport(pid: pid)?.startedAt)

        // A reused pid has a different start time, so the signal must not go out.
        XCTAssertFalse(ProcessActions.quit(pid: pid, confirmedStart: started.addingTimeInterval(-600)))
        XCTAssertTrue(child.isRunning, "a mismatched start time must not signal")
        // No confirmed start time fails closed.
        XCTAssertFalse(ProcessActions.quit(pid: pid, confirmedStart: nil))
        XCTAssertTrue(child.isRunning, "a missing start time must not signal")

        XCTAssertTrue(ProcessActions.quit(pid: pid, confirmedStart: started))
        child.waitUntilExit()
        XCTAssertFalse(child.isRunning)
    }
}
