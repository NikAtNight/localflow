import AppKit

/// Floating "listening" HUD shown while the hotkey is held: a non-activating
/// panel at the bottom-center of the screen, draggable to wherever the user
/// wants it (the spot persists across launches). The visual itself is
/// whichever HudTheme the user picked — system glass for Liquid Glass, a
/// frosted capsule for most themes, and no chrome for the bare themes.
@MainActor
final class WaveformOverlay {
    private let panel: NSPanel
    private var hudView: HudView
    private var theme: HudTheme
    private var hideGeneration = 0
    private var previewTimer: Timer?
    // Distinguishes the app's own present/layout moves from a user drag —
    // only drags may persist the origin.
    private var programmaticMove = false
    private var moveObserver: NSObjectProtocol?
    // Audio buffers can arrive much faster than the HUD's 30 fps refresh.
    // Coalesce their peaks so the capture queue never floods the main queue
    // with redundant view updates.
    nonisolated private let inputLock = NSLock()
    nonisolated(unsafe) private var pendingLevel: Float?
    nonisolated(unsafe) private var pendingSpectrum: [Float]?
    nonisolated(unsafe) private var inputDrainScheduled = false

    init() {
        theme = HudTheme.current
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: theme.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        // Draggable, and .nonactivatingPanel keeps the drag from stealing
        // focus from the app being dictated into.
        panel.ignoresMouseEvents = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false

        hudView = HudView(frame: NSRect(origin: .zero, size: theme.size),
                          renderer: theme.makeRenderer())
        applyTheme(theme)

        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.programmaticMove, self.panel.isVisible else { return }
                Settings.hudOrigin = self.panel.frame.origin
            }
        }
    }

    private func applyTheme(_ newTheme: HudTheme) {
        hudView.stopAnimating() // the outgoing view's timer must not outlive it
        theme = newTheme
        let size = newTheme.size
        programmaticMove = true
        panel.setContentSize(size)
        programmaticMove = false
        let bounds = NSRect(origin: .zero, size: size)

        hudView = HudView(frame: bounds, renderer: newTheme.makeRenderer())
        hudView.autoresizingMask = [.width, .height]

        let container: NSView
        if newTheme.isBare {
            let bare = NSView(frame: bounds)
            bare.addSubview(hudView)
            container = bare
        } else if newTheme == .liquidGlass {
            if #available(macOS 26.0, *) {
                let glass = NSGlassEffectView(frame: bounds)
                glass.style = .regular
                glass.cornerRadius = size.height / 2
                glass.tintColor = NSColor.white.withAlphaComponent(0.025)
                glass.wantsLayer = true
                glass.layer?.cornerRadius = size.height / 2
                glass.layer?.cornerCurve = .continuous
                glass.layer?.masksToBounds = true
                glass.contentView = hudView
                container = glass
            } else {
                let blur = NSVisualEffectView(frame: bounds)
                blur.material = .hudWindow
                blur.state = .active
                blur.blendingMode = .behindWindow
                blur.wantsLayer = true
                blur.layer?.cornerRadius = size.height / 2
                blur.layer?.cornerCurve = .continuous
                blur.layer?.masksToBounds = true
                blur.layer?.borderWidth = 1
                blur.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
                blur.addSubview(hudView)
                container = blur
            }
        } else {
            let blur = NSVisualEffectView(frame: bounds)
            blur.material = .hudWindow
            blur.state = .active
            blur.blendingMode = .behindWindow
            blur.wantsLayer = true
            blur.layer?.cornerRadius = size.height / 2
            blur.layer?.cornerCurve = .continuous
            blur.layer?.masksToBounds = true
            blur.layer?.borderWidth = 1
            blur.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
            blur.addSubview(hudView)
            container = blur
        }

        panel.contentView = container
    }

    /// Thread-safe: callable from the audio capture thread.
    nonisolated func push(level: Float) {
        inputLock.lock()
        pendingLevel = max(pendingLevel ?? level, level)
        let shouldSchedule = !inputDrainScheduled
        inputDrainScheduled = true
        inputLock.unlock()

        if shouldSchedule {
            DispatchQueue.main.async { [weak self] in self?.drainInput() }
        }
    }

    /// Thread-safe: callable from the audio capture thread.
    nonisolated func push(spectrum: [Float]) {
        inputLock.lock()
        if var pendingSpectrum {
            if pendingSpectrum.count < spectrum.count {
                pendingSpectrum.append(contentsOf: spectrum[pendingSpectrum.count...])
            }
            for i in 0..<min(pendingSpectrum.count, spectrum.count) {
                pendingSpectrum[i] = max(pendingSpectrum[i], spectrum[i])
            }
            self.pendingSpectrum = pendingSpectrum
        } else {
            pendingSpectrum = spectrum
        }
        let shouldSchedule = !inputDrainScheduled
        inputDrainScheduled = true
        inputLock.unlock()

        if shouldSchedule {
            DispatchQueue.main.async { [weak self] in self?.drainInput() }
        }
    }

    private func drainInput() {
        inputLock.lock()
        let level = pendingLevel
        let spectrum = pendingSpectrum
        pendingLevel = nil
        pendingSpectrum = nil
        inputDrainScheduled = false
        inputLock.unlock()

        if let level { hudView.ingest(level: level) }
        if let spectrum { hudView.ingest(spectrum: spectrum) }
    }

    /// Hotkey pressed: the mic engine is starting but no audio has arrived
    /// yet — a Bluetooth mic can take seconds.
    func show() {
        cancelPreview()
        present(phase: .warming)
    }

    /// First real audio buffer arrived — snap to the full-brightness waveform.
    func captureLive() {
        hudView.setPhase(.live)
    }

    /// Hotkey released: keep the panel up as an indeterminate loading state
    /// until the pipeline resolves and the caller hides it (or a new press
    /// takes the panel over via show()).
    func beginProcessing() {
        hudView.setPhase(.processing)
    }

    func hide() {
        cancelPreview()
        hideGeneration += 1
        let generation = hideGeneration
        hudView.stopAnimating()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // Skip the orderOut if show() ran again during the fade.
                guard let self, self.hideGeneration == generation else { return }
                self.panel.orderOut(nil)
            }
        })
    }

    private func present(phase: HudView.Phase) {
        if HudTheme.current != theme {
            applyTheme(HudTheme.current)
        }
        hideGeneration += 1
        let origin: NSPoint
        if let saved = Settings.hudOrigin,
           Self.isVisible(origin: saved, size: panel.frame.size,
                          on: NSScreen.screens.map(\.visibleFrame)) {
            origin = saved
        } else {
            // Default bottom-center — also the fallback when the saved spot
            // is on a screen that is no longer connected.
            guard let screen = NSScreen.main else { return }
            origin = NSPoint(x: screen.visibleFrame.midX - panel.frame.width / 2,
                             y: screen.visibleFrame.minY + 64)
        }
        programmaticMove = true
        panel.setFrameOrigin(origin)
        programmaticMove = false

        hudView.reset()
        hudView.setPhase(phase)
        hudView.startAnimating()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }
    }

    /// Whether a panel of `size` at `origin` still lands on any connected
    /// screen — a position saved on a since-removed display must not leave
    /// the HUD invisible and undraggable.
    nonisolated static func isVisible(
        origin: NSPoint,
        size: NSSize,
        on screenFrames: [NSRect]
    ) -> Bool {
        let rect = NSRect(origin: origin, size: size)
        return screenFrames.contains { $0.intersects(rect) }
    }

    // MARK: - Menu preview

    /// Shows the HUD for a few seconds fed by synthesized "speech" so a theme
    /// picked from the menu can be judged without dictating anything.
    func preview() {
        cancelPreview()
        present(phase: .live)
        let start = Date()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let t = Date().timeIntervalSince(start)
                if t > 3.6 {
                    self.cancelPreview()
                    self.hide()
                    return
                }
                let level = SyntheticSpeech.level(at: t)
                self.hudView.ingest(level: level)
                self.hudView.ingest(spectrum: SyntheticSpeech.spectrum(at: t, level: level))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        previewTimer = timer
    }

    private func cancelPreview() {
        previewTimer?.invalidate()
        previewTimer = nil
    }
}

/// The drawing surface: latches the loudest level and band energies between
/// ticks (audio buffers arrive slower than 30 fps), applies auto-gain to the
/// spectrum so any mic lands in 0…1, and hands each frame to the renderer.
/// Flipped so renderer coordinates are y-down, matching the design prototypes.
private final class HudView: NSView {
    override var isFlipped: Bool { true }

    /// Lifecycle states drawn on top of (or instead of) the theme renderer,
    /// so all 17 themes get them without per-renderer changes:
    /// warming = mic starting but no audio yet, live = normal waveform,
    /// processing = transcription running after release.
    enum Phase {
        case warming, live, processing
    }

    private let renderer: HudRenderer
    private var phase: Phase = .live
    private var phaseStart: CGFloat = 0 // `time` when the phase was entered
    private var latchedLevel: CGFloat = 0
    private var latchedSpectrum = [CGFloat](repeating: 0, count: 12)
    private var frameLevel: CGFloat = 0
    private var frameSpectrum = [CGFloat](repeating: 0, count: 12)
    private var agcReference: CGFloat = 0.0035
    private var agcLevelReference: CGFloat = 0.4
    private var time: CGFloat = 0
    private var timer: Timer?

    init(frame: NSRect, renderer: HudRenderer) {
        self.renderer = renderer
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func ingest(level: Float) {
        // Same slow-decay AGC idea as the spectrum path: a Bluetooth HFP mic
        // runs far quieter than a wired one, and a fixed scale leaves the
        // bars barely tracking speech. The floor keeps the room's noise
        // floor from being amplified into apparent speech.
        agcLevelReference = max(agcLevelReference * 0.995, CGFloat(level), 0.4)
        latchedLevel = max(latchedLevel, min(1, CGFloat(level) / agcLevelReference * 0.95))
    }

    func ingest(spectrum: [Float]) {
        let n = min(spectrum.count, latchedSpectrum.count)
        var peak: CGFloat = 0
        for i in 0..<n { peak = max(peak, CGFloat(spectrum[i])) }
        // Slow-decay reference: band energies vary wildly across mics, so
        // normalize against the recent loudest band rather than a constant.
        agcReference = max(agcReference * 0.995, peak, 0.0035)
        for i in 0..<n {
            let v = min(1, pow(CGFloat(spectrum[i]) / agcReference, 0.75))
            latchedSpectrum[i] = max(latchedSpectrum[i], v)
        }
    }

    func setPhase(_ newPhase: Phase) {
        guard newPhase != phase else { return }
        phase = newPhase
        phaseStart = time
        needsDisplay = true
    }

    func reset() {
        time = 0
        phaseStart = 0
        latchedLevel = 0
        latchedSpectrum = [CGFloat](repeating: 0, count: 12)
        frameLevel = 0
        frameSpectrum = [CGFloat](repeating: 0, count: 12)
        renderer.reset()
        needsDisplay = true
    }

    func startAnimating() {
        stopAnimating()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopAnimating() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        time += 1.0 / 30.0
        frameLevel = min(1, latchedLevel)
        latchedLevel = 0
        frameSpectrum = latchedSpectrum
        // Decay instead of clearing: audio buffers arrive slower than ticks,
        // and a hard clear makes spectrum-driven themes strobe.
        for i in latchedSpectrum.indices { latchedSpectrum[i] *= 0.55 }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        switch phase {
        case .live:
            renderTheme(in: ctx)
        case .warming:
            // No theme while waiting — its appearance IS the "talk now"
            // signal, which a dimmed rendering muddied on themes whose idle
            // motion looks like their live one (starfields). Dots appear
            // after a grace delay, so a mic that goes live quickly never
            // shows the explicit "wait" treatment.
            let breath = 0.5 + 0.5 * sin(time * 3.0)
            let fade = min(1, max(0, (time - phaseStart - 0.18) / 0.25))
            if fade > 0 {
                drawWaitBackdrop(in: ctx, alpha: fade)
                let pulse = 0.55 + 0.4 * breath
                drawDots(in: ctx, alphas: [CGFloat](repeating: pulse * fade, count: 3))
            }
        case .processing:
            let fade = min(1, max(0, (time - phaseStart) / 0.2))
            drawWaitBackdrop(in: ctx, alpha: fade)
            // Left-to-right chase: indeterminate "working", distinct from
            // the warming state's in-unison pulse.
            let alphas = (0..<3).map { i -> CGFloat in
                let wave = max(0, sin(time * 5.0 - CGFloat(i) * 1.1))
                return (0.4 + 0.55 * wave) * fade
            }
            drawDots(in: ctx, alphas: alphas)
        }
    }

    /// Dark capsule behind the waiting dots. The waiting states hide the
    /// theme, and several themes draw their own background — without this
    /// the dots sit directly on the desktop and can disappear against it.
    private func drawWaitBackdrop(in ctx: CGContext, alpha: CGFloat) {
        let capsule = CGRect(x: bounds.midX - 48, y: bounds.midY - 16,
                             width: 96, height: 32)
        let path = CGPath(roundedRect: capsule, cornerWidth: 16,
                          cornerHeight: 16, transform: nil)
        ctx.saveGState()
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.55 * alpha).cgColor)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.restoreGState()
    }

    private func renderTheme(in ctx: CGContext) {
        renderer.render(in: ctx, bounds: bounds, t: time, dt: 1.0 / 30.0,
                        level: frameLevel, spectrum: frameSpectrum)
    }

    /// Three small dots centered in the HUD — the shared theme-agnostic
    /// vocabulary for both waiting states. The soft shadow keeps them
    /// readable when a bare theme puts them straight over a light desktop.
    private func drawDots(in ctx: CGContext, alphas: [CGFloat]) {
        let radius: CGFloat = 4
        let spacing: CGFloat = 17
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 4,
                      color: NSColor.black.withAlphaComponent(0.5).cgColor)
        for (i, alpha) in alphas.enumerated() {
            let x = bounds.midX + (CGFloat(i) - 1) * spacing
            ctx.setFillColor(NSColor.white.withAlphaComponent(alpha).cgColor)
            ctx.fillEllipse(in: CGRect(x: x - radius, y: bounds.midY - radius,
                                       width: radius * 2, height: radius * 2))
        }
        ctx.restoreGState()
    }
}
