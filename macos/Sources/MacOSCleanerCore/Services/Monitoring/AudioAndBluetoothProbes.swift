import CoreAudio
import Foundation

/// Output/input device state plus per-app audio activity, through the public
/// process-object audio APIs (macOS 14.2+). macOS does not let one app set
/// another app's volume, so this reports who is audible on which direction
/// and controls the default devices.
public enum AudioProbe {
    public static func reading() -> AudioReading {
        var reading = AudioReading()
        reading.outputName = defaultDeviceName(.output)
        reading.inputName = defaultDeviceName(.input)
        if let device = defaultDevice(.output) {
            reading.outputVolume = deviceVolume(device: device, scope: kAudioObjectPropertyScopeOutput)
            reading.outputMuted = deviceMuted(device: device, scope: kAudioObjectPropertyScopeOutput)
        }
        if let device = defaultDevice(.input) {
            reading.inputMuted = deviceMuted(device: device, scope: kAudioObjectPropertyScopeInput)
        }
        reading.isMicrophoneActive = isInputRunning()
        reading.apps = audibleProcesses()
        reading.supportsPerAppVolume = false
        return reading
    }

    // MARK: - Per-app activity

    static func audibleProcesses() -> [AppVolumeReading] {
        guard let ids = processObjectIDs() else { return [] }
        return ids.compactMap { processActivity(object: $0) }
    }

    static func processObjectIDs() -> [AudioObjectID]? {
        var property = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(kAudioHardwarePropertyProcessObjectList),
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectHasProperty(systemObject, &property) else { return nil }
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &property, 0, nil, &size) == noErr, size > 0 else {
            return nil
        }
        let stride = MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / stride)
        var actualSize = size
        guard AudioObjectGetPropertyData(systemObject, &property, 0, nil, &actualSize, &ids) == noErr else { return nil }
        let count = min(ids.count, Int(actualSize) / stride)
        return Array(ids.prefix(count))
    }

    static func processActivity(object: AudioObjectID) -> AppVolumeReading? {
        var pid: pid_t = 0
        guard uintProperty(object: object, selector: AudioObjectPropertySelector(kAudioProcessPropertyPID), into: &pid),
              pid != 0 else { return nil }
        var isRunning: UInt32 = 0
        _ = uintProperty(object: object, selector: AudioObjectPropertySelector(kAudioProcessPropertyIsRunning), into: &isRunning)
        var runsInput: UInt32 = 0
        _ = uintProperty(object: object, selector: AudioObjectPropertySelector(kAudioProcessPropertyIsRunningInput), into: &runsInput)
        var runsOutput: UInt32 = 0
        _ = uintProperty(object: object, selector: AudioObjectPropertySelector(kAudioProcessPropertyIsRunningOutput), into: &runsOutput)
        var audible: UInt32 = 0
        _ = uintProperty(object: object, selector: AudioObjectPropertySelector(kAudioHardwarePropertyProcessIsAudible), into: &audible)
        guard isRunning != 0 || runsInput != 0 || runsOutput != 0 else { return nil }
        let name = ProcessProbe.executablePath(of: pid)
            .map { URL(fileURLWithPath: $0).lastPathComponent } ?? "pid \(pid)"
        return AppVolumeReading(
            id: object,
            pid: pid,
            processName: name,
            volume: audible != 0 ? 1 : 0,
            isMuted: audible == 0,
            isRunning: isRunning != 0)
    }

    static func uintProperty<T: FixedWidthInteger>(
        object: AudioObjectID, selector: AudioObjectPropertySelector, into value: inout T
    ) -> Bool {
        var property = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(object, &property, 0, nil, &size, pointer) == noErr
        }
    }

    // MARK: - Device level

    static func scalarProperty(object: AudioObjectID, property: AudioObjectPropertyAddress) -> Double? {
        var address = property
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr else { return nil }
        let count = Int(size) / MemoryLayout<Float32>.size
        guard count > 0 else { return nil }
        var values = [Float32](repeating: 0, count: count)
        var readSize = UInt32(count * MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &readSize, &values) == noErr else { return nil }
        let valid = values.prefix(min(count, Int(readSize) / MemoryLayout<Float32>.size)).filter { $0.isFinite && $0 >= 0 }
        guard !valid.isEmpty else { return nil }
        return Double(valid.reduce(0, +) / Float32(valid.count))
    }

    enum DeviceType { case output, input }

    static func defaultDevice(_ type: DeviceType) -> AudioObjectID? {
        var property = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(
                type == .output ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice),
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &device) == noErr,
              device != 0 else { return nil }
        return device
    }

    static func deviceName(device: AudioObjectID) -> String? {
        var property = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var unmanagedName: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &unmanagedName) { pointer in
            AudioObjectGetPropertyData(device, &property, 0, nil, &size, pointer)
        }
        guard status == noErr, let name = unmanagedName?.takeRetainedValue() else { return nil }
        return name as String
    }

    static func defaultDeviceName(_ type: DeviceType) -> String? {
        guard let device = defaultDevice(type) else { return nil }
        return deviceName(device: device)
    }

    /// Sets the default output device volume (0…1), falling back to channels 1/2
    /// when the device exposes per-channel controls instead of master element 0.
    public static func setOutputVolume(_ volume: Double) -> Bool {
        guard let device = defaultDevice(.output) else { return false }
        var scalar = Float32(min(1, max(0, volume)))
        let size = UInt32(MemoryLayout<Float32>.size)
        let mainAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        if setScalarProperty(device: device, address: mainAddress, value: &scalar, size: size) {
            return true
        }
        var updated = false
        for channel: AudioObjectPropertyElement in [1, 2] {
            var channelScalar = scalar
            let channelAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: channel)
            if setScalarProperty(device: device, address: channelAddress, value: &channelScalar, size: size) {
                updated = true
            }
        }
        return updated
    }

    public static func setOutputMuted(_ muted: Bool) -> Bool {
        guard let device = defaultDevice(.output) else { return false }
        var value: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        let mainAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        if setScalarProperty(device: device, address: mainAddress, value: &value, size: size) {
            return true
        }
        var updated = false
        for channel: AudioObjectPropertyElement in [1, 2] {
            var channelValue = value
            let channelAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: channel)
            if setScalarProperty(device: device, address: channelAddress, value: &channelValue, size: size) {
                updated = true
            }
        }
        return updated
    }

    private static func setScalarProperty<T>(
        device: AudioObjectID,
        address: AudioObjectPropertyAddress,
        value: inout T,
        size: UInt32
    ) -> Bool {
        var property = address
        guard AudioObjectHasProperty(device, &property) else { return false }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &property, &settable) == noErr, settable.boolValue else {
            return false
        }
        return withUnsafePointer(to: &value) { pointer in
            AudioObjectSetPropertyData(device, &property, 0, nil, size, pointer) == noErr
        }
    }

    static func deviceVolume(device: AudioObjectID, scope: AudioObjectPropertyScope) -> Double? {
        if let mainChannel = scalarProperty(
            object: device,
            property: AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar, mScope: scope,
                mElement: kAudioObjectPropertyElementMain)) {
            return mainChannel
        }
        let channels = [AudioObjectPropertyElement(1), AudioObjectPropertyElement(2)].compactMap {
            scalarProperty(
                object: device,
                property: AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyVolumeScalar, mScope: scope, mElement: $0))
        }
        guard !channels.isEmpty else { return nil }
        return channels.reduce(0, +) / Double(channels.count)
    }

    static func deviceMuted(device: AudioObjectID, scope: AudioObjectPropertyScope) -> Bool? {
        for element in [kAudioObjectPropertyElementMain, AudioObjectPropertyElement(1), AudioObjectPropertyElement(2)] {
            var property = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute, mScope: scope, mElement: element)
            guard AudioObjectHasProperty(device, &property) else { continue }
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(device, &property, 0, nil, &size, &value) == noErr {
                return value != 0
            }
        }
        return nil
    }

    static func isInputRunning() -> Bool {
        guard let device = defaultDevice(.input) else { return false }
        var property = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }
}

/// Paired Bluetooth accessories and their battery levels, from
/// system_profiler's JSON report.
public enum BluetoothProbe {
    public static func devices() async -> [BluetoothDeviceReading] {
        guard let output = try? await SystemTool.run(
            "/usr/sbin/system_profiler", arguments: ["SPBluetoothDataType", "-json"]) else { return [] }
        return Self.parse(output)
    }

    public static func parse(_ json: String) -> [BluetoothDeviceReading] {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["SPBluetoothDataType"] as? [[String: Any]] else { return [] }
        var readings: [BluetoothDeviceReading] = []
        var seenIDs = Set<String>()
        for entry in entries {
            for (section, isConnected) in [("device_connected", true), ("device_not_connected", false)] {
                guard let devices = entry[section] as? [[String: Any]] else { continue }
                for device in devices {
                    guard let name = device["device_title"] as? String else { continue }
                    let reading = BluetoothDeviceReading(
                        name: name,
                        kind: (device["device_minorType"] as? String)
                            ?? (device["device_majorType"] as? String),
                        address: device["device_address"] as? String,
                        isConnected: isConnected,
                        batteryLevels: batteryLevels(from: device))
                    guard seenIDs.insert(reading.id).inserted else { continue }
                    readings.append(reading)
                }
            }
        }
        return readings
    }

    static func batteryLevels(from device: [String: Any]) -> [String: Double] {
        var levels: [String: Double] = [:]
        func addBattery(_ label: String, _ key: String) {
            if let text = device[key] as? String, let parsed = parsePercent(text) {
                levels[label] = parsed
            }
        }
        addBattery("Device", "device_batteryLevelMain")
        addBattery("Left", "device_batteryLevelLeft")
        addBattery("Right", "device_batteryLevelRight")
        addBattery("Case", "device_batteryLevelCase")
        addBattery("Combined", "device_batteryLevelCombined")
        return levels
    }

    static func parsePercent(_ text: String) -> Double? {
        let numeric = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { $0.isNumber || $0 == "." }
        guard !numeric.isEmpty, let value = Double(numeric), value.isFinite else { return nil }
        return min(1, max(0, value / 100))
    }
}
