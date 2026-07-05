import AppKit

/// Floating "listening" HUD shown while the hotkey is held: a non-activating,
/// click-through panel at the bottom-center of the screen. The visual itself
/// is whichever HudTheme the user picked — a frosted capsule for most themes,
/// borderless for the ones that draw straight over the desktop.
final class WaveformOverlay {
    private let panel: NSPanel
    private var hudView: HudView
    private var theme: HudTheme
    private var hideGeneration = 0
    private var previewTimer: Timer?

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
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false

        hudView = HudView(frame: NSRect(origin: .zero, size: theme.size),
                          renderer: theme.makeRenderer())
        applyTheme(theme)
    }

    private func applyTheme(_ newTheme: HudTheme) {
        hudView.stopAnimating() // the outgoing view's timer must not outlive it
        theme = newTheme
        let size = newTheme.size
        panel.setContentSize(size)
        let bounds = NSRect(origin: .zero, size: size)

        let container: NSView
        if newTheme.isBare {
            container = NSView(frame: bounds)
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
            container = blur
        }

        hudView = HudView(frame: bounds, renderer: newTheme.makeRenderer())
        hudView.autoresizingMask = [.width, .height]
        container.addSubview(hudView)
        panel.contentView = container
    }

    /// Thread-safe: callable from the audio capture thread.
    func push(level: Float) {
        DispatchQueue.main.async { [weak self] in
            self?.hudView.ingest(level: level)
        }
    }

    /// Thread-safe: callable from the audio capture thread.
    func push(spectrum: [Float]) {
        DispatchQueue.main.async { [weak self] in
            self?.hudView.ingest(spectrum: spectrum)
        }
    }

    func show() {
        cancelPreview()
        present()
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
            // Skip the orderOut if show() ran again during the fade.
            guard let self, self.hideGeneration == generation else { return }
            self.panel.orderOut(nil)
        })
    }

    private func present() {
        if HudTheme.current != theme {
            applyTheme(HudTheme.current)
        }
        hideGeneration += 1
        guard let screen = NSScreen.main else { return }
        let x = screen.visibleFrame.midX - panel.frame.width / 2
        let y = screen.visibleFrame.minY + 64
        panel.setFrameOrigin(NSPoint(x: x, y: y))

        hudView.reset()
        hudView.startAnimating()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }
    }

    // MARK: - Menu preview

    /// Shows the HUD for a few seconds fed by synthesized "speech" so a theme
    /// picked from the menu can be judged without dictating anything.
    func preview() {
        cancelPreview()
        present()
        let start = Date()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
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

    private let renderer: HudRenderer
    private var latchedLevel: CGFloat = 0
    private var latchedSpectrum = [CGFloat](repeating: 0, count: 12)
    private var frameLevel: CGFloat = 0
    private var frameSpectrum = [CGFloat](repeating: 0, count: 12)
    private var agcReference: CGFloat = 0.0035
    private var time: CGFloat = 0
    private var timer: Timer?

    init(frame: NSRect, renderer: HudRenderer) {
        self.renderer = renderer
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func ingest(level: Float) {
        latchedLevel = max(latchedLevel, CGFloat(level))
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

    func reset() {
        time = 0
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
            self?.tick()
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
        renderer.render(in: ctx, bounds: bounds, t: time, dt: 1.0 / 30.0,
                        level: frameLevel, spectrum: frameSpectrum)
    }
}
