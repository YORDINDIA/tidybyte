import XCTest
@testable import MacOSCleanerCore

/// Parser and decoding tests for the monitoring probes: tool output, sensor
/// values, and history storage. All fixtures are synthetic.
final class MonitoringParserTests: XCTestCase {
    private func sample(
        pid: pid_t, parent: pid_t = 1, name: String, path: String? = nil,
        bundlePath: String? = nil, bundleName: String? = nil, cpu: Double = 0, memory: Int64 = 0,
        kernel: Bool = false
    ) -> ProcessSample {
        ProcessSample(
            pid: pid, parentPID: parent, name: name, state: .running, isKernelProcess: kernel,
            executablePath: path, bundlePath: bundlePath, bundleName: bundleName,
            residentBytes: memory, cpuPercent: cpu)
    }

    // MARK: - Dev servers

    func testListenerParsingFromLsofOutput() {
        let output = """
        COMMAND   PID   USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        node     4041  saksham   24u  IPv4 0xabc123      0t0  TCP *:5173 (LISTEN)
        node     4041  saksham   25u  IPv6 0xabc124      0t0  TCP [::1]:5174 (LISTEN)
        rapportd  462  saksham   10u  IPv4 0x64e7      0t0  TCP *:60065 (LISTEN)
        """
        let listeners = DevEnvironmentProbe.parseListeners(output)
        XCTAssertEqual(listeners.count, 3)
        XCTAssertEqual(listeners[0].port, 5173)
        XCTAssertEqual(listeners[0].address, "*")
        XCTAssertEqual(listeners[1].port, 5174)
        XCTAssertEqual(listeners[2].pid, 462)
    }

    func testWorkingDirectoryParsingFromLsofOutput() {
        let output = """
        p 4041
        n/Users/me/code/storefront
        p 9999
        n/Users/me/elsewhere
        """
        let directories = DevEnvironmentProbe.parseWorkingDirectories(output, pids: [4041, 9999])
        XCTAssertEqual(directories[4041], "/Users/me/code/storefront")
        XCTAssertEqual(directories[9999], "/Users/me/elsewhere")
    }

    // MARK: - Agents

    func testAgentKindDetection() {
        XCTAssertEqual(AgentProbe.kind(of: sample(pid: 1, name: "claude", path: "/usr/local/bin/claude")), .claude)
        XCTAssertEqual(AgentProbe.kind(of: sample(pid: 2, name: "codex", path: "/opt/homebrew/bin/codex")), .codex)
        XCTAssertEqual(AgentProbe.kind(of: sample(pid: 3, name: "gemini", path: "/usr/bin/gemini")), .gemini)
        XCTAssertNil(AgentProbe.kind(of: sample(pid: 4, name: "Safari", path: "/Applications/Safari.app/Contents/MacOS/Safari")))
    }

    func testDescendantsWalksTheTree() {
        let processes = [
            sample(pid: 10, name: "claude", path: "/usr/local/bin/claude"),
            sample(pid: 11, parent: 10, name: "node test"),
            sample(pid: 12, parent: 11, name: "jest"),
            sample(pid: 20, parent: 99, name: "unrelated")
        ]
        let root = processes[0]
        let descendants = AgentProbe.descendants(of: root, in: processes)
        XCTAssertEqual(Set(descendants.map(\.pid)), [11, 12])
    }

    func testClaudeUsageParsing() {
        let json = #"{"utilization": 0.42, "resets_at": 1735689600}"#
        let reading = ClaudeUsageReader.parse(json)
        XCTAssertEqual(reading?.usedFraction ?? 0, 0.42, accuracy: 0.001)
        XCTAssertEqual(reading?.resetsAt, Date(timeIntervalSince1970: 1_735_689_600))
        XCTAssertNil(ClaudeUsageReader.parse("not json at all {} nothing"))
    }

    /// `{"a":}` used to recurse forever: the unwrap produced the same string
    /// again. It must return nil quickly, exactly one unwrap level later.
    func testClaudeUsageMalformedInputDoesNotRecurse() {
        let start = Date()
        XCTAssertNil(ClaudeUsageReader.parse(#"{"a":}"#))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }

    // MARK: - Alerts

    func testSustainedCPUAlert() {
        var windows: [String: AlertEngine.CPUWindow] = [:]
        var baselines: [String: (value: Int64, at: Date)] = [:]
        let thresholds = AlertEngine.AlertThresholds(
            isEnabled: true, cpuPercent: 50, cpuWindowMinutes: 1, memoryGrowthBytes: 1000,
            diskBytesPerSecond: 1_000_000, networkBytesPerSecond: 1_000_000)
        let start = Date(timeIntervalSince1970: 1000)

        func tick(_ cpu: Double, at seconds: Double) -> [AlertEngine.Finding] {
            let group = AppProcessGroup(
                id: "app:\(start)", name: "Hog", kind: .app, bundlePath: nil, bundleID: "com.hog",
                members: [sample(pid: 1, name: "Hog", cpu: cpu)])
            let snapshot = SystemSnapshot(timestamp: start.addingTimeInterval(seconds), groups: [group])
            return AlertEngine.findings(
                in: snapshot, thresholds: thresholds, cpuWindows: &windows, memoryBaselines: &baselines,
                now: snapshot.timestamp)
        }

        XCTAssertEqual(tick(90, at: 0).count, 0) // nothing observed yet
        XCTAssertEqual(tick(90, at: 30).count, 1) // half the window, all over the bar
        XCTAssertEqual(tick(90, at: 70).count, 0) // window reset after the alert
        let finding = tick(90, at: 105).first // full window again → second alert
        XCTAssertEqual(finding?.kind, .cpu)
        XCTAssertEqual(finding?.appName, "Hog")
    }

    func testShortCPUSpikeDoesNotAlert() {
        var windows: [String: AlertEngine.CPUWindow] = [:]
        var baselines: [String: (value: Int64, at: Date)] = [:]
        let thresholds = AlertEngine.AlertThresholds(
            isEnabled: true, cpuPercent: 50, cpuWindowMinutes: 10, memoryGrowthBytes: 1000,
            diskBytesPerSecond: 1_000_000, networkBytesPerSecond: 1_000_000)
        let group = AppProcessGroup(
            id: "a", name: "Spike", kind: .app, bundlePath: nil, bundleID: nil,
            members: [sample(pid: 1, name: "Spike", cpu: 99)])
        let snapshot = SystemSnapshot(timestamp: .init(), groups: [group])
        let findings = AlertEngine.findings(
            in: snapshot, thresholds: thresholds, cpuWindows: &windows, memoryBaselines: &baselines,
            now: snapshot.timestamp)
        XCTAssertTrue(findings.isEmpty)
    }

    func testMemoryGrowthAlertAfterAnHour() {
        var windows: [String: AlertEngine.CPUWindow] = [:]
        var baselines: [String: (value: Int64, at: Date)] = [:]
        let thresholds = AlertEngine.AlertThresholds(
            isEnabled: true, cpuPercent: 100, cpuWindowMinutes: 10, memoryGrowthBytes: 1_000_000,
            diskBytesPerSecond: 1_000_000_000, networkBytesPerSecond: 1_000_000_000)
        let start = Date(timeIntervalSince1970: 0)

        func tick(_ memory: Int64, seconds: Double) -> [AlertEngine.Finding] {
            let group = AppProcessGroup(
                id: "m", name: "Leak", kind: .app, bundlePath: nil, bundleID: nil,
                members: [sample(pid: 1, name: "Leak", memory: memory)])
            let snapshot = SystemSnapshot(timestamp: start.addingTimeInterval(seconds), groups: [group])
            return AlertEngine.findings(
                in: snapshot, thresholds: thresholds, cpuWindows: &windows, memoryBaselines: &baselines,
                now: snapshot.timestamp)
        }

        XCTAssertTrue(tick(500_000_000, seconds: 0).isEmpty)
        XCTAssertTrue(tick(800_000_000, seconds: 1800).isEmpty) // window not elapsed
        let findings = tick(2_000_000_000, seconds: 3601)
        XCTAssertEqual(findings.first?.kind, .memory)
        XCTAssertTrue(findings.first?.detail.contains("Leak") == true)
    }

    /// Keys leave the alert state when their app leaves the snapshot, and
    /// baselines/cooldowns expire after 2 and 24 hours.
    func testStaleAlertStateIsPruned() {
        let now = Date(timeIntervalSince1970: 100_000)
        let present = AppProcessGroup(
            id: "p", name: "Present", kind: .app, bundlePath: nil, bundleID: nil, members: [])
        let old = AppProcessGroup(
            id: "o", name: "Old", kind: .app, bundlePath: nil, bundleID: nil, members: [])
        var windows = ["Present": AlertEngine.CPUWindow(), "Old": AlertEngine.CPUWindow(), "Gone": AlertEngine.CPUWindow()]
        var baselines: [String: (value: Int64, at: Date)] = [
            "Present": (value: 10, at: now.addingTimeInterval(-1000)),
            "Old": (value: 20, at: now.addingTimeInterval(-7201)),
            "Gone": (value: 30, at: now.addingTimeInterval(-10))
        ]
        var lastRaised = [
            "cpu-Present": now.addingTimeInterval(-23 * 3600),
            "cpu-Old": now.addingTimeInterval(-25 * 3600),
            "cpu-Gone": now.addingTimeInterval(-3600)
        ]
        AlertEngine.pruneStaleState(
            cpuWindows: &windows, memoryBaselines: &baselines, lastRaised: &lastRaised,
            groups: [present, old], now: now)
        XCTAssertEqual(Set(windows.keys), ["Present", "Old"])
        XCTAssertEqual(Set(baselines.keys), ["Present"]) // "Old" is older than 2 hours
        XCTAssertEqual(Set(lastRaised.keys), ["cpu-Present"]) // "cpu-Old" is older than 24 hours
    }

    // MARK: - Power assertions

    /// Real `pmset -g assertions` line shape: id in brackets, held time,
    /// kind, then `named:` detail.
    func testPmsetAssertionsParsing() {
        let output = """
        Listed by owning process:
           pid 175(cupsd): [0x0000c0010001] 11:27:58 PreventUserIdleSystemSleep named: "com.apple.cupsd"
           pid 903(WindowServer): [0x0000c0010003] 00:00:42 UserIsActive named: "com.apple.iohideventsystem"
        """
        let readings = PowerProbe.parseAssertions(output)
        XCTAssertEqual(readings.count, 2)
        XCTAssertEqual(readings[0].pid, 175)
        XCTAssertEqual(readings[0].processName, "cupsd")
        XCTAssertEqual(readings[0].kind, "PreventUserIdleSystemSleep")
        XCTAssertEqual(readings[0].heldSeconds, 11 * 3600 + 27 * 60 + 58, accuracy: 0.001)
        XCTAssertEqual(readings[0].detail, "com.apple.cupsd")
        XCTAssertEqual(readings[1].kind, "UserIsActive")
        XCTAssertEqual(readings[1].heldSeconds, 42, accuracy: 0.001)
    }

    func testParseHeldTime() {
        XCTAssertEqual(PowerProbe.parseHeldTime("11:27:58"), 41_278, accuracy: 0.001)
        XCTAssertEqual(PowerProbe.parseHeldTime("00:00:42"), 42, accuracy: 0.001)
        XCTAssertEqual(PowerProbe.parseHeldTime("nonsense"), 0)
        XCTAssertEqual(PowerProbe.parseHeldTime(""), 0)
    }

    // MARK: - rusage layout

    /// The Swift mirror must stay byte-compatible with the kernel's
    /// `struct rusage_info_v4` or every counter reads garbage.
    func testRUsageInfoV4LayoutMatchesKernelStruct() {
        XCTAssertEqual(MemoryLayout<RUsageInfoV4>.size, 296)
    }

    // MARK: - SMC value decoding

    func testSP78Decoding() {
        XCTAssertEqual(SMCSensors.sp78Value([0x40, 0x00]), 64.0)
        XCTAssertEqual(SMCSensors.sp78Value([0x1A, 0x80]), 26.5)
        XCTAssertNil(SMCSensors.sp78Value([0x1A]))
    }

    func testFixedPointDecoding() {
        // fpe2: big-endian with 16 fractional bits → value / 65536.
        let value = SMCSensors.fixedPoint([0x0E, 0x66, 0x2A, 0x00], dataType: "fpe2")
        XCTAssertEqual(value ?? 0, 0x0E662A00 / 65536.0, accuracy: 0.001)
    }

    func testEncodeFixedPointRoundTrip() {
        let encoded = SMCSensors.encodeFixedPoint(26.5, byteCount: 4, fractionBits: 16)
        XCTAssertEqual(encoded, [0x00, 0x1A, 0x80, 0x00])
        XCTAssertEqual(SMCSensors.fixedPoint(encoded, dataType: "fpe2") ?? 0, 26.5, accuracy: 0.001)
        // Clamped, never overflowing the byte count.
        XCTAssertEqual(SMCSensors.encodeFixedPoint(300, byteCount: 2, fractionBits: 0), [0x01, 0x2C])
    }

    /// data8 is one byte before the data32/data union; writing it must not
    /// clobber the value bytes, in either write order.
    func testParameterBufferSetData8LeavesDataUntouched() {
        let selectorFirst = SMCSensors.ParameterBuffer()
        selectorFirst.setData8(0x05)
        selectorFirst.setData([0xAB, 0xCD])
        XCTAssertEqual(selectorFirst.dataBytes(2), [0xAB, 0xCD])

        let dataFirst = SMCSensors.ParameterBuffer()
        dataFirst.setData([0xAB, 0xCD])
        dataFirst.setData8(0x05)
        XCTAssertEqual(dataFirst.dataBytes(2), [0xAB, 0xCD])
        XCTAssertEqual(dataFirst.dataSizeByte(), 0)
    }

    func testFanKeyFormatting() {
        XCTAssertEqual(SMCSensors.fanKey(index: 0, suffix: "Ac"), "F0Ac")
        XCTAssertEqual(SMCSensors.fanKey(index: 2, suffix: "Mn"), "F2Mn")
    }

    // MARK: - Bluetooth

    func testBluetoothJSONParsing() {
        let json = """
        {"SPBluetoothDataType": [{
          "device_connected": [{"device_title": "AirPods Pro", "device_batteryLevelLeft": "80%", "device_batteryLevelRight": "75%"}],
          "device_not_connected": [{"device_title": "Magic Keyboard", "device_address": "aa-bb-cc-dd-ee-ff"}]
        }]}
        """
        let devices = BluetoothProbe.parse(json)
        XCTAssertEqual(devices.count, 2)
        let airpods = devices.first { $0.name == "AirPods Pro" }
        XCTAssertTrue(airpods?.isConnected == true)
        XCTAssertEqual(airpods?.batteryLevels["Left"], 0.8)
        let keyboard = devices.first { $0.name == "Magic Keyboard" }
        XCTAssertTrue(keyboard?.isConnected == false)
    }

    // MARK: - History

    func testHistoryRecordAndSeriesRoundTrip() async throws {
        let store = try MetricsHistoryStore(databaseURL: URL(fileURLWithPath: ":memory:"))
        var snapshot = SystemSnapshot(timestamp: Date(timeIntervalSince1970: 100_000), interval: 2)
        snapshot.cpu.usagePercent = 42
        snapshot.memory.usedBytes = 8_000_000_000
        snapshot.groups = [
            AppProcessGroup(
                id: "g", name: "Hog", kind: .app, bundlePath: nil, bundleID: nil,
                members: [sample(pid: 1, name: "Hog", cpu: 42, memory: 8_000_000_000)])
        ]
        await store.record(snapshot)
        let series = await store.series(
            metric: .cpu, from: Date(timeIntervalSince1970: 90_000), to: Date(timeIntervalSince1970: 200_000))
        XCTAssertEqual(series.count, 1)
        XCTAssertEqual(series.first?.average ?? 0, 42, accuracy: 0.001)
        let appSeries = await store.appSeries(
            metric: .memory, appName: "Hog", from: Date(timeIntervalSince1970: 90_000), to: Date(timeIntervalSince1970: 200_000))
        XCTAssertEqual(appSeries.count, 1)
        XCTAssertEqual(appSeries.first?.average ?? 0, 8_000_000_000, accuracy: 0.001)
    }

    func testHistoryPruneRemovesOldRows() async throws {
        let store = try MetricsHistoryStore(databaseURL: URL(fileURLWithPath: ":memory:"))
        let old = SystemSnapshot(timestamp: Date(timeIntervalSince1970: 1_000), interval: 2)
        await store.record(old)
        let fresh = SystemSnapshot(timestamp: Date.now, interval: 2)
        await store.record(fresh)
        await store.prune(olderThanDays: 7)
        let series = await store.series(
            metric: .cpu, from: Date(timeIntervalSince1970: 0), to: Date.now.addingTimeInterval(60))
        XCTAssertEqual(series.count, 1)
        XCTAssertEqual(series.first?.timestamp.timeIntervalSince1970 ?? 0, Date.now.timeIntervalSince1970, accuracy: 120)
    }

    /// Host metrics must be findable through the UsageMetric raw values:
    /// "disk" (read+write) and "network" (down+up).
    func testHistoryDiskAndNetworkRoundTrip() async throws {
        let store = try MetricsHistoryStore(databaseURL: URL(fileURLWithPath: ":memory:"))
        var snapshot = SystemSnapshot(timestamp: Date(timeIntervalSince1970: 100_000), interval: 2)
        snapshot.disk.readBytesPerSecond = 300
        snapshot.disk.writeBytesPerSecond = 700
        snapshot.network.downloadBytesPerSecond = 1500
        snapshot.network.uploadBytesPerSecond = 500
        await store.record(snapshot)
        let range = Date(timeIntervalSince1970: 90_000)...Date(timeIntervalSince1970: 200_000)
        let disk = await store.series(metric: .disk, from: range.lowerBound, to: range.upperBound)
        XCTAssertEqual(disk.count, 1)
        XCTAssertEqual(disk.first?.average ?? 0, 1000, accuracy: 0.001)
        let network = await store.series(metric: .network, from: range.lowerBound, to: range.upperBound)
        XCTAssertEqual(network.count, 1)
        XCTAssertEqual(network.first?.average ?? 0, 2000, accuracy: 0.001)
    }

    /// A snapshot without battery or sensor readings records cleanly — no -1
    /// sentinel rows get written for the absent readings.
    func testHistoryRecordsWithoutBatteryOrSensors() async throws {
        let store = try MetricsHistoryStore(databaseURL: URL(fileURLWithPath: ":memory:"))
        var snapshot = SystemSnapshot(timestamp: Date(timeIntervalSince1970: 100_000), interval: 2)
        snapshot.cpu.usagePercent = 12
        await store.record(snapshot)
        let cpu = await store.series(
            metric: .cpu, from: Date(timeIntervalSince1970: 90_000), to: Date(timeIntervalSince1970: 200_000))
        XCTAssertEqual(cpu.count, 1)
        XCTAssertEqual(cpu.first?.average ?? 0, 12, accuracy: 0.001)
    }

    // MARK: - nettop

    func testNettopCSVParser() {
        let parsed = MonitoringEngine.parseNettopCSV(
            """
            time,process,bytes_in,bytes_out,bytes_in_per_s,bytes_out_per_s
            2026-11-01 10:00:00,Safari.123,4096,1024,512,128
            2026-11-01 10:00:00,node.456,2048,8192,256,1024
            """)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[0].name, "Safari")
        XCTAssertEqual(parsed[0].pid, 123)
        XCTAssertEqual(parsed[0].downloadPerSecond, 512)
        XCTAssertEqual(parsed[0].uploadPerSecond, 128)
        XCTAssertEqual(parsed[1].name, "node")
        XCTAssertEqual(parsed[1].pid, 456)
        XCTAssertEqual(parsed[1].uploadPerSecond, 1024)
        // An identifier without a numeric pid keeps the whole name and no pid.
        let unnamed = MonitoringEngine.parseNettopCSV(
            """
            time,process,bytes_in,bytes_out
            t,weird.name,10,20
            """)
        XCTAssertEqual(unnamed.count, 1)
        XCTAssertEqual(unnamed[0].name, "weird.name")
        XCTAssertNil(unnamed[0].pid)
    }
}
