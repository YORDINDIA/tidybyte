import Darwin
import Foundation
import IOKit
import os

/// Temperature and fan readings from the SMC via the AppleSMC IOKit user
/// client. Readings are best-effort: Macs differ in which keys they carry, so
/// anything that does not answer is simply absent from the results. Fan
/// control writes are separate, explicit, and restore the previous value.
public actor SMCSensors {
    private static let logger = Logger(subsystem: AppIdentity.bundleIdentifier, category: "SMCSensors")
    private var connection: io_connect_t = 0
    private var isOpen = false
    /// Fan minimums this session changed, so they can be restored on quit.
    private var overriddenFanMinimums: [Int: Double] = [:]

    public init() {}

    deinit {
        if isOpen {
            IOServiceClose(connection)
        }
    }

    // MARK: - Public readings

    public func temperatures() -> [SensorReading] {
        guard open() else { return [] }
        var readings: [SensorReading] = []
        for (key, name) in Self.temperatureKeys {
            if let value = readTemperature(key: key) {
                readings.append(SensorReading(key: key, name: name, celsius: value))
            }
        }
        return readings
    }

    public func fans() -> [FanReading] {
        guard open(), let count = readUInt(key: "FNum") else { return [] }
        var readings: [FanReading] = []
        for index in 0..<min(Int(count), 8) {
            if let reading = fan(index: index) { readings.append(reading) }
        }
        return readings
    }

    /// Explicitly sets a fan's minimum speed. The previous minimum is kept so
    /// `restoreFanControl` can put the machine back the way it was. No UI calls
    /// this yet; it stays paired with the restore path below.
    public func setFanMinimum(fanIndex: Int, minimumRPM: Double) -> Bool {
        guard open() else { return false }
        let key = Self.fanKey(index: fanIndex, suffix: "Mn")
        guard let current = readFloat(key: key) else { return false }
        guard writeFloat(key: key, value: minimumRPM) else {
            Self.logger.error("Fan \(fanIndex, privacy: .public) minimum write failed")
            return false
        }
        if overriddenFanMinimums[fanIndex] == nil { overriddenFanMinimums[fanIndex] = current }
        return true
    }

    /// Restores every fan minimum this session changed.
    public func restoreFanControl() {
        for (index, original) in overriddenFanMinimums {
            _ = writeFloat(key: Self.fanKey(index: index, suffix: "Mn"), value: original)
        }
        overriddenFanMinimums.removeAll()
    }

    // MARK: - Reads

    private func fan(index: Int) -> FanReading? {
        guard let rpm = readFloat(key: Self.fanKey(index: index, suffix: "Ac")) else { return nil }
        let minimum = readFloat(key: Self.fanKey(index: index, suffix: "Mn")) ?? 0
        let maximum = readFloat(key: Self.fanKey(index: index, suffix: "Mx")) ?? rpm
        let target = readFloat(key: Self.fanKey(index: index, suffix: "Tg"))
        let mode = readUInt(key: Self.fanKey(index: index, suffix: "Md")) ?? 1
        let name = readString(key: Self.fanKey(index: index, suffix: "ID")) ?? "Fan \(index + 1)"
        return FanReading(
            id: index, name: name, rpm: rpm, minimumRPM: minimum, maximumRPM: maximum,
            targetRPM: target, isUserControllable: mode == 0)
    }

    func readTemperature(key: String) -> Double? {
        guard let entry = read(key: key), entry.data.count >= Self.minimumBytes(for: entry.dataType) else { return nil }
        switch entry.dataType {
        case "f  ", "fl t": return Self.readFloatValue(entry.data)
        case "sp78": return Self.sp78Value(entry.data)
        case "ui8": return Double(entry.data[0]) == 0 ? nil : Double(entry.data[0])
        default: return Self.sp78Value(entry.data)
        }
    }

    func readFloat(key: String) -> Double? {
        guard let entry = read(key: key), entry.data.count >= Self.minimumBytes(for: entry.dataType) else { return nil }
        switch entry.dataType {
        case "fpe2", "fp2e", "fp88", "f  ": return Self.fixedPoint(entry.data, dataType: entry.dataType)
        case "ui8": return Double(entry.data[0])
        case "ui16": return Double(UInt16(entry.data[0]) << 8 | UInt16(entry.data[1]))
        case "sp78": return Self.sp78Value(entry.data)
        default: return Self.fixedPoint(entry.data, dataType: entry.dataType)
        }
    }

    /// Bytes each decodable SMC type needs. The reply buffer is as long as the
    /// key-info reply declared it — a virtual/odd SMC can declare more than it
    /// sends, and indexing past the buffer traps on every sampling tick.
    private static func minimumBytes(for dataType: String) -> Int {
        switch dataType {
        case "ui16": return 2
        case "f  ", "fl t": return 4
        default: return 1
        }
    }

    func readUInt(key: String) -> UInt8? {
        guard let entry = read(key: key), entry.dataType == "ui8" || entry.dataSize == 1,
            entry.data.count >= 1 else { return nil }
        return entry.data[0]
    }

    func readString(key: String) -> String? {
        guard let entry = read(key: key) else { return nil }
        let characters = entry.data.prefix(Int(entry.dataSize)).prefix { $0 != 0 }
        let text = String(bytes: characters, encoding: .utf8) ?? ""
        return text.isEmpty ? nil : text
    }

    // MARK: - User client

    struct SMCEntry {
        var key: String
        var dataSize: UInt8
        var dataType: String
        var data: [UInt8]
    }

    /// Opens the AppleSMC user client once; later calls reuse it.
    private func open() -> Bool {
        if isOpen { return true }
        var service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return false }
        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        IOObjectRelease(service)
        service = 0
        guard result == kIOReturnSuccess else { return false }
        isOpen = true
        return true
    }

    private func call(_ selector: UInt32, input: ParameterBuffer) -> ParameterBuffer {
        let output = ParameterBuffer()
        var outputSize = ParamLayout.size
        let result = IOConnectCallStructMethod(
            connection, selector, input.pointer, ParamLayout.size, output.pointer, &outputSize)
        if result != kIOReturnSuccess {
            Self.logger.error(
                "SMC user-client call \(selector, privacy: .public) failed: \(String(result, radix: 16), privacy: .public)")
        }
        return output
    }

    private func read(key: String) -> SMCEntry? {
        let info = ParameterBuffer()
        info.setKey(key)
        info.setData8(UInt8(ParamLayout.keyInfoSelector))
        let infoReply = call(ParamLayout.keyInfoSelector, input: info)
        guard infoReply.result() == 0 else { return nil }
        let size = infoReply.dataSizeByte()
        let dataType = infoReply.dataType()

        let request = ParameterBuffer()
        request.setKey(key)
        request.setDataSize(size)
        request.setDataType(dataType)
        request.setData8(UInt8(ParamLayout.readKeySelector))
        let reply = call(ParamLayout.readKeySelector, input: request)
        guard reply.result() == 0 else { return nil }
        return SMCEntry(key: key, dataSize: size, dataType: dataType, data: reply.dataBytes(Int(size)))
    }

    private func writeFloat(key: String, value: Double) -> Bool {
        let bytes = Self.encodeFixedPoint(value, byteCount: 2, fractionBits: 16)
        let request = ParameterBuffer()
        request.setKey(key)
        request.setDataSize(UInt8(bytes.count))
        request.setDataType("fpe2")
        // The selector byte first: it is the last field before the union, and
        // writing the value afterwards must not disturb it.
        request.setData8(UInt8(ParamLayout.writeKeySelector))
        request.setData(bytes)
        let reply = call(ParamLayout.writeKeySelector, input: request)
        return reply.result() == 0
    }

    // MARK: - Struct layout

    /// The SMCParamStruct the user client exchanges, as an exact 68-byte
    /// buffer. Offsets follow the canonical layout; a Swift struct with
    /// tuples does not keep a stable size, so the raw buffer does.
    enum ParamLayout {
        static let size = 68
        static let key = 0
        static let pLimit = 16
        static let dataSize = 20
        static let dataType = 24
        static let dataAttributes = 28
        static let result = 32
        static let status = 33
        static let data8 = 34
        static let data32 = 35
        static let data = 36
        static let readKeySelector: UInt32 = 4
        static let writeKeySelector: UInt32 = 5
        static let keyInfoSelector: UInt32 = 8
    }

    /// One allocated parameter block; freed with the instance.
    final class ParameterBuffer {
        let pointer: UnsafeMutableRawPointer

        init() {
            pointer = UnsafeMutableRawPointer.allocate(
                byteCount: ParamLayout.size, alignment: 4)
            pointer.initializeMemory(as: UInt8.self, repeating: 0, count: ParamLayout.size)
        }

        deinit {
            pointer.deallocate()
        }

        func setKey(_ key: String) {
            let characters = Array(key.utf8.prefix(4))
            for (index, character) in characters.enumerated() {
                pointer.storeBytes(of: character, toByteOffset: ParamLayout.key + index, as: UInt8.self)
            }
        }

        /// data8 is a one-byte field ahead of the data32/data union; storing
        /// anything wider would clobber the value bytes written next to it.
        func setData8(_ value: UInt8) {
            pointer.storeBytes(of: value, toByteOffset: ParamLayout.data8, as: UInt8.self)
        }

        func result() -> UInt8 {
            pointer.load(fromByteOffset: ParamLayout.result, as: UInt8.self)
        }

        func dataSizeByte() -> UInt8 {
            pointer.load(fromByteOffset: ParamLayout.dataSize, as: UInt8.self)
        }

        func dataType() -> String {
            let characters = (0..<4).map {
                pointer.load(fromByteOffset: ParamLayout.dataType + $0, as: UInt8.self)
            }
            return String(bytes: characters, encoding: .utf8) ?? ""
        }

        func dataBytes(_ count: Int) -> [UInt8] {
            (0..<min(count, 32)).map {
                pointer.load(fromByteOffset: ParamLayout.data + $0, as: UInt8.self)
            }
        }

        func setDataSize(_ size: UInt8) {
            pointer.storeBytes(of: size, toByteOffset: ParamLayout.dataSize, as: UInt8.self)
        }

        func setDataType(_ type: String) {
            let characters = Array(type.utf8.prefix(4))
            for (index, character) in characters.enumerated() {
                pointer.storeBytes(of: character, toByteOffset: ParamLayout.dataType + index, as: UInt8.self)
            }
        }

        func setData(_ bytes: [UInt8]) {
            for (index, byte) in bytes.prefix(32).enumerated() {
                pointer.storeBytes(of: byte, toByteOffset: ParamLayout.data + index, as: UInt8.self)
            }
        }
    }

    // MARK: - Value decoding (pure, testable)

    /// sp78: one signed byte of whole degrees plus 8 fractional bits.
    static func sp78Value(_ data: [UInt8]) -> Double? {
        guard data.count >= 2 else { return nil }
        let whole = Int16(bitPattern: UInt16(data[0]) << 8 | UInt16(data[1]))
        return Double(whole) / 256.0
    }

    static func readFloatValue(_ data: [UInt8]) -> Double? {
        guard data.count >= 4 else { return nil }
        let bits = UInt32(data[0]) << 24 | UInt32(data[1]) << 16 | UInt32(data[2]) << 8 | UInt32(data[3])
        return Double(Float(bitPattern: bits))
    }

    /// fpe2 and friends: big-endian fixed point with the low bits fractional.
    static func fixedPoint(_ data: [UInt8], dataType: String) -> Double? {
        let fractionBits: Int
        switch dataType {
        case "fpe2", "fp2e": fractionBits = 16
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

    /// The temperature keys worth showing, with friendly names. A Mac answers
    /// only the keys it physically has.
    static let temperatureKeys: [(key: String, name: String)] = [
        ("TC0P", "CPU proximity"),
        ("TC0C", "CPU core"),
        ("TC0D", "CPU diode"),
        ("TC0E", "CPU"),
        ("TC0F", "CPU Fin Stack"),
        ("TC0H", "CPU heatsink"),
        ("TCAD", "CPU PECI"),
        ("TCAG", "CPU GC"),
        ("TCBH", "CPU 2 heatsink"),
        ("TCXC", "CPU PECI core"),
        ("TG0D", "GPU diode"),
        ("TG0H", "GPU heatsink"),
        ("TG0P", "GPU proximity"),
        ("TGDD", "GPU"),
        ("TPCD", "Platform controller hub"),
        ("TP01", "Heat pipe 1"),
        ("TP02", "Heat pipe 2"),
        ("Th0H", "Heatsink system"),
        ("Th1H", "Heatsink 1"),
        ("Th2H", "Heatsink 2"),
        ("Ts0P", "Palm rest"),
        ("Ts0S", "Storage"),
        ("TA0P", "Ambient"),
        ("TA1P", "Ambient 2"),
        ("TM0P", "Memory proximity"),
        ("TM0S", "Memory module"),
        ("TB1T", "Battery 1"),
        ("TB2T", "Battery 2"),
        ("TW0P", "Wireless"),
        ("VLDF", "Power supply"),
        ("VP0R", "Power rail 12V")
    ]
}
