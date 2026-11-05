import CoreAudio
import Foundation

/// Output/input device state plus per-app audio activity, through the public
/// process-object audio APIs (macOS 14.2+). macOS does not let one app set
/// another app's volume, so this reports who is audible on which direction
/// and controls the default devices; the mixer UI labels it accordingly and
/// never pretends a control exists that the system does not expose.
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
        // Public macOS APIs expose activity, not other apps' volume knobs.
        reading.supportsPerAppVolume = false
        return reading
    }

    // MARK: - Per-app activity

    /// Every process the HAL currently knows is playing or recording, with
    /// the direction it is active in.
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
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(systemObject, &property, 0, nil, &size, &ids) == noErr else { return nil }
        return ids
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

    static func uintProperty<T>(object: AudioObjectID, selector: AudioObjectPropertySelector, into value: inout T)
        -> Bool {
        var property = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value) == noErr
    }

    // MARK: - Device level

    static func scalarProperty(object: AudioObjectID, property: AudioObjectPropertyAddress) -> Double? {
        var address = property
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr else { return nil }
        // Volume may arrive as one scalar or a list per channel; average them.
        let count = Int(size) / MemoryLayout<Float32>.size
        guard count > 0 else { return nil }
        var values = [Float32](repeating: 0, count: count)
        var readSize = UInt32(count * MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &readSize, &values) == noErr else { return nil }
        let valid = values.filter { $0.isFinite && $0 >= 0 }
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
        var name: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, &name) == noErr,
            let resolved = name as String? else { return nil }
        return resolved
    }

    static func defaultDeviceName(_ type: DeviceType) -> String? {
        guard let device = defaultDevice(type) else { return nil }
        return deviceName(device: device)
    }

    /// Sets the default output device volume (0…1). The one volume knob macOS
    /// gives every app.
    public static func setOutputVolume(_ volume: Double) -> Bool {
        guard let device = defaultDevice(.output) else { return false }
        var property = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var scalar = Float32(min(1, max(0, volume)))
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectSetPropertyData(device, &property, 0, nil, size, &scalar) == noErr
    }

    public static func setOutputMuted(_ muted: Bool) -> Bool {
        guard let device = defaultDevice(.output) else { return false }
        var property = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = muted ? 1 : 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectSetPropertyData(device, &property, 0, nil, size, &value) == noErr
    }

    static func deviceVolume(device: AudioObjectID, scope: AudioObjectPropertyScope) -> Double? {
        scalarProperty(
            object: device,
            property: AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar, mScope: scope,
                mElement: kAudioObjectPropertyElementMain))
    }

    static func deviceMuted(device: AudioObjectID, scope: AudioObjectPropertyScope) -> Bool? {
        var property = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute, mScope: scope,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device, &property) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    /// True while any process holds the input device running — the "mic live"
    /// badge.
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
/// system_profiler's JSON report (an Apple tool, no private framework).
public enum BluetoothProbe {
    public static func devices() async -> [BluetoothDeviceReading] {
        guard let output = try? await SystemTool.run(
            "/usr/sbin/system_profiler", arguments: ["SPBluetoothDataType", "-json"]) else { return [] }
        return Self.parse(output)
    }

    /// Parses the system_profiler JSON: `SPBluetoothDataType` is a list whose
    /// first entry holds `device_connected` and `device_not_connected`.
    /// Pure and testable.
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
                    // system_profiler omits addresses for some disconnected
                    // devices, so same-named entries can collide on id — and
                    // duplicate ForEach IDs crash the device tab.
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
            if let text = device[key] as? String { levels[label] = parsePercent(text) }
        }
        addBattery("Device", "device_batteryLevelMain")
        addBattery("Left", "device_batteryLevelLeft")
        addBattery("Right", "device_batteryLevelRight")
        addBattery("Case", "device_batteryLevelCase")
        addBattery("Case", "device_batteryLevelCombined")
        return levels
    }

    static func parsePercent(_ text: String) -> Double? {
        let digits = text.filter(\.isNumber)
        guard let value = Double(digits) else { return nil }
        return min(1, value / 100)
    }
}
