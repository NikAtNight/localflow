import AppKit

/// Where the dictation is going. Writing into Mail is not the same job as
/// writing into Slack, and the cleanup pass should not produce the same
/// text for both. Resolved from the frontmost app at dictation time.
enum AppStyleProfile: String {
    case email
    case workChat
    case personalChat
    case code
    case general

    /// Appended to the cleanup instructions. Deliberately about register
    /// and punctuation only: never about content.
    var styleInstruction: String {
        switch self {
        case .email:
            return """
            This text is going into an email. Use complete sentences, full punctuation \
            and capitalization, and paragraph breaks between thoughts. Keep it polished \
            but not stiff.
            """
        case .workChat:
            return """
            This text is going into a work chat message. Keep it conversational and \
            brief: sentence case, light punctuation, no formal sign-offs, and no \
            paragraph padding. Do not add greetings the speaker did not say.
            """
        case .personalChat:
            return """
            This text is going into a personal message. Keep it casual and short, the \
            way people actually text. Light punctuation; a trailing period on a one-line \
            message is usually wrong.
            """
        case .code:
            return """
            This text is going into a code editor or terminal. Preserve identifiers, \
            symbols, paths, and casing exactly as dictated; never "correct" camelCase, \
            snake_case, or file extensions into prose. Do not add punctuation to \
            anything that reads like code.
            """
        case .general:
            return "Use ordinary written punctuation and capitalization."
        }
    }

    /// Bundle-identifier prefixes are matched, so "com.apple.mail" covers
    /// the whole family. Unknown apps fall back to `.general` rather than
    /// guessing a register.
    private static let table: [(prefix: String, profile: AppStyleProfile)] = [
        ("com.apple.mail", .email),
        ("com.microsoft.outlook", .email),
        ("com.readdle.smartemail", .email),
        ("com.superhuman", .email),
        ("com.missiveapp", .email),
        ("com.tinyspeck.slackmacgap", .workChat),
        ("com.microsoft.teams", .workChat),
        ("com.hnc.discord", .workChat),
        ("com.linear", .workChat),
        ("com.atlassian", .workChat),
        ("notion.id", .workChat),
        ("com.apple.ichat", .personalChat), // Messages
        ("com.apple.messages", .personalChat),
        ("net.whatsapp", .personalChat),
        ("ru.keepcoder.telegram", .personalChat),
        ("org.signal", .personalChat),
        ("com.apple.dt.xcode", .code),
        ("com.microsoft.vscode", .code),
        ("com.todesktop", .code), // Cursor and friends
        ("com.jetbrains", .code),
        ("dev.zed", .code),
        ("com.apple.terminal", .code),
        ("com.googlecode.iterm2", .code),
        ("dev.warp", .code),
        ("com.github", .code),
        ("com.sublimetext", .code),
    ]

    static func forBundleIdentifier(_ identifier: String?) -> AppStyleProfile {
        guard let identifier = identifier?.lowercased() else { return .general }
        return table.first { identifier.hasPrefix($0.prefix) }?.profile ?? .general
    }

    /// The profile for whatever app will receive the paste. Must be read on
    /// the main thread while that app is still frontmost (LocalFlow is an
    /// accessory app, so it never steals focus itself).
    @MainActor
    static func current() -> AppStyleProfile {
        forBundleIdentifier(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }
}
