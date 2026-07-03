// Renders the LocalFlow app icon: an organic waveform (matching the
// recording overlay) glowing on a dark gradient squircle.
//
//   swift scripts/generate-icon.swift <output.png>
//
// Run via scripts/make-icon.sh, which also packages the .icns.
import AppKit

let canvas: CGFloat = 1024
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(canvas),
    pixelsHigh: Int(canvas),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    FileHandle.standardError.write(Data("could not create bitmap\n".utf8))
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let context = NSGraphicsContext.current!.cgContext

// MARK: Squircle background (Apple margin: ~10% inset, ~22.5% corner radius)

let plate = NSRect(x: 100, y: 100, width: canvas - 200, height: canvas - 200)
let squircle = NSBezierPath(roundedRect: plate, xRadius: 185, yRadius: 185)

NSGradient(colors: [
    NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.25, alpha: 1.0), // indigo night
    NSColor(calibratedRed: 0.05, green: 0.17, blue: 0.20, alpha: 1.0), // deep teal
])!.draw(in: squircle, angle: -70)

// Soft radial light behind the wave.
NSGradient(colors: [
    NSColor.white.withAlphaComponent(0.10),
    NSColor.white.withAlphaComponent(0.0),
])!.draw(in: squircle, relativeCenterPosition: NSPoint(x: 0, y: 0.1))

// MARK: Organic wave (deterministic levels, gaussian-ish envelope)

func wavePath(amplitudeScale: CGFloat) -> NSBezierPath {
    let n = 48
    let left = plate.minX + 88
    let right = plate.maxX - 88
    let step = (right - left) / CGFloat(n - 1)
    let midY = plate.midY
    let maxAmplitude: CGFloat = 210 * amplitudeScale

    var top: [NSPoint] = []
    var bottom: [NSPoint] = []
    for i in 0..<n {
        let u = CGFloat(i) / CGFloat(n - 1)
        let envelope = pow(sin(.pi * u), 0.9)
        let texture = abs(sin(u * 14.0) * sin(u * 6.3 + 1.2)) * 0.65 + 0.35
        let amplitude = max(6, maxAmplitude * envelope * texture)
        let x = left + CGFloat(i) * step
        top.append(NSPoint(x: x, y: midY + amplitude))
        bottom.append(NSPoint(x: x, y: midY - amplitude))
    }

    func addSmoothCurve(to path: NSBezierPath, through points: [NSPoint]) {
        for i in 1..<(points.count - 1) {
            let control = points[i]
            let target = i == points.count - 2
                ? points[i + 1]
                : NSPoint(x: (points[i].x + points[i + 1].x) / 2,
                          y: (points[i].y + points[i + 1].y) / 2)
            let current = path.currentPoint
            let c1 = NSPoint(x: current.x + (control.x - current.x) * 2 / 3,
                             y: current.y + (control.y - current.y) * 2 / 3)
            let c2 = NSPoint(x: target.x + (control.x - target.x) * 2 / 3,
                             y: target.y + (control.y - target.y) * 2 / 3)
            path.curve(to: target, controlPoint1: c1, controlPoint2: c2)
        }
    }

    let path = NSBezierPath()
    path.move(to: top[0])
    addSmoothCurve(to: path, through: top)
    path.line(to: bottom[n - 1])
    addSmoothCurve(to: path, through: bottom.reversed())
    path.close()
    return path
}

context.saveGState()
squircle.addClip() // keep the glow inside the plate

// Faint echo wave for depth.
NSColor(calibratedRed: 0.45, green: 0.75, blue: 0.95, alpha: 0.20).setFill()
wavePath(amplitudeScale: 1.30).fill()

// Main wave: glow pass, then gradient.
let wave = wavePath(amplitudeScale: 1.0)
context.saveGState()
context.setShadow(
    offset: .zero, blur: 70,
    color: NSColor(calibratedRed: 0.30, green: 0.85, blue: 0.80, alpha: 0.65).cgColor
)
NSColor(calibratedRed: 0.30, green: 0.85, blue: 0.80, alpha: 0.9).setFill()
wave.fill()
context.restoreGState()

NSGradient(colors: [
    NSColor(calibratedRed: 0.25, green: 0.87, blue: 0.82, alpha: 1.0), // teal
    NSColor(calibratedRed: 0.42, green: 0.94, blue: 0.68, alpha: 1.0), // mint
    NSColor(calibratedRed: 0.55, green: 0.62, blue: 0.97, alpha: 1.0), // periwinkle
    NSColor(calibratedRed: 0.76, green: 0.52, blue: 0.95, alpha: 1.0), // orchid
])!.draw(in: wave, angle: 0)

context.restoreGState()

// Hairline inner edge to lift the plate off light backgrounds.
NSColor.white.withAlphaComponent(0.08).setStroke()
let edge = NSBezierPath(roundedRect: plate.insetBy(dx: 3, dy: 3), xRadius: 182, yRadius: 182)
edge.lineWidth = 6
edge.stroke()

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("could not encode png\n".utf8))
    exit(1)
}
try! png.write(to: URL(fileURLWithPath: output))
print("wrote \(output)")
