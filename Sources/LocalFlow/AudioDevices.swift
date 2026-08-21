import AVFoundation
import CoreAudio

/// Enumerates input devices and resolves a saved UID back to a CoreAudio
/// device ID so `AVAudioEngine`'s input node can be pointed at it.
enum AudioDevices {
    struct Device: Identifiable, Hashable {
        let id: String       // unique UID, stable across reboots
        let name: String
        let deviceID: AudioDeviceID
    }

    static func inputs() -> [Device] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        return session.devices.compactMap { device in
            guard let coreID = coreAudioID(forUID: device.uniqueID) else { return nil }
            return Device(id: device.uniqueID, name: device.localizedName, deviceID: coreID)
        }
    }

    static func defaultInputName() -> String {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr else { return "Unknown" }
        return name(of: deviceID) ?? "Unknown"
    }

    /// Look up the CoreAudio device whose UID matches the AVFoundation UID.
    static func coreAudioID(forUID uid: String) -> AudioDeviceID? {
        for device in allDeviceIDs() {
            if self.uid(of: device) == uid { return device }
        }
        return nil
    }

    // MARK: - CoreAudio plumbing

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }
        return ids
    }

    private static func uid(of device: AudioDeviceID) -> String? {
        stringProperty(device, kAudioDevicePropertyDeviceUID)
    }

    private static func name(of device: AudioDeviceID) -> String? {
        stringProperty(device, kAudioObjectPropertyName)
    }

    private static func stringProperty(
        _ device: AudioDeviceID,
        _ selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString? = nil
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else { return nil }
        return value as String?
    }
}
