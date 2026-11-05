import Darwin
import Foundation
import IOKit
import IOKit.ps
import Metal

/// GPU inventory and utilization. Device identity comes from Metal; the busy
/// percentage comes from the IOAccelerator registry entry's performance
/// statistics, which the driver publishes publicly on Apple silicon.
public enum GPUProbe {
    public static func devices() -> [GPUDeviceReading] {
        var readings: [GPUDeviceReading] = []
        var seenRegistryIDs = Set<UInt64>()
        for device in MTLCopyAllDevices() {
            let registryID = device.registryID
            guard !seenRegistryIDs.contains(registryID) else { continue }
            seenRegistryIDs.insert(registryID)
            readings.append(
                GPUDeviceReading(
                    name: device.name,
                    vendor: "Apple",
                    utilizationPercent: nil,
                    coreCount: nil,
                    memoryLimitBytes: Int64(device.recommendedMaxWorkingSetSize),
                    isLowPower: device.isLowPower,
                    registryID: registryID))
        }
        // One registry walk per reading; the stats dictionary is reused both
        // for the merge below and for filling in Metal devices' missing slots.
        let statisticsByRegistryID = acceleratorStatistics()
        // The registry can carry accelerators Metal does not enumerate (or the
        // app may not have Metal access in a sandbox); merge their stats in.
        for (registryID, statistics) in statisticsByRegistryID where !seenRegistryIDs.contains(registryID) {
            seenRegistryIDs.insert(registryID)
            readings.append(
                GPUDeviceReading(
                    name: statistics.name ?? "GPU",
                    vendor: "Apple",
                    utilizationPercent: statistics.utilizationPercent,
                    registryID: registryID))
        }
        for index in readings.indices {
            let statistics = statisticsByRegistryID[readings[index].registryID ?? 0]
            if readings[index].utilizationPercent == nil {
                readings[index].utilizationPercent = statistics?.utilizationPercent
            }
            if readings[index].coreCount == nil {
                readings[index].coreCount = statistics?.coreCount
            }
        }
        return readings
    }

    struct AcceleratorStatistics {
        var name: String?
        var utilizationPercent: Double?
        var coreCount: Int?
    }

    /// Reads "PerformanceStatistics" from every IOAccelerator entry. Keys and
    /// availability vary by driver; missing values stay missing.
    static func acceleratorStatistics() -> [UInt64: AcceleratorStatistics] {
        var result: [UInt64: AcceleratorStatistics] = [:]
        guard let iterator = IOKitSupport.Iterator(serviceName: "IOAccelerator") else { return result }
        defer { IOObjectRelease(iterator.object) }
        while let entry = iterator.next() {
            defer { IOObjectRelease(entry) }
            guard let dictionary = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] else { continue }
            let registryID = IOKitSupport.registryID(of: entry)
            let utilization = (dictionary["Device Utilization %"] as? NSNumber)?.doubleValue
            let coreCount = (dictionary["gpu-core-count"] as? NSNumber)?.intValue
                ?? ((IORegistryEntrySearchCFProperty(
                    entry, kIOServicePlane, "gpu-core-count" as CFString, kCFAllocatorDefault,
                    IOOptionBits(kIORegistryIterateRecursively)) as? NSNumber)?.intValue)
            let name = (dictionary["Model"] as? String) ?? (IORegistryEntrySearchCFProperty(
                entry, kIOServicePlane, "model" as CFString, kCFAllocatorDefault,
                IOOptionBits(kIORegistryIterateRecursively)) as? String)
            result[registryID] = AcceleratorStatistics(
                name: name?.trimmingCharacters(in: .whitespacesAndNewlines),
                utilizationPercent: utilization,
                coreCount: coreCount)
        }
        return result
    }
}

/// Neural Engine state. Apple does not publish ANE utilization through a
/// public interface, so this reports presence on Apple silicon and leaves the
/// number honestly missing when it cannot be measured.
public enum NeuralEngineProbe {
    public static func reading() -> NeuralEngineReading {
        let isAppleSilicon = ProcessInfo.processInfo.machineHardwareModel().hasPrefix("arm") || isAppleSiliconByCPU()
        guard isAppleSilicon else { return NeuralEngineReading(isAppleSilicon: false) }
        return NeuralEngineReading(
            isAppleSilicon: true,
            utilizationPercent: nil,
            isMeasurable: false)
    }

    static func isAppleSiliconByCPU() -> Bool {
        var size = 0
        sysctlbyname("hw.optional.arm64", nil, &size, nil, 0)
        guard size == MemoryLayout<Int32>.size else { return false }
        var value: Int32 = 0
        sysctlbyname("hw.optional.arm64", &value, &size, nil, 0)
        return value == 1
    }
}

/// Battery, power source, wattage, and sleep-preventing assertions.
public enum PowerProbe {
    public static func reading() async -> PowerReading {
        var reading = await batteryReading()
        reading.assertions = await assertions()
        return reading
    }

    /// IOPS battery details, plus the AppleSmartBattery registry entry for
    /// figures the power sources API does not carry (cycles, health, watts).
    static func batteryReading() async -> PowerReading {
        let source = powerSources()
        let smart = smartBattery()
        let hasBattery = source.hasBattery || smart != nil
        guard hasBattery else { return PowerReading(hasBattery: false) }
        return PowerReading(
            hasBattery: true,
            level: source.level ?? smart.map { Double($0.currentCapacity) / Double(max(1, $0.maxCapacity)) },
            isCharging: source.isCharging ?? smart?.isCharging ?? false,
            isPluggedIn: source.isPluggedIn,
            isCharged: source.isCharged,
            timeToEmptySeconds: source.timeToEmpty ?? smart.map { Double($0.timeToEmpty) * 60 },
            timeToFullSeconds: source.timeToFull,
            cycleCount: smart?.cycleCount,
            healthFraction: smart.map { smart in
                guard smart.maxCapacity > 0 else { return 1 }
                return min(1, Double(smart.designCapacity) / Double(max(1, smart.maxCapacity)))
            },
            temperatureCelsius: smart.map { Double($0.temperature) / 100 },
            wattage: smart.map { smart in
                let milliVolts = Double(max(1, smart.voltage))
                return Double(smart.amperage) * milliVolts / 1_000_000
            },
            powerSource: source.name)
    }

    struct PowerSourceFacts {
        var hasBattery = false
        var level: Double?
        var isCharging: Bool?
        var isPluggedIn = false
        var isCharged = false
        var timeToEmpty: TimeInterval?
        var timeToFull: TimeInterval?
        var name: String?
    }

    /// Applies one power source's state to the running facts.
    static func applyPowerState(_ description: [String: Any], to facts: inout PowerSourceFacts) {
        switch description[kIOPSPowerSourceStateKey] as? String {
        case kIOPSACPowerValue:
            facts.isPluggedIn = true
            facts.isCharging = (description[kIOPSIsChargingKey] as? Bool) ?? false
            if let minutes = description[kIOPSTimeToFullChargeKey] as? Int, minutes > 0 {
                facts.timeToFull = TimeInterval(minutes * 60)
            }
            if (description[kIOPSCurrentCapacityKey] as? Int) == 100 { facts.isCharged = true }
        case kIOPSBatteryPowerValue:
            facts.isPluggedIn = false
            facts.isCharging = false
            if let minutes = description[kIOPSTimeToEmptyKey] as? Int, minutes > 0 {
                facts.timeToEmpty = TimeInterval(minutes * 60)
            }
        default:
            break
        }
    }

    static func powerSources() -> PowerSourceFacts {
        var facts = PowerSourceFacts()
        guard let sourceList = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sources = IOPSCopyPowerSourcesList(sourceList)?.takeRetainedValue() as? [CFTypeRef] else {
            return facts
        }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(sourceList, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            if description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType { facts.hasBattery = true }
            if let percent = description[kIOPSCurrentCapacityKey] as? Int,
                let capacity = description[kIOPSMaxCapacityKey] as? Int, capacity > 0 {
                facts.level = Double(percent) / Double(capacity)
            }
            Self.applyPowerState(description, to: &facts)
            facts.name = description[kIOPSNameKey] as? String
        }
        return facts
    }

    struct SmartBatteryFacts {
        var currentCapacity: Int
        var maxCapacity: Int
        var designCapacity: Int
        var cycleCount: Int
        var temperature: Int
        var voltage: Int
        var amperage: Int
        var isCharging: Bool
        var timeToEmpty: Int
    }

    /// Reads the AppleSmartBattery registry entry. Desktops have none, which
    /// keeps this honest on Mac minis and Studio displays.
    static func smartBattery() -> SmartBatteryFacts? {
        guard let iterator = IOKitSupport.Iterator(serviceName: "AppleSmartBattery") else { return nil }
        defer { IOObjectRelease(iterator.object) }
        guard let entry = iterator.next() else { return nil }
        defer { IOObjectRelease(entry) }
        func property(_ key: String) -> NSNumber? {
            IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber
        }
        guard let maxCapacity = property("MaxCapacity")?.intValue else { return nil }
        return SmartBatteryFacts(
            currentCapacity: property("CurrentCapacity")?.intValue ?? 0,
            maxCapacity: maxCapacity,
            designCapacity: property("DesignCapacity")?.intValue ?? maxCapacity,
            cycleCount: property("CycleCount")?.intValue ?? 0,
            temperature: property("Temperature")?.intValue ?? 0,
            voltage: property("Voltage")?.intValue ?? 0,
            amperage: property("Amperage")?.intValue ?? 0,
            isCharging: property("IsCharging")?.boolValue ?? false,
            timeToEmpty: property("TimeRemaining")?.intValue ?? 0)
    }

    /// `pmset -g assertions`: who is keeping the Mac (or its display) awake.
    static func assertions() async -> [PowerAssertionReading] {
        guard let output = try? await SystemTool.run("/usr/bin/pmset", arguments: ["-g", "assertions"]) else { return [] }
        return Self.parseAssertions(output)
    }

    /// Parses the "Listed by owning process" section; pure and testable.
    /// Lines look like
    /// `pid 175(cupsd): [0x0000c0010001] 11:27:58 PreventUserIdleSystemSleep named: "…"`
    /// — after the parenthesised process name come the assertion id in
    /// brackets, the held time, the assertion kind, and the detail.
    static func parseAssertions(_ output: String) -> [PowerAssertionReading] {
        var readings: [PowerAssertionReading] = []
        var seenIDs = Set<String>()
        var inList = false
        for line in output.split(separator: "\n") {
            let text = String(line).trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("Listed by owning process") {
                inList = true
                continue
            }
            guard inList else { continue }
            if text.hasPrefix("Kernel Assertions") || text.hasPrefix("No kernel assertions") { break }
            guard text.hasPrefix("pid "), let open = text.firstIndex(of: "("),
                let close = text.firstIndex(of: ")"), open < close else { continue }
            let pid = pid_t(text.dropFirst(4).prefix(while: \.isNumber)) ?? 0
            let name = String(text[text.index(after: open)..<close])
            let remainder = String(text[text.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            // Skip the "[0x…]" assertion id and any trailing colon token so
            // the held time and kind land in the right slots.
            let tokens = remainder.split(separator: " ", omittingEmptySubsequences: true)
                .filter { !$0.hasPrefix("[0x") && !$0.hasSuffix(":") }
            guard tokens.count >= 2 else { continue }
            let held = Self.parseHeldTime(String(tokens[0]))
            let kind = String(tokens[1])
            var detail: String?
            if let namedRange = remainder.range(of: "named:") {
                detail = String(remainder[namedRange.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if detail?.isEmpty == true { detail = nil }
            }
            // One process can hold several assertions of the same kind; the
            // view's ForEach identifies rows by pid-name-kind, so duplicates
            // must be folded here or SwiftUI crashes on repeated IDs.
            let reading = PowerAssertionReading(pid: pid, processName: name, kind: kind, detail: detail, heldSeconds: held)
            if seenIDs.insert(reading.id).inserted {
                readings.append(reading)
            }
        }
        return readings
    }

    /// "01:23:45" → seconds.
    static func parseHeldTime(_ text: String) -> TimeInterval {
        let parts = text.split(separator: ":").compactMap { TimeInterval($0) }
        guard parts.count == 3 else { return 0 }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }
}

// MARK: - Shared IOKit helpers

/// Registry iteration shared by the GPU and battery probes.
enum IOKitSupport {
    struct Iterator {
        let object: io_iterator_t

        init?(serviceName: String) {
            var iterator: io_iterator_t = 0
            let result = IOServiceGetMatchingServices(
                kIOMainPortDefault, IOServiceMatching(serviceName), &iterator)
            guard result == kIOReturnSuccess, iterator != 0 else { return nil }
            object = iterator
        }

        func next() -> io_registry_entry_t? {
            let entry = IOIteratorNext(object)
            return entry == 0 ? nil : entry
        }
    }

    static func registryID(of entry: io_registry_entry_t) -> UInt64 {
        var value: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(entry, &value)
        return value
    }
}

extension ProcessInfo {
    /// hw.model via sysctl, e.g. "Mac15,6".
    func machineHardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }
}

/// Runs an Apple system tool and returns stdout. Thin wrapper so probes do
/// not each duplicate error handling; the caller decides how to degrade.
enum SystemTool {
    static func run(_ path: String, arguments: [String]) async throws -> String {
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw MonitoringError.toolUnavailable(path)
        }
        let result = await ProcessRunner.run(URL(fileURLWithPath: path), arguments: arguments, timeout: 15)
        guard result.exitCode == 0 else {
            throw MonitoringError.toolFailed(path, result.stderr)
        }
        return result.stdout
    }
}

public enum MonitoringError: Error, LocalizedError, Sendable {
    case toolUnavailable(String)
    /// Path plus the tool's own stderr.
    case toolFailed(String, String)

    public var errorDescription: String? {
        switch self {
        case .toolUnavailable(let path):
            let name = URL(fileURLWithPath: path).lastPathComponent
            return String(
                localized: "The tool \(name) is not available.", comment: "Monitoring tool missing")
        case .toolFailed(let path, let message):
            let name = URL(fileURLWithPath: path).lastPathComponent
            return String(
                localized: "\(name) failed: \(message)", comment: "Monitoring tool failure")
        }
    }
}
