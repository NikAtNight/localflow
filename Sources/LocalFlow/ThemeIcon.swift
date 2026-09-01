import AppKit

/// Regenerates the app icon for the active listening theme. Every theme's
/// icon is the same composition as the original hand-made icon — the organic
/// glowing waveform from generate-icon.swift on a dark squircle — recolored
/// with that theme's palette. (Baking a literal frame of the HUD renderer
/// was tried first and read as mud at icon sizes.)
///
/// The running process gets the new image immediately, while Finder and
/// Launchpad read the bundle's AppIcon.icns. Rewriting it breaks the code seal,
/// so the bundle is re-signed with the same identity scheme as make-app.sh; a
/// marker file tracks which theme the baked icon belongs to (reinstalls reset
/// it). Avoid NSWorkspace's custom-icon API here: its Finder xattrs make strict
/// code-sign validation fail even after the bundle is re-signed.
enum ThemeIcon {
    // Serial so rapid theme changes never run two `codesign --force` passes on
    // our own bundle at once (a torn signature drops the app's TCC grants).
    private static let queue = DispatchQueue(label: "app.talix.localflow.themeicon")
    private static let pendingLock = NSLock()
    // Every access is protected by pendingLock. Swift cannot infer lock-based
    // isolation, so make that synchronization contract explicit.
    nonisolated(unsafe) private static var pendingTheme: HudTheme?

    /// Fire-and-forget: generation runs off the main thread, application on it.
    /// Jobs coalesce — only the latest requested theme is applied; stale ones skip.
    @MainActor
    static func apply(_ theme: HudTheme) {
        pendingLock.lock()
        pendingTheme = theme
        pendingLock.unlock()
        queue.async {
            pendingLock.lock()
            let latest = pendingTheme
            pendingLock.unlock()
            guard latest == theme else { return } // superseded by a newer request
            // The bundle already supplies the right icon on normal launches.
            // Rendering a 1024 px replacement is only needed after a theme
            // change (or under `swift run`, where there is no app bundle).
            if bundledThemeMatches(theme) { return }
            guard let cgImage = compose(theme) else { return }
            let icon = NSImage(cgImage: cgImage, size: NSSize(width: 512, height: 512))
            DispatchQueue.main.async {
                NSApp.applicationIconImage = icon
            }
            syncBundleIcon(theme, cgImage)
        }
    }

    // MARK: Bundle icon (what Launchpad shows)

    private static let lsregister =
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    private static func bundledThemeMatches(_ theme: HudTheme) -> Bool {
        let bundlePath = Bundle.main.bundlePath
        guard bundlePath.hasSuffix(".app") else { return false }
        return bakedTheme(in: bundlePath) == theme.rawValue
    }

    private static func bakedTheme(in bundlePath: String) -> String {
        let markerPath = bundlePath + "/Contents/Resources/ThemeIcon.marker"
        let baked = (try? String(contentsOfFile: markerPath, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? HudTheme.classic.rawValue
        return baked
    }

    private static func syncBundleIcon(_ theme: HudTheme, _ image: CGImage) {
        let bundlePath = Bundle.main.bundlePath
        guard bundlePath.hasSuffix(".app") else { return }
        let resources = bundlePath + "/Contents/Resources"
        let markerPath = resources + "/ThemeIcon.marker"
        // A fresh install ships the classic icon and no marker.
        let baked = bakedTheme(in: bundlePath)
        guard baked != theme.rawValue else { return }
        guard FileManager.default.isWritableFile(atPath: resources) else {
            DiagLog.log("bundle not writable — Launchpad icon left as-is")
            return
        }
        // A distributed build is signed with a Developer ID and carries a
        // stapled notarization ticket. Any re-sign here invalidates that
        // ticket (it is bound to the signature), which is far worse than a
        // stale Launchpad icon: Gatekeeper would start questioning the app
        // and its TCC grants could be dropped. The running app still shows
        // the themed icon via NSApp.applicationIconImage.
        guard canSafelyResign(bundlePath) else {
            DiagLog.log("release-signed bundle — leaving the Launchpad icon alone")
            return
        }
        // The rewrite and re-sign must be transactional: bundle contents
        // that don't match the seal make validation fail and macOS silently
        // drops the app's Microphone/Accessibility grants. Both the icns AND
        // the marker are sealed resources, so both go in before signing and
        // both roll back if the sign/verify fails (identical restored bytes
        // mean the previous seal is valid again). A failed rebake is
        // retried on the next apply because the marker was rolled back too.
        // Backups live OUTSIDE the bundle: anything left inside Resources
        // while codesign runs would itself be sealed, and deleting it
        // afterwards would tear the seal all over again.
        let fm = FileManager.default
        let icnsPath = resources + "/AppIcon.icns"
        let markerExisted = fm.fileExists(atPath: markerPath)
        let backupDir = fm.temporaryDirectory
            .appendingPathComponent("LocalFlowIconBackup-\(UUID().uuidString)").path
        try? fm.createDirectory(atPath: backupDir, withIntermediateDirectories: true)
        let icnsBackup = backupDir + "/AppIcon.icns"
        let markerBackup = backupDir + "/ThemeIcon.marker"
        try? fm.removeItem(atPath: icnsBackup)
        try? fm.copyItem(atPath: icnsPath, toPath: icnsBackup)
        try? fm.removeItem(atPath: markerBackup)
        if markerExisted { try? fm.copyItem(atPath: markerPath, toPath: markerBackup) }
        // No verified backup, no rebake: without one, a later failure has
        // nothing to roll back to and the bundle would stay torn.
        let icnsBackedUp = !fm.fileExists(atPath: icnsPath) || fm.fileExists(atPath: icnsBackup)
        let markerBackedUp = !markerExisted || fm.fileExists(atPath: markerBackup)
        guard icnsBackedUp, markerBackedUp else {
            try? fm.removeItem(atPath: backupDir)
            DiagLog.log("could not back up current icon, leaving bundle untouched")
            return
        }
        func restorePrevious() {
            if fm.fileExists(atPath: icnsBackup) {
                try? fm.removeItem(atPath: icnsPath)
                try? fm.copyItem(atPath: icnsBackup, toPath: icnsPath)
            }
            try? fm.removeItem(atPath: markerPath)
            if markerExisted { try? fm.copyItem(atPath: markerBackup, toPath: markerPath) }
        }
        defer { try? fm.removeItem(atPath: backupDir) }

        guard writeIcns(image, to: icnsPath) else {
            restorePrevious()
            DiagLog.log("icon write failed, bundle icon left as-is")
            return
        }
        try? theme.rawValue.write(toFile: markerPath, atomically: true, encoding: .utf8)
        guard resign(bundlePath) else {
            restorePrevious()
            // Best effort: the failed attempt may have left a seal that no
            // longer matches the restored bytes; try once to reseal them.
            _ = resign(bundlePath)
            DiagLog.log("re-sign failed, previous icon restored; will retry on the next theme change")
            return
        }
        // Nudge LaunchServices/iconservices to pick the new icon up.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: bundlePath)
        _ = run(lsregister, ["-f", bundlePath])
        DiagLog.log("bundle icon rebaked for theme %@", theme.rawValue)
    }

    /// Same signing scheme as make-app.sh: the stable self-signed identity if
    /// present, else ad-hoc with the pinned identifier requirement — either
    /// way the designated requirement stays `identifier "app.talix.localflow"`,
    /// so TCC grants survive the rewrite.
    /// True only when the bundle's existing seal is one this machine can
    /// reproduce exactly: an ad-hoc signature, or the local development
    /// identity. Anything issued by Apple (Developer ID, Apple
    /// Development) belongs to a distributed build and must be left alone.
    private static func canSafelyResign(_ bundlePath: String) -> Bool {
        let description = run("/usr/bin/codesign", ["-dvv", bundlePath]).1
        let authorities = description
            .components(separatedBy: .newlines)
            .filter { $0.hasPrefix("Authority=") }
            .map { String($0.dropFirst("Authority=".count)) }
        guard let authority = authorities.first else {
            // No authority line: ad-hoc. Nothing to invalidate.
            return true
        }
        guard authority == localSigningIdentity else { return false }
        let identities = run("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"]).1
        return identities.contains(localSigningIdentity)
    }

    private static let localSigningIdentity = "Talix Dev Signing"

    private static func resign(_ bundlePath: String) -> Bool {
        let (_, identities) = run("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"])
        let result: (Int32, String)
        if identities.contains("Talix Dev Signing") {
            result = run("/usr/bin/codesign", [
                "--force", "--sign", "Talix Dev Signing",
                "--identifier", "app.talix.localflow", bundlePath,
            ])
        } else if run("/usr/bin/codesign", ["-dvv", bundlePath]).1.contains("Talix Dev Signing") {
            // The bundle carries the certificate-backed identity but the
            // keychain can't produce it right now (locked, transient error).
            // Downgrading to ad-hoc would change the designated requirement
            // and orphan the TCC grants; fail and let the rollback run.
            DiagLog.log("signing identity unavailable, refusing to downgrade the bundle to ad-hoc")
            return false
        } else {
            result = run("/usr/bin/codesign", [
                "--force", "--sign", "-",
                "--identifier", "app.talix.localflow",
                "-r=designated => identifier \"app.talix.localflow\"", bundlePath,
            ])
        }
        if result.0 != 0 {
            DiagLog.log("re-sign after icon rebake failed: %@", result.1)
            return false
        }
        // Trust the verifier, not codesign's exit status alone: this seal
        // is what stands between the app and losing its TCC grants.
        let verify = run("/usr/bin/codesign", ["--verify", "--deep", bundlePath])
        if verify.0 != 0 {
            DiagLog.log("re-signed bundle fails verification: %@", verify.1)
            return false
        }
        return true
    }

    private static func writeIcns(_ image: CGImage, to icnsPath: String) -> Bool {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("LocalFlowIcon-\(UUID().uuidString)")
        let iconset = tmp.appendingPathComponent("AppIcon.iconset")
        do {
            try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
        } catch {
            return false
        }
        defer { try? fm.removeItem(at: tmp) }

        let entries: [(Int, String)] = [
            (16, "icon_16x16"), (32, "icon_16x16@2x"),
            (32, "icon_32x32"), (64, "icon_32x32@2x"),
            (128, "icon_128x128"), (256, "icon_128x128@2x"),
            (256, "icon_256x256"), (512, "icon_256x256@2x"),
            (512, "icon_512x512"), (1024, "icon_512x512@2x"),
        ]
        for (size, name) in entries {
            let url = iconset.appendingPathComponent("\(name).png")
            guard let scaled = scale(image, to: size),
                  let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
                return false
            }
            CGImageDestinationAddImage(dest, scaled, nil)
            guard CGImageDestinationFinalize(dest) else { return false }
        }
        let (status, output) = run("/usr/bin/iconutil", ["-c", "icns", "-o", icnsPath, iconset.path])
        if status != 0 {
            DiagLog.log("iconutil failed: %@", output)
            return false
        }
        return true
    }

    private static func scale(_ image: CGImage, to size: Int) -> CGImage? {
        guard let ctx = CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        return ctx.makeImage()
    }

    private static func run(_ tool: String, _ args: [String]) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        // Drain the pipe before waiting: a chatty child can otherwise fill the
        // buffer and block on write while we block on exit.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// Dark plate gradient per theme, matching each design's world.
    private static func backdrop(_ theme: HudTheme) -> (HudColor, HudColor) {
        switch theme {
        case .classic: return (HudColor("#1A1F40"), HudColor("#0D2B33"))
        case .typeset: return (HudColor("#241318"), HudColor("#140D0A"))
        case .aurora: return (HudColor("#0A1220"), HudColor("#060A12"))
        case .bolide: return (HudColor("#191024"), HudColor("#0B0A14"))
        case .mercury: return (HudColor("#1B1F2C"), HudColor("#101319"))
        case .liquidGlass: return (HudColor("#18232D"), HudColor("#0B1118"))
        case .ticker: return (HudColor("#1E2128"), HudColor("#101216"))
        case .constellation: return (HudColor("#0D1428"), HudColor("#05070E"))
        case .loom: return (HudColor("#221418"), HudColor("#120C0E"))
        case .vapor: return (HudColor("#131C22"), HudColor("#0A0F14"))
        case .sonar: return (HudColor("#07202E"), HudColor("#04121C"))
        case .shorthand: return (HudColor("#151936"), HudColor("#0B0D18"))
        case .prism: return (HudColor("#1B1D26"), HudColor("#0D0E13"))
        case .murmuration: return (HudColor("#241B38"), HudColor("#5A3038")) // dusk
        case .filament: return (HudColor("#0E1322"), HudColor("#07080F"))
        case .bloom: return (HudColor("#1A2414"), HudColor("#0C1108"))
        case .pianola: return (HudColor("#241610"), HudColor("#120B07"))
        }
    }

    /// Each theme's icon is the bespoke mark designed on the concept board:
    /// the same glyph the HTML artboard drew, ported 1:1. The plate, radial
    /// light, and hairline edge are shared; the glyph is each theme's own.
    private static func compose(_ theme: HudTheme, canvas S: CGFloat = 1024) -> CGImage? {
        guard let ctx = CGContext(
            data: nil, width: Int(S), height: Int(S),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Apple margin: ~10% inset, ~22.5% corner radius.
        let inset = S * 0.098
        let plate = CGRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
        let radius = plate.width * 0.225
        let squircle = CGPath(roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil)

        let (top, bottom) = backdrop(theme)
        hudLinearGradient(ctx, from: CGPoint(x: 0, y: S), to: CGPoint(x: S * 0.25, y: 0),
                          stops: [(0, top.cg(1)), (1, bottom.cg(1))], clippedTo: squircle)

        ctx.saveGState()
        ctx.addPath(squircle)
        ctx.clip()
        hudRadialGlow(ctx, center: CGPoint(x: plate.midX, y: plate.midY),
                      radius: plate.width * 0.62, stops: [
                          (0, CGColor(gray: 1, alpha: 0.07)),
                          (1, CGColor(gray: 1, alpha: 0)),
                      ])
        // The artboard glyphs were drawn y-down; flip once and port verbatim.
        ctx.translateBy(x: 0, y: S)
        ctx.scaleBy(x: 1, y: -1)
        drawGlyph(theme, ctx, S)
        ctx.restoreGState()

        // Hairline inner edge to lift the plate off light backgrounds.
        ctx.addPath(CGPath(roundedRect: plate.insetBy(dx: 3, dy: 3),
                           cornerWidth: radius - 3, cornerHeight: radius - 3, transform: nil))
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.08))
        ctx.setLineWidth(6 * S / 1024)
        ctx.strokePath()

        return ctx.makeImage()
    }

    // MARK: Per-theme glyphs (ports of the concept-board icons)

    private static func roundedRect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
        CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h),
               cornerWidth: min(r, w / 2), cornerHeight: min(r, h / 2), transform: nil)
    }

    private static func circle(_ ctx: CGContext, _ x: CGFloat, _ y: CGFloat, _ r: CGFloat) {
        ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    }

    /// Stroke a path with a linear gradient (stroke → clip → gradient).
    private static func strokeGradient(_ ctx: CGContext, _ path: CGPath, width: CGFloat,
                                       from: CGPoint, to: CGPoint, stops: [(CGFloat, CGColor)]) {
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        hudLinearGradient(ctx, from: from, to: to, stops: stops)
        ctx.restoreGState()
    }

    private static func drawGlyph(_ theme: HudTheme, _ ctx: CGContext, _ S: CGFloat) {
        switch theme {
        case .classic: classicGlyph(ctx, S)
        case .typeset: typesetGlyph(ctx, S)
        case .aurora: auroraGlyph(ctx, S)
        case .bolide: bolideGlyph(ctx, S)
        case .mercury: mercuryGlyph(ctx, S)
        case .liquidGlass: liquidGlassGlyph(ctx, S)
        case .ticker: tickerGlyph(ctx, S)
        case .constellation: constellationGlyph(ctx, S)
        case .loom: loomGlyph(ctx, S)
        case .vapor: vaporGlyph(ctx, S)
        case .sonar: sonarGlyph(ctx, S)
        case .shorthand: shorthandGlyph(ctx, S)
        case .prism: prismGlyph(ctx, S)
        case .murmuration: murmurationGlyph(ctx, S)
        case .filament: filamentGlyph(ctx, S)
        case .bloom: bloomGlyph(ctx, S)
        case .pianola: pianolaGlyph(ctx, S)
        }
    }

    /// The original hand-made icon: organic glowing wave, teal→orchid.
    private static func classicGlyph(_ ctx: CGContext, _ S: CGFloat) {
        let left = S * 0.184, right = S * 0.816, midY = S * 0.5
        func wavePath(_ amplitudeScale: CGFloat) -> CGPath {
            let n = 48
            let step = (right - left) / CGFloat(n - 1)
            var topPts: [CGPoint] = []
            var bottomPts: [CGPoint] = []
            for i in 0..<n {
                let u = CGFloat(i) / CGFloat(n - 1)
                let envelope = pow(sin(.pi * u), 0.9)
                let texture = abs(sin(u * 14.0) * sin(u * 6.3 + 1.2)) * 0.65 + 0.35
                let amplitude = max(S * 0.006, S * 0.205 * amplitudeScale * envelope * texture)
                let x = left + CGFloat(i) * step
                topPts.append(CGPoint(x: x, y: midY - amplitude))
                bottomPts.append(CGPoint(x: x, y: midY + amplitude))
            }
            let path = CGMutablePath()
            path.move(to: topPts[0])
            hudSmoothPath(path, through: topPts)
            path.addLine(to: bottomPts[bottomPts.count - 1])
            hudSmoothPath(path, through: bottomPts.reversed())
            path.closeSubpath()
            return path
        }
        ctx.addPath(wavePath(1.30))
        ctx.setFillColor(CGColor(red: 0.45, green: 0.75, blue: 0.95, alpha: 0.20))
        ctx.fillPath()
        let wave = wavePath(1.0)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: S * 0.068, color: HudColor("#4DD9CC").cg(0.65))
        ctx.addPath(wave)
        ctx.setFillColor(HudColor("#4DD9CC").cg(0.9))
        ctx.fillPath()
        ctx.restoreGState()
        hudLinearGradient(ctx, from: CGPoint(x: left, y: 0), to: CGPoint(x: right, y: 0), stops: [
            (0.00, HudColor("#40DED1").cg(1)), (0.33, HudColor("#6BF0AE").cg(1)),
            (0.67, HudColor("#8C9EF8").cg(1)), (1.00, HudColor("#C285F2").cg(1)),
        ], clippedTo: wave)
    }

    /// Molten flicks cooling into a set line of ink, with the glowing caret.
    private static func typesetGlyph(_ ctx: CGContext, _ S: CGFloat) {
        let base = S * 0.56, left = S * 0.20, right = S * 0.72
        let molten = HudRamp([(0, "#FFC46B"), (0.5, "#F65E8E"), (1, "#B07CF7")])
        let flicks: [CGFloat] = [0.9, 0.5, 0.95, 0.35, 0.7, 0.25]
        ctx.setLineCap(.round)
        for (i, f) in flicks.enumerated() {
            let u = CGFloat(i) / CGFloat(flicks.count - 1)
            let x = left + (right - left - S * 0.14) * u + S * 0.10
            let wet = u // fresher toward the caret
            let c = molten.at(f)
            ctx.saveGState()
            ctx.setStrokeColor(c.cg(0.25 + 0.75 * wet))
            ctx.setLineWidth(S * 0.035)
            ctx.setShadow(offset: .zero, blur: S * 0.05 * wet, color: c.cg(0.6 * wet))
            ctx.move(to: CGPoint(x: x, y: base + S * 0.008))
            ctx.addLine(to: CGPoint(x: x, y: base - f * S * 0.26 * (0.3 + wet * 0.7)))
            ctx.strokePath()
            ctx.restoreGState()
        }
        ctx.setStrokeColor(HudColor("#F4E9D4").cg(0.95))
        ctx.setLineWidth(S * 0.035)
        ctx.move(to: CGPoint(x: left, y: base))
        ctx.addLine(to: CGPoint(x: right, y: base))
        ctx.strokePath()
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: S * 0.06, color: HudColor("#FFC46B").cg(0.8))
        ctx.setFillColor(HudColor("#FFD68C").cg(1))
        ctx.addPath(roundedRect(right + S * 0.05, base - S * 0.11, S * 0.035, S * 0.22, S * 0.02))
        ctx.fillPath()
        ctx.restoreGState()
    }

    /// Four northern-light curtains.
    private static func auroraGlyph(_ ctx: CGContext, _ S: CGFloat) {
        let colors = ["#3AF0A0", "#3DD6F5", "#6E7BFF", "#D96BFF"].map { HudColor($0) }
        ctx.saveGState()
        ctx.setBlendMode(.plusLighter)
        for i in 0..<4 {
            let x = S * (0.26 + CGFloat(i) * 0.17)
            let height = S * (0.5 - abs(CGFloat(i) - 1.6) * 0.09)
            let w = S * 0.09
            let path = CGMutablePath()
            path.move(to: CGPoint(x: x - w / 2, y: S * 0.80))
            path.addQuadCurve(to: CGPoint(x: x - w / 4, y: S * 0.80 - height),
                              control: CGPoint(x: x - w * 0.8, y: S * 0.5))
            path.addLine(to: CGPoint(x: x + w / 4, y: S * 0.80 - height))
            path.addQuadCurve(to: CGPoint(x: x + w / 2, y: S * 0.80),
                              control: CGPoint(x: x + w * 0.2, y: S * 0.5))
            path.closeSubpath()
            hudLinearGradient(ctx, from: CGPoint(x: 0, y: S * 0.80),
                              to: CGPoint(x: 0, y: S * 0.80 - height), stops: [
                                  (0, colors[i].cg(0)),
                                  (0.35, colors[i].cg(0.8)),
                                  (1, colors[i].cg(0)),
                              ], clippedTo: path)
        }
        ctx.restoreGState()
    }

    /// Comet head with a cooling dust trail.
    private static func bolideGlyph(_ ctx: CGContext, _ S: CGFloat) {
        let hx = S * 0.68, hy = S * 0.46
        let cool = HudRamp([(0, "#FFF7E8"), (0.3, "#FFC46B"), (0.6, "#FF6B5E"), (1, "#4D5C9E")])
        ctx.saveGState()
        ctx.setBlendMode(.plusLighter)
        for i in 0..<46 {
            let u = CGFloat(i) / 45
            let x = hx - u * S * 0.46 - CGFloat((i * i * 7) % 13) / 13 * S * 0.03
            let y = hy + sin(CGFloat(i) * 2.7) * S * 0.085 * u + sin(CGFloat(i) * 1.3) * S * 0.02
            let r = S * 0.02 * (1 - u * 0.5) + CGFloat((i * 5) % 7) / 7 * S * 0.008
            ctx.setFillColor(cool.at(u).cg((1 - u) * 0.85))
            circle(ctx, x, y, r)
        }
        hudRadialGlow(ctx, center: CGPoint(x: hx, y: hy), radius: S * 0.2, stops: [
            (0.0, HudColor("#FFFBF0").cg(1)),
            (0.4, HudColor("#FFC46B").cg(0.6)),
            (1.0, HudColor("#FF785A").cg(0)),
        ])
        ctx.restoreGState()
    }

    /// Iridescent liquid pool with a specular surface.
    private static func mercuryGlyph(_ ctx: CGContext, _ S: CGFloat) {
        let base = S * 0.55
        func surface(_ path: CGMutablePath) {
            path.move(to: CGPoint(x: S * 0.06, y: base + S * 0.05))
            path.addCurve(to: CGPoint(x: S * 0.62, y: base - S * 0.06),
                          control1: CGPoint(x: S * 0.3, y: base - S * 0.16),
                          control2: CGPoint(x: S * 0.45, y: base + S * 0.14))
            path.addCurve(to: CGPoint(x: S * 0.94, y: base - S * 0.02),
                          control1: CGPoint(x: S * 0.76, y: base - S * 0.20),
                          control2: CGPoint(x: S * 0.86, y: base + S * 0.02))
        }
        let body = CGMutablePath()
        surface(body)
        body.addLine(to: CGPoint(x: S * 0.94, y: S * 0.94))
        body.addLine(to: CGPoint(x: S * 0.06, y: S * 0.94))
        body.closeSubpath()
        hudLinearGradient(ctx, from: CGPoint(x: 0, y: 0), to: CGPoint(x: S, y: 0), stops: [
            (0.00, HudColor("#62F0C8").cg(1)), (0.38, HudColor("#6FA8FF").cg(1)),
            (0.70, HudColor("#C77BFF").cg(1)), (1.00, HudColor("#FF8FB8").cg(1)),
        ], clippedTo: body)
        hudLinearGradient(ctx, from: CGPoint(x: 0, y: base - S * 0.2), to: CGPoint(x: 0, y: S), stops: [
            (0, HudColor("#101319").cg(0)), (1, HudColor("#101319").cg(0.8)),
        ], clippedTo: body)
        let spec = CGMutablePath()
        surface(spec)
        ctx.addPath(spec)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.75))
        ctx.setLineWidth(S * 0.018)
        ctx.setLineCap(.round)
        ctx.strokePath()
    }

    /// The Apple Intelligence bar wave — the marketing site's hero waveform,
    /// frozen mid-phrase: symmetric rounded bars through the four-hue
    /// gradient, each with the renderer's soft halo behind a bright core.
    private static func liquidGlassGlyph(_ ctx: CGContext, _ S: CGFloat) {
        let heights: [CGFloat] = [14, 26, 40, 58, 44, 70, 52, 82, 60, 88, 66,
                                  90, 58, 76, 46, 64, 38, 52, 28, 40, 18, 30, 12]
        let intelligence = HudRamp([
            (0.00, "#0A84FF"), (0.25, "#BF5AF2"), (0.50, "#FF375F"),
            (0.75, "#FF9F0A"), (1.00, "#0A84FF"),
        ])
        let left = S * 0.175
        let pitch = S * 0.65 / CGFloat(heights.count)
        let core = pitch * 0.40
        let midY = S * 0.5
        let maxHalf = S * 0.21
        ctx.saveGState()
        ctx.setBlendMode(.plusLighter)
        for (i, h) in heights.enumerated() {
            let u = (CGFloat(i) + 0.5) / CGFloat(heights.count)
            let color = intelligence.at(u)
            let half = max(S * 0.010, maxHalf * h / 100)
            let x = left + (CGFloat(i) + 0.5) * pitch
            func bar(_ w: CGFloat, _ alpha: CGFloat) {
                ctx.setFillColor(color.cg(alpha))
                ctx.addPath(roundedRect(x - w / 2, midY - half, w, half * 2, w / 2))
                ctx.fillPath()
            }
            bar(core * 2.8, 0.10)
            bar(core * 1.7, 0.22)
            bar(core, 0.95)
        }
        ctx.restoreGState()
    }

    /// Paper tape with a graphite trace and red peak stamps.
    private static func tickerGlyph(_ ctx: CGContext, _ S: CGFloat) {
        ctx.saveGState()
        let tape = roundedRect(S * 0.12, S * 0.33, S * 0.76, S * 0.34, S * 0.05)
        ctx.addPath(tape)
        ctx.setFillColor(HudColor("#EDE7DA").cg(1))
        ctx.fillPath()
        ctx.addPath(tape)
        ctx.clip()
        ctx.setStrokeColor(HudColor("#2E3038").cg(0.12))
        ctx.setLineWidth(S * 0.008)
        var x = S * 0.12
        while x < S * 0.9 {
            ctx.move(to: CGPoint(x: x, y: S * 0.33))
            ctx.addLine(to: CGPoint(x: x, y: S * 0.67))
            x += S * 0.09
        }
        ctx.strokePath()
        let mid = S * 0.5
        let segments: [(CGFloat, CGFloat)] = [
            (0.2, 0.02), (0.28, -0.05), (0.36, 0.1), (0.44, -0.13), (0.5, 0.04),
            (0.58, -0.03), (0.66, 0.11), (0.74, -0.06), (0.88, 0.01),
        ]
        ctx.setStrokeColor(HudColor("#2E3038").cg(1))
        ctx.setLineWidth(S * 0.022)
        ctx.setLineJoin(.round)
        ctx.move(to: CGPoint(x: S * 0.12, y: mid))
        for (sx, sv) in segments {
            ctx.addLine(to: CGPoint(x: S * sx, y: mid - S * sv))
        }
        ctx.strokePath()
        ctx.setFillColor(HudColor("#FF4D3D").cg(1))
        circle(ctx, S * 0.44, mid + S * 0.13, S * 0.028)
        circle(ctx, S * 0.66, mid - S * 0.11, S * 0.028)
        ctx.restoreGState()
    }

    /// A small constellation joined by chart lines.
    private static func constellationGlyph(_ ctx: CGContext, _ S: CGFloat) {
        for i in 0..<22 {
            ctx.setFillColor(HudColor("#E6EBFF").cg(0.10 + CGFloat((i * 31) % 17) / 17 * 0.12))
            let x = S * 0.1 + CGFloat((i * 137) % 809) / 809 * S * 0.8
            let y = S * 0.1 + CGFloat((i * 211) % 613) / 613 * S * 0.8
            ctx.fill(CGRect(x: x, y: y, width: S * 0.012, height: S * 0.012))
        }
        let pts: [(CGFloat, CGFloat)] = [(0.20, 0.62), (0.33, 0.42), (0.46, 0.58),
                                         (0.60, 0.34), (0.71, 0.52), (0.81, 0.40)]
        ctx.setStrokeColor(HudColor("#6C8FD0").cg(0.55))
        ctx.setLineWidth(S * 0.012)
        ctx.move(to: CGPoint(x: S * pts[0].0, y: S * pts[0].1))
        for (px, py) in pts.dropFirst() {
            ctx.addLine(to: CGPoint(x: S * px, y: S * py))
        }
        ctx.strokePath()
        for (i, (px, py)) in pts.enumerated() {
            let big = i == 3
            let R = big ? S * 0.045 : S * 0.026
            let c = CGPoint(x: S * px, y: S * py)
            hudRadialGlow(ctx, center: c, radius: R * 3, stops: [
                (0.0, HudColor("#FFEFC4").cg(1)),
                (0.4, HudColor("#FFE9B8").cg(0.4)),
                (1.0, HudColor("#FFE9B8").cg(0)),
            ])
            ctx.setFillColor(HudColor("#FAF6EB").cg(0.95))
            circle(ctx, c.x, c.y, R * 0.6)
            if big {
                ctx.setStrokeColor(HudColor("#FFF4D6").cg(0.6))
                ctx.setLineWidth(S * 0.008)
                ctx.move(to: CGPoint(x: c.x - R * 2.6, y: c.y))
                ctx.addLine(to: CGPoint(x: c.x + R * 2.6, y: c.y))
                ctx.move(to: CGPoint(x: c.x, y: c.y - R * 2.6))
                ctx.addLine(to: CGPoint(x: c.x, y: c.y + R * 2.6))
                ctx.strokePath()
            }
        }
    }

    /// Warp threads with a woven band of colored picks.
    private static func loomGlyph(_ ctx: CGContext, _ S: CGFloat) {
        ctx.setStrokeColor(HudColor("#E8DFC8").cg(0.14))
        ctx.setLineWidth(S * 0.008)
        var wx = S * 0.14
        while wx < S * 0.88 {
            ctx.move(to: CGPoint(x: wx, y: S * 0.12))
            ctx.addLine(to: CGPoint(x: wx, y: S * 0.88))
            wx += S * 0.065
        }
        ctx.strokePath()
        let rows = ["#F2B94B", "#E85D4A", "#3FBF8F", "#4C6EE6", "#F2B94B"].map { HudColor($0) }
        let cw = S * 0.065, ch = S * 0.062, top = S * 0.34
        for (r, color) in rows.enumerated() {
            for c in 0..<11 {
                let px = S * 0.14 + CGFloat(c) * cw
                if px > S * 0.85 { break }
                let shade: CGFloat = (r + c) % 2 == 0 ? 1 : 0.72
                ctx.setFillColor(HudColor(r: color.r * shade, g: color.g * shade, b: color.b * shade).cg(0.96))
                ctx.addPath(roundedRect(px - cw * 0.42, top + CGFloat(r) * ch, cw * 0.8, ch * 0.82, S * 0.012))
                ctx.fillPath()
            }
        }
    }

    /// Wisps of breath thinning as they drift.
    private static func vaporGlyph(_ ctx: CGContext, _ S: CGFloat) {
        ctx.saveGState()
        ctx.setBlendMode(.screen)
        let wisps: [(CGFloat, CGFloat, CGFloat, String, CGFloat)] = [
            (0.72, 0.58, 0.10, "#A8F0DC", 0.55),
            (0.58, 0.48, 0.14, "#A8F0DC", 0.38),
            (0.44, 0.42, 0.17, "#9CCBFF", 0.30),
            (0.31, 0.38, 0.20, "#C9B8FF", 0.22),
            (0.20, 0.34, 0.22, "#C9B8FF", 0.13),
        ]
        for (x, y, r, hexColor, alpha) in wisps {
            let c = HudColor(hexColor)
            hudRadialGlow(ctx, center: CGPoint(x: S * x, y: S * y), radius: S * r, stops: [
                (0, c.cg(alpha)), (1, c.cg(0)),
            ])
        }
        ctx.restoreGState()
        ctx.setFillColor(HudColor("#EAF4F4").cg(0.9))
        circle(ctx, S * 0.78, S * 0.60, S * 0.022)
    }

    /// Left-facing echo arcs from a bright emitter.
    private static func sonarGlyph(_ ctx: CGContext, _ S: CGFloat) {
        let ex = S * 0.72, ey = S * 0.5
        func arc(_ r: CGFloat) {
            for k in 0...26 {
                let a = .pi * 0.62 + .pi * 0.76 * CGFloat(k) / 26
                let p = CGPoint(x: ex + cos(a) * r, y: ey + sin(a) * r)
                if k == 0 { ctx.move(to: p) } else { ctx.addLine(to: p) }
            }
            ctx.strokePath()
        }
        ctx.setLineCap(.round)
        ctx.setLineWidth(S * 0.018)
        for (radius, alpha) in [(0.14, 0.85), (0.26, 0.55), (0.38, 0.32), (0.50, 0.16)] {
            ctx.setStrokeColor(HudColor("#45E8D0").cg(alpha))
            arc(S * radius)
        }
        for i in 0..<10 {
            ctx.setFillColor(HudColor("#9ADCE8").cg(0.12 + CGFloat((i * 29) % 13) / 13 * 0.1))
            let x = S * 0.12 + CGFloat((i * 173) % 607) / 607 * S * 0.7
            let y = S * 0.14 + CGFloat((i * 241) % 509) / 509 * S * 0.72
            ctx.fill(CGRect(x: x, y: y, width: S * 0.014, height: S * 0.014))
        }
        hudRadialGlow(ctx, center: CGPoint(x: ex, y: ey), radius: S * 0.08, stops: [
            (0.0, HudColor("#DCFFF6").cg(1)),
            (0.5, HudColor("#45E8D0").cg(0.6)),
            (1.0, HudColor("#45E8D0").cg(0)),
        ])
    }

    /// A cursive shorthand loop, faded ink to fresh, with the glowing nib.
    private static func shorthandGlyph(_ ctx: CGContext, _ S: CGFloat) {
        let path = CGMutablePath()
        var nib = CGPoint.zero
        for i in 0...72 {
            let u = CGFloat(i) / 72
            let px = S * (0.82 - 0.62 * u) + cos(u * .pi * 4 + 0.6) * S * 0.055
            let py = S * 0.52 + sin(u * .pi * 4 + 0.6) * S * (0.05 + 0.05 * sin(u * .pi)) + sin(u * 5) * S * 0.03
            if i == 0 {
                path.move(to: CGPoint(x: px, y: py))
                nib = CGPoint(x: px, y: py)
            } else {
                path.addLine(to: CGPoint(x: px, y: py))
            }
        }
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: S * 0.04, color: HudColor("#6BE8F0").cg(0.4))
        strokeGradient(ctx, path, width: S * 0.028,
                       from: CGPoint(x: S * 0.15, y: 0), to: CGPoint(x: S * 0.85, y: 0), stops: [
                           (0.0, HudColor("#4A4E86").cg(1)),
                           (0.5, HudColor("#7B8AF5").cg(1)),
                           (1.0, HudColor("#6BE8F0").cg(1)),
                       ])
        ctx.restoreGState()
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: S * 0.05, color: HudColor("#6BE8F0").cg(0.9))
        ctx.setFillColor(HudColor("#DCFAFC").cg(0.95))
        circle(ctx, nib.x, nib.y, S * 0.028)
        ctx.restoreGState()
    }

    /// White beam in, spectrum fan out.
    private static func prismGlyph(_ ctx: CGContext, _ S: CGFloat) {
        let px = S * 0.58, py = S * 0.46
        ctx.setStrokeColor(HudColor("#F8F5EE").cg(0.85))
        ctx.setLineWidth(S * 0.022)
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: S * 0.92, y: py))
        ctx.addLine(to: CGPoint(x: px + S * 0.06, y: py))
        ctx.strokePath()
        let colors = ["#FF6B6B", "#FFC46B", "#F2E86B", "#5EE889", "#5EA8FF", "#B57BFF"].map { HudColor($0) }
        ctx.saveGState()
        ctx.setBlendMode(.plusLighter)
        for i in 0..<6 {
            let dy = (CGFloat(i) - 2.5) * S * 0.062
            let ray = CGMutablePath()
            ray.move(to: CGPoint(x: px - S * 0.07, y: py + dy * 0.12))
            ray.addLine(to: CGPoint(x: S * 0.10, y: py + dy))
            strokeGradient(ctx, ray, width: S * 0.030,
                           from: CGPoint(x: px - S * 0.07, y: 0), to: CGPoint(x: S * 0.10, y: 0), stops: [
                               (0, colors[i].cg(0.94)), (1, colors[i].cg(0)),
                           ])
        }
        ctx.restoreGState()
        let triangle = CGMutablePath()
        triangle.move(to: CGPoint(x: px, y: py - S * 0.14))
        triangle.addLine(to: CGPoint(x: px - S * 0.115, y: py + S * 0.105))
        triangle.addLine(to: CGPoint(x: px + S * 0.115, y: py + S * 0.105))
        triangle.closeSubpath()
        ctx.addPath(triangle)
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.08))
        ctx.fillPath()
        ctx.addPath(triangle)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.5))
        ctx.setLineWidth(S * 0.012)
        ctx.strokePath()
    }

    /// A swoosh of starlings over a dusk horizon.
    private static func murmurationGlyph(_ ctx: CGContext, _ S: CGFloat) {
        hudLinearGradient(ctx, from: CGPoint(x: 0, y: 0), to: CGPoint(x: 0, y: S), stops: [
            (0.00, HudColor("#241B38").cg(1)),
            (0.72, HudColor("#3A2440").cg(1)),
            (1.00, HudColor("#5A3038").cg(1)),
        ])
        hudLinearGradient(ctx, from: CGPoint(x: 0, y: S * 0.7), to: CGPoint(x: 0, y: S * 0.95), stops: [
            (0, HudColor("#FFB98A").cg(0)), (1, HudColor("#FFB98A").cg(0.30)),
        ])
        ctx.setLineCap(.round)
        for i in 0..<52 {
            let u = CGFloat(i) / 51
            let jx = (CGFloat((i * 137) % 401) / 401 - 0.5) * S * 0.13 * (0.4 + u)
            let jy = (CGFloat((i * 211) % 307) / 307 - 0.5) * S * 0.14 * (0.4 + u)
            let x = S * (0.82 - 0.62 * u) + jx
            let y = S * (0.34 + 0.30 * sin(u * 2.6 + 0.4)) + jy
            let angle = atan2(cos(u * 2.6 + 0.4) * 0.55, -1)
            let len = S * (0.012 + 0.008 * CGFloat((i * 53) % 97) / 97)
            ctx.setStrokeColor(HudColor("#DEE2F0").cg(0.35 + CGFloat(i % 4) * 0.16))
            ctx.setLineWidth(S * 0.010)
            ctx.move(to: CGPoint(x: x - cos(angle) * len, y: y - sin(angle) * len))
            ctx.addLine(to: CGPoint(x: x + cos(angle) * len, y: y + sin(angle) * len))
            ctx.strokePath()
        }
    }

    /// A jagged arc between copper terminals, with one fork.
    private static func filamentGlyph(_ ctx: CGContext, _ S: CGFloat) {
        let mid = S * 0.5
        let zig: [(CGFloat, CGFloat)] = [(0.18, 0), (0.28, -0.05), (0.36, 0.03), (0.45, -0.09),
                                         (0.52, 0.06), (0.60, -0.02), (0.68, 0.07), (0.76, -0.03), (0.82, 0)]
        func trace() {
            ctx.move(to: CGPoint(x: S * zig[0].0, y: mid + S * zig[0].1))
            for (zx, zy) in zig.dropFirst() {
                ctx.addLine(to: CGPoint(x: S * zx, y: mid + S * zy))
            }
        }
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: S * 0.06, color: HudColor("#6BB8FF").cg(0.9))
        ctx.setStrokeColor(HudColor("#6BB8FF").cg(0.55))
        ctx.setLineWidth(S * 0.030)
        trace()
        ctx.strokePath()
        ctx.restoreGState()
        ctx.setStrokeColor(HudColor("#F2F6FF").cg(0.95))
        ctx.setLineWidth(S * 0.012)
        trace()
        ctx.strokePath()
        ctx.setStrokeColor(HudColor("#A87BFF").cg(0.8))
        ctx.setLineWidth(S * 0.010)
        ctx.move(to: CGPoint(x: S * 0.45, y: mid - S * 0.09))
        ctx.addLine(to: CGPoint(x: S * 0.40, y: mid - S * 0.17))
        ctx.addLine(to: CGPoint(x: S * 0.34, y: mid - S * 0.21))
        ctx.strokePath()
        for tx in [S * 0.13, S * 0.87] {
            ctx.setFillColor(HudColor("#B87E45").cg(1))
            circle(ctx, tx, mid, S * 0.045)
            ctx.setFillColor(HudColor("#E8A25E").cg(1))
            circle(ctx, tx - S * 0.008, mid - S * 0.008, S * 0.026)
        }
    }

    /// A vine with leaves, one blossom, and the glowing growth tip.
    private static func bloomGlyph(_ ctx: CGContext, _ S: CGFloat) {
        ctx.setStrokeColor(HudColor("#4FBF7A").cg(1))
        ctx.setLineWidth(S * 0.025)
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: S * 0.14, y: S * 0.62))
        ctx.addCurve(to: CGPoint(x: S * 0.80, y: S * 0.52),
                     control1: CGPoint(x: S * 0.34, y: S * 0.50),
                     control2: CGPoint(x: S * 0.52, y: S * 0.66))
        ctx.strokePath()
        ctx.setFillColor(HudColor("#7ADB8F").cg(1))
        for (lx, ly, rotation, offset, rx, ry) in [
            (0.36, 0.55, CGFloat(-0.9), CGFloat(-0.055), CGFloat(0.035), CGFloat(0.062)),
            (0.56, 0.63, CGFloat(0.95), CGFloat(0.055), CGFloat(0.032), CGFloat(0.058)),
        ] {
            ctx.saveGState()
            ctx.translateBy(x: S * CGFloat(lx), y: S * CGFloat(ly))
            ctx.rotate(by: rotation)
            ctx.fillEllipse(in: CGRect(x: -S * rx, y: S * offset - S * ry,
                                       width: S * rx * 2, height: S * ry * 2))
            ctx.restoreGState()
        }
        let bx = S * 0.66, by = S * 0.40, R = S * 0.085
        ctx.setFillColor(HudColor("#FF8A7A").cg(1))
        for p in 0..<5 {
            let angle = CGFloat(p) * 1.2566 - 0.3
            ctx.saveGState()
            ctx.translateBy(x: bx + cos(angle) * R, y: by + sin(angle) * R)
            ctx.rotate(by: angle)
            ctx.fillEllipse(in: CGRect(x: -R * 0.62, y: -R * 0.42, width: R * 1.24, height: R * 0.84))
            ctx.restoreGState()
        }
        ctx.setFillColor(HudColor("#FFD37A").cg(1))
        circle(ctx, bx, by, R * 0.34)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: S * 0.05, color: HudColor("#7ADB8F").cg(0.9))
        ctx.setFillColor(HudColor("#BEF0BE").cg(0.95))
        circle(ctx, S * 0.80, S * 0.52, S * 0.032)
        ctx.restoreGState()
    }

    /// A punched piano roll under a brass tracker bar.
    private static func pianolaGlyph(_ ctx: CGContext, _ S: CGFloat) {
        ctx.saveGState()
        let band = roundedRect(S * 0.10, S * 0.30, S * 0.80, S * 0.40, S * 0.04)
        ctx.addPath(band)
        ctx.setFillColor(HudColor("#F2E8CF").cg(1))
        ctx.fillPath()
        ctx.addPath(band)
        ctx.clip()
        ctx.setFillColor(HudColor("#26211A").cg(0.4))
        var px = S * 0.13
        while px < S * 0.9 {
            circle(ctx, px, S * 0.335, S * 0.009)
            circle(ctx, px, S * 0.665, S * 0.009)
            px += S * 0.075
        }
        ctx.setStrokeColor(HudColor("#26211A").cg(0.14))
        ctx.setLineWidth(S * 0.008)
        for lane in 0..<4 {
            let y = S * (0.385 + CGFloat(lane) * 0.077)
            ctx.move(to: CGPoint(x: S * 0.10, y: y))
            ctx.addLine(to: CGPoint(x: S * 0.90, y: y))
        }
        ctx.strokePath()
        ctx.setFillColor(HudColor("#26211A").cg(1))
        let slots: [(CGFloat, CGFloat, CGFloat)] = [
            (0.16, 0.385, 0.10), (0.34, 0.539, 0.16), (0.30, 0.462, 0.07),
            (0.56, 0.616, 0.12), (0.60, 0.385, 0.08),
        ]
        for (sx, sy, sl) in slots {
            ctx.addPath(roundedRect(S * sx, S * sy - S * 0.020, S * sl, S * 0.040, S * 0.020))
            ctx.fillPath()
        }
        hudLinearGradient(ctx, from: CGPoint(x: S * 0.78, y: 0), to: CGPoint(x: S * 0.835, y: 0), stops: [
            (0.0, HudColor("#E8BC66").cg(1)), (0.5, HudColor("#D9A84E").cg(1)), (1.0, HudColor("#A8783A").cg(1)),
        ], clippedTo: roundedRect(S * 0.78, S * 0.31, S * 0.055, S * 0.38, S * 0.025))
        ctx.setFillColor(HudColor("#C24545").cg(0.95))
        circle(ctx, S * 0.808, S * 0.462, S * 0.018)
        ctx.restoreGState()
    }
}
