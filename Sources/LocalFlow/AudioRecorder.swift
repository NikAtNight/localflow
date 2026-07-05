import AVFoundation
import CoreMedia

/// Captures microphone audio and converts it on the fly to 16 kHz mono
/// Float32 PCM — the format Whisper expects.
///
/// Built on AVCaptureSession, not AVAudioEngine. The engine validates tap
/// formats against an internal cache that goes stale whenever the device
/// changes underneath it (Bluetooth mics flip rates on every hands-free
/// transition) — with a nil tap format it dies at engine start (-10868),
/// and with an explicit one it dies in installTap with an *uncatchable*
/// NSException. AVCaptureSession has no cached-format validation at all:
/// every delivered buffer self-describes its format.
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

    /// RMS energy of a capture in dBFS (0 = full scale); -infinity for
    /// empty or all-zero buffers. Used to tell silence from speech before
    /// handing audio to Whisper.
    static func rmsDBFS(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return -.infinity }
        // Double accumulator: a 5-minute capture is ~5M squares and a Float
        // running sum loses the small terms.
        var sum = 0.0
        for s in samples { sum += Double(s) * Double(s) }
        let rms = (sum / Double(samples.count)).squareRoot()
        guard rms > 0 else { return -.infinity }
        return Float(20 * log10(rms))
    }

    /// Called on the capture queue with a 0…1 loudness level per captured
    /// buffer — drives the waveform overlay. Callee must hop to main itself.
    var onLevel: ((Float) -> Void)?

    /// Called on the capture queue with 12 coarse band magnitudes (low
    /// frequencies first, ~120 Hz – 3.8 kHz, log-spaced) per captured buffer.
    /// Raw energies — the overlay normalizes them. Callee hops to main itself.
    var onSpectrum: (([Float]) -> Void)?

    /// Goertzel center frequencies: 12 log-spaced bands across the speech range.
    private static let bandFrequencies: [Float] = {
        (0..<12).map { 120 * pow(3800 / 120, Float($0) / 11) }
    }()

    /// Called once per `start`, on the capture queue, when the first buffer
    /// actually arrives. Session start alone doesn't mean audio is flowing —
    /// a Bluetooth mic's hands-free profile can take a second (or a rebuild)
    /// to deliver anything, and the "speak now" cue must not lie.
    var onCaptureLive: (() -> Void)?

    /// Called on the control queue when capture died mid-recording and could
    /// not be recovered — without it the app looks like it's recording while
    /// no audio flows. The session is already torn down when this fires.
    /// Callee must hop to main itself.
    var onRuntimeFailure: ((Error) -> Void)?

    /// UID of the microphone to record from; nil follows the system default.
    /// Takes effect at the next `start`. Written from the main thread (menu
    /// picks) and read on the control queue — hence the lock.
    var deviceUID: String? {
        get { lock.lock(); defer { lock.unlock() }; return _deviceUID }
        set { lock.lock(); defer { lock.unlock() }; _deviceUID = newValue }
    }
    private var _deviceUID: String?

    private static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: AudioRecorder.sampleRate,
        channels: 1,
        interleaved: false
    )!

    private var session: AVCaptureSession?
    private var forwarder: SampleForwarder?
    private var runtimeObserver: NSObjectProtocol?
    private var samples: [Float] = []
    private var captureLive = false // guarded by `lock`
    private var buffersThisSession = 0 // guarded by `lock`
    private var recordingGeneration = 0 // touched only on `controlQueue`
    private let lock = NSLock()

    // Session start/stop can block (mic hardware spin-up, TCC prompts) —
    // keep that off the main thread. Serial, so a rapid press→release→press
    // always runs start/stop/start in order.
    private let controlQueue = DispatchQueue(label: "LocalFlow.AudioControl", qos: .userInitiated)
    private let sampleQueue = DispatchQueue(label: "LocalFlow.AudioSamples", qos: .userInitiated)

    /// Starts capture; `completion` runs on the main queue with nil on
    /// success or the error that prevented recording.
    func start(completion: @escaping (Error?) -> Void) {
        controlQueue.async {
            do {
                try self.startCapture()
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
            self.recordingGeneration += 1
            self.tearDownSession()
            self.lock.lock()
            let captured = self.samples
            self.samples = []
            self.lock.unlock()
            DispatchQueue.main.async { completion(captured) }
        }
    }

    private func startCapture() throws {
        recordingGeneration += 1
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        captureLive = false
        buffersThisSession = 0
        lock.unlock()
        try captureWithFallback()
        armNoAudioWatchdog(rebuildsLeft: 2)
    }

    /// A Bluetooth mic's first activation can "start" successfully yet never
    /// deliver a buffer; a rebuild reliably unsticks it. Pinned to the
    /// recording generation, not the session object — a quick press→release→
    /// press can't have a stale check tear down the next recording's mic,
    /// but a session replaced by error recovery stays watched (pinning the
    /// object let a runtime-error resume in the first 1.2s escape the
    /// watchdog entirely: silent session, no rebuild, "heard nothing").
    private func armNoAudioWatchdog(rebuildsLeft: Int) {
        let generation = recordingGeneration
        controlQueue.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, generation == self.recordingGeneration, self.session != nil else { return }
            self.lock.lock()
            let live = self.captureLive
            self.lock.unlock()
            guard !live else { return }
            guard rebuildsLeft > 0 else {
                NSLog("LocalFlow: still no audio after rebuilding capture — giving up")
                self.tearDownSession()
                self.onRuntimeFailure?(RecorderError.noInput)
                return
            }
            NSLog("LocalFlow: capture started but no audio after 1.2s — rebuilding capture")
            do {
                try self.captureWithFallback()
                self.armNoAudioWatchdog(rebuildsLeft: rebuildsLeft - 1)
            } catch {
                NSLog("LocalFlow: capture rebuild failed: %@", error.localizedDescription)
                self.tearDownSession()
                self.onRuntimeFailure?(error)
            }
        }
    }

    /// Starts capture on the preferred mic; if that fails (a device
    /// mid-transition, a half-disconnected mic), retries once after a beat,
    /// then falls back to the built-in microphone. Dictation must not die
    /// while a working mic exists — a wrong-mic recording beats no recording.
    private func captureWithFallback() throws {
        let preferred = deviceUID
        do {
            try beginCapture(pinning: preferred)
        } catch {
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

    /// Builds a fresh session capturing from the given device UID (nil =
    /// current system default). Split from `startCapture` so recovery paths
    /// can rebuild without discarding what was already recorded.
    private func beginCapture(pinning uid: String?) throws {
        tearDownSession()
        // Stray buffers from a torn-down session must not count toward the
        // fresh session's sustained-delivery threshold.
        lock.lock()
        buffersThisSession = 0
        lock.unlock()

        var device: AVCaptureDevice?
        if let uid {
            // AVCaptureDevice uniqueIDs are the CoreAudio device UIDs.
            device = AVCaptureDevice(uniqueID: uid)
            if device == nil {
                NSLog("LocalFlow: selected microphone (%@) not available — using system default", uid)
            }
        }
        guard let device = device ?? AVCaptureDevice.default(for: .audio) else {
            throw RecorderError.noInput
        }

        let session = AVCaptureSession()
        session.beginConfiguration()
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw RecorderError.noInput }
        session.addInput(input)

        let output = AVCaptureAudioDataOutput()
        let forwarder = SampleForwarder(targetFormat: Self.targetFormat) { [weak self] converted in
            self?.append(converted)
        }
        output.setSampleBufferDelegate(forwarder, queue: sampleQueue)
        guard session.canAddOutput(output) else { throw RecorderError.noInput }
        session.addOutput(output)
        session.commitConfiguration()

        runtimeObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionRuntimeError,
            object: session,
            queue: nil
        ) { [weak self] note in
            self?.handleRuntimeError(of: note.object as? AVCaptureSession)
        }

        session.startRunning()
        guard session.isRunning else {
            tearDownSession()
            throw RecorderError.noInput
        }
        self.session = session
        self.forwarder = forwarder
    }

    /// The session hit a runtime error (device yanked, media services
    /// reset) mid-recording — resume on whatever device is right now,
    /// keeping the samples already captured.
    private func handleRuntimeError(of errored: AVCaptureSession?) {
        controlQueue.async {
            guard let errored, errored === self.session else { return }
            NSLog("LocalFlow: capture session error mid-recording — resuming capture")
            do {
                try self.captureWithFallback()
                // An error before the first buffer means the replacement is
                // just as suspect — keep it under the no-audio watchdog.
                self.lock.lock()
                let live = self.captureLive
                self.lock.unlock()
                if !live { self.armNoAudioWatchdog(rebuildsLeft: 1) }
            } catch {
                NSLog("LocalFlow: could not resume capture: %@", error.localizedDescription)
                self.tearDownSession()
                self.onRuntimeFailure?(error)
            }
        }
    }

    private func tearDownSession() {
        if let runtimeObserver {
            NotificationCenter.default.removeObserver(runtimeObserver)
            self.runtimeObserver = nil
        }
        guard let session else { return }
        session.stopRunning()
        self.session = nil
        forwarder = nil
    }

    private func append(_ converted: AVAudioPCMBuffer) {
        guard let channel = converted.floatChannelData else { return }
        let count = Int(converted.frameLength)
        guard count > 0 else { return }

        lock.lock()
        let wasLive = captureLive
        // A Bluetooth mic mid-A2DP→HFP negotiation can emit a spurious
        // buffer (or a few) before the real stream stabilizes — a single
        // buffer must not declare capture live (it flashed the HUD's "talk
        // now" and disarmed the no-audio watchdog while the mic was still
        // seconds from working). Live = sustained delivery.
        if !wasLive {
            buffersThisSession += 1
            if buffersThisSession >= 3 { captureLive = true }
        }
        let nowLive = captureLive
        samples.append(contentsOf: UnsafeBufferPointer(start: channel[0], count: count))
        lock.unlock()
        if !wasLive && nowLive { onCaptureLive?() }

        if let onLevel {
            var sum: Float = 0
            for i in 0..<count { sum += channel[0][i] * channel[0][i] }
            let rms = (sum / Float(count)).squareRoot()
            // sqrt curve so quiet speech still moves the bars; ~0.2 RMS ≈ full scale
            onLevel(min(1, rms.squareRoot() * 2.2))
        }

        // Coarse spectrum for the pitch-aware HUD themes: one Goertzel filter
        // per band over the tail of the buffer. 12 × ≤512 multiplies — cheap.
        if let onSpectrum {
            let n = min(count, 512)
            let start = count - n
            var bands = [Float](repeating: 0, count: Self.bandFrequencies.count)
            for (bi, freq) in Self.bandFrequencies.enumerated() {
                let omega = 2 * Float.pi * freq / Float(Self.sampleRate)
                let coeff = 2 * cos(omega)
                var s1: Float = 0, s2: Float = 0
                for i in start..<count {
                    let s0 = channel[0][i] + coeff * s1 - s2
                    s2 = s1
                    s1 = s0
                }
                let power = s1 * s1 + s2 * s2 - coeff * s1 * s2
                bands[bi] = max(0, power).squareRoot() / Float(n)
            }
            onSpectrum(bands)
        }
    }
}

/// Bridges AVCaptureAudioDataOutput's CMSampleBuffers to 16 kHz mono
/// Float32 AVAudioPCMBuffers. Owns the converter, rebuilt whenever the
/// incoming format changes (Bluetooth profile flips mid-recording) — each
/// buffer self-describes its format, so there is nothing to go stale.
private final class SampleForwarder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let targetFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private let onPCM: (AVAudioPCMBuffer) -> Void

    init(targetFormat: AVAudioFormat, onPCM: @escaping (AVAudioPCMBuffer) -> Void) {
        self.targetFormat = targetFormat
        self.onPCM = onPCM
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc),
              let sourceFormat = AVAudioFormat(streamDescription: asbd) else { return }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0,
              let raw = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frames) else { return }
        raw.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: raw.mutableAudioBufferList
        ) == noErr else { return }

        if converter == nil || converter!.inputFormat != sourceFormat {
            converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
        }
        guard let converter else { return }

        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(raw.frameLength) * ratio) + 32
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
            return raw
        }
        guard conversionError == nil, converted.frameLength > 0 else { return }
        onPCM(converted)
    }
}
