# LocalFlow

A fully local WhisperFlow-style push-to-talk dictation app for Apple Silicon Macs.
Hold a hotkey anywhere, speak, release — your words are transcribed on-device by
[WhisperKit](https://github.com/argmaxinc/WhisperKit) (CoreML → Neural Engine),
optionally cleaned up by a local Ollama LLM, and pasted into whatever app has focus.

No audio ever leaves your machine.

```
 [Hold hotkey]                                   [Release]
     │                                               │
     ▼                                               ▼
┌─────────┐  16kHz mono  ┌───────────┐  raw text  ┌───────────┐ clean text ┌──────────┐
│  Mic    │─────PCM─────▶│ WhisperKit│───────────▶│  Ollama   │───────────▶│  Text    │
│ capture │              │   (STT)   │            │  cleanup  │ (optional) │ injector │
└─────────┘              └───────────┘            └───────────┘            └──────────┘
 AVAudioEngine            CoreML / ANE             gemma3:4b               clipboard + ⌘V
```

## Build & run

Requires macOS 14+ and the Swift toolchain (Xcode Command Line Tools are enough).

```bash
./scripts/make-app.sh          # builds release + packages build/LocalFlow.app
open build/LocalFlow.app
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
  - **Retry Failed Dictation** — appears if a transcription errored; the
    audio is kept so your words aren't lost.
  - **Clean up transcripts** — toggle the LLM cleanup pass (Apple
    Intelligence on-device when available, else Ollama — see below).
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

## Optional: LLM cleanup (the WhisperFlow "magic" pass)

Whisper already punctuates reasonably well; larger Whisper models improve word
recognition but do not replace semantic cleanup. The cleanup pass additionally
strips filler tics ("um", standalone "like"), fixes false starts, and handles
the judgment-call formatting (topic-shift paragraphs, list detection). It is
**off by default** because it's the main latency cost.

Two backends, picked automatically:

1. **Apple Intelligence (preferred)**: on macOS 26+ with Apple Intelligence
   turned on in System Settings, cleanup runs on Apple's on-device foundation
   model. Nothing to install, no server, fully local, typically well under a
   second.
2. **Ollama (fallback)**: used only when the on-device model isn't available.

```bash
brew install ollama
ollama serve                # or: brew services start ollama
ollama pull gemma3:4b
```

Enable the cleanup toggle in Settings (its label shows which backend is
active). If the backend is down or errors, LocalFlow pastes the raw
transcript instead — dictation never blocks on the LLM. Different Ollama
model: `defaults write app.talix.localflow ollamaModel "qwen2.5:3b"`.

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
| `Sources/LocalFlow/Transcriber.swift` | WhisperKit model load + transcription, vocabulary biasing, pause-paragraphing |
| `Sources/LocalFlow/VoiceFormatter.swift` | Spoken formatting commands + automatic list detection |
| `Sources/LocalFlow/TranscriptCleaner.swift` | Cleanup contract + Apple Intelligence on-device backend |
| `Sources/LocalFlow/OllamaCleaner.swift` | Fallback LLM cleanup via Ollama HTTP API |
| `Sources/LocalFlow/TextInjector.swift` | Clipboard+⌘V injection with save/restore, keystroke fallback |
| `Sources/LocalFlow/AppDelegate.swift` | Menubar UI, permissions, pipeline orchestration |

## License

MIT. See [LICENSE](LICENSE).
