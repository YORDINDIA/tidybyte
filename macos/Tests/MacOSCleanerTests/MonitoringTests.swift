import XCTest
@testable import MacOSCleanerCore

/// Tests for the monitoring suite: app grouping, rate math, tool-output
/// parsers, alert thresholds, history storage, and CLI rendering. Everything
/// runs on synthetic fixtures — no live process is touched.
final class MonitoringTests: XCTestCase {
    // MARK: - Fixtures

    private func sample(
        pid: pid_t, parent: pid_t = 1, name: String, path: String? = nil,
        bundlePath: String? = nil, bundleName: String? = nil, cpu: Double = 0,
        memory: Int64 = 0, diskReadRate: Double = 0, diskWriteRate: Double = 0,
        download: Double = 0, upload: Double = 0, wakeups: Double = 0,
        kernel: Bool = false, user: uid_t = 501
    ) -> ProcessSample {
        ProcessSample(
            pid: pid, parentPID: parent, name: name, userID: user, state: .running,
            isKernelProcess: kernel, executablePath: path, bundlePath: bundlePath,
            bundleName: bundleName, residentBytes: memory, cpuPercent: cpu,
            diskReadPerSecond: diskReadRate, diskWritePerSecond: diskWriteRate,
            wakeupsPerSecond: wakeups,
            networkUsage: ProcessNetworkUsage(downloadPerSecond: download, uploadPerSecond: upload))
    }

    // MARK: - Grouping

    func testHelpersRollIntoParentApp() {
        let processes = [
            sample(pid: 100, name: "Chrome", path: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
                   bundlePath: "/Applications/Google Chrome.app", bundleName: "Google Chrome", cpu: 10),
            sample(
                pid: 101, parent: 100, name: "Chrome Helper (Renderer)",
                path: "/Applications/Google Chrome.app/Contents/Frameworks/Chrome Framework.framework/"
                    + "Helpers/Chrome Helper (Renderer).app/Contents/MacOS/Chrome Helper (Renderer)",
                bundlePath: "/Applications/Google Chrome.app", bundleName: "Google Chrome", cpu: 30),
            sample(pid: 102, parent: 100, name: "Chrome Helper (GPU)",
                   path: "/Applications/Google Chrome.app/Helpers/GPU.app/Contents/MacOS/GPU",
                   bundlePath: "/Applications/Google Chrome.app", bundleName: "Google Chrome", cpu: 5)
        ]
        let groups = AppProcessCatalog.group(processes, mode: .byApp)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.name, "Google Chrome")
        XCTAssertEqual(groups.first?.members.count, 3)
        XCTAssertEqual(groups.first?.cpuPercent ?? 0, 45, accuracy: 0.001)
    }

    func testUnbundledSystemProcessesShareOneGroup() {
        let processes = [
            sample(pid: 1, name: "launchd", path: "/sbin/launchd", user: 0),
            sample(pid: 2, name: "WindowServer", path: "/System/Library/PrivateFrameworks/SkyLight.framework/WindowServer", user: 0)
        ]
        let groups = AppProcessCatalog.group(processes, mode: .byApp)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.kind, .background)
    }

    func testByProcessModeKeepsUnbundledProcessesSeparate() {
        let processes = [
            sample(pid: 1, name: "node", path: "/usr/local/bin/node"),
            sample(pid: 2, name: "node", path: "/usr/local/bin/node")
        ]
        let groups = AppProcessCatalog.group(processes, mode: .byProcess)
        XCTAssertEqual(groups.count, 2)
    }

    func testKernelProcessesGroupTogether() {
        let processes = [
            sample(pid: 0, name: "kernel_task", kernel: true)
        ]
        let groups = AppProcessCatalog.group(processes, mode: .byApp)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.kind, .kernel)
    }

    func testBusiestSortsByMetric() {
        let processes = [
            sample(pid: 1, name: "quiet", cpu: 1, memory: 100),
            sample(pid: 2, name: "loud", cpu: 50, memory: 10)
        ]
        let groups = AppProcessCatalog.group(processes, mode: .byApp)
        let snapshot = SystemSnapshot(groups: groups)
        XCTAssertEqual(snapshot.busiest(metric: .cpu).first?.name, "loud")
        XCTAssertEqual(snapshot.busiest(metric: .memory).first?.name, "quiet")
    }

    func testNetworkRatesMergeIntoGroups() {
        let processes = [
            sample(pid: 1, name: "App", path: "/Applications/App.app/Contents/MacOS/App",
                   bundlePath: "/Applications/App.app", bundleName: "App", download: 10),
            sample(pid: 2, parent: 1, name: "App Helper", path: "/Applications/App.app/Helpers/H",
                   bundlePath: "/Applications/App.app", bundleName: "App", download: 40)
        ]
        let groups = AppProcessCatalog.group(processes, mode: .byApp)
        XCTAssertEqual(groups.first?.downloadPerSecond ?? 0, 50, accuracy: 0.001)
    }

    // MARK: - Rate math

    func testUsageRatesFromCounterDeltas() {
        let previous = ProcessProbe.ProcessUsageCounters(
            cpuTimeSeconds: 10, diskReadBytes: 1000, diskWrittenBytes: 0, wakeups: 100, energy: 0)
        let current = ProcessProbe.ProcessUsageCounters(
            cpuTimeSeconds: 10.5, diskReadBytes: 2000, diskWrittenBytes: 500, wakeups: 150, energy: 42)
        let rates = ProcessProbe.rates(from: previous, to: current, interval: 0.5)
        XCTAssertEqual(rates.cpuPercent, 100, accuracy: 0.01)
        XCTAssertEqual(rates.diskReadPerSecond, 2000, accuracy: 0.01)
        XCTAssertEqual(rates.diskWritePerSecond, 1000, accuracy: 0.01)
        XCTAssertEqual(rates.wakeupsPerSecond, 100, accuracy: 0.01)
        XCTAssertEqual(rates.energyDelta, 42, accuracy: 0.001)
    }

    func testCountersGoingBackwardsYieldZeroRates() {
        let previous = ProcessProbe.ProcessUsageCounters(
            cpuTimeSeconds: 10, diskReadBytes: 5000, diskWrittenBytes: 0, wakeups: 0, energy: 5)
        let current = ProcessProbe.ProcessUsageCounters(
            cpuTimeSeconds: 2, diskReadBytes: 10, diskWrittenBytes: 0, wakeups: 0, energy: 1)
        let rates = ProcessProbe.rates(from: previous, to: current, interval: 1)
        XCTAssertEqual(rates.cpuPercent, 0)
        XCTAssertEqual(rates.diskReadPerSecond, 0)
        XCTAssertEqual(rates.energyDelta, 0)
    }

    // MARK: - KERN_PROCARGS2 parsing

    func testCommandLineParsing() {
        var data = Data()
        var argc = Int32(3)
        withUnsafeBytes(of: &argc) { data.append(contentsOf: $0) }
        data.append(Data("/usr/bin/env node script.js".utf8))
        data.append(Data([0, 0, 0, 0])) // padding between exec path and argv
        for argument in ["/usr/bin/env", "node", "script.js"] {
            data.append(Data(argument.utf8))
            data.append(Data([0]))
        }
        let parsed = ProcessProbe.parseArguments(data)
        XCTAssertEqual(parsed, ["/usr/bin/env", "node", "script.js"])
    }

    // MARK: - Network parser

    /// 600 real bytes from the live route table, read with
    /// `sysctl [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IF_LIST2, 0]` on macOS 26
    /// arm64 and trimmed to: lo0 (loopback, skipped), a 60-byte interleaved
    /// RTM_NEWADDR, en0 (index 14, ibytes 43320886050, obytes 36562230449),
    /// and gif0 (index 2). Message layout checked against net/if.h's
    /// if_msghdr2 and net/if_var.h's if_data64.
    static let routeDump: [UInt8] = [
        180, 0, 5, 18, 16, 0, 0, 0, 73, 128, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 24, 0, 0, 0, 4, 0, 0, 0, 0, 64, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 227, 150, 86, 4,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 227, 150, 86, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 115, 111, 81, 158, 66, 0, 0, 0, 115, 111, 81, 158, 66, 0, 0, 0, 232, 100, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 141, 62, 227, 106, 0, 0, 0, 0, 20, 18, 1, 0, 24, 3, 0, 0, 108, 111, 48, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        60, 0, 5, 12, 164, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 5, 2, 0, 0, 255, 0, 0, 0, 16, 2,
        0, 0, 127, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 16, 2, 0, 0, 127, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0,
        180, 0, 5, 18, 16, 0, 0, 0, 99, 136, 0, 0, 14, 0, 0, 0, 0, 0, 0, 0, 128, 0, 0, 0, 113, 2, 0, 0, 0, 0,
        0, 0, 6, 0, 0, 6, 14, 0, 0, 0, 220, 5, 0, 0, 0, 0, 0, 0, 0, 1, 181, 8, 0, 0, 0, 0, 113, 14, 222, 2,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 102, 27, 132, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 34, 67, 32, 22, 10, 0, 0, 0, 177, 92, 71, 131, 8, 0, 0, 0, 20, 19, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 69, 141, 230, 106, 0, 0, 0, 0, 20, 18, 14, 0, 6, 3, 6, 0, 101, 110, 48, 234, 207, 223, 163, 156, 227, 0, 0, 0,
        180, 0, 5, 18, 16, 0, 0, 0, 16, 128, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 55, 0, 0, 0, 0, 0, 0, 0, 0, 5, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 141, 62, 227, 106, 0, 0, 0, 0, 20, 18, 2, 0, 55, 4, 0, 0, 103, 105, 102, 48, 0, 0, 0, 0, 0, 0, 0, 0
    ]

    /// The trimmed live dump must parse against the real if_msghdr2 layout.
    func testRouteTableParsingAgainstRealDump() {
        let counters = NetworkProbe.parseInterfaceList(Data(Self.routeDump))
        // lo0 (IFF_LOOPBACK) is skipped; en0 and gif0 both parse.
        XCTAssertEqual(counters.count, 2)
        // The 60-byte RTM_NEWADDR between lo0 and en0 did not stop the walk:
        // en0 sits after it in the fixture and carries its exact live bytes.
        let en0 = counters.first { $0.receivedBytes == 43_320_886_050 && $0.sentBytes == 36_562_230_449 }
        XCTAssertNotNil(en0)
        // Loopback totals must not leak in under any name.
        XCTAssertFalse(counters.contains { $0.receivedBytes == 286_123_978_611 })
        // Names come from if_indextoname when the index resolves, "if%d"
        // otherwise; gif0's index (2) resolves on every macOS system.
        let zeroTraffic = counters.first { $0.receivedBytes == 0 && $0.sentBytes == 0 }
        XCTAssertEqual(zeroTraffic?.name, NetworkProbe.interfaceName(2))
        XCTAssertEqual(zeroTraffic?.name, "gif0")
    }

    // MARK: - Containers

    func testDockerStatsParsing() {
        let stats = ContainerProbe.parseStats(
            """
            {"ID":"abc123","Name":"web","CPUPerc":"0.15%","MemUsage":"45.2MiB / 3.842GB","NetIO":"1.2MB / 340kB"}
            {"ID":"def456","Name":"db","CPUPerc":"1.20%","MemUsage":"512kB / 1GB","NetIO":"0B / 0B"}
            """)
        XCTAssertEqual(stats["web"]?.cpuPercent ?? -1, 0.15, accuracy: 0.001)
        XCTAssertEqual(stats["web"]?.memoryBytes ?? -1, 45 * 1024 * 1024 + Int64(0.2 * 1024 * 1024), accuracy: 100_000)
        XCTAssertEqual(stats["web"]?.memoryLimitBytes ?? -1, 3_842_000_000, accuracy: 1_000_000)
        XCTAssertEqual(stats["web"]?.networkRxBytes ?? -1, 1_200_000, accuracy: 1_000)
        XCTAssertEqual(stats["web"]?.networkTxBytes ?? -1, 340_000, accuracy: 1_000)
        XCTAssertEqual(stats["db"]?.memoryBytes, 512_000)
    }

    func testDockerListParsing() {
        let listed = ContainerProbe.parseContainerList(
            """
            {"ID":"abc123def","Names":"web,web1","Image":"nginx:latest","State":"running","Ports":"0.0.0.0:8080->80/tcp"}
            """)
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0].name, "web")
        XCTAssertEqual(listed[0].image, "nginx:latest")
        XCTAssertEqual(listed[0].ports, ["0.0.0.0:8080->80/tcp"])
    }

    func testSizeStringParsing() {
        XCTAssertEqual(ContainerProbe.parseSizeString("45.2MB"), 45_200_000)
        XCTAssertEqual(ContainerProbe.parseSizeString("512kB"), 512_000)
        XCTAssertEqual(ContainerProbe.parseSizeString("1.234GB"), 1_234_000_000)
        XCTAssertEqual(ContainerProbe.parseSizeString("0B"), 0)
        XCTAssertEqual(ContainerProbe.parseSizeString(nil), 0)
    }

    // MARK: - CLI

    func testStatusTableAndJSON() {
        var snapshot = SystemSnapshot(timestamp: .init(), interval: 2)
        snapshot.cpu.usagePercent = 33
        snapshot.memory.usedBytes = 4_000_000_000
        snapshot.memory.totalBytes = 16_000_000_000
        snapshot.uptime = 90061
        snapshot.groups = [AppProcessGroup(id: "g", name: "A", kind: .app, bundlePath: nil, bundleID: nil, members: [])]
        snapshot.processes = [sample(pid: 1, name: "A")]

        let table = MonitorCLI.statusTable(snapshot)
        XCTAssertTrue(table.contains("CPU 33%"))
        XCTAssertTrue(table.contains("4 GB"))
        XCTAssertTrue(table.contains("1d 1h"))
        XCTAssertTrue(table.contains("1 apps"))

        let json = MonitorCLI.statusJSON(snapshot)
        let data = Data(json.utf8)
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(object?["cpu_percent"] as? Double, 33)
        XCTAssertEqual(object?["uptime_seconds"] as? Int, 90_061)
    }

    func testPortsTableFlagsIdle() {
        var snapshot = SystemSnapshot()
        snapshot.devServers = [
            DevServerReading(
                project: "storefront", projectRoot: "/code/storefront", port: 3000, address: "*", pid: 42,
                processName: "node", isIdle: true, cpuPercent: 0.2)
        ]
        let table = MonitorCLI.portsTable(snapshot)
        XCTAssertTrue(table.contains("storefront"))
        XCTAssertTrue(table.contains("idle"))
        XCTAssertTrue(MonitorCLI.portsJSON(snapshot).contains("true"))
    }
}
