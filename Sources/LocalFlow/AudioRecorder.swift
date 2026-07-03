import AudioToolbox
import AVFoundation

/// Captures microphone audio with AVAudioEngine and converts it on the fly
/// to 16 kHz mono Float32 PCM — the format Whisper expects.
final class AudioRecorder {
    enum RecorderError: Error, LocalizedError {
        case noInput

        var errorDescription: String? {
            switch self {
            case .noInput: return "No microphone input available."
            }
        }
    }

    static let sampleRate: Double = 16_000

    /// Called on the audio thread with a 0…1 loudness level per captured
    /// buffer — drives the waveform overlay. Callee must hop to main itself.
    var onLevel: ((Float) -> Void)?

    /// UID of the microphone to record from; nil follows the system default.
    /// Takes effect at the next `start`. Written from the main thread (menu
    /// picks) and read on the control queue — hence the lock.
    var deviceUID: String? {
        get { lock.lock(); defer { lock.unlock() }; return _deviceUID }
        set { lock.lock(); defer { lock.unlock() }; _deviceUID = newValue }
    }
    private var _deviceUID: String?

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: AudioRecorder.sampleRate,
        channels: 1,
        interleaved: false
    )!

    // One engine per recording, never reused. AVAudioEngine caches its input
    // node's format; after a microphone change the cache can disagree with
    // the hardware, and installTap raises an uncatchable NSException on the
    // mismatch (this crashed the app). A fresh engine cannot be stale.
    private var engine: AVAudioEngine?
    private var configObserver: NSObjectProtocol?
    private var samples: [Float] = []
    private let lock = NSLock()

    // Engine start/stop can block for hundreds of ms (mic hardware spin-up,
    // TCC prompts) — keep that off the main thread. Serial, so a rapid
    // press→release→press always runs start/stop/start in order.
    private let controlQueue = DispatchQueue(label: "LocalFlow.AudioControl", qos: .userInitiated)

    /// Starts capture; `completion` runs on the main queue with nil on
    /// success or the error that prevented recording.
    func start(completion: @escaping (Error?) -> Void) {
        controlQueue.async {
            do {
                try self.startEngine()
                DispatchQueue.main.async { completion(nil) }
            } catch {
                DispatchQueue.main.async { completion(error) }
            }
        }
    }

    /// Stops capture; `completion` runs on the main queue with everything
    /// recorded since start.
    func stop(completion: @escaping ([Float]) -> Void) {
        controlQueue.async {
            let samples = self.stopEngine()
            DispatchQueue.main.async { completion(samples) }
        }
    }

    private func startEngine() throws {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        lock.unlock()
        try captureWithFallback()
    }

    /// Starts capture on the preferred mic; if that fails (a Bluetooth mic
    /// that won't activate, a half-disconnected device), retries on the
    /// built-in microphone. Dictation must not die while a working mic
    /// exists — a wrong-mic recording beats no recording.
    private func captureWithFallback() throws {
        var preferred = deviceUID
        // "System Default" deliberately skips a Bluetooth default mic
        // (AirPods auto-connecting): engaging its hands-free profile is
        // slow, stutters all system audio (the cues), and often captures
        // nothing usable. Explicitly picking the Bluetooth mic in the menu
        // still pins it — that's a real choice, this is just a default.
        if preferred == nil,
           let defaultID = AudioDevices.defaultInputDeviceID(),
           AudioDevices.isBluetooth(defaultID),
           let builtIn = AudioDevices.builtInInputDevice() {
            NSLog("LocalFlow: default input is a Bluetooth mic — using %@ instead (pick the Bluetooth mic in the Microphone menu to override)",
                  builtIn.name)
            preferred = builtIn.uid
        }
        do {
            try beginCapture(pinning: preferred)
        } catch {
            // The HAL transiently refuses to start I/O (EAGAIN, "already is
            // a thread") while Bluetooth devices are mid-transition — a
            // short pause and one retry absorbs that before giving up on
            // the device entirely.
            NSLog("LocalFlow: capture start failed (%@) — retrying once",
                  error.localizedDescription)
            usleep(300_000)
            do {
                try beginCapture(pinning: preferred)
            } catch {
                let builtIn = AudioDevices.builtInInputDevice()
                let attemptedBuiltIn = preferred == nil
                    ? AudioDevices.defaultInputDeviceID() == builtIn?.id
                    : preferred == builtIn?.uid
                guard let builtIn, !attemptedBuiltIn else { throw error }
                NSLog("LocalFlow: mic failed to start (%@) — falling back to %@",
                      error.localizedDescription, builtIn.name)
                try beginCapture(pinning: builtIn.uid)
            }
        }
    }

    /// Builds a fresh engine and starts appending to `samples`. Split from
    /// `startEngine` so a mid-recording device change can resume capture
    /// without discarding what was already recorded. A nil `uid` leaves the
    /// engine on the system default device — a fresh engine binds the
    /// current default at creation, so no explicit pinning is needed.
    private func beginCapture(pinning uid: String?) throws {
        tearDownEngine()

        // Resolve the device and its TRUE format from the HAL before the
        // engine gets involved. The engine's node formats (and a format:nil
        // tap, which snapshots them) go stale when a device is pinned over
        // the default — a 24kHz-cached tap on 48kHz hardware kills engine
        // init with -10868. The HAL always answers for the actual device.
        let pinnedID = uid.flatMap { AudioDevices.deviceID(forUID: $0) }
        if uid != nil, pinnedID == nil {
            NSLog("LocalFlow: selected microphone (%@) not available — using system default", uid!)
        }
        guard let deviceID = pinnedID ?? AudioDevices.defaultInputDeviceID(),
              let hw = AudioDevices.inputHardwareFormat(deviceID),
              let tapFormat = AVAudioFormat(standardFormatWithSampleRate: hw.sampleRate, channels: hw.channels)
        else { throw RecorderError.noInput }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let pinnedID {
            // AUAudioUnit's setter (unlike raw AudioUnitSetProperty) reports
            // failure as a throwable error instead of silently misbinding.
            try input.auAudioUnit.setDeviceID(pinnedID)
        }

        // The converter is still built from each buffer's actual format —
        // belt and suspenders against a device rate change mid-recording.
        var converter: AVAudioConverter?
        let targetFormat = self.targetFormat
        input.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { [weak self] buffer, _ in
            guard let self else { return }
            if converter?.inputFormat != buffer.format {
                converter = AVAudioConverter(from: buffer.format, to: targetFormat)
            }
            guard let converter else { return }
            self.append(buffer, using: converter)
        }
        engine.prepare()

        // AirPods connecting or the current mic unplugging stops the engine
        // silently mid-recording; resume on whatever device is current.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] note in
            self?.handleConfigurationChange(of: note.object as? AVAudioEngine)
        }

        self.engine = engine
        do {
            try engine.start()
        } catch {
            tearDownEngine()
            throw error
        }
    }

    private func handleConfigurationChange(of changed: AVAudioEngine?) {
        controlQueue.async {
            // A notification can be in flight while the recording it belongs
            // to is being torn down — react only for the current engine.
            guard let changed, changed === self.engine else { return }
            // Engines also post a configuration change right after starting
            // on a pinned non-default device; rebuilding on that
            // self-notification triggers the next one — an infinite
            // teardown/rebuild loop that shredded capture into fragments.
            // Only a stopped engine (device died/reconfigured) needs help.
            guard !changed.isRunning else { return }
            NSLog("LocalFlow: audio device changed mid-recording — resuming capture")
            do {
                try self.captureWithFallback()
            } catch {
                NSLog("LocalFlow: could not resume capture after device change: %@",
                      error.localizedDescription)
            }
        }
    }

    private func tearDownEngine() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    private func stopEngine() -> [Float] {
        tearDownEngine()

        lock.lock()
        defer {
            samples = []
            lock.unlock()
        }
        return samples
    }

    private func append(_ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter) {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return
        }

        var consumed = false
        var conversionError: NSError?
        converter.convert(to: converted, error: &conversionError) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard conversionError == nil, let channel = converted.floatChannelData else { return }

        let count = Int(converted.frameLength)
        lock.lock()
        samples.append(contentsOf: UnsafeBufferPointer(start: channel[0], count: count))
        lock.unlock()

        if let onLevel, count > 0 {
            var sum: Float = 0
            for i in 0..<count { sum += channel[0][i] * channel[0][i] }
            let rms = (sum / Float(count)).squareRoot()
            // sqrt curve so quiet speech still moves the bars; ~0.2 RMS ≈ full scale
            onLevel(min(1, rms.squareRoot() * 2.2))
        }
    }
}
