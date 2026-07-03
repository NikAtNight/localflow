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
        try beginCapture()
    }

    /// Builds a fresh engine and starts appending to `samples`. Split from
    /// `startEngine` so a mid-recording device change can resume capture
    /// without discarding what was already recorded.
    private func beginCapture() throws {
        tearDownEngine()

        let engine = AVAudioEngine()
        let input = engine.inputNode
        applyDeviceSelection(to: input)
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecorderError.noInput
        }

        // format: nil — take whatever the node actually produces. The
        // converter is built from the first buffer's real format (and rebuilt
        // if it changes) instead of a format read before the engine ran;
        // requesting a format the hardware disagrees with is what crashed.
        var converter: AVAudioConverter?
        let targetFormat = self.targetFormat
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
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
            NSLog("LocalFlow: audio device changed mid-recording — resuming capture")
            do {
                try self.beginCapture()
            } catch {
                NSLog("LocalFlow: could not resume capture after device change: %@",
                      error.localizedDescription)
            }
        }
    }

    /// Pins the requested microphone on the input unit. Once pinned, the
    /// unit stops following the system default, so "default" is re-resolved
    /// and re-applied explicitly on every start. Must run before reading the
    /// input format — it changes with the device.
    private func applyDeviceSelection(to input: AVAudioInputNode) {
        var wanted: AudioDeviceID?
        if let deviceUID {
            wanted = AudioDevices.deviceID(forUID: deviceUID)
            if wanted == nil {
                NSLog("LocalFlow: selected microphone (%@) not connected — using system default", deviceUID)
            }
        }
        guard let deviceID = wanted ?? AudioDevices.defaultInputDeviceID(),
              let unit = input.audioUnit else { return }
        var id = deviceID
        let err = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if err != noErr {
            NSLog("LocalFlow: could not set input device %u (err %d)", id, err)
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
