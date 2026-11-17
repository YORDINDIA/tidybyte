import Darwin
import Foundation
import IOKit
import IOKit.ps
import Metal

/// GPU inventory and utilization. Device identity comes from Metal; live
/// utilization and memory counters come from IOAccelerator PerformanceStatistics.
public enum GPUProbe {
    public static func devices() -> [GPUDeviceReading] {
        var readings: [GPUDeviceReading] = []
        var seenRegistryIDs = Set<UInt64>()
        for device in MTLCopyAllDevices() {
            let registryID = device.registryID
            guard seenRegistryIDs.insert(registryID).inserted else { continue }
            readings.append(
                GPUDeviceReading(
                    name: device.name,
                    vendor: "Apple",
                    memoryLimitBytes: Int64(device.recommendedMaxWorkingSetSize),
                    isLowPower: device.isLowPower,
                    registryID: registryID))
        }
        let statisticsByRegistryID = acceleratorStatistics()
        for (registryID, statistics) in statisticsByRegistryID where !seenRegistryIDs.contains(registryID) {
            seenRegistryIDs.insert(registryID)
            readings.append(
                GPUDeviceReading(
                    name: statistics.name ?? "GPU",
                    vendor: "Apple",
                    utilizationPercent: statistics.utilizationPercent,
                    rendererUtilizationPercent: statistics.rendererUtilizationPercent,
                    tilerUtilizationPercent: statistics.tilerUtilizationPercent,
                    coreCount: statistics.coreCount,
                    inUseMemoryBytes: statistics.inUseMemoryBytes,
                    allocatedMemoryBytes: statistics.allocatedMemoryBytes,
                    registryID: registryID))
        }
        for index in readings.indices {
            guard let statistics = statisticsByRegistryID[readings[index].registryID ?? 0] else { continue }
            readings[index].utilizationPercent = readings[index].utilizationPercent ?? statistics.utilizationPercent
            readings[index].rendererUtilizationPercent = readings[index].rendererUtilizationPercent
                ?? statistics.rendererUtilizationPercent
            readings[index].tilerUtilizationPercent = readings[index].tilerUtilizationPercent
                ?? statistics.tilerUtilizationPercent
            readings[index].coreCount = readings[index].coreCount ?? statistics.coreCount
            readings[index].inUseMemoryBytes = readings[index].inUseMemoryBytes ?? statistics.inUseMemoryBytes
            readings[index].allocatedMemoryBytes = readings[index].allocatedMemoryBytes ?? statistics.allocatedMemoryBytes
        }
        return readings
    }

    struct AcceleratorStatistics {
        var name: String?
        var utilizationPercent: Double?
        var rendererUtilizationPercent: Double?
        var tilerUtilizationPercent: Double?
        var coreCount: Int?
        var inUseMemoryBytes: Int64?
        var allocatedMemoryBytes: Int64?
    }

    private static func directProperty(_ entry: io_registry_entry_t, key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func entryProperty(_ entry: io_registry_entry_t, key: String) -> Any? {
        if let direct = directProperty(entry, key: key) { return direct }
        return IORegistryEntrySearchCFProperty(
            entry, kIOServicePlane, key as CFString, kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively))
    }

    /// Reads "PerformanceStatistics" and model/core metadata from every IOAccelerator entry.
    static func acceleratorStatistics() -> [UInt64: AcceleratorStatistics] {
        var result: [UInt64: AcceleratorStatistics] = [:]
        guard let iterator = IOKitSupport.Iterator(serviceName: "IOAccelerator") else { return result }
        defer { IOObjectRelease(iterator.object) }
        while let entry = iterator.next() {
            defer { IOObjectRelease(entry) }
            guard let dictionary = directProperty(entry, key: "PerformanceStatistics") as? [String: Any] else {
                continue
            }
            let registryID = IOKitSupport.registryID(of: entry)
            let coreCount = (dictionary["gpu-core-count"] as? NSNumber)?.intValue
                ?? (entryProperty(entry, key: "gpu-core-count") as? NSNumber)?.intValue
            let rawModel = (dictionary["Model"] as? String)
                ?? (entryProperty(entry, key: "model") as? String)
                ?? (entryProperty(entry, key: "model") as? Data).flatMap { data in
                    String(bytes: data.prefix { $0 != 0 }, encoding: .utf8)
                }
            result[registryID] = AcceleratorStatistics(
                name: rawModel?.trimmingCharacters(in: .whitespacesAndNewlines),
                utilizationPercent: (dictionary["Device Utilization %"] as? NSNumber)?.doubleValue,
                rendererUtilizationPercent: (dictionary["Renderer Utilization %"] as? NSNumber)?.doubleValue,
                tilerUtilizationPercent: (dictionary["Tiler Utilization %"] as? NSNumber)?.doubleValue,
                coreCount: coreCount,
                inUseMemoryBytes: (dictionary["In use system memory"] as? NSNumber)?.int64Value,
                allocatedMemoryBytes: (dictionary["Alloc system memory"] as? NSNumber)?.int64Value)
        }
        return result
    }
}

/// Neural Engine state. Apple does not publish ANE utilization through a
/// public interface, so this reports presence on Apple silicon and leaves the
/// number honestly missing when it cannot be measured.
public enum NeuralEngineProbe {
    private static let isAppleSiliconCached: Bool = {
        ProcessInfo.cachedHardwareModel.hasPrefix("arm") || isAppleSiliconByCPU()
    }()

    public static func reading() -> NeuralEngineReading {
        guard isAppleSiliconCached else { return NeuralEngineReading(isAppleSilicon: false) }
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
        let isCharging = source.isCharging ?? smart?.isCharging ?? false
        let level = source.level ?? smart.flatMap { smart -> Double? in
            let cap = smart.maxCapacity > 0 ? smart.maxCapacity : 100
            return min(1, max(0, Double(smart.currentCapacity) / Double(cap)))
        }
        let timeToEmpty: TimeInterval? = if let sourceEmpty = source.timeToEmpty {
            sourceEmpty
        } else if !source.isPluggedIn, let smart, smart.timeToEmpty > 0, smart.timeToEmpty < 65_535 {
            Double(smart.timeToEmpty) * 60
        } else {
            nil
        }
        let healthFraction: Double? = smart.flatMap { smart in
            guard smart.designCapacity > 0 else { return nil }
            let fullCharge = smart.rawMaxCapacity ?? (smart.maxCapacity > 100 ? smart.maxCapacity : nil)
            guard let fullCharge, fullCharge > 0 else { return nil }
            return min(1, max(0, Double(fullCharge) / Double(smart.designCapacity)))
        }
        let wattage: Double? = smart.flatMap { smart in
            guard smart.voltage > 0 else { return nil }
            return Double(smart.amperage) * Double(smart.voltage) / 1_000_000
        }
        return PowerReading(
            hasBattery: true,
            level: level,
            isCharging: isCharging,
            isPluggedIn: source.isPluggedIn,
            isCharged: source.isPluggedIn && source.isCharged,
            timeToEmptySeconds: timeToEmpty,
            timeToFullSeconds: isCharging ? source.timeToFull : nil,
            cycleCount: smart?.cycleCount,
            healthFraction: healthFraction,
            temperatureCelsius: smart.map { Double($0.temperature) / 100 },
            wattage: wattage,
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

    /// Applies the internal battery's power state to the running facts.
    static func applyPowerState(_ description: [String: Any], to facts: inout PowerSourceFacts) {
        switch description[kIOPSPowerSourceStateKey] as? String {
        case kIOPSACPowerValue:
            facts.isPluggedIn = true
            let charging = (description[kIOPSIsChargingKey] as? Bool) ?? false
            facts.isCharging = charging
            if let minutes = description[kIOPSTimeToFullChargeKey] as? Int, minutes > 0 {
                facts.timeToFull = TimeInterval(minutes * 60)
            }
            let explicitCharged = description[kIOPSIsChargedKey] as? Bool
            let atHundred = (description[kIOPSCurrentCapacityKey] as? Int) == 100 && !charging
            facts.isCharged = explicitCharged ?? atHundred
        case kIOPSBatteryPowerValue:
            facts.isPluggedIn = false
            facts.isCharging = false
            facts.isCharged = false
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
                .takeUnretainedValue() as? [String: Any],
                  (description[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else {
                continue
            }
            facts.hasBattery = true
            if let percent = description[kIOPSCurrentCapacityKey] as? Int,
               let capacity = description[kIOPSMaxCapacityKey] as? Int, capacity > 0 {
                facts.level = min(1, max(0, Double(percent) / Double(capacity)))
            }
            Self.applyPowerState(description, to: &facts)
            facts.name = description[kIOPSNameKey] as? String
            break
        }
        return facts
    }

    struct SmartBatteryFacts {
        var currentCapacity: Int
        var maxCapacity: Int
        var rawMaxCapacity: Int?
        var designCapacity: Int
        var cycleCount: Int
        var temperature: Int
        var voltage: Int
        var amperage: Int
        var isCharging: Bool
        var timeToEmpty: Int
    }

    /// Reads the AppleSmartBattery registry entry. Desktops have none.
    static func smartBattery() -> SmartBatteryFacts? {
        guard let iterator = IOKitSupport.Iterator(serviceName: "AppleSmartBattery") else { return nil }
        defer { IOObjectRelease(iterator.object) }
        guard let entry = iterator.next() else { return nil }
        defer { IOObjectRelease(entry) }
        func property(_ key: String) -> NSNumber? {
            IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber
        }
        func signedInt64(_ key: String) -> Int? {
            guard let number = property(key) else { return nil }
            return Int(clamping: Int64(bitPattern: number.uint64Value))
        }
        guard let maxCapacity = property("MaxCapacity")?.intValue else { return nil }
        let rawMax = property("AppleRawMaxCapacity")?.intValue ?? property("NominalChargeCapacity")?.intValue
        let amperage = signedInt64("Amperage") ?? signedInt64("InstantAmperage") ?? 0
        return SmartBatteryFacts(
            currentCapacity: property("CurrentCapacity")?.intValue ?? 0,
            maxCapacity: maxCapacity,
            rawMaxCapacity: rawMax,
            designCapacity: property("DesignCapacity")?.intValue ?? rawMax ?? maxCapacity,
            cycleCount: property("CycleCount")?.intValue ?? 0,
            temperature: property("Temperature")?.intValue ?? 0,
            voltage: property("Voltage")?.intValue ?? 0,
            amperage: amperage,
            isCharging: property("IsCharging")?.boolValue ?? false,
            timeToEmpty: property("TimeRemaining")?.intValue ?? 0)
    }

    /// `pmset -g assertions`: who is keeping the Mac (or its display) awake.
    static func assertions() async -> [PowerAssertionReading] {
        guard let output = try? await SystemTool.run("/usr/bin/pmset", arguments: ["-g", "assertions"]) else { return [] }
        return Self.parseAssertions(output)
    }

    /// Parses the "Listed by owning process" section; pure and testable.
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
    static let cachedHardwareModel: String = {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "" }
        let bytes = buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }()

    func machineHardwareModel() -> String {
        Self.cachedHardwareModel
    }
}

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
