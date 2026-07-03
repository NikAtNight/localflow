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

**If the hotkey stops working after a rebuild:** the ad-hoc code signature
changes on every build, which silently invalidates the old TCC grant even
though the checkbox still looks enabled. Fix: in System Settings →
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
  - **Whisper Model** — Tiny/Base/Small/Large-v3-Turbo. Small (default) is the
    right latency/accuracy trade-off for dictation; switching triggers a new download.
  - **Recent Dictations** — the last 5 transcripts; click one to copy it back
    to the clipboard (the safety net if a paste ever goes astray).
  - **Retry Failed Dictation** — appears if a transcription errored; the
    audio is kept so your words aren't lost.
  - **Clean Up with Ollama** — toggle the LLM cleanup pass (see below).
  - **Sound Cues** — start/finish sounds, plus a low "Basso" when something
    fails (mic denied, nothing heard, transcription error).
- Your previous clipboard contents are saved and restored after the paste.
- Recordings cap at 5 minutes, and putting the Mac to sleep mid-hold discards
  the recording (rather than pasting it somewhere surprising at wake).
- Start at Login uses a LaunchAgent that relaunches LocalFlow if it ever
  crashes; quitting from the menu stays quit.
- If something misfires, the menu keeps a "Last error" line until the next
  successful dictation.
- **The very first transcription is slow** (~20 s): CoreML specializes the
  model for the Neural Engine once per binary; the OS caches the result and
  every transcription after that is sub-second.
- End-to-end latency (hotkey release → text pasted) is logged on every
  dictation. To see the logs, run the binary from a terminal
  (`build/LocalFlow.app/Contents/MacOS/LocalFlow`) or open Console.app and
  filter for "LocalFlow:".

### Headless testing / benchmarking

The same binary doubles as a CLI for measuring the pipeline without touching
the mic (the plan's "measure hotkey-release → pasted-text early" step):

```bash
say -o /tmp/test.aiff "This is a test sentence."
build/LocalFlow.app/Contents/MacOS/LocalFlow --transcribe /tmp/test.aiff
# stderr: model load / transcribe / cleanup timings; stdout: final text
```

Measured on this machine (M-series, small.en, warm): **~790 ms** for 7 s of
speech, model load ~1.8 s at app startup.

## Optional: Ollama cleanup (the WhisperFlow "magic" pass)

Whisper already punctuates reasonably well; the cleanup pass additionally
strips fillers ("um", "like"), fixes false starts, and formats dictated lists.
It runs against a local Ollama server and is **off by default** because it's
the main latency cost (roughly 0.5–1.5 s extra for a 4B model).

```bash
brew install ollama
ollama serve                # or: brew services start ollama
ollama pull gemma3:4b
```

Then enable **Clean Up with Ollama** in the menubar. If Ollama is down or
errors, LocalFlow pastes the raw transcript instead — dictation never blocks
on the LLM. To use a different model:
`defaults write app.talix.localflow ollamaModel "qwen2.5:3b"`.

## Known limitations (v1)

- English-only decoding by default (the `.en` Whisper models).
- In Secure Input fields (password boxes), LocalFlow avoids the clipboard and
  falls back to synthesized keystrokes, which some apps ignore.
- No streaming/partial transcription — audio is transcribed on hotkey release.
- No cursor-context awareness or custom vocabulary yet (see plan roadmap).

## Layout

| File | Role |
|---|---|
| `Sources/LocalFlow/HotkeyManager.swift` | CGEventTap hold-to-talk on a modifier key |
| `Sources/LocalFlow/AudioRecorder.swift` | AVAudioEngine capture → 16 kHz mono Float32 |
| `Sources/LocalFlow/WaveformOverlay.swift` | Floating live-waveform pill shown while recording |
| `scripts/generate-icon.swift` + `scripts/make-icon.sh` | Renders the app icon (organic wave motif) → `Resources/AppIcon.icns` |
| `Sources/LocalFlow/Transcriber.swift` | WhisperKit model load + transcription |
| `Sources/LocalFlow/OllamaCleaner.swift` | Optional local LLM cleanup via Ollama HTTP API |
| `Sources/LocalFlow/TextInjector.swift` | Clipboard+⌘V injection with save/restore, keystroke fallback |
| `Sources/LocalFlow/AppDelegate.swift` | Menubar UI, permissions, pipeline orchestration |
