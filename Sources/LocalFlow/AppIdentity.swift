import Foundation

/// Keeps local builds' writable data separate while sharing downloaded models.
struct AppIdentity {
    static let productionID = "app.talix.localflow"
    static let localID = "app.talix.localflow.local"
    static let current = AppIdentity(bundleIdentifier: Bundle.main.bundleIdentifier)

    let isLocal: Bool

    init(bundleIdentifier: String?) {
        isLocal = bundleIdentifier == Self.localID
    }

    var bundleIdentifier: String { isLocal ? Self.localID : Self.productionID }
    var name: String { isLocal ? "LocalFlow Local" : "LocalFlow" }
    var historyDirectory: String { "\(name)/History" }
    var logFilename: String { isLocal ? "LocalFlow-Local-diag.log" : "LocalFlow-diag.log" }
}

/// Bundle metadata shared by the settings sidebar and diagnostics pane.
struct AppBuildInfo {
    static let current = AppBuildInfo(info: Bundle.main.infoDictionary ?? [:])

    let versionLabel: String
    let revisionLabel: String
    let builtAt: String

    init(info: [String: Any]) {
        let version = info["CFBundleShortVersionString"] as? String ?? "Unknown"
        let build = info["CFBundleVersion"] as? String
        versionLabel = "Version \(version)" + (build != nil && build != version ? " (\(build!))" : "")
        let commit = info["LFBuildCommit"] as? String ?? "unknown"
        let dirty = info["LFBuildDirty"] as? String == "true"
        revisionLabel = String(commit.prefix(8)) + (dirty ? " · modified" : "")
        builtAt = info["LFBuildDate"] as? String ?? "Not recorded"
    }
}
