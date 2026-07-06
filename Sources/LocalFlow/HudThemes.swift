import AppKit

// MARK: - Theme registry

/// Every listening-HUD design the user can pick from the menu bar. Each is a
/// self-contained Core Graphics renderer driven by the live mic level and a
/// coarse 12-band spectrum; the overlay panel adapts its size and chrome
/// (frosted capsule vs. borderless) to the theme.
enum HudTheme: String, CaseIterable {
    case classic, typeset, aurora, bolide, mercury, ticker
    case constellation, loom, vapor, sonar, shorthand
    case prism, murmuration, filament, bloom, pianola

    static var current: HudTheme {
        HudTheme(rawValue: Settings.hudTheme) ?? .classic
    }

    var label: String {
        switch self {
        case .classic: return "Classic Wave"
        case .typeset: return "Typeset — molten ink"
        case .aurora: return "Aurora — spectrogram"
        case .bolide: return "Bolide — comet"
        case .mercury: return "Mercury — liquid metal"
        case .ticker: return "Ticker — chart recorder"
        case .constellation: return "Constellation — star chart"
        case .loom: return "Loom — woven thread"
        case .vapor: return "Vapor — breath"
        case .sonar: return "Sonar — echo pings"
        case .shorthand: return "Shorthand — pen loops"
        case .prism: return "Prism — split light"
        case .murmuration: return "Murmuration — starlings"
        case .filament: return "Filament — electric arc"
        case .bloom: return "Bloom — vine"
        case .pianola: return "Pianola — piano roll"
        }
    }

    var size: NSSize {
        switch self {
        case .classic: return NSSize(width: 280, height: 64)
        case .typeset: return NSSize(width: 340, height: 58)
        case .aurora: return NSSize(width: 320, height: 64)
        case .bolide: return NSSize(width: 430, height: 88)
        case .mercury: return NSSize(width: 300, height: 62)
        case .ticker: return NSSize(width: 330, height: 58)
        case .constellation: return NSSize(width: 340, height: 64)
        case .loom: return NSSize(width: 320, height: 60)
        case .vapor: return NSSize(width: 410, height: 90)
        case .sonar: return NSSize(width: 320, height: 64)
        case .shorthand: return NSSize(width: 340, height: 58)
        case .prism: return NSSize(width: 330, height: 64)
        case .murmuration: return NSSize(width: 430, height: 92)
        case .filament: return NSSize(width: 340, height: 56)
        case .bloom: return NSSize(width: 340, height: 62)
        case .pianola: return NSSize(width: 330, height: 58)
        }
    }

    /// Bare themes draw straight over the desktop with no frosted capsule.
    var isBare: Bool {
        switch self {
        case .bolide, .vapor, .murmuration: return true
        default: return false
        }
    }

    func makeRenderer() -> HudRenderer {
        switch self {
        case .classic: return ClassicRenderer()
        case .typeset: return TypesetRenderer()
        case .aurora: return AuroraRenderer()
        case .bolide: return BolideRenderer()
        case .mercury: return MercuryRenderer()
        case .ticker: return TickerRenderer()
        case .constellation: return ConstellationRenderer()
        case .loom: return LoomRenderer()
        case .vapor: return VaporRenderer()
        case .sonar: return SonarRenderer()
        case .shorthand: return ShorthandRenderer()
        case .prism: return PrismRenderer()
        case .murmuration: return MurmurationRenderer()
        case .filament: return FilamentRenderer()
        case .bloom: return BloomRenderer()
        case .pianola: return PianolaRenderer()
        }
    }
}

/// One frame of drawing. The context comes from a flipped NSView, so the
/// coordinate system is y-down (like the design prototypes). `level` is the
/// latched 0…1 loudness for this tick; `spectrum` is 12 normalized band
/// energies, low frequencies first.
protocol HudRenderer: AnyObject {
    func reset()
    func render(in ctx: CGContext, bounds: CGRect, t: CGFloat, dt: CGFloat,
                level: CGFloat, spectrum: [CGFloat])
}

// MARK: - Synthesized speech (for previews)

/// Speech-shaped fake mic input: syllable bursts inside phrases with natural
/// pauses. Drives the menu-bar preview and the settings-window theme gallery,
/// and matches the prototype the themes were designed against.
enum SyntheticSpeech {
    static func level(at t: Double) -> Float {
        let period = 3.4
        let phase = t.truncatingRemainder(dividingBy: period)
        if phase > 2.5 {
            return Float(0.02 + 0.012 * (0.5 + 0.5 * sin(t * 7)))
        }
        let syllable = max(0, sin(phase * 2 * .pi * 3.6 + sin(t * 0.9) * 1.7))
        let word = (t / period).rounded(.down)
        let stress = 0.6 + 0.4 * sin(phase * 2.3 + word * 1.7)
        let jitter = 0.86 + 0.28 * Double.random(in: 0...1)
        return Float(min(1, (0.10 + 0.9 * pow(syllable, 1.6)) * stress * jitter))
    }

    static func spectrum(at t: Double, level: Float) -> [Float] {
        let bands = 12
        var out = [Float](repeating: 0, count: bands)
        for b in 0..<bands {
            let tilt = pow(1 - Double(b) / Double(bands), 0.9) * 0.75 + 0.22
            let osc = 0.42 + 0.58 * abs(sin(t * (1.3 + Double(b) * 0.7) + Double(b) * 2.1))
            let formant = exp(-pow(Double(b) - (3 + 2.5 * sin(t * 0.6)), 2) / 6)
            out[b] = Float(min(1, Double(level) * (tilt * osc + formant * 0.9 * Double(level))))
        }
        return out
    }
}

// MARK: - Shared drawing helpers

struct HudColor {
    var r: CGFloat, g: CGFloat, b: CGFloat // 0…255

    init(_ hexStr: String) {
        var v: UInt64 = 0
        Scanner(string: String(hexStr.dropFirst())).scanHexInt64(&v)
        r = CGFloat((v >> 16) & 0xFF)
        g = CGFloat((v >> 8) & 0xFF)
        b = CGFloat(v & 0xFF)
    }

    init(r: CGFloat, g: CGFloat, b: CGFloat) {
        self.r = r; self.g = g; self.b = b
    }

    func cg(_ alpha: CGFloat) -> CGColor {
        CGColor(red: r / 255, green: g / 255, blue: b / 255, alpha: alpha)
    }

    static func lerp(_ a: HudColor, _ b: HudColor, _ u: CGFloat) -> HudColor {
        let k = min(1, max(0, u))
        return HudColor(r: a.r + (b.r - a.r) * k,
                        g: a.g + (b.g - a.g) * k,
                        b: a.b + (b.b - a.b) * k)
    }
}

struct HudRamp {
    let stops: [(CGFloat, HudColor)]

    init(_ stops: [(CGFloat, String)]) {
        self.stops = stops.map { ($0.0, HudColor($0.1)) }
    }

    func at(_ u: CGFloat) -> HudColor {
        let x = min(1, max(0, u))
        for i in 1..<stops.count where x <= stops[i].0 {
            let (p0, c0) = stops[i - 1]
            let (p1, c1) = stops[i]
            let span = max(0.0001, p1 - p0)
            return HudColor.lerp(c0, c1, (x - p0) / span)
        }
        return stops[stops.count - 1].1
    }
}

/// Quadratic midpoint smoothing — the same curve the classic wave has always
/// used, on a CGMutablePath. Caller must have already moved to points[0].
func hudSmoothPath(_ path: CGMutablePath, through points: [CGPoint]) {
    guard points.count > 2 else {
        points.dropFirst().forEach { path.addLine(to: $0) }
        return
    }
    for i in 1..<(points.count - 1) {
        let control = points[i]
        let target = i == points.count - 2
            ? points[i + 1]
            : CGPoint(x: (points[i].x + points[i + 1].x) / 2,
                      y: (points[i].y + points[i + 1].y) / 2)
        path.addQuadCurve(to: target, control: control)
    }
}

func hudLinearGradient(_ ctx: CGContext, from: CGPoint, to: CGPoint,
                       stops: [(CGFloat, CGColor)], clippedTo path: CGPath? = nil) {
    guard let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: stops.map { $0.1 } as CFArray,
        locations: stops.map { $0.0 }
    ) else { return }
    ctx.saveGState()
    if let path {
        ctx.addPath(path)
        ctx.clip()
    }
    // Extend past both endpoints: without this, anything beyond the gradient's
    // start/end planes is left unpainted (bit the icon's squircle corner).
    ctx.drawLinearGradient(gradient, start: from, end: to,
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

func hudRadialGlow(_ ctx: CGContext, center: CGPoint, radius: CGFloat,
                   stops: [(CGFloat, CGColor)]) {
    guard let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: stops.map { $0.1 } as CFArray,
        locations: stops.map { $0.0 }
    ) else { return }
    ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                           endCenter: center, endRadius: radius, options: [])
}

/// Per-frame voice features derived from the 12-band spectrum — the shared
/// vocabulary every pitch-reactive renderer keys off instead of timers or
/// dice. `centroid` is the energy-weighted mean band, 0…1 (0 = low-pitched,
/// 1 = high-pitched/bright); `low`/`mid`/`high` are the summed energies of
/// the bottom, middle, and top four bands. Twelve bands — trivially cheap.
///
/// `onset` is a real syllable detector, not a level threshold. A fixed
/// crossing goes blind during fast speech (the level never dips between
/// syllables, so a whole phrase fires once); instead each frame sums the
/// rectified spectral flux — the positive band-to-band deltas since the
/// previous frame — which spikes on every re-articulation even when overall
/// loudness stays high. An onset fires when flux clears an adaptive gate: a
/// fast-decaying peak envelope of recent flux (≈98% gone per second) times a
/// margin, plus an absolute floor so a quiet room stays silent, with a short
/// refractory so fast speech reads as one ping per syllable, not a smear.
/// Stateful — one instance per renderer, `reset()` alongside the renderer.
struct VoiceFeatures {
    private(set) var centroid: CGFloat = 0.5
    private(set) var low: CGFloat = 0
    private(set) var mid: CGFloat = 0
    private(set) var high: CGFloat = 0
    private(set) var onset = false
    /// How hard the syllable hit, 0…1: how far the flux spike cleared its
    /// adaptive gate (flux at 4× the gate saturates to 1). Every
    /// emission-driven theme sizes AND paces its emission from this — a weak
    /// onset spawns a small, slow-radiating emission, a strong one a big,
    /// quick one — so the same voice reads the same across themes. Only
    /// meaningful on frames where `onset` is true; zero otherwise.
    private(set) var onsetStrength: CGFloat = 0

    private var previousBands = [CGFloat](repeating: 0, count: 12)
    private var fluxEnvelope: CGFloat = 0
    private var lastOnset: CGFloat = -9

    mutating func reset() { self = VoiceFeatures() }

    /// Call once per frame, before reading any feature.
    mutating func update(t: CGFloat, dt: CGFloat, level: CGFloat, spectrum: [CGFloat]) {
        var num: CGFloat = 0, den: CGFloat = 0
        var lo: CGFloat = 0, mi: CGFloat = 0, hi: CGFloat = 0
        var flux: CGFloat = 0
        for (i, e) in spectrum.enumerated() {
            num += CGFloat(i) * e
            den += e
            if i < 4 { lo += e } else if i < 8 { mi += e } else { hi += e }
            if i < previousBands.count {
                flux += max(0, e - previousBands[i])
                previousBands[i] = e
            }
        }
        low = lo; mid = mi; high = hi
        centroid = den > 0.001 && spectrum.count > 1
            ? num / den / CGFloat(spectrum.count - 1)
            : 0.5

        // Gate against the pre-update envelope so a syllable only has to beat
        // the *recent* flux, then fold the current flux back in.
        fluxEnvelope *= pow(0.02, dt)
        let gate = max(0.15, fluxEnvelope * 1.4)
        onset = t - lastOnset > 0.1 && level > 0.15 && flux > gate
        if onset {
            lastOnset = t
            // Ratio above the gate, so mid-speech re-articulations (which
            // fight a raised envelope) still span the range instead of every
            // first-word attack pinning strength at 1.
            onsetStrength = min(1, (flux / gate - 1) / 3)
        } else {
            onsetStrength = 0
        }
        fluxEnvelope = max(fluxEnvelope, flux)
    }
}

// MARK: - Classic (the original organic wave)

final class ClassicRenderer: HudRenderer {
    private static let pointCount = 56
    private var levels = [CGFloat](repeating: 0, count: ClassicRenderer.pointCount)
    private var smoothed: CGFloat = 0

    func reset() {
        levels = [CGFloat](repeating: 0, count: Self.pointCount)
        smoothed = 0
    }

    func render(in ctx: CGContext, bounds: CGRect, t: CGFloat, dt: CGFloat,
                level: CGFloat, spectrum: [CGFloat]) {
        let target = min(1, level)
        smoothed = target > smoothed
            ? smoothed + (target - smoothed) * 0.7
            : smoothed * 0.78
        levels.removeFirst()
        levels.append(smoothed)

        let scale = bounds.height / 64
        let maxAmplitude = (bounds.height - 24 * scale) / 2

        func wavePath(amplitudeScale: CGFloat) -> CGPath {
            let n = levels.count
            let inset: CGFloat = 26 * (bounds.width / 280)
            let step = (bounds.width - inset * 2) / CGFloat(n - 1)
            let midY = bounds.midY
            var top: [CGPoint] = []
            var bottom: [CGPoint] = []
            for i in 0..<n {
                let u = CGFloat(i) / CGFloat(n - 1)
                let envelope = pow(sin(.pi * u), 0.85)
                let wobble = 0.82 + 0.18 * sin(t * 2.6 + CGFloat(i) * 0.45)
                let breathing = (2.2 + 1.4 * sin(t * 2.0 + CGFloat(i) * 0.30)) * envelope * scale
                let amplitude = max(breathing, levels[i] * maxAmplitude * envelope * wobble * amplitudeScale)
                let x = inset + CGFloat(i) * step
                top.append(CGPoint(x: x, y: midY - amplitude))
                bottom.append(CGPoint(x: x, y: midY + amplitude))
            }
            let path = CGMutablePath()
            path.move(to: top[0])
            hudSmoothPath(path, through: top)
            path.addLine(to: bottom[bottom.count - 1])
            hudSmoothPath(path, through: bottom.reversed())
            path.closeSubpath()
            return path
        }

        // Faint echo behind the main wave.
        ctx.addPath(wavePath(amplitudeScale: 1.35))
        ctx.setFillColor(CGColor(red: 0.45, green: 0.75, blue: 0.95, alpha: 0.18))
        ctx.fillPath()

        let wave = wavePath(amplitudeScale: 1.0)

        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 14,
                      color: CGColor(red: 0.30, green: 0.85, blue: 0.80, alpha: 0.55))
        ctx.addPath(wave)
        ctx.setFillColor(CGColor(red: 0.30, green: 0.85, blue: 0.80, alpha: 0.9))
        ctx.fillPath()
        ctx.restoreGState()

        hudLinearGradient(
            ctx,
            from: CGPoint(x: 0, y: 0), to: CGPoint(x: bounds.width, y: 0),
            stops: [
                (0.00, HudColor("#40DED1").cg(1)),
                (0.35, HudColor("#6BF0AE").cg(1)),
                (0.68, HudColor("#8C9EF8").cg(1)),
                (1.00, HudColor("#C285F2").cg(1)),
            ],
            clippedTo: wave
        )
    }
}

// MARK: - Typeset (molten strokes settle into an ink ribbon)

final class TypesetRenderer: HudRenderer {
    private var hist: [CGFloat] = []
    private let maxHist = 400
    private let speed: CGFloat = 1.9
    private let wetFrames = 46
    private let molten = HudRamp([(0, "#FFC46B"), (0.4, "#FF7E63"), (0.7, "#F65E8E"), (1, "#B07CF7")])

    func reset() { hist = [] }

    func render(in ctx: CGContext, bounds: CGRect, t: CGFloat, dt: CGFloat,
                level: CGFloat, spectrum: [CGFloat]) {
        hist.insert(level, at: 0)
        if hist.count > maxHist { hist.removeLast() }

        let penX = bounds.width - 44
        let base = bounds.height * 0.60
        let leftEdge: CGFloat = 22

        struct Entry { var x: CGFloat; var thickness: CGFloat; var wet: CGFloat; var lv: CGFloat }
        var entries: [Entry] = []
        for (i, lv) in hist.enumerated() {
            let x = penX - CGFloat(i) * speed
            if x < leftEdge { break }
            let wet = max(0, 1 - CGFloat(i) / CGFloat(wetFrames))
            let thickness = (1.4 + lv * 4.6) * (1 - wet * 0.85) + 0.8
            entries.append(Entry(x: x, thickness: thickness, wet: wet, lv: lv))
        }

        // Settled ink ribbon.
        if entries.count > 2 {
            let tops = entries.map { CGPoint(x: $0.x, y: base - $0.thickness / 2) }
            let bots = entries.map { CGPoint(x: $0.x, y: base + $0.thickness / 2) }
            let ribbon = CGMutablePath()
            ribbon.move(to: tops[0])
            hudSmoothPath(ribbon, through: tops)
            ribbon.addLine(to: bots[bots.count - 1])
            hudSmoothPath(ribbon, through: bots.reversed())
            ribbon.closeSubpath()
            hudLinearGradient(
                ctx,
                from: CGPoint(x: leftEdge, y: 0), to: CGPoint(x: penX, y: 0),
                stops: [
                    (0.00, HudColor("#F4E9D4").cg(0.85)),
                    (0.72, HudColor("#F4E9D4").cg(0.95)),
                    (1.00, HudColor("#FFC46B").cg(1.0)),
                ],
                clippedTo: ribbon
            )
        }

        // Wet zone: colorful flicks cooling toward the ribbon.
        ctx.saveGState()
        ctx.setLineCap(.round)
        for entry in entries.prefix(wetFrames) {
            if entry.lv < 0.05 { continue }
            let flick = entry.lv * bounds.height * 0.38 * entry.wet
            if flick < 1.5 { continue }
            let c = molten.at(entry.lv * 0.65 + (1 - entry.wet) * 0.5)
            ctx.setStrokeColor(c.cg(0.28 + 0.72 * entry.wet))
            ctx.setLineWidth(2.2)
            ctx.setShadow(offset: .zero, blur: 7, color: c.cg(0.6 * entry.wet))
            ctx.move(to: CGPoint(x: entry.x, y: base + 2))
            ctx.addLine(to: CGPoint(x: entry.x, y: base - flick))
            ctx.strokePath()
        }
        ctx.restoreGState()

        // Writing caret.
        let on: CGFloat = t.truncatingRemainder(dividingBy: 1.1) < 0.62 ? 1 : 0.15
        let glow = min(1, level * 2.2)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 6 + glow * 10,
                      color: HudColor("#FFC46B").cg(0.35 + glow * 0.55))
        ctx.setFillColor(HudColor("#FFD68C").cg(on * (0.75 + glow * 0.25)))
        let caret = CGPath(roundedRect: CGRect(x: penX + 7, y: base - 12, width: 2.6, height: 24),
                           cornerWidth: 1.3, cornerHeight: 1.3, transform: nil)
        ctx.addPath(caret)
        ctx.fillPath()
        ctx.restoreGState()
    }
}

// MARK: - Aurora (scrolling spectrogram curtains)

final class AuroraRenderer: HudRenderer {
    private let cols = 110
    private let bands = 12
    private var history: [[CGFloat]] = []
    private var bandColors: [HudColor] = []

    init() {
        let ramp = HudRamp([(0, "#3AF0A0"), (0.34, "#3DD6F5"), (0.64, "#6E7BFF"), (1, "#D96BFF")])
        bandColors = (0..<bands).map { ramp.at(CGFloat($0) / CGFloat(bands - 1)) }
    }

    func reset() { history = [] }

    func render(in ctx: CGContext, bounds: CGRect, t: CGFloat, dt: CGFloat,
                level: CGFloat, spectrum: [CGFloat]) {
        history.insert(spectrum, at: 0)
        if history.count > cols { history.removeLast() }

        // Tiny bitmap, scaled up with interpolation for the soft curtain look.
        var pix = [UInt8](repeating: 0, count: cols * bands * 4)
        for x in 0..<cols {
            let age = cols - 1 - x // rightmost pixel = newest column
            let column = age < history.count ? history[age] : nil
            let fresh = 1 - CGFloat(age) / CGFloat(cols)
            for y in 0..<bands {
                let band = bands - 1 - y // low frequencies at the bottom
                let energy = column?[band] ?? 0
                let alpha = min(1, energy * (0.30 + 0.70 * fresh) * 1.5)
                let c = bandColors[band]
                let idx = (y * cols + x) * 4
                pix[idx] = UInt8(c.r * alpha)
                pix[idx + 1] = UInt8(c.g * alpha)
                pix[idx + 2] = UInt8(c.b * alpha)
                pix[idx + 3] = UInt8(alpha * 255)
            }
        }
        guard let provider = CGDataProvider(data: Data(pix) as CFData),
              let image = CGImage(
                  width: cols, height: bands, bitsPerComponent: 8, bitsPerPixel: 32,
                  bytesPerRow: cols * 4, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: true,
                  intent: .defaultIntent
              ) else { return }

        let rect = CGRect(x: 20, y: 8, width: bounds.width - 40, height: bounds.height - 16)
        // Double-flip so image row 0 lands at the rect's top in this flipped view.
        func drawCurtain(_ r: CGRect, alpha: CGFloat) {
            ctx.saveGState()
            ctx.setAlpha(alpha)
            ctx.translateBy(x: 0, y: r.minY + r.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: r)
            ctx.restoreGState()
        }
        drawCurtain(rect, alpha: 1)
        ctx.saveGState()
        ctx.setBlendMode(.plusLighter)
        drawCurtain(CGRect(x: 20, y: 6, width: bounds.width - 40, height: bounds.height - 12), alpha: 0.55)
        ctx.restoreGState()

        // Fade the trailing edge and feather top/bottom.
        ctx.saveGState()
        ctx.setBlendMode(.destinationOut)
        hudLinearGradient(ctx, from: .zero, to: CGPoint(x: bounds.width * 0.35, y: 0),
                          stops: [(0, CGColor(gray: 0, alpha: 1)), (1, CGColor(gray: 0, alpha: 0))],
                          clippedTo: CGPath(rect: CGRect(x: 0, y: 0, width: bounds.width * 0.35, height: bounds.height), transform: nil))
        hudLinearGradient(ctx, from: .zero, to: CGPoint(x: 0, y: 10),
                          stops: [(0, CGColor(gray: 0, alpha: 0.9)), (1, CGColor(gray: 0, alpha: 0))],
                          clippedTo: CGPath(rect: CGRect(x: 0, y: 0, width: bounds.width, height: 10), transform: nil))
        hudLinearGradient(ctx, from: CGPoint(x: 0, y: bounds.height - 10), to: CGPoint(x: 0, y: bounds.height),
                          stops: [(0, CGColor(gray: 0, alpha: 0)), (1, CGColor(gray: 0, alpha: 0.9))],
                          clippedTo: CGPath(rect: CGRect(x: 0, y: bounds.height - 10, width: bounds.width, height: 10), transform: nil))
        ctx.restoreGState()

        // Bright leading line at the newest column.
        let lead = min(1, level * 2.5)
        ctx.setFillColor(HudColor("#BEFFE6").cg(0.12 + lead * 0.5))
        ctx.fill(CGRect(x: bounds.width - 22, y: 10, width: 1.6, height: bounds.height - 20))
    }
}

// MARK: - Bolide (particle comet, color encodes age)

final class BolideRenderer: HudRenderer {
    private struct Particle {
        var x, y, vx, vy, life, age, radius: CGFloat
    }
    private var particles: [Particle] = []
    private var smoothed: CGFloat = 0
    private var emitCarry: CGFloat = 0
    private var voice = VoiceFeatures()
    private let cool = HudRamp([(0, "#FFF7E8"), (0.22, "#FFC46B"), (0.5, "#FF6B5E"), (0.78, "#8B6BFF"), (1, "#3D4E8C")])

    func reset() {
        particles = []
        smoothed = 0
        emitCarry = 0
        voice.reset()
    }

    func render(in ctx: CGContext, bounds: CGRect, t: CGFloat, dt: CGFloat,
                level: CGFloat, spectrum: [CGFloat]) {
        smoothed += (level - smoothed) * (level > smoothed ? 0.5 : 0.06)
        voice.update(t: t, dt: dt, level: level, spectrum: spectrum)
        let headX = bounds.width - 64
        let headY = bounds.height / 2

        // Emission IS the voice: the stream rides the level, each syllable
        // onset kicks out a burst sized and paced by how hard it hit (a soft
        // onset sheds a few slow embers, a sharp one blasts fast sparks), and
        // idle is a constant faint drip (steady, never random, so it can't
        // read as speech). Pitch is a light accent on spark speed/chunkiness;
        // the scatter is just spray around a voice-driven emission point.
        let idle = level < 0.05
        emitCarry += (idle ? 3.5 : level * 16 * 60) * dt
        var births = Int(emitCarry)
        emitCarry -= CGFloat(births)
        if voice.onset { births += 3 + Int(voice.onsetStrength * 16) }
        let kick = voice.onset ? 0.75 + voice.onsetStrength * 0.7 : 1
        let pitch = voice.centroid
        for _ in 0..<births where particles.count < 650 {
            particles.append(Particle(
                x: headX + CGFloat.random(in: -3...3),
                y: headY + CGFloat.random(in: -7...7) * (0.3 + level),
                vx: -(50 + CGFloat.random(in: 0...330) * (0.25 + level) * (0.85 + 0.3 * pitch)) * kick,
                vy: CGFloat.random(in: -35...35) * (0.2 + level),
                life: 0.9 + CGFloat.random(in: 0...0.7),
                age: 0,
                radius: (0.9 + CGFloat.random(in: 0...2.1) * (0.4 + level)) * (1.15 - 0.3 * pitch) * kick
            ))
        }

        ctx.saveGState()
        ctx.setBlendMode(.plusLighter)
        var alive: [Particle] = []
        alive.reserveCapacity(particles.count)
        for var p in particles {
            p.age += dt
            if p.age >= p.life || p.x < -10 { continue }
            p.x += p.vx * dt
            p.y += p.vy * dt + sin(t * 3 + p.x * 0.05) * 6 * dt
            p.vy *= 0.99
            let u = p.age / p.life
            let c = cool.at(u)
            ctx.setFillColor(c.cg((1 - u) * 0.9))
            let r = p.radius * (1 - u * 0.55)
            ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
            alive.append(p)
        }
        particles = alive

        // The head.
        let R = 5 + smoothed * 15
        hudRadialGlow(ctx, center: CGPoint(x: headX, y: headY), radius: R * 2.6, stops: [
            (0.00, HudColor("#FFF7E8").cg(0.95)),
            (0.35, HudColor("#FFC46B").cg(0.55)),
            (1.00, HudColor("#FF785A").cg(0)),
        ])
        ctx.setFillColor(HudColor("#FFFBF0").cg(0.95))
        let core = 2.4 + smoothed * 3.4
        ctx.fillEllipse(in: CGRect(x: headX - core, y: headY - core, width: core * 2, height: core * 2))
        ctx.restoreGState()
    }
}

// MARK: - Mercury (liquid surface with iridescent sheen)

final class MercuryRenderer: HudRenderer {
    private let n = 72
    private var heights: [CGFloat]
    private var velocities: [CGFloat]

    init() {
        heights = [CGFloat](repeating: 0, count: n)
        velocities = [CGFloat](repeating: 0, count: n)
    }

    func reset() {
        heights = [CGFloat](repeating: 0, count: n)
        velocities = [CGFloat](repeating: 0, count: n)
    }

    func render(in ctx: CGContext, bounds: CGRect, t: CGFloat, dt: CGFloat,
                level: CGFloat, spectrum: [CGFloat]) {
        let h = bounds.height
        // Inject near the right; waves advect left.
        let src = n - 7
        heights[src] += (level * h * 0.30 - heights[src]) * 0.45
        heights[src - 1] += (level * h * 0.22 - heights[src - 1]) * 0.3
        for i in 1..<(n - 1) {
            velocities[i] += (heights[i - 1] + heights[i + 1] - 2 * heights[i]) * 0.30
        }
        for i in 0..<n {
            velocities[i] *= 0.955
            heights[i] += velocities[i]
            heights[i] *= 0.995
        }
        for i in 0..<(n - 1) {
            heights[i] += (heights[i + 1] - heights[i]) * 0.32
        }

        let baseY = h * 0.60
        let inset: CGFloat = 16
        let step = (bounds.width - inset * 2) / CGFloat(n - 1)
        var pts: [CGPoint] = []
        for i in 0..<n {
            let u = CGFloat(i) / CGFloat(n - 1)
            let envelope = pow(sin(.pi * u), 0.5)
            let idleRipple = sin(t * 1.4 + u * 9) * 1.1 * envelope
            let amp = max(-h * 0.3, min(h * 0.42, heights[i] * envelope))
            pts.append(CGPoint(x: inset + CGFloat(i) * step, y: baseY - amp - idleRipple))
        }

        let body = CGMutablePath()
        body.move(to: pts[0])
        hudSmoothPath(body, through: pts)
        body.addLine(to: CGPoint(x: bounds.width - inset, y: h - 8))
        body.addLine(to: CGPoint(x: inset, y: h - 8))
        body.closeSubpath()

        // Iridescent, slowly hue-shifting fill.
        var stops: [(CGFloat, CGColor)] = []
        let base = (t * 26).truncatingRemainder(dividingBy: 360)
        for s in 0...5 {
            let hue = (160 + (base + CGFloat(s) * 38).truncatingRemainder(dividingBy: 160)) / 360
            let color = NSColor(hue: hue, saturation: 0.55, brightness: 0.92, alpha: 0.88)
            stops.append((CGFloat(s) / 5, color.cgColor))
        }
        hudLinearGradient(ctx, from: CGPoint(x: 0, y: 0), to: CGPoint(x: bounds.width, y: 0),
                          stops: stops, clippedTo: body)
        // Depth shading.
        hudLinearGradient(ctx, from: CGPoint(x: 0, y: baseY - h * 0.3), to: CGPoint(x: 0, y: h),
                          stops: [(0, HudColor("#171A24").cg(0)), (1, HudColor("#171A24").cg(0.72))],
                          clippedTo: body)

        // Specular surface line, brighter toward the fresh (right) end.
        ctx.saveGState()
        ctx.setLineWidth(1.4)
        ctx.setLineCap(.round)
        for i in 1..<pts.count {
            let u = CGFloat(i) / CGFloat(pts.count - 1)
            let alpha = 0.05 + 0.7 * pow(u, 1.6)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: alpha))
            ctx.move(to: pts[i - 1])
            ctx.addLine(to: pts[i])
            ctx.strokePath()
        }
        ctx.restoreGState()
    }
}

// MARK: - Ticker (chart recorder tape, single ink trace)

final class TickerRenderer: HudRenderer {
    private var samples: [CGFloat] = []
    private let maxSamples = 600
    private var phase: CGFloat = 0
    private let speed: CGFloat = 2.1
    private var voice = VoiceFeatures()

    func reset() {
        samples = []
        phase = 0
        voice.reset()
    }

    func render(in ctx: CGContext, bounds: CGRect, t: CGFloat, dt: CGFloat,
                level: CGFloat, spectrum: [CGFloat]) {
        voice.update(t: t, dt: dt, level: level, spectrum: spectrum)
        // The pen draws the voice's actual waveform character: oscillation
        // frequency tracks the pitch (centroid), excursion tracks loudness.
        phase += dt * (18 + 130 * voice.centroid)
        var s = level * sin(phase) * (0.72 + 0.28 * sin(phase * 0.31))
        if level < 0.05 { s = 0.012 * sin(t * 6) }
        samples.insert(s, at: 0)
        if samples.count > maxSamples { samples.removeLast() }

        let pad: CGFloat = 9
        let tape = CGPath(roundedRect: CGRect(x: pad, y: pad, width: bounds.width - pad * 2, height: bounds.height - pad * 2),
                          cornerWidth: 7, cornerHeight: 7, transform: nil)
        hudLinearGradient(ctx, from: CGPoint(x: 0, y: pad), to: CGPoint(x: 0, y: bounds.height - pad),
                          stops: [(0, HudColor("#E6E0D2").cg(1)), (0.5, HudColor("#EDE7DA").cg(1)), (1, HudColor("#E2DBCC").cg(1))],
                          clippedTo: tape)

        ctx.saveGState()
        ctx.addPath(tape)
        ctx.clip()

        // Scrolling ruling.
        let offX = (t * 34).truncatingRemainder(dividingBy: 16)
        ctx.setStrokeColor(HudColor("#2E3038").cg(0.10))
        ctx.setLineWidth(1)
        var gx = bounds.width
        while gx > 0 {
            ctx.move(to: CGPoint(x: gx - offX, y: pad))
            ctx.addLine(to: CGPoint(x: gx - offX, y: bounds.height - pad))
            gx -= 16
        }
        ctx.strokePath()
        ctx.setStrokeColor(HudColor("#2E3038").cg(0.14))
        ctx.move(to: CGPoint(x: pad, y: bounds.height / 2))
        ctx.addLine(to: CGPoint(x: bounds.width - pad, y: bounds.height / 2))
        ctx.strokePath()

        // Ink trace.
        let penX = bounds.width - 30
        let mid = bounds.height / 2
        let amp = (bounds.height - pad * 2) * 0.40
        ctx.setStrokeColor(HudColor("#2E3038").cg(1))
        ctx.setLineWidth(1.7)
        ctx.setLineJoin(.round)
        var started = false
        for (i, sample) in samples.enumerated() {
            let x = penX - CGFloat(i) * speed
            if x < pad + 3 { break }
            let y = mid - sample * amp
            if !started {
                ctx.move(to: CGPoint(x: x, y: y))
                started = true
            } else {
                ctx.addLine(to: CGPoint(x: x, y: y))
            }
        }
        ctx.strokePath()

        // Red peak stamps.
        ctx.setFillColor(HudColor("#FF4D3D").cg(1))
        var j = 0
        while j < samples.count {
            if abs(samples[j]) > 0.58 {
                let px = penX - CGFloat(j) * speed
                if px < pad + 3 { break }
                let py = mid - samples[j] * amp
                ctx.fillEllipse(in: CGRect(x: px - 2.1, y: py - 2.1, width: 4.2, height: 4.2))
            }
            j += 2
        }

        // Pen head.
        let py = mid - (samples.first ?? 0) * amp
        ctx.move(to: CGPoint(x: penX + 9, y: py - 4))
        ctx.addLine(to: CGPoint(x: penX + 1.5, y: py))
        ctx.addLine(to: CGPoint(x: penX + 9, y: py + 4))
        ctx.closePath()
        ctx.fillPath()
        ctx.restoreGState()
    }
}

// MARK: - Constellation (syllables become stars, phrases link)

final class ConstellationRenderer: HudRenderer {
    private struct Star {
        var x, y, brightness: CGFloat
        var band: Int // the spectrum band the syllable lived in — its pulse source
        var phrase: Int
    }
    private var stars: [Star] = []
    private var phrase = 0
    private var lastOnset: CGFloat = -9
    private var voice = VoiceFeatures()

    func reset() {
        stars = []
        phrase = 0
        lastOnset = -9
        voice.reset()
    }

    func render(in ctx: CGContext, bounds: CGRect, t: CGFloat, dt: CGFloat,
                level: CGFloat, spectrum: [CGFloat]) {
        let speed: CGFloat = 34
        voice.update(t: t, dt: dt, level: level, spectrum: spectrum)
        if voice.onset {
            if t - lastOnset > 0.55 { phrase += 1 } // a real pause starts a new constellation
            // Star magnitude is the syllable's attack: a soft onset is a dim
            // pinprick, a hard one a bright flaring star. Pitch sets where in
            // the sky it lands (and which band relights it later).
            let c = voice.centroid
            stars.append(Star(
                x: bounds.width - 44,
                y: bounds.height * 0.80 - c * bounds.height * 0.58 + CGFloat.random(in: -3...3),
                brightness: 0.3 + voice.onsetStrength * 0.7,
                band: max(0, min(spectrum.count - 1, Int(c * CGFloat(spectrum.count)))),
                phrase: phrase
            ))
            lastOnset = t
        }
        for i in stars.indices { stars[i].x -= speed * dt }
        stars.removeAll { $0.x < -10 }

        // Background microstars (deterministic positions).
        for i in 0..<34 {
            let bx = CGFloat((i * 73) % 997) / 997 * bounds.width
            let by = 7 + CGFloat((i * 211) % 613) / 613 * (bounds.height - 14)
            let r = 0.5 + CGFloat((i * 37) % 89) / 89 * 0.9
            let a = 0.09 + 0.09 * sin(t * 1.6 + CGFloat(i) * 0.7)
            ctx.setFillColor(HudColor("#E6EBFF").cg(a))
            ctx.fill(CGRect(x: bx, y: by, width: r, height: r))
        }

        // Constellation lines between syllables of the same phrase.
        ctx.setLineWidth(1)
        for i in 1..<max(1, stars.count) {
            let a = stars[i - 1], b = stars[i]
            guard a.phrase == b.phrase else { continue }
            ctx.setStrokeColor(HudColor("#6C8FD0").cg(0.14 + 0.34 * min(a.brightness, b.brightness)))
            ctx.move(to: CGPoint(x: a.x, y: a.y))
            ctx.addLine(to: CGPoint(x: b.x, y: b.y))
            ctx.strokePath()
        }

        // Stars. Each one shimmers with the live energy of the band its
        // syllable lived in — speaking in a star's register relights it,
        // instead of every star twinkling on a uniform clock.
        for star in stars {
            let energy = star.band < spectrum.count ? spectrum[star.band] : 0
            let twinkle = 0.68 + 0.32 * min(1, energy)
            let R = (1 + star.brightness * 2.2) * twinkle
            hudRadialGlow(ctx, center: CGPoint(x: star.x, y: star.y), radius: R * 3, stops: [
                (0.0, HudColor("#FFEFC4").cg(0.9 * twinkle)),
                (0.4, HudColor("#FFE9B8").cg(0.35 * star.brightness)),
                (1.0, HudColor("#FFE9B8").cg(0)),
            ])
            ctx.setFillColor(HudColor("#FAF6EB").cg(0.85 * twinkle))
            let core = max(0.7, R * 0.55)
            ctx.fillEllipse(in: CGRect(x: star.x - core, y: star.y - core, width: core * 2, height: core * 2))
            if star.brightness > 0.68 {
                ctx.setStrokeColor(HudColor("#FFF4D6").cg(0.45 * twinkle))
                ctx.setLineWidth(0.8)
                ctx.move(to: CGPoint(x: star.x - R * 2.4, y: star.y))
                ctx.addLine(to: CGPoint(x: star.x + R * 2.4, y: star.y))
                ctx.move(to: CGPoint(x: star.x, y: star.y - R * 2.4))
                ctx.addLine(to: CGPoint(x: star.x, y: star.y + R * 2.4))
                ctx.strokePath()
            }
        }
    }
}

// MARK: - Loom (voice as weft, woven pick by pick)

final class LoomRenderer: HudRenderer {
    private struct Pick {
        var rows: Int
        var colorIndex: Int
        var quiet: Bool
    }
    private var picks: [Pick] = []
    private var accumulator: CGFloat = 0
    private var smoothed: CGFloat = 0
    private var voice = VoiceFeatures()
    private let threads = ["#E85D4A", "#F2B94B", "#3FBF8F", "#4C6EE6"].map { HudColor($0) }
    private let linen = HudColor("#E8DFC8")

    func reset() {
        picks = []
        accumulator = 0
        smoothed = 0
        voice.reset()
    }

    func render(in ctx: CGContext, bounds: CGRect, t: CGFloat, dt: CGFloat,
                level: CGFloat, spectrum: [CGFloat]) {
        smoothed += (level - smoothed) * 0.35
        voice.update(t: t, dt: dt, level: level, spectrum: spectrum)
        let pickWidth: CGFloat = 5
        accumulator += dt * 60
        if accumulator >= 2 {
            accumulator -= 2
            // Thread color is the voice's register: centroid picks the shade,
            // sibilant high-band energy pushes it a step brighter — no dice.
            let c = voice.centroid + min(0.24, voice.high * 0.12)
            let colorIndex = max(0, min(3, Int(c * 4)))
            picks.insert(Pick(
                rows: smoothed < 0.05 ? 1 : 1 + Int((smoothed * 9).rounded()),
                colorIndex: colorIndex,
                quiet: smoothed < 0.05
            ), at: 0)
            let maxPicks = Int(ceil(bounds.width / pickWidth)) + 2
            if picks.count > maxPicks { picks.removeLast() }
        }

        // Warp threads.
        ctx.setStrokeColor(linen.cg(0.10))
        ctx.setLineWidth(1)
        var x: CGFloat = 9
        while x < bounds.width - 6 {
            ctx.move(to: CGPoint(x: x, y: 8))
            ctx.addLine(to: CGPoint(x: x, y: bounds.height - 8))
            x += 6
        }
        ctx.strokePath()

        // Fabric.
        let mid = bounds.height / 2
        let cellH: CGFloat = 4.4
        let right = bounds.width - 26
        for (i, pick) in picks.enumerated() {
            let px = right - CGFloat(i) * pickWidth
            if px < 10 { break }
            let fade = px < 44 ? (px - 10) / 34 : 1
            for row in 0..<pick.rows {
                let yy = mid + (CGFloat(row) - CGFloat(pick.rows - 1) / 2) * cellH
                let color = pick.quiet ? linen : threads[pick.colorIndex]
                let shade: CGFloat = (i + row) % 2 == 0 ? 1 : 0.76
                let alpha = (pick.quiet ? 0.42 : 0.95) * fade
                ctx.setFillColor(HudColor(r: color.r * shade, g: color.g * shade, b: color.b * shade).cg(alpha))
                let cell = CGPath(roundedRect: CGRect(x: px - pickWidth / 2, y: yy - cellH / 2 + 0.4,
                                                      width: pickWidth - 1, height: cellH - 0.9),
                                  cornerWidth: 1.4, cornerHeight: 1.4, transform: nil)
                ctx.addPath(cell)
                ctx.fillPath()
            }
        }

        // Shuttle riding the newest pick.
        let sh = 2 + smoothed * 11
        ctx.setFillColor(linen.cg(0.92))
        let shuttle = CGPath(roundedRect: CGRect(x: right + 6, y: mid - sh, width: 3.2, height: sh * 2),
                             cornerWidth: 1.6, cornerHeight: 1.6, transform: nil)
        ctx.addPath(shuttle)
        ctx.fillPath()
    }
}

// MARK: - Vapor (breath wisps that condense and vanish)

final class VaporRenderer: HudRenderer {
    private struct Puff {
        var x, y, vx, vy, radius, life, age, seed: CGFloat
    }
    private var puffs: [Puff] = []
    private var smoothed: CGFloat = 0
    private var emitCarry: CGFloat = 0
    private var voice = VoiceFeatures()
    private let mint = HudColor("#A8F0DC")
    private let lavender = HudColor("#C9B8FF")

    func reset() {
        puffs = []
        smoothed = 0
        emitCarry = 0
        voice.reset()
    }

    func render(in ctx: CGContext, bounds: CGRect, t: CGFloat, dt: CGFloat,
                level: CGFloat, spectrum: [CGFloat]) {
        smoothed += (level - smoothed) * 0.25
        voice.update(t: t, dt: dt, level: level, spectrum: spectrum)
        let ex = bounds.width - 56
        let ey = bounds.height * 0.56
        // Breath is continuous, so the plume rides the level; each syllable
        // onset exhales a cluster sized and paced by how hard it hit (a soft
        // onset drifts out a small slow puff, a sharp one blows a big quick
        // one), and idle is a steady faint wisp (constant rate — texture, not
        // fake speech). Pitch is a light accent on puff size/speed; the
        // scatter is spray around the voice-driven mouth point.
        let idle = level < 0.05
        emitCarry += (idle ? 1.0 : smoothed * 7 * 60) * dt
        var births = Int(emitCarry)
        emitCarry -= CGFloat(births)
        if voice.onset { births += 2 + Int(voice.onsetStrength * 6) }
        let kick = voice.onset ? 0.75 + voice.onsetStrength * 0.7 : 1
        let pitch = voice.centroid
        for _ in 0..<births where puffs.count < 140 {
            puffs.append(Puff(
                x: ex + CGFloat.random(in: -4...4),
                y: ey + CGFloat.random(in: -5...5),
                vx: -(16 + CGFloat.random(in: 0...74) * (0.3 + smoothed)) * (0.9 + 0.2 * pitch) * kick,
                vy: -(2 + CGFloat.random(in: 0...9)),
                radius: (3 + CGFloat.random(in: 0...4)) * (1.15 - 0.3 * pitch) * kick,
                life: 1.6 + CGFloat.random(in: 0...1.5),
                age: 0,
                seed: CGFloat.random(in: 0...7)
            ))
        }

        ctx.saveGState()
        ctx.setBlendMode(.screen)
        var alive: [Puff] = []
        alive.reserveCapacity(puffs.count)
        for var p in puffs {
            p.age += dt
            if p.age >= p.life || p.x < -24 { continue }
            let u = p.age / p.life
            p.x += p.vx * dt
            p.y += p.vy * dt + sin(t * 1.7 + p.seed) * 9 * dt
            p.vx *= 0.995
            p.vy -= 1.4 * dt
            let R = p.radius * (1 + u * 3.4)
            let c = HudColor.lerp(mint, lavender, u)
            hudRadialGlow(ctx, center: CGPoint(x: p.x, y: p.y), radius: R, stops: [
                (0, c.cg((1 - u) * 0.15)),
                (1, c.cg(0)),
            ])
            alive.append(p)
        }
        puffs = alive
        ctx.restoreGState()

        // Breath source glow.
        let sourceR = 9 + smoothed * 26
        hudRadialGlow(ctx, center: CGPoint(x: ex + 8, y: ey), radius: sourceR, stops: [
            (0, HudColor("#EAF4F4").cg(0.10 + smoothed * 0.5)),
            (1, HudColor("#EAF4F4").cg(0)),
        ])
    }
}

// MARK: - Sonar (syllables fire pings that travel left)

final class SonarRenderer: HudRenderer {
    private struct Ring {
        var x, y, radius, alpha, growth, decay, width: CGFloat
    }
    private var rings: [Ring] = []
    private var voice = VoiceFeatures()

    func reset() {
        rings = []
        voice.reset()
    }

    private func strokeArc(_ ctx: CGContext, center: CGPoint, radius: CGFloat,
                           from a0: CGFloat, to a1: CGFloat) {
        let segments = 26
        for i in 0...segments {
            let a = a0 + (a1 - a0) * CGFloat(i) / CGFloat(segments)
            let p = CGPoint(x: center.x + cos(a) * radius, y: center.y + sin(a) * radius)
            if i == 0 { ctx.move(to: p) } else { ctx.addLine(to: p) }
        }
        ctx.strokePath()
    }

    func render(in ctx: CGContext, bounds: CGRect, t: CGFloat, dt: CGFloat,
                level: CGFloat, spectrum: [CGFloat]) {
        let ex = bounds.width - 42
        let ey = bounds.height / 2
        voice.update(t: t, dt: dt, level: level, spectrum: spectrum)
        if voice.onset {
            // The ping is the syllable's attack: a soft onset spawns a small
            // ring that radiates slowly and dies close to the emitter; a hard
            // one a big ring that races the width of the panel. Loudness sets
            // brightness; pitch only accents the stroke (lower voice, heavier
            // ring). No timed idle ping — the emitter dot alone marks
            // silence, so every ring on screen was a syllable.
            let s = voice.onsetStrength
            rings.append(Ring(
                x: ex, y: ey, radius: 3,
                alpha: min(1, 0.30 + level * 0.9),
                growth: 36 + s * 80,
                decay: 0.05 + s * 0.24, // per-second alpha retention
                width: 0.9 + s * 1.3 + (1 - voice.centroid) * 0.4
            ))
        }

        // Marine snow.
        for i in 0..<26 {
            let s = 0.4 + CGFloat((i * 53) % 97) / 97
            let baseX = CGFloat((i * 131) % 911) / 911 * bounds.width
            var mx = (baseX - t * 3 * s).truncatingRemainder(dividingBy: bounds.width)
            if mx < 0 { mx += bounds.width }
            let my = 6 + CGFloat((i * 197) % 701) / 701 * (bounds.height - 12)
            ctx.setFillColor(HudColor("#9ADCE8").cg(0.05 + 0.05 * s))
            ctx.fill(CGRect(x: mx, y: my, width: 1.1, height: 1.1))
        }

        ctx.setLineCap(.round)
        var alive: [Ring] = []
        for var ring in rings {
            ring.radius += ring.growth * dt
            ring.x -= 46 * dt
            ring.alpha *= pow(ring.decay, dt)
            if ring.alpha < 0.02 || ring.x + ring.radius < 0 { continue }
            ctx.setStrokeColor(HudColor("#45E8D0").cg(ring.alpha))
            ctx.setLineWidth(ring.width)
            strokeArc(ctx, center: CGPoint(x: ring.x, y: ring.y), radius: ring.radius,
                      from: .pi * 0.62, to: .pi * 1.38)
            ctx.setStrokeColor(HudColor("#7FF2A9").cg(ring.alpha * 0.4))
            ctx.setLineWidth(ring.width * 0.55)
            strokeArc(ctx, center: CGPoint(x: ring.x, y: ring.y), radius: ring.radius * 0.82,
                      from: .pi * 0.7, to: .pi * 1.3)
            alive.append(ring)
        }
        rings = alive

        // Emitter node.
        let sm = min(1, level * 2)
        let pulse = 0.5 + 0.5 * sin(t * 4)
        ctx.setFillColor(HudColor("#45E8D0").cg(0.5 + sm * 0.5))
        let r = 2.2 + sm * 2.4 + pulse * 0.6
        ctx.fillEllipse(in: CGRect(x: ex - r, y: ey - r, width: r * 2, height: r * 2))
        ctx.setStrokeColor(HudColor("#45E8D0").cg(0.16 + sm * 0.25))
        ctx.setLineWidth(1)
        let ringR = 5 + sm * 4
        ctx.strokeEllipse(in: CGRect(x: ex - ringR, y: ey - ringR, width: ringR * 2, height: ringR * 2))
    }
}

// MARK: - Shorthand (one live pen line, loops on syllables)

final class ShorthandRenderer: HudRenderer {
    private struct Point {
        var x, y, width: CGFloat
    }
    private var points: [Point] = []
    private var theta: CGFloat = 0
    private var smoothed: CGFloat = 0
    private var pitch: CGFloat = 0.5
    private var loopKick: CGFloat = 0
    private var voice = VoiceFeatures()
    private let faded = HudColor("#4A4E86")
    private let mid = HudColor("#7B8AF5")
    private let fresh = HudColor("#6BE8F0")

    func reset() {
        points = []
        theta = 0
        smoothed = 0
        pitch = 0.5
        loopKick = 0
        voice.reset()
    }

    private func inkColor(at u: CGFloat) -> HudColor {
        // left (old) → faded, middle → periwinkle, right (fresh) → cyan
        u < 0.55
            ? HudColor.lerp(faded, mid, u / 0.55)
            : HudColor.lerp(mid, fresh, (u - 0.55) / 0.45)
    }

    func render(in ctx: CGContext, bounds: CGRect, t: CGFloat, dt: CGFloat,
                level: CGFloat, spectrum: [CGFloat]) {
        smoothed += (level - smoothed) * (level > smoothed ? 0.5 : 0.12)
        voice.update(t: t, dt: dt, level: level, spectrum: spectrum)
        pitch += (voice.centroid - pitch) * 0.2
        // Each syllable whips the pen through an extra loop — the harder the
        // onset, the bigger and quicker the curl. The voice's register only
        // sets the hand: high voices write tight curls with a light nib, low
        // voices carve lazy loops in heavy ink.
        if voice.onset { loopKick = 0.3 + voice.onsetStrength * 0.7 }
        loopKick *= pow(0.03, dt)
        let speed: CGFloat = 46
        let penX = bounds.width - 40
        let midY = bounds.height / 2
        for i in points.indices { points[i].x -= speed * dt }
        let wander = sin(t * 0.8) * 6 + sin(t * 1.9) * 3.5
        theta += dt * (4 + smoothed * (16 + 64 * pitch) + loopKick * 40)
        let loopR = smoothed * bounds.height * (0.42 - 0.22 * pitch) * (1 + loopKick * 0.4)
        points.insert(Point(
            x: penX + cos(theta) * loopR * 0.75,
            y: midY + wander + sin(theta) * loopR,
            width: 1 + smoothed * (1.4 + 2.6 * (1 - pitch))
        ), at: 0)
        while points.count > 540 || (points.last.map { $0.x < 14 } ?? false) {
            points.removeLast()
        }

        guard points.count > 2 else { return }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for i in 1..<points.count {
            let a = points[i - 1], b = points[i]
            let u = b.x / bounds.width
            let alpha = 0.25 + 0.75 * u
            ctx.setStrokeColor(inkColor(at: u).cg(alpha))
            ctx.setLineWidth(max(1.2, b.width))
            ctx.move(to: CGPoint(x: a.x, y: a.y))
            ctx.addLine(to: CGPoint(x: b.x, y: b.y))
            ctx.strokePath()
        }

        // Pen nib.
        if let p0 = points.first {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 8, color: fresh.cg(0.9))
            ctx.setFillColor(HudColor("#DCFAFC").cg(0.95))
            let r = 1.8 + smoothed * 1.6
            ctx.fillEllipse(in: CGRect(x: p0.x - r, y: p0.y - r, width: r * 2, height: r * 2))
            ctx.restoreGState()
        }
    }
}

// MARK: - Prism (voice as white light split into a spectrum)

final class PrismRenderer: HudRenderer {
    private let cols = 100
    private var history: [[CGFloat]] = []
    private let colors6 = ["#FF6B6B", "#FFC46B", "#F2E86B", "#5EE889", "#5EA8FF", "#B57BFF"].map { HudColor($0) }

    func reset() { history = [] }

    func render(in ctx: CGContext, bounds: CGRect, t: CGFloat, dt: CGFloat,
                level: CGFloat, spectrum: [CGFloat]) {
        var e: [CGFloat] = []
        for i in 0..<6 {
            let a = i * 2 < spectrum.count ? spectrum[i * 2] : 0
            let b = i * 2 + 1 < spectrum.count ? spectrum[i * 2 + 1] : 0
            e.append(min(1, (a + b) * 0.75))
        }
        history.insert(e, at: 0)
        if history.count > cols { history.removeLast() }

        let px = bounds.width - 56
        let py = bounds.height / 2

        // Incoming beam.
        let beamRect = CGRect(x: px + 9, y: py - (0.8 + level * 2.6) / 2,
                              width: bounds.width - 2 - (px + 9), height: 0.8 + level * 2.6)
        hudLinearGradient(ctx, from: CGPoint(x: bounds.width, y: 0), to: CGPoint(x: px + 9, y: 0),
                          stops: [(0, HudColor("#F8F5EE").cg(0)), (1, HudColor("#F8F5EE").cg(0.22 + level * 0.7))],
                          clippedTo: CGPath(rect: beamRect, transform: nil))

        // Spectral ribbons drifting left.
        let exitX = px - 10
        let leftEdge: CGFloat = 14
        let span = exitX - leftEdge
        let colW = span / CGFloat(cols)
        let spread = bounds.height * 0.34
        ctx.saveGState()
        ctx.setBlendMode(.plusLighter)
        ctx.setLineCap(.round)
        for b in 0..<6 {
            let slope = ((CGFloat(b) - 2.5) / 2.5) * spread / span
            let c = colors6[b]
            for i in 0..<max(0, history.count - 1) {
                let x1 = exitX - CGFloat(i) * colW
                let x2 = exitX - CGFloat(i + 1) * colW
                if x2 < leftEdge { break }
                let energy = history[i][b]
                if energy < 0.02 { continue }
                let fade = 1 - CGFloat(i) / CGFloat(cols)
                ctx.setStrokeColor(c.cg(energy * (0.12 + 0.7 * fade)))
                ctx.setLineWidth(1.1 + energy * 2.2 * fade)
                ctx.move(to: CGPoint(x: x1, y: py + (exitX - x1) * slope))
                ctx.addLine(to: CGPoint(x: x2, y: py + (exitX - x2) * slope))
                ctx.strokePath()
            }
        }
        ctx.restoreGState()

        // The prism.
        ctx.move(to: CGPoint(x: px, y: py - 15))
        ctx.addLine(to: CGPoint(x: px - 12, y: py + 11))
        ctx.addLine(to: CGPoint(x: px + 12, y: py + 11))
        ctx.closePath()
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.05 + level * 0.05))
        ctx.fillPath()
        ctx.move(to: CGPoint(x: px, y: py - 15))
        ctx.addLine(to: CGPoint(x: px - 12, y: py + 11))
        ctx.addLine(to: CGPoint(x: px + 12, y: py + 11))
        ctx.closePath()
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.38))
        ctx.setLineWidth(1)
        ctx.strokePath()
        // Glint on the entry face.
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.15 + level * 0.4))
        ctx.move(to: CGPoint(x: px + 10, y: py + 8))
        ctx.addLine(to: CGPoint(x: px + 3, y: py - 7))
        ctx.strokePath()
    }
}

// MARK: - Murmuration (a flock that startles at syllables)

final class MurmurationRenderer: HudRenderer {
    private struct Bird {
        var x, y, vx, vy: CGFloat
    }
    private var birds: [Bird] = []
    private var smoothed: CGFloat = 0
    private var pitch: CGFloat = 0.5
    private var voice = VoiceFeatures()

    func reset() {
        birds = []
        smoothed = 0
        pitch = 0.5
        voice.reset()
    }

    func render(in ctx: CGContext, bounds: CGRect, t: CGFloat, dt: CGFloat,
                level: CGFloat, spectrum: [CGFloat]) {
        let count = 80
        if birds.isEmpty {
            for _ in 0..<count {
                birds.append(Bird(
                    x: CGFloat.random(in: 0...bounds.width),
                    y: bounds.height * 0.25 + CGFloat.random(in: 0...(bounds.height * 0.5)),
                    vx: -24 - CGFloat.random(in: 0...20),
                    vy: CGFloat.random(in: -5...5)
                ))
            }
        }
        smoothed += (level - smoothed) * 0.22
        voice.update(t: t, dt: dt, level: level, spectrum: spectrum)
        pitch += (voice.centroid - pitch) * 0.12

        var cx: CGFloat = 0, cy: CGFloat = 0, avx: CGFloat = 0, avy: CGFloat = 0
        for b in birds { cx += b.x; cy += b.y; avx += b.vx; avy += b.vy }
        let n = CGFloat(birds.count)
        cx /= n; cy /= n; avx /= n; avy /= n

        // Idle: lazy sinusoidal cruising. Speaking: the flock's altitude
        // tracks the voice's pitch — high registers lift it, low ones sink it.
        let idleY = bounds.height * 0.5 + sin(t * 0.7) * bounds.height * 0.16 + sin(t * 1.7) * bounds.height * 0.05
        let voiceY = bounds.height * (0.78 - pitch * 0.56)
        let ty = idleY + (voiceY - idleY) * min(1, smoothed * 2.2)
        let cruise = 26 + smoothed * 150
        let sepR2 = pow(4 + smoothed * 13, 2)

        for i in birds.indices {
            var b = birds[i]
            var fx = (cx - b.x) * 0.5 + (bounds.width * 0.5 - b.x) * 0.06 + (avx - b.vx) * 0.6
            var fy = (ty - b.y) * 1.1 + (cy - b.y) * 0.5 + (avy - b.vy) * 0.6
            for j in birds.indices where j != i {
                let dx = b.x - birds[j].x
                let dy = b.y - birds[j].y
                let d2 = max(4, dx * dx + dy * dy)
                if d2 < sepR2 {
                    fx += dx / d2 * 160
                    fy += dy / d2 * 160
                }
            }
            b.vx += fx * dt * 2.4
            b.vy += fy * dt * 2.4
            b.vx += (-cruise - b.vx) * dt * 1.1
            if smoothed > 0.22 {
                b.vx += CGFloat.random(in: -0.5...0.5) * smoothed * 300 * dt
                b.vy += CGFloat.random(in: -0.5...0.5) * smoothed * 300 * dt
            }
            let sp = max(0.001, (b.vx * b.vx + b.vy * b.vy).squareRoot())
            let maxSp = 55 + smoothed * 250
            if sp > maxSp {
                b.vx *= maxSp / sp
                b.vy *= maxSp / sp
            }
            b.x += b.vx * dt
            b.y += b.vy * dt
            if b.x < -8 {
                b.x = bounds.width + 6
                b.y = ty + CGFloat.random(in: -14...14)
            }
            if b.y < 6 { b.y = 6; b.vy = abs(b.vy) * 0.5 }
            if b.y > bounds.height - 6 { b.y = bounds.height - 6; b.vy = -abs(b.vy) * 0.5 }
            birds[i] = b
        }

        ctx.setLineWidth(1.1)
        ctx.setLineCap(.round)
        for (i, b) in birds.enumerated() {
            let sp = max(0.001, (b.vx * b.vx + b.vy * b.vy).squareRoot())
            let ux = b.vx / sp, uy = b.vy / sp
            let len = 1.8 + min(2.4, sp * 0.012)
            ctx.setStrokeColor(HudColor("#DEE2F0").cg(0.42 + CGFloat(i % 5) * 0.09))
            ctx.move(to: CGPoint(x: b.x - ux * len, y: b.y - uy * len))
            ctx.addLine(to: CGPoint(x: b.x + ux * len, y: b.y + uy * len))
            ctx.strokePath()
        }
    }
}

// MARK: - Filament (a live arc between two copper terminals)

final class FilamentRenderer: HudRenderer {
    private let segments = 64
    private var offsets: [CGFloat]
    private struct Branch {
        var index: Int
        var dy, life, age: CGFloat
    }
    private struct Pulse {
        var u, speed: CGFloat
    }
    private var branches: [Branch] = []
    private var pulses: [Pulse] = []
    private var branchSide: CGFloat = 1
    private var smoothed: CGFloat = 0
    private var voice = VoiceFeatures()

    init() {
        offsets = [CGFloat](repeating: 0, count: segments + 1)
    }

    func reset() {
        offsets = [CGFloat](repeating: 0, count: segments + 1)
        branches = []
        pulses = []
        branchSide = 1
        smoothed = 0
        voice.reset()
    }

    private func displace(amplitude: CGFloat) -> [CGFloat] {
        var tmp = [CGFloat](repeating: 0, count: segments + 1)
        var step = segments
        var amp = amplitude
        while step > 1 {
            var i = step / 2
            while i < segments {
                tmp[i] = (tmp[i - step / 2] + tmp[i + step / 2]) / 2 + CGFloat.random(in: -0.5...0.5) * amp
                i += step
            }
            step /= 2
            amp *= 0.55
        }
        return tmp
    }

    func render(in ctx: CGContext, bounds: CGRect, t: CGFloat, dt: CGFloat,
                level: CGFloat, spectrum: [CGFloat]) {
        smoothed += (level - smoothed) * (level > smoothed ? 0.6 : 0.15)
        voice.update(t: t, dt: dt, level: level, spectrum: spectrum)
        // Arc jaggedness is voice energy: overall level plus an extra bite
        // from sibilant high-band hiss. (The midpoint displacement inside
        // stays random — that's the arc's texture, its amplitude is not.)
        let target = displace(amplitude: 2 + smoothed * 11 + min(1, voice.high * 0.4) * 5)
        for i in 0...segments {
            offsets[i] = offsets[i] * 0.45 + target[i] * 0.55
        }
        let x0: CGFloat = 30
        let x1 = bounds.width - 30
        let midY = bounds.height / 2
        func point(_ k: Int) -> CGPoint {
            CGPoint(x: x0 + (x1 - x0) * CGFloat(k) / CGFloat(segments), y: midY + offsets[k])
        }

        if voice.onset {
            // A soft syllable sends a slow pulse down the arc; a hard one a
            // fast pulse that also forks — the branch peels off at the arc
            // position matching the syllable's pitch, sized by the hit,
            // alternating sides so consecutive forks don't overlap.
            let s = voice.onsetStrength
            pulses.append(Pulse(u: 1, speed: 0.7 + s * 1.5))
            if s > 0.35 {
                branchSide = -branchSide
                branches.append(Branch(
                    index: 8 + Int(voice.centroid * CGFloat(segments - 16)),
                    dy: branchSide * (5 + s * 11),
                    life: 0.14, age: 0
                ))
            }
        }

        func traceArc() {
            ctx.move(to: point(0))
            for i in 1...segments { ctx.addLine(to: point(i)) }
        }

        // Glow pass, then core.
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 10 + smoothed * 8, color: HudColor("#6BB8FF").cg(0.8))
        ctx.setStrokeColor(HudColor("#6BB8FF").cg(0.3 + smoothed * 0.4))
        ctx.setLineWidth(2.6)
        ctx.setLineJoin(.round)
        traceArc()
        ctx.strokePath()
        ctx.restoreGState()
        ctx.setStrokeColor(HudColor("#F2F6FF").cg(0.55 + smoothed * 0.45))
        ctx.setLineWidth(1.2)
        traceArc()
        ctx.strokePath()

        // Short-lived forks.
        var liveBranches: [Branch] = []
        for var branch in branches {
            branch.age += dt
            if branch.age > branch.life { continue }
            let a = 1 - branch.age / branch.life
            let p0 = point(branch.index)
            ctx.setStrokeColor(HudColor("#A87BFF").cg(0.7 * a))
            ctx.setLineWidth(1)
            ctx.move(to: p0)
            ctx.addLine(to: CGPoint(x: p0.x - 7, y: p0.y + branch.dy * 0.55))
            ctx.addLine(to: CGPoint(x: p0.x - 13, y: p0.y + branch.dy))
            ctx.strokePath()
            liveBranches.append(branch)
        }
        branches = liveBranches

        // Pulses travel right-to-left along the arc.
        var livePulses: [Pulse] = []
        for var pulse in pulses {
            pulse.u -= pulse.speed * dt
            if pulse.u <= 0 { continue }
            let pp = point(Int((pulse.u * CGFloat(segments)).rounded()))
            hudRadialGlow(ctx, center: pp, radius: 8, stops: [
                (0.0, HudColor("#F2F6FF").cg(0.95)),
                (0.4, HudColor("#6BB8FF").cg(0.5)),
                (1.0, HudColor("#6BB8FF").cg(0)),
            ])
            livePulses.append(pulse)
        }
        pulses = livePulses

        // Copper terminals.
        for tx in [x0 - 7, x1 + 7] {
            ctx.setFillColor(HudColor("#B87E45").cg(1))
            ctx.fillEllipse(in: CGRect(x: tx - 4.4, y: midY - 4.4, width: 8.8, height: 8.8))
            ctx.setFillColor(HudColor("#E8A25E").cg(1))
            ctx.fillEllipse(in: CGRect(x: tx - 3.4, y: midY - 3.4, width: 5.2, height: 5.2))
        }
    }
}

// MARK: - Bloom (a vine that leafs and blossoms as you speak)

final class BloomRenderer: HudRenderer {
    private struct Sprout {
        var x, y, size, born, grow: CGFloat // grow = seconds to unfurl
        var side: CGFloat
        var flower: Bool
        var color: HudColor
    }
    private var stem: [CGPoint] = []
    private var sprouts: [Sprout] = []
    private var side: CGFloat = 1
    private var smoothed: CGFloat = 0
    private var voice = VoiceFeatures()
    private let petals = ["#FF8A7A", "#FFB3C7", "#C89BF2"].map { HudColor($0) }

    func reset() {
        stem = []
        sprouts = []
        side = 1
        smoothed = 0
        voice.reset()
    }

    private func easeOutBack(_ x: CGFloat) -> CGFloat {
        let c1: CGFloat = 1.70158
        let c3 = c1 + 1
        return 1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2)
    }

    func render(in ctx: CGContext, bounds: CGRect, t: CGFloat, dt: CGFloat,
                level: CGFloat, spectrum: [CGFloat]) {
        smoothed += (level - smoothed) * 0.3
        let speed: CGFloat = 34
        let penX = bounds.width - 34
        let midY = bounds.height * 0.60
        for i in stem.indices { stem[i].x -= speed * dt }
        for i in sprouts.indices { sprouts[i].x -= speed * dt }
        while stem.last.map({ $0.x < 16 }) ?? false { stem.removeLast() }
        sprouts.removeAll { $0.x < 18 }

        let tipY = midY + sin(t * 0.9) * 5 + sin(t * 2.1) * 2.5
        stem.insert(CGPoint(x: penX, y: tipY), at: 0)
        if stem.count > 560 { stem.removeLast() }

        voice.update(t: t, dt: dt, level: level, spectrum: spectrum)
        if voice.onset {
            side = -side
            // A soft syllable buds a small leaf that unfurls lazily; a hard
            // one springs open a big sprout. Pitch just picks the petal shade.
            let s = voice.onsetStrength
            sprouts.append(Sprout(
                x: penX, y: tipY,
                size: 0.25 + 0.75 * s,
                born: t,
                grow: 0.62 - 0.34 * s,
                side: side,
                flower: level > 0.62,
                color: petals[max(0, min(2, Int(voice.centroid * 3)))]
            ))
        }

        func sway(_ x: CGFloat) -> CGFloat { sin(t * 1.3 + x * 0.045) * 1.6 }

        // Stem.
        if stem.count > 2 {
            ctx.setLineWidth(2)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            for i in 1..<stem.count {
                let a = stem[i - 1], b = stem[i]
                let u = b.x / bounds.width
                let color = HudColor.lerp(HudColor("#4FBF7A"), HudColor("#7ADB8F"), u)
                ctx.setStrokeColor(color.cg(0.35 + 0.65 * u))
                ctx.move(to: CGPoint(x: a.x, y: a.y + sway(a.x)))
                ctx.addLine(to: CGPoint(x: b.x, y: b.y + sway(b.x)))
                ctx.strokePath()
            }
        }

        // Leaves and blossoms.
        for sprout in sprouts {
            let k = easeOutBack(min(1, (t - sprout.born) / sprout.grow))
            let alpha = max(0, min(1, (sprout.x - 18) / 30))
            let sy = sprout.y + sway(sprout.x)
            ctx.saveGState()
            ctx.translateBy(x: sprout.x, y: sy)
            if !sprout.flower {
                ctx.rotate(by: sprout.side * 0.95 + sin(t * 1.5 + sprout.x * 0.1) * 0.08)
                let len = (5.5 + sprout.size * 5) * k
                ctx.setFillColor(HudColor("#7ADB8F").cg(0.85 * alpha))
                ctx.saveGState()
                ctx.translateBy(x: 0, y: -len * 0.6)
                ctx.fillEllipse(in: CGRect(x: -len * 0.38, y: -len * 0.62, width: len * 0.76, height: len * 1.24))
                ctx.restoreGState()
            } else {
                let R = (3.2 + sprout.size * 3.4) * k
                for p in 0..<5 {
                    let angle = CGFloat(p) * 1.2566 + sin(t * 0.8 + sprout.x) * 0.05
                    ctx.saveGState()
                    ctx.translateBy(x: cos(angle) * R, y: sin(angle) * R - R * 0.5)
                    ctx.rotate(by: angle)
                    ctx.setFillColor(sprout.color.cg(0.9 * alpha))
                    ctx.fillEllipse(in: CGRect(x: -R * 0.62, y: -R * 0.42, width: R * 1.24, height: R * 0.84))
                    ctx.restoreGState()
                }
                ctx.setFillColor(HudColor("#FFD37A").cg(0.95 * alpha))
                let cr = R * 0.32
                ctx.fillEllipse(in: CGRect(x: -cr, y: -R * 0.5 - cr, width: cr * 2, height: cr * 2))
            }
            ctx.restoreGState()
        }

        // The growing tip: a bud that pulses with the mic.
        let bud = 2 + smoothed * 4 + sin(t * 3) * 0.4
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 7 + smoothed * 9, color: HudColor("#7ADB8F").cg(0.9))
        ctx.setFillColor(HudColor("#BEF0BE").cg(0.95))
        let by = tipY + sway(penX)
        ctx.fillEllipse(in: CGRect(x: penX - bud, y: by - bud, width: bud * 2, height: bud * 2))
        ctx.restoreGState()
    }
}

// MARK: - Pianola (syllables punched into a player-piano roll)

final class PianolaRenderer: HudRenderer {
    private final class Hole {
        var x: CGFloat
        var length: CGFloat
        let lane: Int
        let width: CGFloat
        init(x: CGFloat, length: CGFloat, lane: Int, width: CGFloat) {
            self.x = x; self.length = length; self.lane = lane; self.width = width
        }
    }
    private var holes: [Hole] = []
    private var active: Hole?
    private var voice = VoiceFeatures()
    private let lanes = 6

    func reset() {
        holes = []
        active = nil
        voice.reset()
    }

    func render(in ctx: CGContext, bounds: CGRect, t: CGFloat, dt: CGFloat,
                level: CGFloat, spectrum: [CGFloat]) {
        let speed: CGFloat = 44
        let pad: CGFloat = 9
        let punchX = bounds.width - 34

        voice.update(t: t, dt: dt, level: level, spectrum: spectrum)
        for hole in holes { hole.x -= speed * dt }
        holes.removeAll { $0.x + $0.length < pad + 3 }
        if let hole = active {
            hole.length += speed * dt
            if level < 0.24 { active = nil }
        }
        // Every syllable punches a fresh slot on the lane matching its pitch —
        // even mid-phrase, so fast speech reads as separate notes; sustained
        // sound keeps extending the current slot. The hit's strength sets the
        // punch width: soft syllables cut narrow slots, hard ones wide.
        if voice.onset {
            let lane = max(0, min(lanes - 1, Int((voice.centroid * CGFloat(lanes - 1)).rounded())))
            let hole = Hole(x: punchX, length: 3, lane: lane,
                            width: 3 + voice.onsetStrength * 3.8)
            holes.append(hole)
            active = hole
        }

        // Paper roll.
        let tape = CGPath(roundedRect: CGRect(x: pad, y: pad, width: bounds.width - pad * 2, height: bounds.height - pad * 2),
                          cornerWidth: 7, cornerHeight: 7, transform: nil)
        hudLinearGradient(ctx, from: CGPoint(x: 0, y: pad), to: CGPoint(x: 0, y: bounds.height - pad),
                          stops: [(0, HudColor("#EAE0C6").cg(1)), (0.5, HudColor("#F2E8CF").cg(1)), (1, HudColor("#E5DBC0").cg(1))],
                          clippedTo: tape)

        ctx.saveGState()
        ctx.addPath(tape)
        ctx.clip()

        // Feed perforations scrolling with the roll.
        let offX = (t * speed).truncatingRemainder(dividingBy: 11)
        ctx.setFillColor(HudColor("#26211A").cg(0.35))
        var gx = bounds.width
        while gx > 0 {
            ctx.fillEllipse(in: CGRect(x: gx - offX - 1.15, y: pad + 4.4 - 1.15, width: 2.3, height: 2.3))
            ctx.fillEllipse(in: CGRect(x: gx - offX - 1.15, y: bounds.height - pad - 4.4 - 1.15, width: 2.3, height: 2.3))
            gx -= 11
        }

        // Note lanes.
        let top = pad + 9.5
        let bottom = bounds.height - pad - 9.5
        ctx.setStrokeColor(HudColor("#26211A").cg(0.12))
        ctx.setLineWidth(1)
        for lane in 0..<lanes {
            let ly = bottom - (bottom - top) * CGFloat(lane) / CGFloat(lanes - 1)
            ctx.move(to: CGPoint(x: pad, y: ly))
            ctx.addLine(to: CGPoint(x: bounds.width - pad, y: ly))
            ctx.strokePath()
        }

        // Punched slots.
        for hole in holes {
            let y = bottom - (bottom - top) * CGFloat(hole.lane) / CGFloat(lanes - 1)
            let x = max(pad + 2, hole.x)
            let length = min(hole.length, hole.x + hole.length - (pad + 2))
            if length < 0.5 { continue }
            ctx.setFillColor(HudColor("#26211A").cg(1))
            let slot = CGPath(roundedRect: CGRect(x: x, y: y - hole.width / 2, width: length, height: hole.width),
                              cornerWidth: hole.width / 2, cornerHeight: hole.width / 2, transform: nil)
            ctx.addPath(slot)
            ctx.fillPath()
            // Paper edge catches the light below the cut.
            ctx.setStrokeColor(HudColor("#FFFCF0").cg(0.5))
            ctx.setLineWidth(0.8)
            ctx.move(to: CGPoint(x: x + 1, y: y + hole.width / 2 + 0.6))
            ctx.addLine(to: CGPoint(x: x + length - 1, y: y + hole.width / 2 + 0.6))
            ctx.strokePath()
        }

        // Brass tracker bar.
        let barRect = CGRect(x: punchX + 4, y: pad + 2, width: 6, height: bounds.height - pad * 2 - 4)
        hudLinearGradient(ctx, from: CGPoint(x: barRect.minX, y: 0), to: CGPoint(x: barRect.maxX, y: 0),
                          stops: [(0, HudColor("#E8BC66").cg(1)), (0.5, HudColor("#D9A84E").cg(1)), (1, HudColor("#A8783A").cg(1))],
                          clippedTo: CGPath(roundedRect: barRect, cornerWidth: 3, cornerHeight: 3, transform: nil))

        // Punch nib flash on the active lane.
        if let hole = active {
            let ay = bottom - (bottom - top) * CGFloat(hole.lane) / CGFloat(lanes - 1)
            ctx.setFillColor(HudColor("#C24545").cg(0.9))
            ctx.fillEllipse(in: CGRect(x: punchX + 7 - 2.2, y: ay - 2.2, width: 4.4, height: 4.4))
        }
        ctx.restoreGState()
    }
}
