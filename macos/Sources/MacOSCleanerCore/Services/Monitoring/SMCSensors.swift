import Darwin
import Foundation
import IOKit
import os

/// Temperature and fan readings from the SMC via the AppleSMC IOKit user
/// client. Readings are best-effort: Macs differ in which keys they carry, so
/// anything that does not answer is simply absent from the results. Fan
/// control writes remain safely disabled.
public actor SMCSensors {
    private static let logger = Logger(subsystem: AppIdentity.bundleIdentifier, category: "SMCSensors")
    private var connection: io_connect_t = 0
    private var isOpen = false
    private var availableKeys: Set<String> = []
    private var keyInfoCache: [String: KeyInfo] = [:]
    private var missingKeys: Set<String> = []
    private var activeTemperatureKeys: [String]?
    private var overriddenFanMinimums: [Int: Double] = [:]

    struct KeyInfo {
        var dataSize: UInt32
        var dataType: String
    }

    public init() {}

    deinit {
        if isOpen {
            IOServiceClose(connection)
        }
    }

    // MARK: - Public readings

    public func temperatures() -> [SensorReading] {
        guard open() else { return [] }
        let knownNames = Dictionary(Self.temperatureKeys, uniquingKeysWith: { first, _ in first })
        let keys = activeTemperatureKeys ?? Self.temperatureKeys.map(\.key)
        var readings: [SensorReading] = []
        for key in keys where !missingKeys.contains(key) {
            guard let value = readTemperature(key: key), value.isFinite, (10.0...125.0).contains(value) else {
                continue
            }
            let name = knownNames[key] ?? Self.friendlyTemperatureName(for: key)
            readings.append(SensorReading(key: key, name: name, celsius: value))
        }
        return readings
    }

    public func fans() -> [FanReading] {
        guard open() else { return [] }
        if !availableKeys.isEmpty, !availableKeys.contains("FNum") {
            return []
        }
        guard let count = readUInt(key: "FNum") else { return [] }
        var readings: [FanReading] = []
        for index in 0..<min(Int(count), 8) {
            if let reading = fan(index: index) { readings.append(reading) }
        }
        return readings
    }

    /// Fan writes are safely disabled while macOS gates direct SMC fan control.
    public func setFanMinimum(fanIndex: Int, minimumRPM: Double) -> Bool {
        false
    }

    /// Clears tracked fan overrides (no-op while fan writes are disabled).
    public func restoreFanControl() {
        overriddenFanMinimums.removeAll()
    }

    // MARK: - Reads

    private func fan(index: Int) -> FanReading? {
        guard let rpm = readFloat(key: Self.fanKey(index: index, suffix: "Ac")) else { return nil }
        let minimum = readFloat(key: Self.fanKey(index: index, suffix: "Mn")) ?? 0
        let maximum = readFloat(key: Self.fanKey(index: index, suffix: "Mx")) ?? rpm
        let targetKey = Self.fanKey(index: index, suffix: "Tg")
        let target = hasKey(targetKey) ? readFloat(key: targetKey) : nil
        let idKey = Self.fanKey(index: index, suffix: "ID")
        let name = hasKey(idKey) ? (readString(key: idKey) ?? "Fan \(index + 1)") : "Fan \(index + 1)"
        return FanReading(
            id: index, name: name, rpm: rpm, minimumRPM: minimum, maximumRPM: maximum,
            targetRPM: target, isUserControllable: false)
    }

    func readTemperature(key: String) -> Double? {
        guard let entry = read(key: key), entry.data.count >= Self.minimumBytes(for: entry.dataType) else { return nil }
        switch entry.dataType {
        case "flt ", "f   ", "fl t": return Self.readFloatValue(entry.data)
        case "sp78": return Self.sp78Value(entry.data)
        case "sp87": return Self.sp87Value(entry.data)
        case "fpe2", "fp2e", "fp88": return Self.fixedPoint(entry.data, dataType: entry.dataType)
        case "ui8 ", "ui8": return entry.data[0] == 0 ? nil : Double(entry.data[0])
        case "ui16": return Double(UInt16(entry.data[0]) << 8 | UInt16(entry.data[1]))
        default: return Self.sp78Value(entry.data)
        }
    }

    func readFloat(key: String) -> Double? {
        guard let entry = read(key: key), entry.data.count >= Self.minimumBytes(for: entry.dataType) else { return nil }
        switch entry.dataType {
        case "flt ", "f   ", "fl t": return Self.readFloatValue(entry.data)
        case "fpe2", "fp2e", "fp88": return Self.fixedPoint(entry.data, dataType: entry.dataType)
        case "sp78": return Self.sp78Value(entry.data)
        case "sp87": return Self.sp87Value(entry.data)
        case "ui8 ", "ui8": return Double(entry.data[0])
        case "ui16": return Double(UInt16(entry.data[0]) << 8 | UInt16(entry.data[1]))
        case "ui32": return Self.readBigEndianUInt32(entry.data).map(Double.init)
        default: return Self.fixedPoint(entry.data, dataType: entry.dataType)
        }
    }

    private static func minimumBytes(for dataType: String) -> Int {
        switch dataType {
        case "ui16", "sp78", "sp87", "fpe2", "fp2e", "fp88": return 2
        case "ui32", "flt ", "f   ", "fl t": return 4
        default: return 1
        }
    }

    func readUInt(key: String) -> UInt8? {
        guard let entry = read(key: key), entry.dataType == "ui8 " || entry.dataType == "ui8" || entry.dataSize == 1,
              !entry.data.isEmpty else { return nil }
        return entry.data[0]
    }

    func readString(key: String) -> String? {
        guard let entry = read(key: key) else { return nil }
        let characters = entry.data.prefix(Int(entry.dataSize)).prefix { $0 != 0 }
        let text = String(bytes: characters, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    // MARK: - User client & key discovery

    struct SMCEntry {
        var key: String
        var dataSize: UInt32
        var dataType: String
        var data: [UInt8]
    }

    private func open() -> Bool {
        if isOpen { return true }
        var service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        if service == 0 {
            service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMCKeysEndpoint"))
        }
        guard service != 0 else { return false }
        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        IOObjectRelease(service)
        guard result == kIOReturnSuccess else { return false }
        isOpen = true
        discoverKeys()
        return true
    }

    private func hasKey(_ key: String) -> Bool {
        availableKeys.isEmpty ? !missingKeys.contains(key) : availableKeys.contains(key)
    }

    private func discoverKeys() {
        if let keyCountEntry = read(key: "#KEY", bypassPresenceCheck: true),
           let rawCount = Self.readBigEndianUInt32(keyCountEntry.data) {
            let total = min(Int(rawCount), 4096)
            for index in 0..<total {
                let request = ParameterBuffer()
                request.setData8(ParamLayout.keyFromIndexCommand)
                request.setData32(UInt32(index))
                guard let reply = call(input: request), reply.result() == 0 else { continue }
                let key = reply.key()
                if key.count == 4 { availableKeys.insert(key) }
            }
        }
        buildActiveTemperatureKeys()
    }

    private func buildActiveTemperatureKeys() {
        var resolved: [String] = []
        var knownSet = Set<String>()
        for entry in Self.temperatureKeys where availableKeys.isEmpty || availableKeys.contains(entry.key) {
            if knownSet.insert(entry.key).inserted { resolved.append(entry.key) }
        }
        let extraKeys = availableKeys.filter { $0.hasPrefix("T") && !knownSet.contains($0) }.sorted()
        for key in extraKeys {
            guard let value = readTemperature(key: key), value.isFinite, (10.0...125.0).contains(value) else {
                continue
            }
            resolved.append(key)
        }
        activeTemperatureKeys = resolved
    }

    private func call(input: ParameterBuffer) -> ParameterBuffer? {
        let output = ParameterBuffer()
        var outputSize = ParamLayout.size
        let result = IOConnectCallStructMethod(
            connection, ParamLayout.kernelSelector, input.pointer, ParamLayout.size, output.pointer, &outputSize)
        guard result == kIOReturnSuccess else {
            if result != kIOReturnNotFound {
                Self.logger.debug("SMC call failed: \(String(result, radix: 16), privacy: .public)")
            }
            return nil
        }
        return output
    }

    private func keyInfo(for key: String) -> KeyInfo? {
        if let cached = keyInfoCache[key] { return cached }
        let info = ParameterBuffer()
        info.setKey(key)
        info.setData8(ParamLayout.keyInfoCommand)
        guard let infoReply = call(input: info), infoReply.result() == 0 else {
            missingKeys.insert(key)
            return nil
        }
        let resolved = KeyInfo(dataSize: infoReply.dataSize(), dataType: infoReply.dataType())
        keyInfoCache[key] = resolved
        return resolved
    }

    private func read(key: String, bypassPresenceCheck: Bool = false) -> SMCEntry? {
        if !bypassPresenceCheck && !hasKey(key) { return nil }
        guard let info = keyInfo(for: key), info.dataSize > 0, info.dataSize <= 32 else { return nil }
        let request = ParameterBuffer()
        request.setKey(key)
        request.setDataSize(info.dataSize)
        request.setDataType(info.dataType)
        request.setData8(ParamLayout.readKeyCommand)
        guard let reply = call(input: request), reply.result() == 0 else {
            if availableKeys.isEmpty { missingKeys.insert(key) }
            return nil
        }
        return SMCEntry(
            key: key, dataSize: info.dataSize, dataType: info.dataType,
            data: reply.dataBytes(Int(info.dataSize)))
    }
}

// MARK: - Struct layout, parameter buffer & decoding

extension SMCSensors {
    /// Canonical 80-byte AppleSMC `SMCKeyData_t` layout:
    /// key@0 (4B), vers@4 (6B+2B pad), pLimitData@12 (16B), keyInfo@28 (12B),
    /// result@40 (1B), status@41 (1B), data8@42 (1B+1B pad), data32@44 (4B),
    /// bytes@48 (32B).
    enum ParamLayout {
        static let size = 80
        static let key = 0
        static let vers = 4
        static let pLimit = 12
        static let dataSize = 28
        static let dataType = 32
        static let dataAttributes = 36
        static let result = 40
        static let status = 41
        static let data8 = 42
        static let data32 = 44
        static let data = 48

        static let kernelSelector: UInt32 = 2
        static let readKeyCommand: UInt8 = 5
        static let writeKeyCommand: UInt8 = 6
        static let keyFromIndexCommand: UInt8 = 8
        static let keyInfoCommand: UInt8 = 9
    }

    /// One allocated 80-byte parameter block; freed with the instance.
    final class ParameterBuffer {
        let pointer: UnsafeMutableRawPointer

        init() {
            pointer = UnsafeMutableRawPointer.allocate(byteCount: ParamLayout.size, alignment: 8)
            pointer.initializeMemory(as: UInt8.self, repeating: 0, count: ParamLayout.size)
        }

        deinit {
            pointer.deallocate()
        }

        func setKey(_ key: String) {
            pointer.storeBytes(of: Self.encodeFourCC(key), toByteOffset: ParamLayout.key, as: UInt32.self)
        }

        func key() -> String {
            Self.decodeFourCC(pointer.load(fromByteOffset: ParamLayout.key, as: UInt32.self))
        }

        /// data8 is a one-byte field ahead of data32/bytes; storing anything
        /// wider would clobber adjacent fields.
        func setData8(_ value: UInt8) {
            pointer.storeBytes(of: value, toByteOffset: ParamLayout.data8, as: UInt8.self)
        }

        func setData32(_ value: UInt32) {
            pointer.storeBytes(of: value, toByteOffset: ParamLayout.data32, as: UInt32.self)
        }

        func result() -> UInt8 {
            pointer.load(fromByteOffset: ParamLayout.result, as: UInt8.self)
        }

        func dataSize() -> UInt32 {
            pointer.load(fromByteOffset: ParamLayout.dataSize, as: UInt32.self)
        }

        func dataSizeByte() -> UInt8 {
            UInt8(truncatingIfNeeded: dataSize())
        }

        func setDataSize(_ size: UInt32) {
            pointer.storeBytes(of: size, toByteOffset: ParamLayout.dataSize, as: UInt32.self)
        }

        func setDataSize(_ size: UInt8) {
            setDataSize(UInt32(size))
        }

        func dataType() -> String {
            Self.decodeFourCC(pointer.load(fromByteOffset: ParamLayout.dataType, as: UInt32.self))
        }

        func setDataType(_ type: String) {
            pointer.storeBytes(of: Self.encodeFourCC(type), toByteOffset: ParamLayout.dataType, as: UInt32.self)
        }

        func dataBytes(_ count: Int) -> [UInt8] {
            (0..<min(max(0, count), 32)).map {
                pointer.load(fromByteOffset: ParamLayout.data + $0, as: UInt8.self)
            }
        }

        func setData(_ bytes: [UInt8]) {
            for (index, byte) in bytes.prefix(32).enumerated() {
                pointer.storeBytes(of: byte, toByteOffset: ParamLayout.data + index, as: UInt8.self)
            }
        }

        /// Encodes a 4-char SMC key/type into host-endian `UInt32` FourCC
        /// (`[b3, b2, b1, b0]` in little-endian memory).
        private static func encodeFourCC(_ string: String) -> UInt32 {
            var bytes = Array(string.utf8.prefix(4))
            while bytes.count < 4 { bytes.append(0x20) }
            return (UInt32(bytes[0]) << 24)
                | (UInt32(bytes[1]) << 16)
                | (UInt32(bytes[2]) << 8)
                | UInt32(bytes[3])
        }

        private static func decodeFourCC(_ raw: UInt32) -> String {
            let bytes = [
                UInt8((raw >> 24) & 0xFF),
                UInt8((raw >> 16) & 0xFF),
                UInt8((raw >> 8) & 0xFF),
                UInt8(raw & 0xFF)
            ]
            return String(bytes: bytes, encoding: .utf8) ?? ""
        }
    }

    // MARK: - Value decoding (pure, testable)

    /// sp78: signed 7.8 fixed point (big-endian Int16 / 256).
    static func sp78Value(_ data: [UInt8]) -> Double? {
        guard data.count >= 2 else { return nil }
        let whole = Int16(bitPattern: UInt16(data[0]) << 8 | UInt16(data[1]))
        return Double(whole) / 256.0
    }

    /// sp87: signed 8.7 fixed point (big-endian Int16 / 128).
    static func sp87Value(_ data: [UInt8]) -> Double? {
        guard data.count >= 2 else { return nil }
        let whole = Int16(bitPattern: UInt16(data[0]) << 8 | UInt16(data[1]))
        return Double(whole) / 128.0
    }

    /// `"flt "`: little-endian IEEE 754 single-precision Float.
    static func readFloatValue(_ data: [UInt8]) -> Double? {
        guard data.count >= 4 else { return nil }
        let bits = UInt32(data[0])
            | (UInt32(data[1]) << 8)
            | (UInt32(data[2]) << 16)
            | (UInt32(data[3]) << 24)
        let value = Double(Float(bitPattern: bits))
        return value.isFinite ? value : nil
    }

    static func readBigEndianUInt32(_ data: [UInt8]) -> UInt32? {
        guard data.count >= 4 else { return nil }
        return (UInt32(data[0]) << 24)
            | (UInt32(data[1]) << 16)
            | (UInt32(data[2]) << 8)
            | UInt32(data[3])
    }

    /// Big-endian unsigned fixed point (`fpe2` = 2 frac bits, `fp2e` = 14, `fp88` = 8).
    static func fixedPoint(_ data: [UInt8], dataType: String) -> Double? {
        guard !data.isEmpty else { return nil }
        let fractionBits: Int
        switch dataType {
        case "fpe2": fractionBits = 2
        case "fp2e": fractionBits = 14
        case "fp88": fractionBits = 8
        default: fractionBits = 0
        }
        var raw: UInt64 = 0
        for byte in data.prefix(4) { raw = raw << 8 | UInt64(byte) }
        return Double(raw) / Double(1 << fractionBits)
    }

    static func encodeFixedPoint(_ value: Double, byteCount: Int, fractionBits: Int) -> [UInt8] {
        var raw = UInt64(max(0, (value * Double(1 << fractionBits)).rounded()))
        var bytes = [UInt8](repeating: 0, count: byteCount)
        for index in stride(from: byteCount - 1, through: 0, by: -1) {
            bytes[index] = UInt8(raw & 0xFF)
            raw >>= 8
        }
        return bytes
    }

    static func fanKey(index: Int, suffix: String) -> String {
        "F\(index)\(suffix)"
    }

    static func friendlyTemperatureName(for key: String) -> String {
        switch String(key.prefix(2)) {
        case "Tp", "TC": return L10n.format("CPU / SoC (%@)", key)
        case "Tg", "TG": return L10n.format("GPU (%@)", key)
        case "Te": return L10n.format("Efficiency Cluster (%@)", key)
        case "Tf": return L10n.format("Neural / Fabric (%@)", key)
        case "TB": return L10n.format("Battery (%@)", key)
        case "TH": return L10n.format("Storage (%@)", key)
        case "Ts": return L10n.format("Enclosure (%@)", key)
        case "Ta", "TA": return L10n.format("Ambient (%@)", key)
        case "Tm", "TM": return L10n.format("Memory (%@)", key)
        default: return L10n.format("Sensor %@", key)
        }
    }

    static var temperatureKeys: [(key: String, name: String)] {
        [
            // Apple Silicon SoC / PMU / GPU / enclosure keys
            ("Tp01", L10n.string("CPU / SoC 1")), ("Tp05", L10n.string("CPU / SoC 2")),
            ("Tp09", L10n.string("CPU / SoC 3")), ("Tp0D", L10n.string("CPU / SoC 4")),
            ("Tp0H", L10n.string("CPU / SoC 5")), ("Tp0L", L10n.string("CPU / SoC 6")),
            ("Tp0P", L10n.string("CPU / SoC 7")), ("Tp0T", L10n.string("CPU / SoC 8")),
            ("Tp0X", L10n.string("CPU / SoC 9")), ("Tp0b", L10n.string("CPU / SoC 10")),
            ("Tp0f", L10n.string("CPU / SoC 11")), ("Tp0j", L10n.string("CPU / SoC 12")),
            ("Tg0f", L10n.string("GPU 1")), ("Tg0j", L10n.string("GPU 2")), ("Tg0n", L10n.string("GPU 3")),
            ("Tg0D", L10n.string("GPU diode")), ("Tg0P", L10n.string("GPU proximity")),
            ("Te05", L10n.string("Efficiency core 1")), ("Te0L", L10n.string("Efficiency core 2")),
            ("Te0P", L10n.string("Efficiency core 3")), ("Te0S", L10n.string("Efficiency core 4")),
            ("Tf04", L10n.string("ANE / Fabric 1")), ("Tf09", L10n.string("ANE / Fabric 2")),
            ("Tf0A", L10n.string("ANE / Fabric 3")), ("Tf0B", L10n.string("ANE / Fabric 4")),
            ("Tf0C", L10n.string("ANE / Fabric 5")),
            ("TB0T", L10n.string("Battery")), ("TB1T", L10n.string("Battery 1")), ("TB2T", L10n.string("Battery 2")),
            ("Ts0P", L10n.string("Palm rest")), ("Ts1P", L10n.string("Palm rest 2")), ("Ts0S", L10n.string("Storage")),
            ("TH0A", L10n.string("NAND 1")), ("TH0B", L10n.string("NAND 2")), ("TW0P", L10n.string("Wireless")),
            ("TaLP", L10n.string("Airflow left")), ("TaRF", L10n.string("Airflow right")),
            ("Tm0P", L10n.string("Memory proximity")),
            // Intel SMC keys
            ("TC0P", L10n.string("CPU proximity")), ("TC0C", L10n.string("CPU core")),
            ("TC0D", L10n.string("CPU diode")), ("TC0E", L10n.string("CPU")),
            ("TC0F", L10n.string("CPU Fin Stack")), ("TC0H", L10n.string("CPU heatsink")),
            ("TCAD", L10n.string("CPU PECI")), ("TCAG", L10n.string("CPU GC")),
            ("TCBH", L10n.string("CPU 2 heatsink")), ("TCXC", L10n.string("CPU PECI core")),
            ("TG0D", L10n.string("GPU diode")), ("TG0H", L10n.string("GPU heatsink")),
            ("TG0P", L10n.string("GPU proximity")), ("TGDD", L10n.string("GPU")),
            ("TPCD", L10n.string("Platform controller hub")), ("TP01", L10n.string("Heat pipe 1")),
            ("TP02", L10n.string("Heat pipe 2")), ("Th0H", L10n.string("Heatsink system")),
            ("Th1H", L10n.string("Heatsink 1")), ("Th2H", L10n.string("Heatsink 2")),
            ("TA0P", L10n.string("Ambient")), ("TA1P", L10n.string("Ambient 2")),
            ("TM0P", L10n.string("Memory proximity")), ("TM0S", L10n.string("Memory module"))
        ]
    }
}
