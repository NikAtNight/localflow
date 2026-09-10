# Security

## Reporting a vulnerability

Please report security issues privately through
[GitHub Security Advisories](../../security/advisories/new) rather than a
public issue. Include what you found, how to reproduce it, and what an
attacker could do with it.

This is a personal project maintained in spare time. Expect an initial reply
within about a week. There is no bounty program.

## What LocalFlow can do, and why

LocalFlow needs unusually powerful permissions for a dictation app, so it is
worth being explicit about them:

| Capability | Why it needs it | Entitlement / permission |
|---|---|---|
| Microphone | Records while you hold the hotkey | `com.apple.security.device.audio-input`, TCC Microphone |
| Global key monitoring | Detects the hold-to-talk key in any app, via a `CGEventTap` on modifier-key events only | TCC Accessibility |
| Synthesized keystrokes | Pastes with ⌘V, and reads the selection with ⌘C in command mode | TCC Accessibility |
| Clipboard access | Puts the transcript on the clipboard to paste it, then restores your previous contents | none (unrestricted on macOS) |
| Network | Downloads the Whisper model on first run; talks to `localhost:11434` if the optional Ollama backend is used | `com.apple.security.network.client` |

The event tap only observes `flagsChanged` (modifier) events. It does not
observe or record character keystrokes.

## Where your data goes

Nowhere. There is no account, no server, and no telemetry.

- **Audio** is transcribed on-device by WhisperKit. It stays in memory by
  default. Opt-in diagnostic recordings save captured audio, recognition inputs,
  transcript stages, vocabulary/correction/snippet settings, and build/timing
  metadata under `Application Support/LocalFlow/DiagnosticRecordings/`. Local
  builds use `LocalFlow Local/DiagnosticRecordings/`. Directories use 0700 and
  files use 0600 permissions. No archive is uploaded. Retention is 7 days and
  1 GB, enforced at launch, on saves, and hourly while the app is open. Settings
  can disable new recordings or delete the diagnostic archive independently
  of transcript history. Command mode is excluded.
- **Personal voice collection** is a separate opt-in setting available only in
  LocalFlow Local. It saves original-rate mono audio, raw and final transcripts,
  reviewed text, and dictation metadata under
  `Application Support/LocalFlow Local/PersonalVoice/`, with 0700 directories
  and 0600 files. Clips have no expiry. New audio saves stop at 20 GB; metadata
  edits remain possible beyond the limit. Nothing is evicted automatically.
  Turning collection off preserves existing files. Import copies completed
  diagnostic originals without deleting them. Export copies only explicitly
  approved WAV/text pairs to the chosen directory. Exports have their own
  lifetime and are outside archive deletion controls. Command mode and manual
  retries do not add clips. The optional developer voice trial downloads public
  model weights, then supports offline synthesis. It does not upload audio or
  text. Its cache and generated files stay in the ignored `build/voice-clone/`
  folder until explicitly removed.
- **Transcripts** are appended to a daily Markdown file under
  `~/Library/Application Support/LocalFlow/History/` (owner-only permissions,
  and deliberately not in `~/Documents`, which iCloud syncs). You can turn
  this off, and delete everything, in Settings.
- **Cleanup and command mode** run on Apple's on-device foundation model.
  Nothing is sent to Apple's servers.
- **Ollama**, if you enable it, is a server you run on your own machine.
- **The diagnostic log** (`~/Library/Logs/LocalFlow-diag.log`) records timings
  and error messages, never transcript text.

The only outbound network request LocalFlow makes on its own is the one-time
Whisper model download from Hugging Face.

## Verifying a download

Every released DMG is:

1. **Signed** with an Apple Developer ID and **notarized** by Apple, so
   Gatekeeper accepts it without workarounds.
2. **Attested**, so you can prove it was built by this repository's release
   workflow from a specific commit, rather than uploaded by hand:

```bash
gh attestation verify LocalFlow-1.0.0.dmg --repo NikAtNight/localflow
```

3. **Checksummed**. `SHA256SUMS.txt` is attached to each release:

```bash
shasum -a 256 -c SHA256SUMS.txt
```

You can also confirm the signature and notarization locally:

```bash
codesign --verify --deep --strict --verbose=2 /Applications/LocalFlow.app
spctl --assess --type execute --verbose=4 /Applications/LocalFlow.app
xcrun stapler validate /Applications/LocalFlow.app
```

## Supported versions

Only the latest release is supported. Fixes ship in a new release rather
than as patches to older versions.
