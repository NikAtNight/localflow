import AppKit
import Carbon.HIToolbox

/// Inserts text into whatever app has focus.
///
/// Default strategy (per plan): put the text on the clipboard, synthesize
/// Cmd+V, then restore the previous clipboard contents. Falls back to
/// synthesized unicode keystrokes when Secure Input is active (password
/// fields block synthesized paste but sometimes accept typed events — and
/// we must never leave dictated text on the clipboard in that case).
enum TextInjector {
    // All mutated on the main thread only (inject is called from the app's
    // main-actor pipeline). Tracks one save/restore cycle across possibly
    // overlapping dictations.
    private static var savedItems: [NSPasteboardItem]?
    private static var restoreWork: DispatchWorkItem?
    private static var pendingCompletion: ((Bool) -> Void)?
    private static var ourChangeCount = -1

    /// `completion` (main queue) reports whether the paste is believed to
    /// have landed: true when the restore window resolved with our text
    /// still on the clipboard (or typing finished, in secure-input mode),
    /// false when the paste couldn't be posted or the window was disturbed.
    static func inject(_ text: String, completion: ((Bool) -> Void)? = nil) {
        guard !text.isEmpty else {
            completion?(false)
            return
        }

        if IsSecureEventInputEnabled() {
            // Password field or similar: avoid the clipboard entirely.
            typeString(text, completion: completion)
            return
        }

        let pasteboard = NSPasteboard.general

        // Two dictations can land within one restore window (recording while
        // the previous one transcribes is allowed). Keep the snapshot from
        // the FIRST of the sequence — snapshotting now would capture the
        // previous dictation as "the user's clipboard" and lose the real one.
        restoreWork?.cancel()
        // A superseded injection never reaches its restore work — resolve it
        // now with the same signal the work item would have used.
        if let pending = pendingCompletion {
            pendingCompletion = nil
            pending(pasteboard.changeCount == ourChangeCount)
        }
        if savedItems == nil || pasteboard.changeCount != ourChangeCount {
            savedItems = snapshot(of: pasteboard)
        }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        ourChangeCount = pasteboard.changeCount
        guard postKeystroke(virtualKey: CGKeyCode(kVK_ANSI_V), flags: .maskCommand) else {
            // No Cmd-V went out — put the user's clipboard back right away.
            if let saved = savedItems {
                savedItems = nil
                pasteboard.clearContents()
                pasteboard.writeObjects(saved)
            }
            completion?(false)
            return
        }
        pendingCompletion = completion

        // Give the frontmost app time to service the paste before restoring —
        // slow apps can take well over a second, and restoring too early
        // pastes the user's old clipboard instead of the dictation.
        let work = DispatchWorkItem {
            restoreWork = nil
            let saved = savedItems
            savedItems = nil
            let done = pendingCompletion
            pendingCompletion = nil
            // changeCount moved = the user copied something themselves in
            // the meantime — theirs wins over the restore, and whether the
            // paste landed first is unknowable.
            let undisturbed = pasteboard.changeCount == ourChangeCount
            if undisturbed, let saved {
                pasteboard.clearContents()
                pasteboard.writeObjects(saved)
            }
            done?(undisturbed)
        }
        restoreWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    // MARK: - Clipboard save/restore

    private static func snapshot(of pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    // MARK: - Synthesized events

    private static func postKeystroke(virtualKey: CGKeyCode, flags: CGEventFlags) -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false)
        else { return false }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    // Serial so overlapping dictations type in order, off the main thread
    // (the per-chunk sleeps would stall it; CGEvent posting is thread-safe).
    private static let typingQueue = DispatchQueue(label: "LocalFlow.TextTyping", qos: .userInitiated)

    /// Types text as synthesized unicode keyboard events, in chunks (long
    /// strings on a single event get truncated by some apps).
    /// `completion` runs on the main queue once every chunk has been posted.
    private static func typeString(_ text: String, completion: ((Bool) -> Void)? = nil) {
        let characters = Array(text.utf16)
        typingQueue.async {
            let source = CGEventSource(stateID: .combinedSessionState)
            let chunkSize = 20

            var index = 0
            while index < characters.count {
                let chunk = Array(characters[index ..< min(index + chunkSize, characters.count)])
                if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                   let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                    down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                    up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                    down.post(tap: .cghidEventTap)
                    up.post(tap: .cghidEventTap)
                }
                index += chunkSize
                usleep(8_000)
            }
            if let completion {
                DispatchQueue.main.async { completion(true) }
            }
        }
    }
}
