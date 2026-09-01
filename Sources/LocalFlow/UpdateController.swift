import AppKit
import Sparkle

/// In-app updates via Sparkle.
///
/// Distribution builds check a signed appcast published with each GitHub
/// release, download the new build, and install it on quit. Two signatures
/// have to line up before anything is installed: the EdDSA signature on the
/// appcast entry (so a hijacked feed cannot serve a malicious build) and the
/// Developer ID code signature, which Sparkle requires to match the running
/// app.
///
/// Local development builds are ad-hoc or self-signed, so their signature
/// can never match a released build. Sparkle is therefore left dormant
/// unless the running copy is the real, Developer ID signed article.
@MainActor
final class UpdateController: NSObject {
    struct AutomaticPreferenceChanges {
        let checks: Bool?
        let downloads: Bool?
    }

    enum ManualCheckDisposition: Equatable {
        case perform
        case busy
        case unavailable
    }

    private var updater: SPUStandardUpdaterController?

    /// True when this build can actually install an update. A dev build
    /// would download the release and then fail signature validation at
    /// install time, which is worse than never offering.
    static let isSupported: Bool = {
        guard Bundle.main.bundlePath.hasSuffix(".app") else { return false }
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return false }
        return signedForDistribution
    }()

    private static var signedForDistribution: Bool {
        var code: SecStaticCode?
        let url = Bundle.main.bundleURL as CFURL
        guard SecStaticCodeCreateWithPath(url, [], &code) == errSecSuccess, let code else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any],
              let authorities = dictionary["certificates"] as? [SecCertificate],
              let leaf = authorities.first else { return false }
        var commonName: CFString?
        SecCertificateCopyCommonName(leaf, &commonName)
        return (commonName as String?)?.hasPrefix("Developer ID Application") ?? false
    }

    func start() {
        guard Self.isSupported else {
            DiagLog.log("updates disabled (not a Developer ID signed bundle)")
            return
        }
        let updater = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        self.updater = updater
        // Configure Sparkle before it starts. Mutating this setting after
        // start schedules another update cycle even when the value is equal.
        applyAutomaticPreference()
        updater.startUpdater()
        DiagLog.log("update checks active (automatic=%d)", Settings.automaticUpdates ? 1 : 0)
    }

    /// Mirrors the Settings toggle onto the live updater.
    func applyAutomaticPreference() {
        guard let updater = updater?.updater else { return }
        let changes = Self.automaticPreferenceChanges(
            currentChecks: updater.automaticallyChecksForUpdates,
            currentDownloads: updater.automaticallyDownloadsUpdates,
            desired: Settings.automaticUpdates
        )
        if let checks = changes.checks {
            updater.automaticallyChecksForUpdates = checks
        }
        if let downloads = changes.downloads {
            updater.automaticallyDownloadsUpdates = downloads
        }
    }

    static func automaticPreferenceChanges(
        currentChecks: Bool,
        currentDownloads: Bool,
        desired: Bool
    ) -> AutomaticPreferenceChanges {
        AutomaticPreferenceChanges(
            checks: currentChecks == desired ? nil : desired,
            downloads: currentDownloads == desired ? nil : desired
        )
    }

    static func manualCheckDisposition(
        canCheckForUpdates: Bool,
        sessionInProgress: Bool
    ) -> ManualCheckDisposition {
        if canCheckForUpdates { return .perform }
        return sessionInProgress ? .busy : .unavailable
    }

    /// Menu action. Always shows UI, even when the background check is off.
    @objc func checkForUpdates(_ sender: Any?) {
        guard let updater else {
            let alert = NSAlert()
            alert.messageText = "Updates aren't available in this build"
            alert.informativeText = """
            Automatic updates only work in the signed release build. This copy \
            was built locally, so install new versions with make-app.sh or from \
            the GitHub releases page.
            """
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }
        let sparkleUpdater = updater.updater
        switch Self.manualCheckDisposition(
            canCheckForUpdates: sparkleUpdater.canCheckForUpdates,
            sessionInProgress: sparkleUpdater.sessionInProgress
        ) {
        case .perform:
            NSApp.activate(ignoringOtherApps: true)
            updater.checkForUpdates(sender)
        case .busy:
            DiagLog.log("manual update check unavailable (sessionInProgress=1)")
            let alert = NSAlert()
            alert.messageText = "An update check is already in progress"
            alert.informativeText = "LocalFlow's updater is busy. Try again in a moment."
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        case .unavailable:
            DiagLog.log("manual update check unavailable (sessionInProgress=0)")
            let alert = NSAlert()
            alert.messageText = "Unable to check for updates"
            alert.informativeText = "LocalFlow's updater is not ready. Restart the app and try again."
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    var canCheckForUpdates: Bool { updater?.updater.canCheckForUpdates ?? false }
}

extension UpdateController: SPUUpdaterDelegate {
    nonisolated func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        DiagLog.log("appcast loaded (%d entries)", appcast.items.count)
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        // A failed check must never be louder than a failed dictation.
        DiagLog.log("update check aborted: %@", error.localizedDescription)
    }

    nonisolated func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        DiagLog.log("relaunching for update")
    }
}
