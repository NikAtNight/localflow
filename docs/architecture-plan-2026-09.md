# Architecture plan: Diagnostic recording archive and voice edits

Status: decided 2026-09-23, not implemented. Build in the order below. Each
step should ship and be tested on its own.

This came out of a full review of main at a353f35 (v1.6.1). Three bugs from
that review were fixed separately: a stale command-mode flag, clipboard loss
when command mode reads the selection during a paste restore, and A to B to A
Whisper model switches ending on B.

Vocabulary: a module is deep when a lot of behavior sits behind a small
interface. A seam is where that interface lives. Domain terms come from
`CONTEXT.md`.

## Step 1: Diagnostic recording owns its archive format

### Problem

Personal voice import reads the Diagnostic recording's files directly. It
depends on folder names, `metadata.json`, stage strings such as `"capture"`,
and the rule that the pipeline writes `original.wav` before logging `capture`
(`PersonalVoiceStore.swift:151-198`, `DictationSessionPipeline.swift:245-251`).
A stage rename silently breaks import. Import can't tell a retry archive or a
deleted clip from a fresh recording.

Bugs this fixes:

- Deleting a Personal voice clip and then importing diagnostics restores it,
  with no expiry (`PersonalVoiceStore.swift:141-160`).
- A Manual retry writes a new archive under a new UUID, and import turns it
  into an extra clip. SECURITY.md:52 and `docs/flows/personal-voice.md:16`
  say retries never add clips.
- An import that runs while a dictation is released can publish the 16 kHz
  diagnostic copy first. The native-rate live save then no-ops
  (`PersonalVoiceStore.swift:234`).
- If the timing-history import fails at launch, retention (7 days / 1 GB)
  never starts that session (`DiagLog.swift:69`).

### Decisions

- Rename `DictationDiagnosticStore` to `DiagnosticRecordings`.
- Interface, three entry points:
  - `begin(_ origin: Origin, _ metadata: Metadata) -> DiagnosticRecording`
  - `DiagnosticRecording.record(_ fact: Fact)` with typed facts (captured
    audio, transcription request and result, inference input and output,
    assembled transcript, cleanup input, candidate and output, outcome,
    cancelled, timing). `record` never throws and never blocks.
  - `claimCaptures(_ receive: (Capture) throws -> Void) throws -> Int` for
    Personal voice import.
  - `deleteAll`, `flush` and `hasWriteFailure` stay as they are.
- `Origin`: `.dictation(personalVoiceClip: Bool)`, `.manualRetry`,
  `.voiceEdit`. Only `.dictation(personalVoiceClip: false)` is ever offered to
  import.
- Each archive holds a hidden import claim, written with `metadata.json`:
  withheld, offered, or claimed. It replaces a separate deleted-ID list and
  expires with the archive.
  - A dictation with a live clip is withheld from the start, so a deleted
    clip can never come back.
  - An imported archive is marked claimed when `receive` returns.
  - Retries and voice edits are never offered.
  - A live clip save that failed (for example at the 20 GB cap) stays
    withheld.
- Archives written before this change have no claim and are all withheld.
- Imported dictations keep their outcome, including cancelled, failed, empty
  and insufficient voice, the same way live saves keep a failure reason.
- Retention runs on every launch, even when the timing-history import fails.
  Remove the `afterRecovery` coupling in `DiagLog.startSession`.
- Generate the shared trace ID once per dictation. Today a nil trace gives the
  archive and the clip different UUIDs (`AppDelegate.swift:819,829`).
- Writing `original.wav` and then the `capture` event becomes one internal
  operation. First capture wins.
- Stage strings on disk stay the same. `docs/flows/diagnostic-recordings.md`
  documents them for people reading archives.

### Out of scope

- A per-session evidence handle that also covers the trace and Personal voice
  clip. It has more leverage but is a much bigger change. Revisit later.
- A storage port with an in-memory adapter. Tests already run on temp folders,
  and the port would have only one real adapter.

### Tests

- Keep: WAV round trip, stages and metadata, deletion with late writes,
  unmanaged files and symlinks, invalid root (`DictationDiagnosticStoreTests`).
- Rewrite: the prune tests, and the Personal voice import tests, which should
  seed archives through `begin` and `record` instead of hand-written events.
- New, at the module interface: retry never offered, live-clip archive never
  offered, delete then import does not restore, claim happens once across two
  instances, capture without `.captured` never offered, a throwing `receive`
  leaves the archive unclaimed, legacy archive withheld, retention runs without
  DiagLog recovery.
- Pipeline tests that decode `events.jsonl` switch to a test helper that reads
  the file as JSON. The on-disk format is a documented contract.

## Step 2: Voice edits go through the dictation pipeline

A voice edit is a hold on the command key whose spoken instruction transforms
the current selection. Today it bypasses the pipeline and is spread across six
places in `AppDelegate`, `CommandMode`, `Settings.commandModeActive`,
`DictationDelivery` and `InjectionCoordinator`.

### Decisions

- A voice edit is a Dictation with `intent: .editSelection`. It uses the same
  capture, audio preparation, noSpeech handling and trace. When Diagnostic
  recordings are on it gets an archive with origin `.voiceEdit`. The archive
  stores the selection and edited result verbatim.
- The instruction gets corrections only. No spoken formatting, snippets or
  LLM cleanup.
- Delivery reads the selection only when the edit reaches the head of the
  queue, after earlier dictations have pasted. No paste can race the selection
  read.
- A failed edit shows an error and is never offered for Manual retry.
- With Secure Input on, the edit refuses with a Basso cue and a banner. It
  never generates text into a secure field.
- A small `CommandMode` module owns the command key tap and availability:
  - The tap stays armed whenever command mode is on and the key doesn't clash
    with the dictation key.
  - Backend availability is checked at press time. A press with no backend
    plays Basso and shows a banner.
  - Ollama reachability changes and settings edits never restart the tap
    mid-hold.
  - A key release only ends a hold of its own kind.
  - Changing the dictation key re-checks the clash. Today it doesn't
    (`AppDelegate.swift:373-376`).
- Reasoning: send `think` only to models whose Ollama capabilities include
  thinking. Otherwise send `think: false` and show a note under the reasoning
  picker in Settings. Today `gemma3:4b` gets `think: true`
  (`OllamaCleaner.swift:280-286`).
- A 300s command hold is still processed at the cap, as today.
- Update `docs/flows/diagnostic-recordings.md`: voice edits create
  Diagnostic recordings when enabled.

### Bugs this fixes

- A reachability change mid-hold restarts the tap, drops the release, and the
  mic runs to the 300s cap.
- A dictation paste during the selection read is taken as the selection.
- Releasing the dictation key during a command hold ends the command early.
- A misleading "needs Apple Intelligence or Ollama" error when Ollama rejects
  `think: true`.

### Tests

- New `CommandModeTests`: availability matrix, no-backend press, reachability
  flip mid-hold leaves the tap alone, tap death mid-hold, Secure Input refusal.
- New Delivery tests: an edit waits for earlier pastes, a failed edit never
  pastes the instruction and never enters retry, history records the edited
  text, a late edit result after cancel is dropped.
- New pipeline test: instruction composition skips formatting, snippets and
  cleanup.
- Rewrite the command tests in `DictationDeliveryTests` (94, 116) at the new
  interface.

## Step 3: One Delivery ordering

Order is enforced twice today: the pipeline orders by generation, and
`InjectionCoordinator` by sequence, each with its own 90s stall timer. A
stalled command ahead of a stalled dictation can wait 180s.

### Decisions

- Delete `InjectionCoordinator`. The pipeline's ordered outcomes plus a small
  paced queue in `DictationDelivery` (0.4s spacing) are the only ordering.
- One stall rule: after 90s a stuck item fails, a dictation's audio goes to
  Manual retry, and the next item moves up. A stuck voice edit just fails. At
  most 90s per stuck item.
- Update `docs/flows/dictation-recovery.md:97-101`, which currently documents
  two distinct stall rules.

### Tests

- `DictationSessionStallTests` becomes the only stall suite.
- Delete `InjectionCoordinatorTests`.

## Other review findings, not yet scheduled

Plausible but not verified at runtime:

- A stale `onRuntimeFailure` from the previous hold can clear the new hold's
  UI and leave the mic open (`AudioRecorder.swift:593`, handler at
  `AppDelegate.swift:334`).
- A runtime mic failure drops the speech already captured instead of offering
  Manual retry, and never calls `recorder.stop`.
- Queued pastes 0.4s apart can double-paste in slow apps
  (`InjectionCoordinator.swift:98`).
- Typing under Secure Input sends each newline as Return, which runs partial
  lines in a terminal with Secure Keyboard Entry (`TextInjector.swift:57`).

Confirmed, small:

- `LocalFlow --transcribe` hangs when cleanup is on. The task awaits the
  main-actor cleanup policy while the main thread blocks in `done.wait()`
  (`LocalFlowMain.swift:117,133`).
- Snippets and corrections with a tab are dropped, and a literal `\n` in a
  snippet becomes a newline (`Settings.swift:92,177-184`).

Docs out of date:

- `docs/flows/settings.md` still says six panes and no production Diagnostics
  pane.
- `docs/flows/dictation-recovery.md:168` cites a test name that no longer
  exists (now `testSilentFullUtteranceSkipsInferenceAndRetry`).
- The README's menu labels don't match the app.

Hardening:

- Pin release workflow actions to commit SHAs and delete the signing keychain
  in an `always()` step (`.github/workflows/release.yml`).
