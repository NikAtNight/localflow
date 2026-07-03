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
    private static var ourChangeCount = -1

    static func inject(_ text: String) {
        guard !text.isEmpty else { return }

        if IsSecureEventInputEnabled() {
            // Password field or similar: avoid the clipboard entirely.
            typeString(text)
            return
        }

        let pasteboard = NSPasteboard.general

        // Two dictations can land within one restore window (recording while
        // the previous one transcribes is allowed). Keep the snapshot from
        // the FIRST of the sequence — snapshotting now would capture the
        // previous dictation as "the user's clipboard" and lose the real one.
        restoreWork?.cancel()
        if savedItems == nil || pasteboard.changeCount != ourChangeCount {
            savedItems = snapshot(of: pasteboard)
        }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        ourChangeCount = pasteboard.changeCount
        postKeystroke(virtualKey: CGKeyCode(kVK_ANSI_V), flags: .maskCommand)

        // Give the frontmost app time to service the paste before restoring.
        let work = DispatchWorkItem {
            restoreWork = nil
            let saved = savedItems
            savedItems = nil
            // changeCount moved = the user copied something themselves in
            // the meantime — theirs wins over the restore.
            guard pasteboard.changeCount == ourChangeCount, let saved else { return }
            pasteboard.clearContents()
            pasteboard.writeObjects(saved)
        }
        restoreWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
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

    private static func postKeystroke(virtualKey: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false)
        else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// Types text as synthesized unicode keyboard events, in chunks (long
    /// strings on a single event get truncated by some apps).
    private static func typeString(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let characters = Array(text.utf16)
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
    }
}
