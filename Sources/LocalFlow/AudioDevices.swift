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
                  // CoreAudio auto-creates transient aggregate devices
                  // (CADefaultDeviceAggregate-…) — internal plumbing, not
                  // something a user should see in a mic picker.
                  transportType(id) != kAudioDeviceTransportTypeAggregate,
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

    private static func transportType(_ id: AudioDeviceID) -> UInt32 {
        var addr = address(kAudioDevicePropertyTransportType)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }

    static func defaultInputDeviceID() -> AudioDeviceID? {
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return err == noErr && id != kAudioObjectUnknown ? id : nil
    }

    /// Stable UID of the current system default input, straight from the
    /// HAL (AVCaptureDevice's notion can lag behind a just-changed default).
    static func defaultInputDeviceUID() -> String? {
        defaultInputDeviceID().flatMap { stringProperty($0, kAudioDevicePropertyDeviceUID) }
    }

    // Touched only on the main queue (the listener blocks are delivered there).
    nonisolated(unsafe) private static var changeCoalescer: DispatchWorkItem?

    /// Fires `handler` on the main queue whenever the system default input
    /// or the device list changes (mic plugged/unplugged, default moved in
    /// System Settings, AirPods connecting). A plug event produces a burst
    /// of HAL notifications, so changes are coalesced for half a second.
    /// Install once; listeners live for the app's lifetime.
    static func observeDeviceChanges(_ handler: @escaping () -> Void) {
        let selectors: [AudioObjectPropertySelector] = [
            kAudioHardwarePropertyDefaultInputDevice,
            kAudioHardwarePropertyDevices,
        ]
        for selector in selectors {
            var addr = address(selector)
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main
            ) { _, _ in
                changeCoalescer?.cancel()
                let work = DispatchWorkItem { handler() }
                changeCoalescer = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
            }
        }
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
