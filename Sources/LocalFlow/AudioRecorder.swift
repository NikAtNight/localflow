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
        case noSignal

        var errorDescription: String? {
            switch self {
            case .noInput: return "No microphone input available."
            case .noSignal: return "Microphone connected but delivering silence."
            }
        }
    }

    static let sampleRate: Double = 16_000

    /// RMS energy of a capture in dBFS (0 = full scale); -infinity for
    /// empty or all-zero buffers. Used to tell silence from speech before
    /// handing audio to Whisper.
    static func rmsDBFS(of samples: [Float]) -> Float {
        samples.withUnsafeBufferPointer { signalMetrics(of: $0).dbfs }
    }

    /// Computes both values consumers need in one pass. Keeping this pointer-
    /// based avoids materializing an Array for each capture buffer.
    private static func signalMetrics(
        of samples: UnsafeBufferPointer<Float>
    ) -> (rms: Float, dbfs: Float) {
        guard !samples.isEmpty else { return (0, -.infinity) }
        // Double accumulator: a 5-minute capture is ~5M squares and a Float
        // running sum loses the small terms.
        var sum = 0.0
        for s in samples { sum += Double(s) * Double(s) }
        let rms = (sum / Double(samples.count)).squareRoot()
        guard rms > 0 else { return (0, -.infinity) }
        return (Float(rms), Float(20 * log10(rms)))
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
    private static let goertzelCoefficients: [Float] = {
        bandFrequencies.map { 2 * cos(2 * Float.pi * $0 / Float(sampleRate)) }
    }()

    /// Called once per `start`, on the capture queue, when the first AUDIBLE
    /// buffer arrives. Neither session start nor buffer arrival means the
    /// mic is hearing — AirPods stream digital zeros for seconds while
    /// their mic path spins up — and the "speak now" cue must not lie.
    var onCaptureLive: (() -> Void)?

    /// RMS floor separating "mic not actually on yet" (exact zeros, -inf)
    /// from a live mic's noise floor (rarely below -70 dBFS).
    static let digitalSilenceDBFS: Float = -80

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

    /// Keep the session running for `warmWindowSeconds` after `stop` so the
    /// next `start` skips device spin-up (a cold AirPods mic takes ~1.8s to
    /// deliver audible audio; a warm one is live in one buffer). Written
    /// from the main thread, read on the control queue — hence the lock.
    var keepWarm: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _keepWarm }
        set { lock.lock(); defer { lock.unlock() }; _keepWarm = newValue }
    }
    private var _keepWarm = false

    private static let warmWindowSeconds: TimeInterval = 120

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
    private var sessionDeviceUID: String? // touched only on `controlQueue`
    private var warmTeardown: DispatchWorkItem? // touched only on `controlQueue`
    private var recordingActive = false // guarded by `lock`
    private var captureLive = false // guarded by `lock`
    private var buffersThisSession = 0 // guarded by `lock`
    private var sessionEpoch = Date() // guarded by `lock`
    private var levelWindowSecond = 0 // guarded by `lock`
    private var peakDBFSWindow: Float = -.infinity // guarded by `lock`
    private var recordingGeneration = 0 // touched only on `controlQueue`
    private var captureGeneration = 0 // guarded by `lock`
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
    /// recorded since start. With `keepWarm`, a session that reached live
    /// audio stays running (discarding buffers) for `warmWindowSeconds` so
    /// the next start is instant; a session that never went live is on a
    /// suspect route and is torn down as before.
    func stop(completion: @escaping ([Float]) -> Void) {
        controlQueue.async {
            self.recordingGeneration += 1
            // Drain conversion work already queued at release time so the
            // tail of the utterance is included in the returned samples.
            self.sampleQueue.sync {}
            self.lock.lock()
            let captured = self.samples
            self.samples = []
            let wasLive = self.captureLive
            let warmWanted = self._keepWarm
            self.recordingActive = false
            self.lock.unlock()
            if warmWanted, wasLive, self.session != nil {
                self.scheduleWarmTeardown()
                DispatchQueue.main.async { completion(captured) }
            } else {
                // Hardware shutdown can block. The immutable sample Array is
                // already detached, so let transcription start in parallel.
                DispatchQueue.main.async { completion(captured) }
                self.tearDownSession()
            }
        }
    }

    /// Releases a warm (idle) session immediately. Device switches, system
    /// sleep, and turning keep-warm off must not hold the old mic open —
    /// on AirPods a warm session pins call-quality audio the whole window.
    /// No-op while a recording is in flight or nothing is warm.
    func releaseWarmSession() {
        controlQueue.async {
            self.lock.lock()
            let active = self.recordingActive
            self.lock.unlock()
            guard !active, self.session != nil else { return }
            DiagLog.log("releasing warm mic session (%@)", self.sessionDeviceUID ?? "?")
            self.warmTeardown?.cancel()
            self.warmTeardown = nil
            self.tearDownSession()
        }
    }

    /// Changes the preferred microphone and, when keep-warm is enabled,
    /// immediately starts an idle session on it. Bluetooth inputs otherwise
    /// pay their hands-free route transition on the first hotkey press after
    /// every switch, losing the start of that dictation while they emit
    /// digital zeroes.
    func selectDevice(_ uid: String?) {
        deviceUID = uid
        controlQueue.async {
            self.lock.lock()
            let active = self.recordingActive
            let warmWanted = self._keepWarm
            self.lock.unlock()

            // Do not interrupt a recording already in flight. Its next start
            // sees that the warm session is on the wrong UID and rebuilds it.
            guard !active else {
                DiagLog.log("microphone changed during capture — applying it on the next recording")
                return
            }

            self.warmTeardown?.cancel()
            self.warmTeardown = nil
            self.tearDownSession()
            guard warmWanted else { return }

            do {
                // Prewarming must target the requested route. Falling back
                // here would keep the wrong microphone warm and force another
                // rebuild on the first press anyway.
                try self.beginCapture(pinning: uid, fallbackToDefaultIfUnavailable: false)
                DiagLog.log("prewarming selected microphone (%@)", self.sessionDeviceUID ?? "system default")
                self.scheduleWarmTeardown()
            } catch {
                // A device can still be enumerating immediately after it is
                // selected. Leave the recorder cold; start() retains its retry
                // and built-in fallback behavior when the user actually holds
                // the hotkey.
                self.tearDownSession()
                DiagLog.log("selected microphone could not be prewarmed (%@) — will retry on first press",
                      error.localizedDescription)
            }
        }
    }

    private func scheduleWarmTeardown() {
        warmTeardown?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            DiagLog.log("warm mic window expired — releasing %@", self.sessionDeviceUID ?? "?")
            self.warmTeardown = nil
            self.tearDownSession()
        }
        warmTeardown = item
        controlQueue.asyncAfter(deadline: .now() + Self.warmWindowSeconds, execute: item)
        DiagLog.log("[diag] keeping mic warm for %.0fs", Self.warmWindowSeconds)
    }

    private func startCapture() throws {
        warmTeardown?.cancel()
        warmTeardown = nil
        recordingGeneration += 1
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        captureLive = false
        buffersThisSession = 0
        levelWindowSecond = 0
        peakDBFSWindow = -.infinity
        recordingActive = true
        sessionEpoch = Date()
        lock.unlock()
        // A warm session on the right device skips spin-up entirely — the
        // next audible buffer (one is usually already in flight) re-fires
        // onCaptureLive. Wrong device (setting changed, default moved, a
        // fallback mic was pinned last time) rebuilds from scratch.
        if let session, session.isRunning, sessionDeviceUID == currentWantedDeviceUID() {
            DiagLog.log("[diag] reusing warm capture session on %@", sessionDeviceUID ?? "?")
            armNoAudioWatchdog(rebuildsLeft: 2)
            return
        }
        try captureWithFallback()
        armNoAudioWatchdog(rebuildsLeft: 2)
    }

    /// The device a fresh capture would land on right now: the selected mic
    /// when it's present, otherwise the current system default.
    private func currentWantedDeviceUID() -> String? {
        if let uid = deviceUID, AVCaptureDevice(uniqueID: uid) != nil { return uid }
        return AVCaptureDevice.default(for: .audio)?.uniqueID
    }

    /// Watches a started session until audible audio arrives. Two distinct
    /// stalls need opposite treatment:
    /// - No buffers at all: the session is stuck (classic first-activation
    ///   Bluetooth failure) — a rebuild reliably unsticks it.
    /// - Buffers flowing but all digital zeros: the AirPods mic path is
    ///   still spinning up behind a healthy HFP stream. Rebuilding thrashes
    ///   a working session; wait it out, with one late rebuild kick and a
    ///   hard stop so a genuinely dead route still surfaces as an error.
    /// Pinned to the recording generation, not the session object — a quick
    /// press→release→press can't have a stale check tear down the next
    /// recording's mic, but a session replaced by error recovery stays
    /// watched.
    private func armNoAudioWatchdog(rebuildsLeft: Int, checks: Int = 0) {
        let generation = recordingGeneration
        controlQueue.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, generation == self.recordingGeneration, self.session != nil else { return }
            self.lock.lock()
            let live = self.captureLive
            let buffers = self.buffersThisSession
            self.lock.unlock()
            guard !live else { return }

            // buffers == 0: stuck session, rebuild is the known fix. Silent
            // buffers get NO rebuild — measured AirPods wakes take 1.3-1.8s
            // and occasionally longer, and a rebuild mid-wake restarts the
            // whole zero cycle (or fails outright: "no microphone input").
            // Wait it out; only a route silent for ~10s is declared dead.
            if buffers > 0 {
                guard checks < 8 else {
                    DiagLog.log("buffers flowing but silent for ~10s — giving up")
                    self.tearDownSession()
                    self.onRuntimeFailure?(RecorderError.noSignal)
                    return
                }
                DiagLog.log("[diag] %d buffers, all silent — waiting for mic to wake", buffers)
                self.armNoAudioWatchdog(rebuildsLeft: rebuildsLeft, checks: checks + 1)
                return
            }

            guard rebuildsLeft > 0 else {
                DiagLog.log("still no audio after rebuilding capture — giving up")
                self.tearDownSession()
                self.onRuntimeFailure?(RecorderError.noInput)
                return
            }
            DiagLog.log("no usable audio after %.1fs (%d buffers) — rebuilding capture",
                  1.2 * Double(checks + 1), buffers)
            do {
                try self.captureWithFallback()
                self.armNoAudioWatchdog(rebuildsLeft: rebuildsLeft - 1, checks: checks + 1)
            } catch {
                DiagLog.log("capture rebuild failed: %@", error.localizedDescription)
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
            DiagLog.log("capture start failed (%@) — retrying once",
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
                DiagLog.log("mic failed to start (%@) — falling back to %@",
                      error.localizedDescription, builtIn.name)
                try beginCapture(pinning: builtIn.uid)
            }
        }
    }

    /// Builds a fresh session capturing from the given device UID (nil =
    /// current system default). Split from `startCapture` so recovery paths
    /// can rebuild without discarding what was already recorded.
    private func beginCapture(
        pinning uid: String?,
        fallbackToDefaultIfUnavailable: Bool = true
    ) throws {
        tearDownSession()
        // Stray buffers from a torn-down session must not count toward the
        // fresh session's sustained-delivery threshold.
        lock.lock()
        buffersThisSession = 0
        captureGeneration &+= 1
        let generation = captureGeneration
        lock.unlock()

        var device: AVCaptureDevice?
        if let uid {
            // AVCaptureDevice uniqueIDs are the CoreAudio device UIDs.
            device = AVCaptureDevice(uniqueID: uid)
            if device == nil {
                guard fallbackToDefaultIfUnavailable else { throw RecorderError.noInput }
                DiagLog.log("selected microphone (%@) not available — using system default", uid)
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
            self?.append(converted, from: generation)
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

        let startBegan = Date()
        session.startRunning()
        guard session.isRunning else {
            tearDownSession()
            throw RecorderError.noInput
        }
        self.session = session
        self.forwarder = forwarder
        sessionDeviceUID = device.uniqueID
        lock.lock()
        sessionEpoch = Date()
        lock.unlock()
        DiagLog.log("[diag] capture running on %@ (startRunning blocked %.0fms)",
              device.localizedName, Date().timeIntervalSince(startBegan) * 1000)
    }

    /// The session hit a runtime error (device yanked, media services
    /// reset) mid-recording — resume on whatever device is right now,
    /// keeping the samples already captured.
    private func handleRuntimeError(of errored: AVCaptureSession?) {
        controlQueue.async {
            guard let errored, errored === self.session else { return }
            self.lock.lock()
            let active = self.recordingActive
            self.lock.unlock()
            // A warm idle session that errors (device yanked, media services
            // reset) isn't worth resuming — just let the mic go; the next
            // press cold-starts on whatever device is right then.
            guard active else {
                DiagLog.log("warm session error while idle — releasing mic")
                self.warmTeardown?.cancel()
                self.warmTeardown = nil
                self.tearDownSession()
                return
            }
            DiagLog.log("capture session error mid-recording — resuming capture")
            do {
                try self.captureWithFallback()
                // An error before the first buffer means the replacement is
                // just as suspect — keep it under the no-audio watchdog.
                self.lock.lock()
                let live = self.captureLive
                self.lock.unlock()
                if !live { self.armNoAudioWatchdog(rebuildsLeft: 1) }
            } catch {
                DiagLog.log("could not resume capture: %@", error.localizedDescription)
                self.tearDownSession()
                self.onRuntimeFailure?(error)
            }
        }
    }

    private func tearDownSession() {
        // Invalidate queued callbacks before stopRunning blocks. A callback
        // from this session must never enter a replacement session.
        lock.lock()
        captureGeneration &+= 1
        lock.unlock()
        if let runtimeObserver {
            NotificationCenter.default.removeObserver(runtimeObserver)
            self.runtimeObserver = nil
        }
        guard let session else { return }
        session.stopRunning()
        self.session = nil
        forwarder = nil
        sessionDeviceUID = nil
    }

    private func append(_ converted: AVAudioPCMBuffer, from generation: Int) {
        guard let channel = converted.floatChannelData else { return }
        let count = Int(converted.frameLength)
        guard count > 0 else { return }
        let buffer = UnsafeBufferPointer(start: channel[0], count: count)
        let metrics = Self.signalMetrics(of: buffer)

        lock.lock()
        // A warm idle session keeps delivering buffers; none of them are
        // part of a recording — no accumulation, no HUD levels, no
        // capture-live transitions.
        guard recordingActive, generation == captureGeneration else {
            lock.unlock()
            return
        }
        let wasLive = captureLive
        // A Bluetooth mic mid-A2DP→HFP negotiation can emit a spurious
        // buffer (or a few) before the real stream stabilizes — a single
        // buffer must not declare capture live (it flashed the HUD's "talk
        // now" and disarmed the no-audio watchdog while the mic was still
        // seconds from working). Live = sustained delivery.
        buffersThisSession += 1
        // Live = audible signal, not buffer arrival. AirPods bring the HFP
        // stream up within ~300ms but deliver exact digital zeros for
        // seconds while the mic path itself spins up — a live microphone
        // always carries a noise floor, so -inf/-80 dBFS means "connected
        // but not hearing yet" and must not cue the user to speak.
        let dbfs = metrics.dbfs
        if !wasLive && dbfs > Self.digitalSilenceDBFS { captureLive = true }
        let nowLive = captureLive
        let bufferIndex = buffersThisSession
        let epoch = sessionEpoch
        // Do not hand Whisper the digital-zero prefix produced while a cold
        // Bluetooth hands-free route is switching on. That prefix contains no
        // recoverable audio and made the first post-switch capture materially
        // different from every warm capture.
        if nowLive { samples.append(contentsOf: buffer) }
        // Per-second peak trace: shows whether speech ever reaches usable
        // levels after the mic wakes (AirPods AGC/noise-gate diagnosis).
        peakDBFSWindow = max(peakDBFSWindow, dbfs)
        var completedSecond = -1
        var completedPeak: Float = -.infinity
        let second = Int(Date().timeIntervalSince(epoch))
        if second > levelWindowSecond {
            completedSecond = levelWindowSecond
            completedPeak = peakDBFSWindow
            levelWindowSecond = second
            peakDBFSWindow = -.infinity
        }
        lock.unlock()
        if completedSecond >= 0 && completedSecond < 20 {
            DiagLog.log("[diag] level s%d peak %.1f dBFS", completedSecond, completedPeak)
        }
        if bufferIndex <= 5 {
            DiagLog.log("[diag] buffer %d at +%.0fms frames=%d %.1f dBFS",
                  bufferIndex, Date().timeIntervalSince(epoch) * 1000, count, dbfs)
        }
        if !wasLive && nowLive {
            DiagLog.log("[diag] first audible buffer (%d) at +%.0fms, %.1f dBFS",
                  bufferIndex, Date().timeIntervalSince(epoch) * 1000, dbfs)
            onCaptureLive?()
        }

        if let onLevel {
            // sqrt curve so quiet speech still moves the bars; ~0.2 RMS ≈ full scale
            onLevel(min(1, metrics.rms.squareRoot() * 2.2))
        }

        // Coarse spectrum for the pitch-aware HUD themes: one Goertzel filter
        // per band over the tail of the buffer. 12 × ≤512 multiplies — cheap.
        if let onSpectrum {
            let n = min(count, 512)
            let start = count - n
            var bands = [Float](repeating: 0, count: Self.goertzelCoefficients.count)
            for (bi, coeff) in Self.goertzelCoefficients.enumerated() {
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
    private var sourceDescription: AudioStreamBasicDescription?
    private var sourceFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var rawBuffer: AVAudioPCMBuffer?
    private var convertedBuffer: AVAudioPCMBuffer?
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
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc) else { return }
        let incomingDescription = asbd.pointee
        if sourceDescription.map({ !Self.matches($0, incomingDescription) }) ?? true {
            guard let format = AVAudioFormat(streamDescription: asbd),
                  let converter = AVAudioConverter(from: format, to: targetFormat) else { return }
            sourceDescription = incomingDescription
            sourceFormat = format
            self.converter = converter
            rawBuffer = nil
            convertedBuffer = nil
        }
        guard let sourceFormat, let converter else { return }

        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0 else { return }
        let raw: AVAudioPCMBuffer
        if let rawBuffer, rawBuffer.frameCapacity >= frames {
            raw = rawBuffer
        } else {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frames) else { return }
            rawBuffer = buffer
            raw = buffer
        }
        raw.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: raw.mutableAudioBufferList
        ) == noErr else { return }

        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(raw.frameLength) * ratio) + 32
        let converted: AVAudioPCMBuffer
        if let convertedBuffer, convertedBuffer.frameCapacity >= capacity {
            converted = convertedBuffer
        } else {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
            convertedBuffer = buffer
            converted = buffer
        }
        converted.frameLength = 0
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

    /// Audio format objects are relatively expensive to build and capture
    /// normally sends the same ASBD hundreds of times. Rebuild only for an
    /// actual device/profile format change.
    private static func matches(
        _ lhs: AudioStreamBasicDescription,
        _ rhs: AudioStreamBasicDescription
    ) -> Bool {
        lhs.mSampleRate == rhs.mSampleRate &&
            lhs.mFormatID == rhs.mFormatID &&
            lhs.mFormatFlags == rhs.mFormatFlags &&
            lhs.mBytesPerPacket == rhs.mBytesPerPacket &&
            lhs.mFramesPerPacket == rhs.mFramesPerPacket &&
            lhs.mBytesPerFrame == rhs.mBytesPerFrame &&
            lhs.mChannelsPerFrame == rhs.mChannelsPerFrame &&
            lhs.mBitsPerChannel == rhs.mBitsPerChannel
    }
}
