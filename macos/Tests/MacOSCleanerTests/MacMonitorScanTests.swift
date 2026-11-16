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
        // The second operation's only record is already restored. It still matches the short id.
        for (index, operation) in ["op-ambig-A-000001", "op-ambig-B-000002"].enumerated() {
            try await store.saveUndoRecord(UndoRecord(
                id: "undo-ambig-\(index)", operationLogID: operation, inverseAction: .restore,
                restoreURL: nil, trashURL: nil, validUntil: nil, status: index == 0 ? .available : .restored
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
        try await expectRefused(kit, tool: "scan", naming: "paths", Self.toolCall(
            id: "a8", name: "scan", arguments: ["paths": ["."]]))
        try await expectRefused(kit, tool: "scan", naming: "paths", Self.toolCall(
            id: "a9", name: "scan", arguments: ["paths": ["relative/folder"]]))
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

    /// The start time read through PROC_PIDTBSDINFO (fixed offsets) must equal the
    /// process table's p_starttime. This checks the offsets ProcessActions relies on.
    func testBSDInfoStartTimeMatchesTheProcessTable() throws {
        let entry = try XCTUnwrap(ProcessProbe.kernelProcessTable().first { pid_t($0.kp_proc.p_pid) == getpid() })
        let live = try XCTUnwrap(LibProc.startTime(pid: getpid()))
        XCTAssertEqual(live.seconds, Int64(entry.kp_proc.p_starttime.tv_sec))
        XCTAssertEqual(live.microseconds, Int64(entry.kp_proc.p_starttime.tv_usec))
        XCTAssertEqual(ProcessActions.liveStart(pid: getpid()), ProcessProbe.date(fromTimeInterval: entry.kp_proc.p_starttime))
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
        let started = try XCTUnwrap(ProcessActions.liveStart(pid: pid))

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

/// Round 2 regression tests: pid reuse, the refresh gate, the two parsers, and
/// history retention. History uses a temporary database, never the user's.
final class MacMonitorRound2Tests: XCTestCase {
    private func counters(start: Date?, cpu: Double) -> ProcessProbe.ProcessUsageCounters {
        ProcessProbe.ProcessUsageCounters(
            cpuTimeSeconds: cpu, diskReadBytes: 0, diskWrittenBytes: 0, wakeups: 0, energy: 0, startedAt: start)
    }

    /// MON-04: a reused pid must not diff against its predecessor's totals.
    func testReusedPidYieldsNoRatesFromItsPredecessor() {
        let first = Date(timeIntervalSince1970: 1_000)
        let reused = Date(timeIntervalSince1970: 2_000)
        let previous = counters(start: first, cpu: 10)
        // The new process has a larger total, so a naive diff would show a spike.
        XCTAssertNil(ProcessProbe.tickRates(previous: previous, current: counters(start: reused, cpu: 50), interval: 1))
        // The same process still diffs: one CPU-second over one second is 100 percent.
        let same = ProcessProbe.tickRates(previous: previous, current: counters(start: first, cpu: 11), interval: 1)
        XCTAssertEqual(same?.cpuPercent ?? -1, 100, accuracy: 0.01)
        XCTAssertNil(ProcessProbe.tickRates(previous: nil, current: counters(start: first, cpu: 11), interval: 1))
        // Unknown start times prove nothing: no rates, even when both are nil.
        XCTAssertNil(ProcessProbe.tickRates(previous: counters(start: nil, cpu: 10), current: counters(start: nil, cpu: 11), interval: 1))
        XCTAssertNil(ProcessProbe.tickRates(previous: counters(start: first, cpu: 10), current: counters(start: nil, cpu: 11), interval: 1))
    }

    /// MON-07: one background refresh at a time.
    func testRefreshGateAllowsOneRefreshAtATime() {
        var gate = RefreshGate()
        XCTAssertTrue(gate.begin())
        XCTAssertFalse(gate.begin(), "a second refresh must wait for the first")
        XCTAssertTrue(gate.isBusy)
        gate.end()
        XCTAssertTrue(gate.begin())
    }

    /// MON-10: an empty argument is kept, so later arguments do not shift.
    func testArgumentParserKeepsEmptyArguments() {
        // The fixture pads the way the kernel does, so argv[0] starts at index 20 for this path.
        let data = kernelArgv(path: "/usr/bin/tool", arguments: ["tool", "", "last"])
        XCTAssertEqual(ProcessProbe.parseArguments(data), ["tool", "", "last"])
    }

    /// Builds argv the way the kernel lays it out: argc, the path and its NUL,
    /// zero padding until argv starts at index 4 (mod 8), then each argument NUL-terminated.
    private func kernelArgv(path: String, arguments: [String]) -> Data {
        var data = Data()
        var argc = Int32(arguments.count)
        withUnsafeBytes(of: &argc) { data.append(contentsOf: $0) }
        data.append(Data(path.utf8))
        data.append(0)
        while (data.count - 4) % 8 != 0 { data.append(0) }
        for argument in arguments {
            data.append(Data(argument.utf8))
            data.append(0)
        }
        return data
    }

    /// An empty argv[0] sits on the aligned boundary; it must not be skipped as padding.
    func testArgumentParserKeepsEmptyFirstArgument() {
        let data = kernelArgv(path: "/bin/cat", arguments: ["", "-", "last"])
        XCTAssertEqual(ProcessProbe.parseArguments(data), ["", "-", "last"])
    }

    /// An empty argument after the first must keep its place too.
    func testArgumentParserKeepsEmptyMiddleArgument() {
        let data = kernelArgv(path: "/bin/sleep", arguments: ["sleep", "", "5"])
        XCTAssertEqual(ProcessProbe.parseArguments(data), ["sleep", "", "5"])
    }

    /// A quoted nettop process field keeps its PID, and its name keeps the comma.
    func testNettopParserReadsQuotedProcessFields() {
        let parsed = MonitoringEngine.parseNettopCSV("""
        time,process,bytes_in,bytes_out
        2026-11-01 10:00:00,"Acme,Ltd.123",4096,1024
        2026-11-01 10:00:00,"say ""hi"".456",1,2
        """)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed.first?.name, "Acme,Ltd")
        XCTAssertEqual(parsed.first?.pid, 123)
        XCTAssertEqual(parsed.first?.downloadPerSecond, 4096)
        XCTAssertEqual(parsed.last?.name, "say \"hi\"")
        XCTAssertEqual(parsed.last?.pid, 456)
    }

    /// A present arguments value that is not an object is refused, not read as {}.
    func testNonObjectArgumentsAreRefused() async throws {
        let kit = try MCPKit(store: SQLiteStore.inMemory())
        let request: [String: Any] = [
            "jsonrpc": "2.0", "id": "n1", "method": "tools/call",
            "params": ["name": "scan", "arguments": "/"]
        ]
        let response = await kit.handle(request: request)
        let result = try XCTUnwrap(response?.payload["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
    }

    /// An action id that matches no pending action is refused, and nothing runs.
    func testUnknownActionPrefixIsRefusedAfterAScan() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCP-UnknownAction-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data("duplicate contents for the unknown-action test".utf8)
        try payload.write(to: root.appendingPathComponent("one.bin"))
        try payload.write(to: root.appendingPathComponent("two.bin"))
        let kit = try MCPKit(store: SQLiteStore.inMemory())
        _ = await kit.handle(request: ["jsonrpc": "2.0", "id": "s", "method": "tools/call", "params": [
            "name": "scan", "arguments": ["paths": [root.path]]
        ]])
        let response = await kit.handle(request: ["jsonrpc": "2.0", "id": "e", "method": "tools/call", "params": [
            "name": "execute", "arguments": ["action_ids": ["zzzzzzzz"], "confirm": true]
        ]])
        let result = try XCTUnwrap(response?.payload["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertTrue(text.contains("No pending action"), "Got: \(text)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("two.bin").path))
    }

    /// MON-11: a process name with a comma stays whole, and the numbers still line up.
    func testNettopParserKeepsCommasInProcessNames() {
        let parsed = MonitoringEngine.parseNettopCSV("""
        time,process,bytes_in,bytes_out,bytes_in_per_s,bytes_out_per_s
        2026-11-01 10:00:00,Acme,Ltd.123,4096,1024,512,128
        """)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.name, "Acme,Ltd")
        XCTAssertEqual(parsed.first?.pid, 123)
        XCTAssertEqual(parsed.first?.downloadPerSecond, 512)
        XCTAssertEqual(parsed.first?.uploadPerSecond, 128)
    }

    /// MON-13: per-app rows expire after 90 days; metric history keeps its retention.
    func testPerAppHistoryExpiresBeforeMetricHistory() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCP-History-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try MetricsHistoryStore(databaseURL: dir.appendingPathComponent("history.sqlite"))
        let old = Date().addingTimeInterval(-100 * 86_400)
        let group = AppProcessGroup(
            id: "app:fixture", name: "Fixture App", kind: .app, bundlePath: nil, bundleID: "com.example.fixture",
            members: [ProcessSample(pid: 1, name: "Fixture App", cpuPercent: 40)])
        await store.record(SystemSnapshot(timestamp: old, groups: [group]))
        // A recent snapshot makes the next rollup pass fold the 100-day-old rows.
        await store.record(SystemSnapshot(timestamp: Date(), groups: [group]))
        let since = old.addingTimeInterval(-86_400)
        await store.prune(olderThanDays: 365)
        let metric = await store.series(metric: .cpu, from: since, to: Date())
        XCTAssertFalse(metric.isEmpty, "metric history keeps its full retention")
        // Before the prune the app series held two points: the 100-day-old rollup
        // and today's raw row. Only today's row may remain.
        let apps = await store.appSeries(metric: .cpu, appName: "Fixture App", from: since, to: Date())
        XCTAssertEqual(apps.count, 1, "the 100-day-old app point must be gone")
        XCTAssertGreaterThan(apps.first?.timestamp ?? .distantPast, Date().addingTimeInterval(-90 * 86_400))
    }
}
