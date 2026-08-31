# LocalFlow

A fully local WhisperFlow-style push-to-talk dictation app for Apple Silicon Macs.
Hold a hotkey anywhere, speak, release — your words are transcribed on-device by
[WhisperKit](https://github.com/argmaxinc/WhisperKit) (CoreML → Neural Engine),
optionally cleaned up by S1-mini by Superwhisper through local Ollama, and
pasted into whatever app has focus.

No audio ever leaves your machine.

```
 [Hold hotkey]                                   [Release]
     │                                               │
     ▼                                               ▼
┌─────────┐  16kHz mono  ┌───────────┐  raw text  ┌───────────┐ clean text ┌──────────┐
│  Mic    │─────PCM─────▶│ WhisperKit│───────────▶│  Ollama   │───────────▶│  Text    │
│ capture │              │   (STT)   │            │ S1-mini   │ (optional) │ injector │
└─────────┘              └───────────┘            └───────────┘            └──────────┘
 AVAudioEngine            CoreML / ANE             Ollama, 0.6B            clipboard + ⌘V
```

## Requirements

LocalFlow is **macOS only** and there are no plans for other platforms: it is
built on CoreML, the Neural Engine, CGEvent taps, and Apple's on-device models.

| | Minimum | Recommended |
|---|---|---|
| Mac | Apple Silicon (M1 or later) | M1 Pro or later |
| macOS | 14 Sonoma | 26 or later |
| Memory | 8 GB | 16 GB |
| Free disk | 2 GB for the model cache | 4 GB |
| Network | First launch only, to download the model | Not needed after that |

Notes on the edges of that table:

- **Apple Silicon is required.** Intel Macs are not supported: transcription
  runs on the Neural Engine, and without it dictation is too slow to be useful.
- **macOS 26+ unlocks command mode.** Transcription, S1-mini cleanup,
  formatting, snippets, and corrections all work on macOS 14. Command mode
  uses Apple's on-device foundation model, which needs macOS 26 with Apple
  Intelligence enabled in System Settings.
- **Disk depends on the model.** Small English is ~500 MB; the default
  Large v3 Turbo is ~1.5 GB. Models download on first launch and are cached in
  `~/Library/Application Support/LocalFlow/`.
- **No account, no server, no subscription.** Nothing is uploaded, so there is
  nothing to sign in to.

## Install

Download the latest `LocalFlow-<version>.dmg` from the
[Releases page](../../releases), open it, and drag LocalFlow to Applications.
Launch it and grant the two permissions below.

The app runs in the menubar with no Dock icon, and registers a LaunchAgent so
it starts at login and comes back if it ever crashes. Quit from the menu and it
stays quit. To uninstall, quit LocalFlow, drag it out of Applications, and
delete `~/Library/Application Support/LocalFlow/`.

> Builds are signed with a Developer ID and notarized by Apple, so they open
> normally. If you build it yourself the result is ad-hoc signed, and macOS
> will block the first launch until you right-click the app and pick **Open**.

### Updates

Released builds update themselves with [Sparkle](https://sparkle-project.org).
LocalFlow checks once a day, downloads in the background, and installs the
next time you quit. "Check for Updates…" in the menubar looks immediately,
and the whole thing can be turned off in Settings.

Updates are only installed if two independent signatures check out: an EdDSA
signature on the appcast entry, so a hijacked feed cannot serve a malicious
build, and the Developer ID code signature, which must match the running app.
Anything that fails is discarded rather than installed.

Locally built copies are self-signed, so they cannot self-update and the
option is disabled for them. Build with `make-app.sh` to upgrade those.

### Verifying what you downloaded

Every release DMG carries build provenance, so you can prove it was built by
this repository's workflow rather than uploaded by someone:

```bash
gh attestation verify LocalFlow-1.0.0.dmg --repo NikAtNight/localflow
shasum -a 256 -c SHA256SUMS.txt      # SHA256SUMS.txt is attached to the release
```

## Security & privacy

LocalFlow asks for the microphone, global key monitoring, and the ability to
synthesize keystrokes. That is a lot of trust, so the details are written
down in [SECURITY.md](SECURITY.md): what each permission is for, what the
event tap does and does not observe (modifier keys only, never characters),
where transcripts are stored, and how to report a vulnerability.

The short version: there is no account, no server, and no telemetry. Audio is
transcribed on-device and never written to disk. The only outbound request
LocalFlow makes on its own is the one-time Whisper model download.

The repository runs CodeQL static analysis on every push, keeps dependencies
current with Dependabot, and builds releases in a workflow with least-
privilege permissions.

## Build from source

Requires macOS 14+ and the Swift toolchain (Xcode Command Line Tools are enough).

```bash
./scripts/make-app.sh          # builds release + packages build/LocalFlow.app
open build/LocalFlow.app

./scripts/make-app.sh --install  # or: replace /Applications/LocalFlow.app and relaunch
./scripts/make-dmg.sh            # wrap the built app in dist/LocalFlow-<version>.dmg
```

For quick dev iteration you can also `swift run`, but then the TCC permissions
below attach to your *terminal app* instead of LocalFlow — the .app bundle is
the intended way to run it.

**First launch downloads the Whisper model** (~500 MB for Small) from the
`argmaxinc/whisperkit-coreml` Hugging Face repo into
`~/Library/Application Support/LocalFlow/` (an older cache in
`~/Documents/huggingface/` is migrated automatically — Documents is
iCloud-synced on many Macs and "Optimize Mac Storage" could evict the model).
The menubar icon shows a download arrow until the model is ready; if the
download fails (offline at login), it retries with backoff, and re-picking
the model in the menu retries immediately. Subsequent launches load from
disk. CoreML also specializes the model on first load, so the very first
launch takes a couple of minutes.

## Permissions (one-time)

macOS will prompt for these on first use — both are required:

1. **Microphone** — to record while you hold the hotkey.
2. **Accessibility** — for the global hotkey listener and the synthesized ⌘V
   paste. Use "Open Accessibility Settings…" in the LocalFlow menu; the app
   retries every few seconds, so the hotkey starts working the moment you
   grant it (no relaunch needed). The menubar icon shows ⚠️ until then.

**If the hotkey stops working after a rebuild:** `make-app.sh` prefers the
stable `Talix Dev Signing` identity and otherwise uses a pinned ad-hoc
requirement, but macOS can still retain a stale TCC grant. In System Settings →
Accessibility, remove LocalFlow with the − button and re-add the new build
(or toggle it off and on).

## Usage

- **Hold Right Option (⌥)**, speak, release. The cleaned text is pasted at your cursor.
- While you hold the key, a frosted-glass pill at the bottom of the screen
  shows a live, organic waveform of the audio being captured (it's
  click-through and never steals focus).
- The menubar icon shows state: waveform = ready, red dot = recording,
  hourglass = transcribing.
- You can start a new dictation immediately, even while the previous one is
  still transcribing.
- Menu options:
  - **Hold to Talk** — switch the hotkey (Right Option / Right Command / Fn).
  - **Whisper Model** — Small English (default) is the latency/accuracy balance.
    Large v3 626 MB prioritizes compact accuracy, while Large v3 Turbo is the
    best speed/accuracy option on a well-provisioned Mac; switching downloads
    and specializes the selected model before Ready.
  - **Recent Dictations** — the last 5 transcripts; click one to copy it back
    to the clipboard (the safety net if a paste ever goes astray).
  - **Open Dictation History** — today's log in Finder (see below).
  - **Retry Failed Dictation** — appears if a transcription errored; the
    audio is kept so your words aren't lost.
  - **Clean up transcripts** — toggle the local S1-mini cleanup pass (see below).
  - **Sound Cues** — start/finish sounds, plus a low "Basso" when something
    fails (mic denied, nothing heard, transcription error).
- In "System Default" microphone mode, plugging in or removing a mic (or
  changing the default in System Settings) re-routes immediately, including
  an idle warm session. A specifically selected mic stays pinned while it's
  connected.
- Your previous clipboard contents are saved and restored after the paste.
- Recordings cap at 5 minutes, and putting the Mac to sleep mid-hold discards
  the recording (rather than pasting it somewhere surprising at wake).
- Start at Login uses a LaunchAgent that relaunches LocalFlow if it ever
  crashes; quitting from the menu stays quit.
- If something misfires, the menu keeps a "Last error" line until the next
  successful dictation.
- **Initial startup or a model switch can take minutes**: LocalFlow downloads,
  loads, and CoreML-specializes the model before the menubar reports Ready.
  Once Ready, the first transcription no longer pays that setup cost.
- End-to-end latency (hotkey release → text pasted) is logged on every
  dictation. Follow `~/Library/Logs/LocalFlow-diag.log`, or open Console.app
  and filter for "LocalFlow:". Launch the app bundle normally so macOS keeps
  Microphone and Accessibility permission attribution on LocalFlow.

### Automatic formatting

Structure is inferred without any spoken command:

- **Paragraphs**: a pause of ~1.75 s after a finished sentence starts a new
  paragraph (detected from Whisper segment timestamps; a mid-sentence
  thinking pause never splits).
- **Numbered lists**: a spoken run of sentence-initial ordinals ("First,
  … Second, … Finally, …" or "Number one, … number two, …") becomes
  `1.` / `2.` / `3.` items. Conservative: needs at least two cues, ascending
  from one, each punctuated. "Second, I want to say thanks" alone stays prose.
- **With cleanup on**, an LLM additionally breaks long text into
  paragraphs at topic shifts and formats clearly-enumerated items as lists,
  while preserving whatever the deterministic pass already produced.

### Voice formatting commands

Explicit spoken commands also work (deterministically, before any Ollama
pass, with cleanup on or off). Case-insensitive, and tolerant of
the commas/periods Whisper wraps around them:

| Say                          | Get                                    |
| ---------------------------- | -------------------------------------- |
| "new line"                   | line break                             |
| "new paragraph"              | blank line                             |
| "bullet point milk bullet point eggs" | `- Milk` / `- Eggs`           |
| "numbered list apples next item bananas" | `1. Apples` / `2. Bananas` |
| "next item"                  | next list item (only inside a list)    |
| "thumbs up emoji"            | 👍                                     |

Emoji names cover the common set (thumbs up/down, heart, fire, rocket,
tada/party, check mark, eyes, thinking, shrug, 💯, …); see `emojiNames` in
`Sources/LocalFlow/VoiceFormatter.swift` to add your own. Caveat: command
phrases are always interpreted, so literally dictating the words "bullet
point" mid-sentence starts a list item.

### Headless testing / benchmarking

The same binary doubles as a CLI for measuring the pipeline without touching
the mic (the plan's "measure hotkey-release → pasted-text early" step):

```bash
say -o /tmp/test.aiff "This is a test sentence."
build/LocalFlow.app/Contents/MacOS/LocalFlow --transcribe /tmp/test.aiff
# stderr: model load / transcribe / cleanup timings; stdout: final text
# Add --no-cleanup to benchmark Whisper alone regardless of saved settings.
```

Measured on this machine (M-series, small.en, warm): **~790 ms** for 7 s of
speech, model load ~1.8 s at app startup.

## Optional: S1-mini cleanup

Whisper already punctuates reasonably well; larger Whisper models improve word
recognition but do not replace semantic cleanup. The optional second stage uses
**S1-mini by Superwhisper**, a 0.6B model built specifically to normalize ASR
output. It removes fillers and false starts, resolves self-corrections, formats
spoken numbers, dates, times, currency, and email addresses, and preserves the
speaker's meaning. It is English-only and **off by default** because it adds
latency.

S1-mini runs fully locally through Ollama. The recommended Q4_K_M build is
462 MiB. Install Ollama and the pinned, checksum-verified model:

```bash
brew install ollama
brew services start ollama
"/Applications/LocalFlow.app/Contents/Resources/install-s1-mini.sh"
```

When building from source, run `./scripts/install-s1-mini.sh` instead.

Enable the cleanup toggle in Settings. If Ollama is down, the model is missing,
or cleanup errors, LocalFlow pastes the raw transcript instead, so dictation is
never lost to the cleanup stage. The app sends S1-mini's exact required system
prompt and control line, disables thinking, and uses deterministic temperature
0 decoding.

S1-mini is released under Apache 2.0 plus a naming clause. LocalFlow does not
redistribute its weights; the install script downloads the pinned model from
[the official repository](https://huggingface.co/superwhisper/s1-mini-GGUF).
Review that repository's [LICENSE](https://huggingface.co/superwhisper/s1-mini-GGUF/blob/main/LICENSE)
and [NOTICE](https://huggingface.co/superwhisper/s1-mini-GGUF/blob/main/NOTICE).

## Command mode (voice editing)

Hold the command key (Right Option by default; configurable in Settings) and
say what you want done:

- **With text selected** it's rewritten in place: "make this shorter",
  "turn this into bullet points", "make it friendlier", "translate to Spanish".
- **With nothing selected** what you ask for is written at the cursor.

Runs on Apple's on-device model, so the text being edited never leaves the
Mac. Needs Apple Intelligence enabled, and a different key from dictation.

## App-aware style

The cleanup pass adapts to whatever app you're dictating into: full
sentences and punctuation in Mail, short and casual in Slack or Messages.
Code editors and terminals bypass S1-mini because its trained controls cannot
guarantee preservation of identifiers, symbols, paths, or casing. Unknown apps
get ordinary written punctuation.

## Snippets

Voice shortcuts for text you type often. Define a trigger in Settings, say
it anywhere in a dictation, and it's replaced verbatim:

> "thanks for the update, insert my signature" → "Thanks for the update,
> Nikhil Kapadia / Talix"

## Custom vocabulary & corrections

Settings has a "Custom vocabulary" field: comma-separated names and jargon
(people, projects, acronyms) that Whisper keeps mishearing. The terms are
tokenized and fed to the decoder as context on every dictation, biasing
recognition toward them. Keep the list short; heavy bias can backfire.

The "Corrections" section closes the loop on words that still come out
wrong: teach a fix ("talex" → "Talix") and it is (1) applied automatically
to every future transcript (whole words only, case-aware) and (2) its
correct form joins the recognition vocabulary, so the decoder gets a chance
to hear it right at the source.

You don't have to type both halves. Fix the text in your app, copy it, then
pick **Fix Last Dictation…** in the menubar: LocalFlow diffs your version
against what it pasted and offers to learn the word swaps. Only one-word
substitutions are proposed, and common words are ignored, so rewording a
sentence never becomes a permanent rule.

## Dictation history

Every dictation is appended to a daily Markdown file:

```
~/Library/Application Support/LocalFlow/History/2026-08-08.md
```

```markdown
# Dictations 2026-08-08

## 09:14:22

1. Review the pull request.
2. Merge it.
```

Application Support rather than `~/Documents` on purpose: Documents is
iCloud-synced on most Macs, and transcripts should stay on the machine.
Files are written owner-only (0600) and nothing is pruned automatically.
The menubar has **Open Dictation History**; Settings has the on/off toggle,
a folder shortcut, and **Delete All History**.

## Known limitations (v1)

- English-only decoding by default (the `.en` Whisper models).
- In Secure Input fields (password boxes), LocalFlow avoids the clipboard and
  falls back to synthesized keystrokes, which some apps ignore.
- No streaming/partial transcription — audio is transcribed on hotkey release.
- No cursor-context awareness yet (see plan roadmap).

## Layout

| File | Role |
|---|---|
| `Sources/LocalFlow/HotkeyManager.swift` | CGEventTap hold-to-talk on a modifier key |
| `Sources/LocalFlow/AudioRecorder.swift` | AVAudioEngine capture → 16 kHz mono Float32 |
| `Sources/LocalFlow/WaveformOverlay.swift` | Floating live-waveform pill shown while recording |
| `scripts/generate-icon.swift` + `scripts/make-icon.sh` | Renders the app icon (organic wave motif) → `Resources/AppIcon.icns` |
| `scripts/install-s1-mini.sh` | Downloads, verifies, and configures S1-mini by Superwhisper for Ollama |
| `Sources/LocalFlow/Transcriber.swift` | WhisperKit model load + transcription, vocabulary biasing, pause-paragraphing |
| `Sources/LocalFlow/VoiceFormatter.swift` | Spoken formatting commands + automatic list detection |
| `Sources/LocalFlow/TranscriptCleaner.swift` | S1-mini input contract + Apple Intelligence command-mode backend |
| `Sources/LocalFlow/OllamaCleaner.swift` | S1-mini cleanup via Ollama HTTP API |
| `Sources/LocalFlow/TextInjector.swift` | Clipboard+⌘V injection with save/restore, keystroke fallback |
| `Sources/LocalFlow/DictationHistory.swift` | Daily Markdown log of every dictation |
| `Sources/LocalFlow/CommandMode.swift` | Voice editing of the current selection |
| `Sources/LocalFlow/AppStyleProfile.swift` | Per-app writing register for the cleanup pass |
| `Sources/LocalFlow/DictationDiff.swift` | Learns corrections from hand-edited dictations |
| `Sources/LocalFlow/AppDelegate.swift` | Menubar UI, permissions, pipeline orchestration |

## Cutting a release

Releases are built by `.github/workflows/release.yml` on a macOS runner:
tests, signed build, notarization, DMG, then the DMG is attached to the
GitHub Release. Publish a release tagged `v1.2.3` and the workflow does the
rest; `workflow_dispatch` produces the same artifact without publishing.

Signing and notarization need these repository secrets. Without them the
workflow still builds and attaches a DMG, but it is ad-hoc signed and
Gatekeeper makes users right-click → Open:

| Secret | What it is |
|---|---|
| `MAC_CERT_P12_BASE64` | Developer ID Application certificate + key, exported as .p12 and base64-encoded |
| `MAC_CERT_PASSWORD` | Password used for that .p12 export |
| `APPLE_ID` | Apple ID for notarization |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password for that Apple ID |
| `APPLE_TEAM_ID` | Developer team ID |

The workflow fails the build if `FoundationModels` did not link, since an
older SDK would silently ship a build with no command mode and no on-device
cleanup.

## License

MIT. See [LICENSE](LICENSE).
