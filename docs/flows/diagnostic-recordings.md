# Diagnostic recording and replay

## Requirement and ownership

The user requested retained audio and raw transcripts on September 10, 2026,
after a dictation silently lost its ending. Owner: LocalFlow maintainers.
Capture enough evidence to distinguish audio capture, recognition, formatting,
cleanup, and dispatch failures. Recognition accuracy and decoder settings are
unchanged. The separate daily transcript log keeps its existing behavior.

## Flow and stored evidence

`AppDelegate.beginDictationSession` snapshots the opt-in
`Settings.saveDiagnosticRecordings` preference and creates a
`DictationDiagnosticStore.Recording`. Default is off. A manual menu retry creates
another archive if enabled. Command mode and CLI replay do not create archives.

`DictationSessionPipeline` owns the archive for that generation. At release,
`AppDelegate.process` saves audio before the voice gate and silence trimming.
`release` also saves audio for sessions started by manual retry. The first save
wins, so a trimmed request cannot overwrite the original capture.

The archive directory name is the timing trace UUID. Each contains:

- `metadata.json`: schema version, start time, build identity, selected models,
  microphone setting, effective vocabulary, cleanup/style settings, corrections,
  and snippets. Actual recognition/cleanup models and capture device events
  also appear in the events below.
- `environment.txt`: the existing content-free environment record, including
  macOS, chip, memory, build configuration, and full bundled commit identity.
- `original.wav`: captured 16 kHz mono Float32 PCM after microphone conversion,
  before silence trimming. This is not the microphone's native hardware format.
- `inference-<UUID>.wav`: exact trimmed samples submitted to each Whisper call.
- `events.jsonl`: ordered recognition requests/results, raw Whisper text and
  segment timestamps, postprocessed recognition output, assembled transcript,
  cleanup input, backend cleanup candidates, cleanup result, final transcript,
  and empty/error/cancellation outcomes. Empty strings are retained.
- `timing.jsonl`: structured events from session start onward, including chunk
  boundaries, retries, model identities, capture device, and paste dispatch.
  Paste dispatch success does not prove visible insertion in the target app.

`Transcriber.transcribe(samples:)` records the exact inference input and raw
results before filtering. `LocalTextModelPolicy` records Apple/Ollama cleanup
candidates before validation. Task-local archive context keeps overlapping
sessions separate. Archive writes run on one utility queue, outside capture and
inference threads. Normal shutdown drains that queue.

## Retention and failures

Storage is under `Application Support/<app name>/DiagnosticRecordings`, with
0700 directories and 0600 files. The setting affects newly started dictations;
an existing archive may finish after it is turned off. Archive deletion is
serialized with writes. Late results do not recreate deleted directories.

Pruning removes folders older than 7 days, then oldest folders until the stored
file bytes total at most 1 GB. It runs at launch, after writes, and hourly while
open. A write can temporarily exceed the cap before its immediate pruning pass.
The app cannot expire files while closed. The quota applies only to managed UUID
folders, not unrelated files placed in the root. Move a case outside this folder
before expiry if it needs longer investigation.

A write or pruning failure leaves dictation delivery unchanged, logs a
content-free warning, and displays an error in History settings. Archives can be
incomplete after disk failure or abrupt process termination. Audio is persisted
at release, so this does not recover an in-progress recording after a crash.
The ordinary menu retry queue still lives in memory.

## Replay

Use a local release binary from this checkout and an explicit saved file:

```bash
swift build -c release --disable-automatic-resolution
.build/release/LocalFlow --replay /absolute/path/to/original.wav --runs 1 --no-cleanup
.build/release/LocalFlow --transcribe /absolute/path/to/inference-UUID.wav --no-cleanup
```

`--replay` reruns incremental scheduling; `--transcribe` sends a file through
recognition without that scheduling. The second command isolates a failed chunk
or full-utterance retry. Compare raw Whisper text, `assembledTranscript`,
`cleanupInput`, `cleanupCandidate`, and `finalTranscript` to identify the first
stage missing the reported words. Keep a human reference transcript alongside
the case when available. The archive cannot infer words never captured.

Replay uses current settings unless overridden; it does not automatically restore
`metadata.json`. Match the saved model with `--whisper-model` on `--replay` and
check the saved vocabulary, corrections, snippets, cleanup model, and style when
comparing outputs. Model names and build metadata are recorded, but model weight
hashes are not. Do not treat a changed model or settings as an identical replay.

## Verification

Verified against base commit `aa5278631c15cbc21d878a460234a002eaa17a6c`
plus the uncommitted diagnostic retention changes. Diff artifact:
`/tmp/localflow-diagnostic-retention.diff`. Environment: macOS 26.6.2,
arm64, Apple Swift 6.3.3.

- PASS: `swift test --disable-automatic-resolution --filter
  'DictationDiagnostic|SettingsApplicationRoutingTests|DictationSessionPipelineTests|DictationTraceTests|LocalTextModelPolicy'`,
  62 tests. Evidence: `/tmp/localflow-diagnostic-focused-tests.log`.
- PASS: `swift test -c release --disable-automatic-resolution`, 228 tests,
  zero failures. Evidence: `/tmp/localflow-diagnostic-release-tests.log`.
  This includes exact Float32 WAV recovery through WhisperKit's replay loader,
  0700/0600 permissions, age/size pruning, deletion with late writes, empty and
  failed recognition, preserved transcript stages, and the default-off setting.
- PASS: `swift build -c release --disable-automatic-resolution` and
  `git diff --check`. Evidence: `/tmp/localflow-diagnostic-release-build.log`.
- PASS: independent read-only review. Its timeout-outcome and trimmed-retry
  findings were fixed and rechecked. `DictationSessionStallTests` now asserts
  the archived timeout message. The new assertions failed before the fix,
  as recorded in `/tmp/localflow-diagnostic-timeout-red.log`, and pass in the
  final 228-test release run. A build interrupted by a concurrent test edit
  was rerun successfully after edits finished.
- NOT RUN: installed-app settings interactions, microphone recording, real
  Whisper/cleanup inference with archive capture, and target-app insertion.

Tests use isolated temporary folders and synthetic audio. They do not establish
actual microphone quality or Whisper accuracy. Two existing release-test compiler
warnings remain in `InjectionCoordinatorTests` and `StartupModelSequenceTests`.
The invalid-root test intentionally emits the content-free archive failure
warning. The initial implementation did not replace or relaunch the running
application.

## Local installation

The user subsequently requested a local build, commit, and push. On September
10, 2026, `./scripts/local-app.sh install` built and installed LocalFlow Local
1.4.1, preserved the previous local bundle, and observed speech recognition ready
in 0.98 seconds. Installed-app signature verification passed. Evidence:
`/tmp/localflow-diagnostic-install.log`.

Diagnostic retention is enabled in the local app's preferences. Production
preferences are unchanged. The bundle was built from the pre-commit working tree,
including the existing local theme-icon edit, and reports its base revision with
a modified-tree flag. The commit excludes that unrelated edit and `.claude`.
No microphone dictation or target-app insertion was performed during installation;
the next live recording remains the end-to-end archive check.
