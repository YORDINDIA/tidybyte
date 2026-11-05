import Foundation

/// Everything one monitoring tick knows about the system. Every probe fills in
/// its slice; a slice a probe cannot read stays empty rather than guessing.
/// Value types only, so the engine can hand snapshots to SwiftUI, the history
/// store, the alert engine, and the CLI interchangeably.
public struct SystemSnapshot: Sendable, Equatable {
    public var timestamp: Date
    /// Seconds between this sample and the one before it, used to turn
    /// cumulative counters into rates.
    public var interval: TimeInterval
    public var cpu: CPUReading
    public var memory: MemoryReading
    public var disk: DiskIOReading
    public var network: NetworkReading
    public var gpu: GPUReading
    public var neural: NeuralEngineReading
    public var power: PowerReading
    public var sensors: [SensorReading]
    public var fans: [FanReading]
    public var audio: AudioReading
    public var bluetooth: [BluetoothDeviceReading]
    public var processes: [ProcessSample]
    public var groups: [AppProcessGroup]
    public var devServers: [DevServerReading]
    public var agents: [AgentSessionReading]
    public var containers: [ContainerReading]
    public var uptime: TimeInterval

    public init(
        timestamp: Date = .init(),
        interval: TimeInterval = 0,
        cpu: CPUReading = .init(),
        memory: MemoryReading = .init(),
        disk: DiskIOReading = .init(),
        network: NetworkReading = .init(),
        gpu: GPUReading = .init(),
        neural: NeuralEngineReading = .init(),
        power: PowerReading = .init(),
        sensors: [SensorReading] = [],
        fans: [FanReading] = [],
        audio: AudioReading = .init(),
        bluetooth: [BluetoothDeviceReading] = [],
        processes: [ProcessSample] = [],
        groups: [AppProcessGroup] = [],
        devServers: [DevServerReading] = [],
        agents: [AgentSessionReading] = [],
        containers: [ContainerReading] = [],
        uptime: TimeInterval = 0
    ) {
        self.timestamp = timestamp
        self.interval = interval
        self.cpu = cpu
        self.memory = memory
        self.disk = disk
        self.network = network
        self.gpu = gpu
        self.neural = neural
        self.power = power
        self.sensors = sensors
        self.fans = fans
        self.audio = audio
        self.bluetooth = bluetooth
        self.processes = processes
        self.groups = groups
        self.devServers = devServers
        self.agents = agents
        self.containers = containers
        self.uptime = uptime
    }

    /// The app groups that lead a metric right now, strongest first.
    public func busiest(metric: UsageMetric, limit: Int = 8) -> [AppProcessGroup] {
        let ranked = groups.filter { !$0.isIdle }
        return Array(ranked.sorted { $0.value(for: metric) > $1.value(for: metric) }.prefix(limit))
    }
}

/// The metric a tile, menu bar item, or "busiest" list is ranked by.
public enum UsageMetric: String, CaseIterable, Codable, Sendable, Identifiable {
    case cpu, memory, disk, network, energy

    public var id: String { rawValue }
}

// MARK: - CPU

public struct CPUReading: Sendable, Equatable {
    /// Percent of all compute capacity in use (100 = every core fully busy).
    public var usagePercent: Double
    public var userPercent: Double
    public var systemPercent: Double
    public var idlePercent: Double
    public var loadAverage1: Double
    public var loadAverage5: Double
    public var loadAverage15: Double
    public var logicalCoreCount: Int
    public var physicalCoreCount: Int
    public var performanceCoreCount: Int?
    public var efficiencyCoreCount: Int?

    public init(
        usagePercent: Double = 0,
        userPercent: Double = 0,
        systemPercent: Double = 0,
        idlePercent: Double = 0,
        loadAverage1: Double = 0,
        loadAverage5: Double = 0,
        loadAverage15: Double = 0,
        logicalCoreCount: Int = 0,
        physicalCoreCount: Int = 0,
        performanceCoreCount: Int? = nil,
        efficiencyCoreCount: Int? = nil
    ) {
        self.usagePercent = usagePercent
        self.userPercent = userPercent
        self.systemPercent = systemPercent
        self.idlePercent = idlePercent
        self.loadAverage1 = loadAverage1
        self.loadAverage5 = loadAverage5
        self.loadAverage15 = loadAverage15
        self.logicalCoreCount = logicalCoreCount
        self.physicalCoreCount = physicalCoreCount
        self.performanceCoreCount = performanceCoreCount
        self.efficiencyCoreCount = efficiencyCoreCount
    }
}

// MARK: - Memory

public struct MemoryReading: Sendable, Equatable {
    public var totalBytes: Int64
    public var usedBytes: Int64
    public var appBytes: Int64
    public var wiredBytes: Int64
    public var compressedBytes: Int64
    public var cachedBytes: Int64
    public var swapUsedBytes: Int64
    /// Pages moved in and out of swap per second across the sample interval.
    public var swapInPerSecond: Double
    public var swapOutPerSecond: Double
    public var pageInPerSecond: Double
    public var pageOutPerSecond: Double
    /// System pressure level as mach reports it: 1 normal, 2 warning, 4 critical.
    public var pressureLevel: Int

    public enum Level: Sendable, Equatable { case normal, warning, critical }

    public var pressure: Level {
        switch pressureLevel {
        case 4, 5, 6, 7, 8: .critical
        case 2, 3: .warning
        default: .normal
        }
    }

    public init(
        totalBytes: Int64 = 0,
        usedBytes: Int64 = 0,
        appBytes: Int64 = 0,
        wiredBytes: Int64 = 0,
        compressedBytes: Int64 = 0,
        cachedBytes: Int64 = 0,
        swapUsedBytes: Int64 = 0,
        swapInPerSecond: Double = 0,
        swapOutPerSecond: Double = 0,
        pageInPerSecond: Double = 0,
        pageOutPerSecond: Double = 0,
        pressureLevel: Int = 1
    ) {
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
        self.appBytes = appBytes
        self.wiredBytes = wiredBytes
        self.compressedBytes = compressedBytes
        self.cachedBytes = cachedBytes
        self.swapUsedBytes = swapUsedBytes
        self.swapInPerSecond = swapInPerSecond
        self.swapOutPerSecond = swapOutPerSecond
        self.pageInPerSecond = pageInPerSecond
        self.pageOutPerSecond = pageOutPerSecond
        self.pressureLevel = pressureLevel
    }
}

// MARK: - Disk

public struct DiskIOReading: Sendable, Equatable {
    public var readBytesPerSecond: Double
    public var writeBytesPerSecond: Double
    public var readOperationsPerSecond: Double
    public var writeOperationsPerSecond: Double
    /// Boot-to-now totals, when the platform reports them.
    public var totalReadBytes: Int64?
    public var totalWriteBytes: Int64?

    public init(
        readBytesPerSecond: Double = 0,
        writeBytesPerSecond: Double = 0,
        readOperationsPerSecond: Double = 0,
        writeOperationsPerSecond: Double = 0,
        totalReadBytes: Int64? = nil,
        totalWriteBytes: Int64? = nil
    ) {
        self.readBytesPerSecond = readBytesPerSecond
        self.writeBytesPerSecond = writeBytesPerSecond
        self.readOperationsPerSecond = readOperationsPerSecond
        self.writeOperationsPerSecond = writeOperationsPerSecond
        self.totalReadBytes = totalReadBytes
        self.totalWriteBytes = totalWriteBytes
    }
}

// MARK: - Network

public struct NetworkReading: Sendable, Equatable {
    public var downloadBytesPerSecond: Double
    public var uploadBytesPerSecond: Double
    public var totalDownloadBytes: Int64
    public var totalUploadBytes: Int64
    /// Human-facing interface the rates came from (en0, en1…).
    public var primaryInterface: String?

    public init(
        downloadBytesPerSecond: Double = 0,
        uploadBytesPerSecond: Double = 0,
        totalDownloadBytes: Int64 = 0,
        totalUploadBytes: Int64 = 0,
        primaryInterface: String? = nil
    ) {
        self.downloadBytesPerSecond = downloadBytesPerSecond
        self.uploadBytesPerSecond = uploadBytesPerSecond
        self.totalDownloadBytes = totalDownloadBytes
        self.totalUploadBytes = totalUploadBytes
        self.primaryInterface = primaryInterface
    }
}

// MARK: - GPU

public struct GPUReading: Sendable, Equatable {
    public var devices: [GPUDeviceReading]

    public init(devices: [GPUDeviceReading] = []) {
        self.devices = devices
    }
}

public struct GPUDeviceReading: Sendable, Equatable, Identifiable {
    public var id: String { registryID.map(String.init) ?? name }
    public var name: String
    public var vendor: String
    /// Percent of the device's time busy, when the platform reports it.
    public var utilizationPercent: Double?
    public var coreCount: Int?
    public var memoryLimitBytes: Int64?
    public var isLowPower: Bool
    public var registryID: UInt64?

    public init(
        name: String,
        vendor: String = "Apple",
        utilizationPercent: Double? = nil,
        coreCount: Int? = nil,
        memoryLimitBytes: Int64? = nil,
        isLowPower: Bool = false,
        registryID: UInt64? = nil
    ) {
        self.name = name
        self.vendor = vendor
        self.utilizationPercent = utilizationPercent
        self.coreCount = coreCount
        self.memoryLimitBytes = memoryLimitBytes
        self.isLowPower = isLowPower
        self.registryID = registryID
    }
}

// MARK: - Neural Engine

public struct NeuralEngineReading: Sendable, Equatable {
    public var isAppleSilicon: Bool
    /// Percent busy, when the platform exposes it. Often it does not.
    public var utilizationPercent: Double?
    /// True when the reading is genuinely measurable on this machine.
    public var isMeasurable: Bool

    public init(isAppleSilicon: Bool = false, utilizationPercent: Double? = nil, isMeasurable: Bool = false) {
        self.isAppleSilicon = isAppleSilicon
        self.utilizationPercent = utilizationPercent
        self.isMeasurable = isMeasurable
    }
}

// MARK: - Power

public struct PowerReading: Sendable, Equatable {
    public var hasBattery: Bool
    /// 0…1.
    public var level: Double?
    public var isCharging: Bool
    public var isPluggedIn: Bool
    public var isCharged: Bool
    public var timeToEmptySeconds: TimeInterval?
    public var timeToFullSeconds: TimeInterval?
    public var cycleCount: Int?
    /// Design capacity fraction, 0…1.
    public var healthFraction: Double?
    public var temperatureCelsius: Double?
    /// Watts: positive while discharging, negative while charging.
    public var wattage: Double?
    public var powerSource: String?
    /// Apps and services currently holding sleep-preventing assertions.
    public var assertions: [PowerAssertionReading]

    public init(
        hasBattery: Bool = false,
        level: Double? = nil,
        isCharging: Bool = false,
        isPluggedIn: Bool = false,
        isCharged: Bool = false,
        timeToEmptySeconds: TimeInterval? = nil,
        timeToFullSeconds: TimeInterval? = nil,
        cycleCount: Int? = nil,
        healthFraction: Double? = nil,
        temperatureCelsius: Double? = nil,
        wattage: Double? = nil,
        powerSource: String? = nil,
        assertions: [PowerAssertionReading] = []
    ) {
        self.hasBattery = hasBattery
        self.level = level
        self.isCharging = isCharging
        self.isPluggedIn = isPluggedIn
        self.isCharged = isCharged
        self.timeToEmptySeconds = timeToEmptySeconds
        self.timeToFullSeconds = timeToFullSeconds
        self.cycleCount = cycleCount
        self.healthFraction = healthFraction
        self.temperatureCelsius = temperatureCelsius
        self.wattage = wattage
        self.powerSource = powerSource
        self.assertions = assertions
    }
}

public struct PowerAssertionReading: Sendable, Equatable, Identifiable {
    public var id: String { "\(pid)-\(processName)-\(kind)" }
    public var pid: pid_t
    public var processName: String
    public var kind: String
    public var detail: String?
    public var heldSeconds: TimeInterval

    public init(
        pid: pid_t, processName: String, kind: String, detail: String? = nil, heldSeconds: TimeInterval = 0
    ) {
        self.pid = pid
        self.processName = processName
        self.kind = kind
        self.detail = detail
        self.heldSeconds = heldSeconds
    }
}

// MARK: - Sensors

public struct SensorReading: Sendable, Equatable, Identifiable {
    public var id: String { key }
    /// Four-character SMC key, e.g. "TC0P".
    public var key: String
    public var name: String
    public var celsius: Double

    public init(key: String, name: String, celsius: Double) {
        self.key = key
        self.name = name
        self.celsius = celsius
    }
}

public struct FanReading: Sendable, Equatable, Identifiable {
    public var id: Int
    public var name: String
    public var rpm: Double
    public var minimumRPM: Double
    public var maximumRPM: Double
    public var targetRPM: Double?
    /// False when the fan is under automatic control and can be overridden.
    public var isUserControllable: Bool

    public init(
        id: Int, name: String, rpm: Double, minimumRPM: Double, maximumRPM: Double,
        targetRPM: Double? = nil, isUserControllable: Bool = false
    ) {
        self.id = id
        self.name = name
        self.rpm = rpm
        self.minimumRPM = minimumRPM
        self.maximumRPM = maximumRPM
        self.targetRPM = targetRPM
        self.isUserControllable = isUserControllable
    }
}

// MARK: - Audio

public struct AudioReading: Sendable, Equatable {
    public var outputName: String?
    /// 0…1.
    public var outputVolume: Double?
    public var outputMuted: Bool?
    public var inputName: String?
    public var inputMuted: Bool?
    public var isMicrophoneActive: Bool
    public var apps: [AppVolumeReading]
    /// True when this Mac exposes per-app volume controls at all.
    public var supportsPerAppVolume: Bool

    public init(
        outputName: String? = nil,
        outputVolume: Double? = nil,
        outputMuted: Bool? = nil,
        inputName: String? = nil,
        inputMuted: Bool? = nil,
        isMicrophoneActive: Bool = false,
        apps: [AppVolumeReading] = [],
        supportsPerAppVolume: Bool = false
    ) {
        self.outputName = outputName
        self.outputVolume = outputVolume
        self.outputMuted = outputMuted
        self.inputName = inputName
        self.inputMuted = inputMuted
        self.isMicrophoneActive = isMicrophoneActive
        self.apps = apps
        self.supportsPerAppVolume = supportsPerAppVolume
    }
}

public struct AppVolumeReading: Sendable, Equatable, Identifiable {
    public var id: UInt32
    public var pid: pid_t?
    public var processName: String
    /// 0…1.
    public var volume: Double
    public var isMuted: Bool
    public var isRunning: Bool

    public init(
        id: UInt32, pid: pid_t? = nil, processName: String, volume: Double = 1, isMuted: Bool = false,
        isRunning: Bool = true
    ) {
        self.id = id
        self.pid = pid
        self.processName = processName
        self.volume = volume
        self.isMuted = isMuted
        self.isRunning = isRunning
    }
}

// MARK: - Bluetooth

public struct BluetoothDeviceReading: Sendable, Equatable, Identifiable {
    public var name: String
    public var kind: String?
    public var address: String?
    public var isConnected: Bool
    /// Battery of the device or of one of its ears; nil when unreported.
    public var batteryLevels: [String: Double]

    public var id: String { address ?? name }

    public init(
        name: String, kind: String? = nil, address: String? = nil, isConnected: Bool = false,
        batteryLevels: [String: Double] = [:]
    ) {
        self.name = name
        self.kind = kind
        self.address = address
        self.isConnected = isConnected
        self.batteryLevels = batteryLevels
    }
}
