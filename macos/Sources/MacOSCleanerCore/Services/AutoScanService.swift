import CoreGraphics
import Darwin
import Foundation
import IOKit.ps
import os
import ServiceManagement

/// Conditions that must hold before unattended maintenance may run: the daily
/// interval has elapsed, the user has been idle for a while, and the Mac is
/// plugged in or reasonably charged. Every input is injectable so tests can
/// exercise the gate without touching real hardware or clocks.
public struct AutoScanConditions: Sendable {
    public let interval: TimeInterval
    public let idleThreshold: TimeInterval
    public let minimumBatteryPercent: Int

    public init(
        interval: TimeInterval = 24 * 3600,
        idleThreshold: TimeInterval = 600,
        minimumBatteryPercent: Int = 50
    ) {
        self.interval = interval
        self.idleThreshold = idleThreshold
        self.minimumBatteryPercent = minimumBatteryPercent
    }

    /// The production gate. Test overrides flow in through `Environment`.
    public static let standard = AutoScanConditions()

    /// True when an automatic run may start. Deliberately fail-closed: when
    /// idle time or the power source cannot be measured, the run is skipped —
    /// unattended work never happens on incomplete information.
    public func isDue(
        lastRun: Date?,
        now: Date = Date(),
        idleSeconds: TimeInterval?,
        onACPower: Bool?,
        batteryPercent: Int?
    ) -> Bool {
        if let lastRun, now.timeIntervalSince(lastRun) < interval {
            return false
        }
        guard let idleSeconds, idleSeconds >= idleThreshold else {
            return false
        }
        if onACPower == true {
            return true
        }
        if let batteryPercent, batteryPercent >= minimumBatteryPercent {
            return true
        }
        return false
    }
}

/// Environment probes feeding `AutoScanConditions.isDue`, with overrides so
/// tests (and debugging) can pin inputs:
/// `TIDYBYTE_IDLE_SECONDS`, `TIDYBYTE_ON_POWER`, `TIDYBYTE_BATTERY_PERCENT`.
public enum AutoScanEnvironment {
    static var environment: [String: String] { ProcessInfo.processInfo.environment }

    /// Seconds since the last user input on the console session.
    public static func idleSeconds() -> TimeInterval? {
        if let override = environment["TIDYBYTE_IDLE_SECONDS"], let seconds = TimeInterval(override) {
            return seconds
        }
        // kCGAnyInputEventType is not exposed to Swift; ~0 selects "any event".
        guard let anyInput = CGEventType(rawValue: ~UInt32(0)) else {
            return nil
        }
        let seconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        return seconds.isFinite && seconds >= 0 ? seconds : nil
    }

    /// `(onACPower, batteryPercent)`; nil values mean "unknown" and the
    /// conditions gate treats that as not suitable.
    public static func powerStatus() -> (onACPower: Bool, batteryPercent: Int?)? {
        if let override = environment["TIDYBYTE_ON_POWER"] {
            return (override == "1", Int(environment["TIDYBYTE_BATTERY_PERCENT"] ?? ""))
        }
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }
        // Battery-less desktop Macs (Mac mini, Mac Studio, iMac, Mac Pro) return
        // zero power sources and run exclusively on AC power.
        if sources.isEmpty {
            return (true, nil)
        }
        var onACPower = false
        var batteryPercent: Int?
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?
                .takeUnretainedValue() as? [String: Any] else {
                continue
            }
            if description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue {
                onACPower = true
            }
            if let current = description[kIOPSCurrentCapacityKey] as? Int,
               let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 {
                batteryPercent = Int((Double(current) / Double(maximum) * 100).rounded())
            }
        }
        return (onACPower, batteryPercent)
    }
}

/// Registers the hourly LaunchAgent bundled at
/// `Contents/Library/LaunchAgents/<label>.plist` (copied by Scripts/build-app.sh
/// from Configuration/). The agent launches the app binary with `--autoscan`.
/// Registration is refused when the binary does not live in /Applications or
/// ~/Applications: a translocated or developer build would schedule a
/// temporary binary that vanishes on rebuild.
public enum LaunchAgentInstaller {
    public static let label = AppIdentity.autoscanLabel
    public static let plistName = "\(AppIdentity.autoscanLabel).plist"

    private static var service: SMAppService { .agent(plistName: plistName) }

    static var executablePath: String {
        Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
    }

    /// Only installed apps may schedule unattended work. Set
    /// `TIDYBYTE_ALLOW_INSTALL=1` to override (development).
    public static func canInstall(executablePath: String? = nil) -> Bool {
        if ProcessInfo.processInfo.environment["TIDYBYTE_ALLOW_INSTALL"] == "1" {
            return true
        }
        let binary = executablePath ?? Self.executablePath
        let homeApplications = PathSafetyPolicy.realHomeDirectory.appendingPathComponent("Applications").path + "/"
        let applications: Set<String> = ["/Applications/", homeApplications]
        return applications.contains { binary.hasPrefix($0) }
    }

    public static func isInstalled() -> Bool {
        service.status == .enabled
    }

    /// - Throws: when the binary location is not installable or registration fails.
    public static func install() throws {
        let executable = executablePath
        guard canInstall(executablePath: executable) else {
            throw AutoScanError.notInstallable(executable)
        }
        try service.register()
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
        logger.info("Registered autoscan agent, status \(service.status.rawValue, privacy: .public)")
    }

    public static func remove() {
        do {
            try service.unregister()
        } catch {
            // The signature is kept for existing callers; the failure is logged, not hidden.
            logger.error("Could not unregister autoscan agent: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static let logger = Logger(subsystem: AppIdentity.bundleIdentifier, category: "LaunchAgentInstaller")
}

public enum AutoScanError: Error, LocalizedError {
    case notInstallable(String)
    /// Conditions not met (interval, idle, power) — a silent skip, not a failure.
    case conditionsNotMet
    case notAllowed

    public var errorDescription: String? {
        switch self {
        case .notInstallable(let path):
            return String(
                localized: "Automatic maintenance needs the app installed in /Applications (found \(path)).",
                comment: "Autoscan install location error"
            )
        case .conditionsNotMet:
            return String(
                localized: "Skipped: the Mac is in use, not charged enough, or maintenance ran recently.",
                comment: "Autoscan conditions skip"
            )
        case .notAllowed:
            return String(localized: "Automatic maintenance is not enabled.", comment: "Autoscan disabled error")
        }
    }
}

public enum AutoScanSettingsKey: String, CaseIterable {
    case enabled = "autoscanEnabled"
    case selectedFolderPaths
}

/// Headless `--autoscan` entry point. Runs at most one unattended pass:
/// gate → scan → execute ONLY clone-fold actions (nothing is ever deleted
/// unattended; trashing needs a human in the app) → notify → stamp → exit.
public enum AutoScanRunner {
    private static let logger = Logger(subsystem: AppIdentity.bundleIdentifier, category: "AutoScanRunner")
    public static let lastRunKey = "lastAutoScanDate"

    /// Runs the gated maintenance pass and returns the process exit code:
    /// 0 when the pass finished, was not due, or auto-scan is disabled; 1 when
    /// the pass failed. The executable passes this value to `exit`.
    @discardableResult
    public static func run() async -> Int32 {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: AutoScanSettingsKey.enabled.rawValue) else {
            logger.info("Auto-scan disabled; exiting")
            return 0
        }
        guard isDue(defaults: defaults) else {
            return 0
        }
        return await runPass(defaults: defaults) { try await runMaintenancePass() }
    }

    /// Runs one pass and maps its outcome to an exit code. The pass is a
    /// parameter so the failure branch can be tested without a real scan.
    static func runPass(
        defaults: UserDefaults,
        pass: () async throws -> MaintenanceSummary
    ) async -> Int32 {
        do {
            let summary = try await pass()
            guard !summary.skipped else {
                logger.info("Auto-scan skipped because another maintenance pass holds the lock.")
                return 0
            }
            defaults.set(Date(), forKey: lastRunKey)
            if summary.foldCount > 0 {
                await NotificationScheduler().scheduleScanCompletedNotification(
                    reclaimedBytes: summary.freedBytes
                )
            }
            logger.info("Auto-scan finished: \(summary.foldCount) folds, \(summary.failureCount) failures")
            return summary.failureCount > 0 ? 1 : 0
        } catch {
            logger.error("Auto-scan failed: \(error.localizedDescription, privacy: .public)")
            return 1
        }
    }

    /// The gate, kept separate so `run` stays readable: interval, idle and
    /// power must all say yes before any unattended work happens.
    private static func isDue(defaults: UserDefaults) -> Bool {
        let idle = AutoScanEnvironment.idleSeconds()
        let power = AutoScanEnvironment.powerStatus()
        let lastRun = defaults.object(forKey: lastRunKey) as? Date
        let due = AutoScanConditions.standard.isDue(
            lastRun: lastRun,
            idleSeconds: idle,
            onACPower: power?.onACPower,
            batteryPercent: power?.batteryPercent
        )
        if !due {
            let idleText = idle.map { String($0) } ?? "?"
            let acText = String(power?.onACPower ?? false)
            logger.info(
                "Auto-scan conditions not met (idle: \(idleText, privacy: .public), AC: \(acText, privacy: .public))"
            )
        }
        return due
    }

    struct MaintenanceSummary {
        let foldCount: Int
        let failureCount: Int
        let freedBytes: Int64
        var skipped: Bool = false
    }

    /// The unattended safety filter, as its own function so the invariant is
    /// directly testable: headless runs may approve ONLY pending clone-fold
    /// actions — they delete, move and rename nothing — and everything else
    /// waits for a human in the app.
    static func unattendedActionFilter(_ plan: Plan) -> [PlannedAction] {
        plan.actions.filter {
            $0.actionType == .cloneDeduplicate && $0.userDecision == .undecided && $0.executedAt == nil
        }
    }

    private static func acquireRunLock() -> Int32? {
        guard let supportBase = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let appDir = supportBase.appendingPathComponent(AppIdentity.supportFolderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        let lockPath = appDir.appendingPathComponent("autoscan.lock", isDirectory: false).path
        let fd = Darwin.open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        var lock = Darwin.flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        lock.l_start = 0
        lock.l_len = 0
        if Darwin.fcntl(fd, F_SETLK, &lock) != 0 {
            let err = errno
            _ = Darwin.close(fd)
            return (err == EACCES || err == EAGAIN) ? -1 : nil
        }
        return fd
    }

    /// One unattended pass: lock -> fail-closed SQLite -> scan -> approve ONLY
    /// clone-fold actions in bounded batches.
    private static func runMaintenancePass() async throws -> MaintenanceSummary {
        let lockFD = acquireRunLock()
        if lockFD == -1 {
            return MaintenanceSummary(foldCount: 0, failureCount: 0, freedBytes: 0, skipped: true)
        }
        defer {
            if let fd = lockFD, fd >= 0 {
                var unlock = Darwin.flock()
                unlock.l_type = Int16(F_UNLCK)
                unlock.l_whence = Int16(SEEK_SET)
                _ = Darwin.fcntl(fd, F_SETLK, &unlock)
                _ = Darwin.close(fd)
            }
        }
        // Fail closed if primary storage cannot open: unattended runs must never
        // discard UndoRecords in an ephemeral /tmp database.
        let store = try SQLiteStore()
        let memory = MemoryEngine(store: store)
        let orchestrator = ScanOrchestrator(store: store, memory: memory)
        let executor = ActionExecutor(store: store)

        let folderPaths = UserDefaults.standard.stringArray(forKey: AutoScanSettingsKey.selectedFolderPaths.rawValue) ?? []
        let folders = folderPaths.map { URL(fileURLWithPath: $0) }

        let (outcome, plan) = try await orchestrator.scan(
            mode: folders.isEmpty ? .homeFolder : .selectedFolders,
            selectedFolders: folders,
            providerSettings: ProviderSettings(),
            includeAI: false,
            posture: .conservative,
            duplicateStrategy: .apfsClone
        )
        var filesByID: [String: FileRecord] = [:]
        for record in outcome.files {
            filesByID[record.id] = record
        }

        var foldActions = Self.unattendedActionFilter(plan)
        for index in foldActions.indices {
            foldActions[index].userDecision = .approved
            foldActions[index].status = .approved
        }
        return await executeMaintenanceBatches(
            foldActions: foldActions,
            filesByID: filesByID,
            executor: executor
        )
    }

    private static func executeMaintenanceBatches(
        foldActions: [PlannedAction],
        filesByID: [String: FileRecord],
        executor: ActionExecutor
    ) async -> MaintenanceSummary {
        var totalFolds = 0
        var totalFailures = 0
        var totalFreed: Int64 = 0
        let batchSize = ExecutionLimits.maxActionsPerBatch
        for start in stride(from: 0, to: foldActions.count, by: batchSize) {
            let end = min(start + batchSize, foldActions.count)
            let batch = Array(foldActions[start..<end])
            let summary = await executor.execute(actions: batch, filesByID: filesByID)
            totalFolds += summary.undoRecords.count
            totalFailures += summary.failures.count
            totalFreed += summary.logs.reduce(Int64(0)) { total, log in
                total + (Int64(log.afterState["freed_bytes"] ?? "") ?? 0)
            }
        }
        return MaintenanceSummary(
            foldCount: totalFolds,
            failureCount: totalFailures,
            freedBytes: totalFreed
        )
    }
}
