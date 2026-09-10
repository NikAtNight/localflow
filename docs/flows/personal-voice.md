# Personal voice collection and review

## Requirement source, owner, and non-goals

The user requested longer local retention of their dictations for future voice
and speaking-style experiments, then asked to implement the proposed archive,
original-rate capture, transcript review/export, and a small local voice trial.
The LocalFlow maintainer owns this flow. Production collection, automatic
transcript approval, model fine-tuning, and a conversational agent are outside
this change.

## Intended behavior and acceptance examples

- With local collection enabled, one hotkey dictation creates one permanent
  clip even when diagnostic recording is disabled. Recognition chunks and manual
  retries do not create extra personal clips.
- A complete 48 kHz capture is saved at 48 kHz. A capture with a format change,
  invalid buffer, or native memory limit falls back to 16 kHz with a source label.
- Automatic transcripts remain unapproved. A reviewed verbatim transcript can
  be approved and exported with its audio. Saving a draft removes approval.
- At the 20 GB admission limit, new audio is refused and existing clips remain
  playable and reviewable. Metadata updates can exceed the admission limit.
- Import waits for completed diagnostic capture, copies only `original.wav`,
  preserves the source, and skips UUIDs already in the personal archive.
- Deleting a clip prevents late callbacks from restoring it. Turning collection
  off only stops new sessions; an in-flight session can finish saving.

## Observed path

`AppDelegate.beginDictationSession` creates a `PersonalVoiceStore.Recording`
only for local dictation when `Settings.savePersonalVoice` is enabled.
`AudioRecorder.start(retainNativeAudio:)` accumulates original-rate mono samples
alongside the existing 16 kHz recognition samples. Its stop callback detaches
both arrays after queued conversion finishes. `NativeAudioAccumulator` caps
retained samples at 310 seconds or 64 MiB and marks incomplete capture instead
of silently treating a truncated native recording as complete.

`DictationSessionPipeline.recordCapturedAudio` retains the first original before
silence trimming. `finalize` records assembled recognition before corrections,
formatting, snippets, and cleanup. Completion saves final text and outcome.
These are separate fields because cleaned text is not a verbatim label.

`PersonalVoiceStore` writes on a utility queue, with a file lock shared by app
and CLI writers. Audio and metadata are staged privately before publishing a
UUID directory. `RetainedAudioFile` is the WAV writer shared with diagnostic
retention; it closes the file before publishing its final name. A clip contains
`audio.wav` and `clip.json`. The JSON stores identity, capture date, duration,
sample rate/source, transcript stages, review state, failure reason, and
dictation metadata. Imported clips must match their diagnostic directory UUID.
Archive metadata identities must also match their directory.

`PersonalVoicePane` provides collection, storage usage, refresh, folder opening,
import, playback, draft saving, approval, deletion confirmation, and export.
The pane and recorder entry point both enforce the local-build boundary.
Errors appear in the pane after refresh or an operation; there is no background
notification. The pane does not poll for new recordings.

## Side effects, failures, retries, and recovery

The archive lives at `~/Library/Application Support/LocalFlow Local/PersonalVoice/`.
There is no expiry, pruning timer, or upload. Directories use 0700 and files 0600.
Quota checks include hidden staging directories left by an abrupt process exit.
The pane reports these unfinished recordings, preserving them for manual recovery.
Temporary staging can need extra space before final admission. Normal failures
remove only staging owned by that operation. Disk errors leave completed clips
in place and surface an issue. No automatic retry of failed archive writes runs.

Import uses the diagnostic `capture` event as completion evidence. Missing or
unfinished originals are skipped. Invalid metadata fails the import with a
visible error; clips already imported remain. Concurrent store instances use
the same file lock for import and quota admission. The local bundle also has
`--import-voice-diagnostics` for maintenance while the app is stopped. It refuses
production identity or a running local app.

Export creates `LocalFlow-Voice-<UUID>/wavs/` and `manifest.jsonl` in the selected
directory. Each row contains `id`, relative `audio_path`, exact reviewed `text`,
`sample_rate`, and a fixed local speaker label. Exports contain approved pairs
only and do not include the full diagnostic metadata. Failed export removes
only its newly created output. Copies outside the archive have no managed
retention. The archive does not align words, crop silence, or assess voice quality.

## Verification

Environment: macOS 26.6.2, Apple Silicon, Swift 6.3.3. Tests use synthetic audio
and isolated temporary directories. Implementation is based on `0cd24e5` plus
the personal voice changes; diff evidence is
`/tmp/localflow-personal-voice.diff`.

- PASS: 43 focused tests with `swift test --disable-automatic-resolution --filter
  'PersonalVoice|NativeAudioRecordingTests|SettingsApplicationRoutingTests|DictationDiagnostic'`.
  Evidence: `/tmp/localflow-personal-voice-focused-tests.log`.
- `PersonalVoiceStoreTests` covers exact audio and permissions, fallback,
  one-original retention, explicit approval, exact export text, storage limits,
  deletion with late writes, import completion, and corrupt identity rejection.
- `PersonalVoicePipelineTests` exercises the assembled pipeline with real file
  persistence and mocked recognition/cleanup. It verifies native audio and raw
  and final text when diagnostic recording is off.
- `NativeAudioRecordingTests` covers PCM representations, downmixing, sample
  rate preservation, invalid data, format changes, and bounded capture.
- PASS: `swift test -c release --disable-automatic-resolution`, 260 tests with
  no failures. Evidence: `/tmp/localflow-personal-voice-release-tests.log`. This
  includes concurrent import and quota accounting for interrupted staging.
- PASS: shell/Python syntax and `git diff --check`.
- PASS: signed local app packaging with `LOCAL_BUILD=1 UPDATER_ENABLED=false
  SKIP_PREWARM=1 APP_VERSION=1.4.1 ./scripts/make-app.sh` and
  `codesign --verify --deep --strict`. Evidence:
  `/tmp/localflow-personal-voice-package.log`.
- PASS: the local bundle CLI imported 10 real diagnostic originals totaling
  143.19 seconds. Every copy matched its source SHA-256, had private permissions,
  and remained unreviewed. A second import returned zero. Evidence:
  `/tmp/localflow-personal-voice-import.log`.
- PASS: independent read-only review and follow-up review of import races,
  identity validation, metadata writes at capacity, and interrupted staging.
- The local installation preference enables collection. The checked-in default
  stays off. `./scripts/local-app.sh install` verifies the installed signature
  and waits for a fresh model-readiness event; it does not verify live dictation.
- PASS: an offline MPS voice trial produced a valid 5.58-second, 24 kHz WAV in
  46.14 seconds, with the model's Perth watermark detected. An ASR replay matched
  the requested text except `I am` becoming `I'm`. See
  [trial setup and evidence](../voice-clone-trial.md).
- NOT RUN: perceptual voice similarity, human verification of the trial
  reference, interactive review/export UI, and a live new-rate microphone
  dictation through target-app insertion. The user must listen to assess voice
  resemblance. Automated audio checks do not establish it.
