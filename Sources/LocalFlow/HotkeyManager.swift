import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// Global push-to-talk via a CGEventTap on flagsChanged events.
/// Hold-to-talk on a bare modifier (Right Option by default) works in any app.
/// Requires the Accessibility permission.
final class HotkeyManager {
    enum Key: String, CaseIterable {
        case rightOption
        case rightCommand
        case fn

        var keyCode: Int64 {
            switch self {
            case .rightOption: return 61
            case .rightCommand: return 54
            case .fn: return 63
            }
        }

        /// The flag bit for this exact physical key. The generic ⌥/⌘ masks
        /// stay set while the *other* side's twin is held — releasing Right
        /// Option during a Left-Option drag looked like "still pressed" and
        /// left the mic recording. The NX_DEVICE* bits are per-key. fn has
        /// no twin, so the generic mask is exact for it.
        var deviceMask: CGEventFlags {
            switch self {
            case .rightOption: return CGEventFlags(rawValue: 0x40) // NX_DEVICERALTKEYMASK
            case .rightCommand: return CGEventFlags(rawValue: 0x10) // NX_DEVICERCMDKEYMASK
            case .fn: return .maskSecondaryFn
            }
        }

        /// The coarse modifier mask (set for either twin) — the fallback
        /// signal for input paths that don't report device-specific bits.
        var genericMask: CGEventFlags {
            switch self {
            case .rightOption: return .maskAlternate
            case .rightCommand: return .maskCommand
            case .fn: return .maskSecondaryFn
            }
        }

        var label: String {
            switch self {
            case .rightOption: return "Right Option (⌥)"
            case .rightCommand: return "Right Command (⌘)"
            case .fn: return "Fn / Globe"
            }
        }
    }

    var key: Key = .rightOption
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    /// Called on the main queue when the verified tap later stops delivering
    /// events entirely (sleep/wake, TCC churn) — the owner should restart it.
    var onTapDied: (() -> Void)?

    private var tap: CFMachPort?
    private var tapThread: Thread?
    private var tapRunLoop: CFRunLoop?
    private var isDown = false // touched only on the tap thread
    private var probeSeen = false
    private var watchdog: Timer?
    private var missedProbes = 0

    /// Marks our self-test event so the callback can recognize it.
    private static let probeMagic: Int64 = 0x10CA1F10

    /// Creates the tap and then VERIFIES events actually flow by posting a
    /// probe event through the system. Verification matters because a tap
    /// can be created successfully against a stale TCC grant (the app's
    /// code signature changes on every rebuild) and then silently receive
    /// nothing — which previously looked like "ready" with a dead hotkey.
    ///
    /// `completion(true/false)` runs on the main queue.
    func start(completion: @escaping (Bool) -> Void) {
        stop()
        // .defaultTap (gated on Accessibility — which the app needs for
        // pasting anyway, so it's the grant users actually maintain) is
        // safe here despite being an active tap: the callback runs on a
        // dedicated thread and returns in microseconds, so it can never
        // stall system input. .listenOnly (Input Monitoring) is the backup.
        tryStart(options: [.defaultTap, .listenOnly], completion: completion)
    }

    private func tryStart(options: [CGEventTapOptions], completion: @escaping (Bool) -> Void) {
        guard let option = options.first else {
            DispatchQueue.main.async { completion(false) }
            return
        }
        let remaining = Array(options.dropFirst())

        guard createTap(option) else {
            tryStart(options: remaining, completion: completion)
            return
        }

        probeSeen = false
        postProbe()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            if self.probeSeen {
                NSLog("LocalFlow: event tap verified (%@)",
                      option == .listenOnly ? "listen-only" : "active")
                self.startWatchdog()
                completion(true)
            } else {
                NSLog("LocalFlow: event tap created (%@) but probe not delivered — stale permission? Trying next option",
                      option == .listenOnly ? "listen-only" : "active")
                self.stop()
                self.tryStart(options: remaining, completion: completion)
            }
        }
    }

    private func createTap(_ option: CGEventTapOptions) -> Bool {
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
            // Consume our own health probes (active tap only — a listen-only
            // tap's return value is ignored) so the synthetic flagsChanged
            // never reaches other apps.
            let isProbe = manager.handle(type: type, event: event)
            return isProbe ? nil : Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: option,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        self.tap = tap

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        // The tap gets a dedicated thread. On the main run loop, any
        // main-thread stall (audio engine spin-up, model work, menu
        // tracking, a TCC prompt) delays event delivery for the whole
        // system until macOS kills the tap by timeout.
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            self?.tapRunLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "LocalFlow.HotkeyTap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        tapThread = thread
        return true
    }

    /// Posts a no-op flagsChanged event (unused keycode, tagged with a magic
    /// user-data value) that only our own tap cares about. If it never
    /// arrives, the tap is dead regardless of what tapCreate claimed.
    /// Posting needs Accessibility — which the app requires for ⌘V anyway.
    private func postProbe() {
        guard let probe = CGEvent(source: nil) else { return }
        probe.type = .flagsChanged
        probe.setIntegerValueField(.keyboardEventKeycode, value: 0x7F)
        // Carry the true current modifier state: when the tap is listen-only
        // the probe can't be consumed in the callback, and an empty-flags
        // event would tell the frontmost app "all modifiers released"
        // mid-⇧/⌘-drag.
        probe.flags = CGEventSource.flagsState(.combinedSessionState)
        probe.setIntegerValueField(.eventSourceUserData, value: Self.probeMagic)
        probe.post(tap: .cgSessionEventTap)
    }

    /// The startup probe only proves the tap worked once — taps can die
    /// later without any callback (sleep/wake, a TCC grant going stale).
    /// Re-run the probe periodically; if it stops arriving, report the tap
    /// dead so the owner can rebuild it.
    private func startWatchdog() {
        watchdog?.invalidate()
        missedProbes = 0
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            self?.checkHealth()
        }
        watchdog = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func checkHealth() {
        guard let tap else { return }
        // Catches a disable where the disable event itself never reached the
        // callback (the in-callback re-enable can't run if nothing arrives).
        if !CGEvent.tapIsEnabled(tap: tap) {
            NSLog("LocalFlow: event tap found disabled — re-enabling")
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        // Secure input (a focused password field) legitimately suppresses
        // event delivery — don't declare the tap dead over it.
        guard !IsSecureEventInputEnabled() else { return }

        probeSeen = false
        postProbe()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, self.tap != nil else { return }
            if self.probeSeen {
                self.missedProbes = 0
                return
            }
            self.missedProbes += 1
            NSLog("LocalFlow: hotkey health probe missed (%d/2)", self.missedProbes)
            guard self.missedProbes >= 2 else { return }
            self.missedProbes = 0
            self.onTapDied?()
        }
    }

    /// Forgets an in-progress hold without firing `onRelease`. For sleep /
    /// session-switch: the release event will never arrive, and stale
    /// `isDown` state would swallow the next press. Only safe to call when
    /// no physical key is held (i.e. the machine is going away from the
    /// user), since the tap thread also touches `isDown`.
    func cancelHold() {
        isDown = false
    }

    func stop() {
        watchdog?.invalidate()
        watchdog = nil
        missedProbes = 0
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            // Invalidating the port also invalidates its run loop source.
            CFMachPortInvalidate(tap)
        }
        if let tapRunLoop {
            CFRunLoopStop(tapRunLoop)
        }
        tap = nil
        tapThread = nil
        tapRunLoop = nil
        isDown = false
        probeSeen = false
    }

    /// Returns true when the event was LocalFlow's own health probe, so the
    /// tap callback can consume it instead of passing it on.
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        // macOS disables taps that stall; re-enable and carry on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            NSLog("LocalFlow: event tap disabled by system (%d) — re-enabling", type.rawValue)
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.probeMagic {
            DispatchQueue.main.async { self.probeSeen = true }
            return true
        }
        guard type == .flagsChanged else { return false }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == key.keyCode else { return false }

        // Only fires for the push-to-talk key itself — a few lines per
        // dictation, and the exact evidence needed when detection misfires.
        NSLog("LocalFlow: hotkey flagsChanged keycode=%d flags=0x%llx isDown=%d",
              keyCode, event.flags.rawValue, isDown ? 1 : 0)

        let pressed: Bool
        if event.flags.contains(key.deviceMask) {
            pressed = true
        } else if !event.flags.contains(key.genericMask) {
            pressed = false
        } else {
            // Generic mask set but no device bit: a release while the twin
            // key is held, or an input path that never reports device bits
            // (some external keyboards / remappers). Either way, an event
            // for OUR keycode while down can only be a release, and while
            // up can only be a press.
            pressed = !isDown
        }
        guard pressed != isDown else { return false }
        isDown = pressed

        let handler = pressed ? onPress : onRelease
        DispatchQueue.main.async { handler?() }
        return false
    }
}
