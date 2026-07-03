import CoreAudio
import Foundation

struct AudioInputDevice {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

/// CoreAudio HAL queries for input-capable devices. AVAudioEngine's input
/// node follows the system default mic; recording from a specific one means
/// resolving its stable UID (what we persist) to today's transient
/// AudioDeviceID and pinning that on the input unit.
enum AudioDevices {
    static func inputDevices() -> [AudioInputDevice] {
        allDeviceIDs().compactMap { id in
            guard hasInputStreams(id),
                  let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, kAudioObjectPropertyName) else { return nil }
            return AudioInputDevice(id: id, uid: uid, name: name)
        }
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        inputDevices().first { $0.uid == uid }?.id
    }

    /// The built-in microphone — the fallback when a chosen device (often a
    /// Bluetooth mic mid-mode-switch) fails to start. Nil on Macs without
    /// one (Mac mini/Studio).
    static func builtInInputDevice() -> AudioInputDevice? {
        inputDevices().first { transportType($0.id) == kAudioDeviceTransportTypeBuiltIn }
    }

    /// Bluetooth mics engage the hands-free profile when recording, which is
    /// slow to start and degrades all system audio for the duration.
    static func isBluetooth(_ id: AudioDeviceID) -> Bool {
        let transport = transportType(id)
        return transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    private static func transportType(_ id: AudioDeviceID) -> UInt32 {
        var addr = address(kAudioDevicePropertyTransportType)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }

    /// The device's current input sample rate and channel count, straight
    /// from the HAL. AVAudioEngine's node formats go stale once a device is
    /// swapped underneath the engine (they reported the previous default's
    /// rate even after pinning) — the HAL is the source of truth.
    static func inputHardwareFormat(_ id: AudioDeviceID) -> (sampleRate: Double, channels: UInt32)? {
        var rateAddr = address(kAudioDevicePropertyNominalSampleRate, scope: kAudioDevicePropertyScopeInput)
        var rate: Double = 0
        var rateSize = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(id, &rateAddr, 0, nil, &rateSize, &rate) == noErr, rate > 0 else {
            return nil
        }

        var confAddr = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeInput)
        var confSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &confAddr, 0, nil, &confSize) == noErr, confSize > 0 else {
            return nil
        }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(confSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &confAddr, 0, nil, &confSize, raw) == noErr else { return nil }
        let buffers = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        let channels = buffers.reduce(0) { $0 + $1.mNumberChannels }
        return channels > 0 ? (rate, channels) : nil
    }

    static func defaultInputDeviceID() -> AudioDeviceID? {
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return err == noErr && id != kAudioObjectUnknown ? id : nil
    }

    // MARK: - HAL plumbing

    private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids
    }

    private static func hasInputStreams(_ id: AudioDeviceID) -> Bool {
        var addr = address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeInput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let err = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0)
        }
        guard err == noErr, let value else { return nil }
        return value as String
    }
}
