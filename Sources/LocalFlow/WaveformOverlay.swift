import AppKit

/// Floating "listening" pill shown while the hotkey is held: a frosted-glass
/// capsule at the bottom-center of the screen with an organic, flowing
/// waveform driven by the live mic level. Non-activating and click-through,
/// so it never steals focus from the app being dictated into.
final class WaveformOverlay {
    private let panel: NSPanel
    private let waveView: WaveformView
    private var hideGeneration = 0

    init() {
        let size = NSSize(width: 280, height: 64)
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
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

        let bounds = NSRect(origin: .zero, size: size)
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

        waveView = WaveformView(frame: bounds)
        waveView.autoresizingMask = [.width, .height]
        blur.addSubview(waveView)
        panel.contentView = blur
    }

    /// Thread-safe: callable from the audio capture thread.
    func push(level: Float) {
        DispatchQueue.main.async { [waveView] in
            waveView.latestLevel = max(waveView.latestLevel, level)
        }
    }

    func show() {
        hideGeneration += 1
        guard let screen = NSScreen.main else { return }
        let x = screen.visibleFrame.midX - panel.frame.width / 2
        let y = screen.visibleFrame.minY + 64
        panel.setFrameOrigin(NSPoint(x: x, y: y))

        waveView.reset()
        waveView.startAnimating()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        hideGeneration += 1
        let generation = hideGeneration
        waveView.stopAnimating()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // Skip the orderOut if show() ran again during the fade.
            guard let self, self.hideGeneration == generation else { return }
            self.panel.orderOut(nil)
        })
    }
}

/// Organic waveform: the mic-level history becomes a smooth, mirrored curve
/// (quadratic midpoint smoothing) filled with a teal→violet gradient and a
/// soft glow. A time-based wobble keeps it fluid, and a low "breathing"
/// ripple keeps it alive during silence. Scrolls right-to-left at 30 fps.
private final class WaveformView: NSView {
    var latestLevel: Float = 0

    private static let pointCount = 56
    private static let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.25, green: 0.87, blue: 0.82, alpha: 1.0), // teal
        NSColor(calibratedRed: 0.42, green: 0.94, blue: 0.68, alpha: 1.0), // mint
        NSColor(calibratedRed: 0.55, green: 0.62, blue: 0.97, alpha: 1.0), // periwinkle
        NSColor(calibratedRed: 0.76, green: 0.52, blue: 0.95, alpha: 1.0), // orchid
    ])!
    private static let glowColor = NSColor(calibratedRed: 0.30, green: 0.85, blue: 0.80, alpha: 0.55)

    private var levels = [CGFloat](repeating: 0, count: WaveformView.pointCount)
    private var smoothed: CGFloat = 0
    private var time: CGFloat = 0
    private var timer: Timer?

    func reset() {
        levels = [CGFloat](repeating: 0, count: Self.pointCount)
        smoothed = 0
        latestLevel = 0
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
        let target = CGFloat(min(1, latestLevel))
        latestLevel = 0
        smoothed = target > smoothed
            ? smoothed + (target - smoothed) * 0.7
            : smoothed * 0.78
        levels.removeFirst()
        levels.append(smoothed)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let maxAmplitude = (bounds.height - 24) / 2

        // Faint echo wave behind the main one for depth.
        let echo = wavePath(amplitudeScale: 1.35, maxAmplitude: maxAmplitude)
        NSColor(calibratedRed: 0.45, green: 0.75, blue: 0.95, alpha: 0.18).setFill()
        echo.fill()

        let wave = wavePath(amplitudeScale: 1.0, maxAmplitude: maxAmplitude)

        // Glow pass: solid fill with a heavy shadow, then gradient on top.
        context.saveGState()
        context.setShadow(offset: .zero, blur: 14, color: Self.glowColor.cgColor)
        NSColor(calibratedRed: 0.30, green: 0.85, blue: 0.80, alpha: 0.9).setFill()
        wave.fill()
        context.restoreGState()

        Self.gradient.draw(in: wave, angle: 0)
    }

    /// Closed, mirrored, smoothed path around the vertical center line.
    private func wavePath(amplitudeScale: CGFloat, maxAmplitude: CGFloat) -> NSBezierPath {
        let n = levels.count
        let inset: CGFloat = 26
        let step = (bounds.width - inset * 2) / CGFloat(n - 1)
        let midY = bounds.midY

        var top: [NSPoint] = []
        var bottom: [NSPoint] = []
        top.reserveCapacity(n)
        bottom.reserveCapacity(n)

        for i in 0..<n {
            let u = CGFloat(i) / CGFloat(n - 1)
            // Taper into the capsule ends so the wave never hits the border.
            let envelope = pow(sin(.pi * u), 0.85)
            // Slow shimmer so the shape never looks frozen mid-word.
            let wobble = 0.82 + 0.18 * sin(time * 2.6 + CGFloat(i) * 0.45)
            // Idle ripple: a quiet room still gets a living, breathing line.
            let breathing = (2.2 + 1.4 * sin(time * 2.0 + CGFloat(i) * 0.30)) * envelope
            let amplitude = max(
                breathing,
                levels[i] * maxAmplitude * envelope * wobble * amplitudeScale
            )
            let x = inset + CGFloat(i) * step
            top.append(NSPoint(x: x, y: midY + amplitude))
            bottom.append(NSPoint(x: x, y: midY - amplitude))
        }

        let path = NSBezierPath()
        path.move(to: top[0])
        addSmoothCurve(to: path, through: top)
        path.line(to: bottom[n - 1])
        addSmoothCurve(to: path, through: bottom.reversed())
        path.close()
        return path
    }

    /// Quadratic midpoint smoothing: each point becomes a control point and
    /// the curve passes through segment midpoints — no corners, ever.
    private func addSmoothCurve(to path: NSBezierPath, through points: [NSPoint]) {
        guard points.count > 2 else {
            points.dropFirst().forEach { path.line(to: $0) }
            return
        }
        for i in 1..<(points.count - 1) {
            let control = points[i]
            let target = i == points.count - 2
                ? points[i + 1]
                : NSPoint(x: (points[i].x + points[i + 1].x) / 2,
                          y: (points[i].y + points[i + 1].y) / 2)
            // Quadratic → cubic: control points at 2/3 toward the quad control.
            let current = path.currentPoint
            let c1 = NSPoint(x: current.x + (control.x - current.x) * 2 / 3,
                             y: current.y + (control.y - current.y) * 2 / 3)
            let c2 = NSPoint(x: target.x + (control.x - target.x) * 2 / 3,
                             y: target.y + (control.y - target.y) * 2 / 3)
            path.curve(to: target, controlPoint1: c1, controlPoint2: c2)
        }
    }
}
