# Dictation recovery

## Requirement and owner

Owner: LocalFlow maintainers. Requested September 9, 2026 after the user confirmed
speaking during a recording whose final recognition result was empty. Recover
empty dictations before discarding audio. Command mode, decoder settings, voice
gates, model selection, and audio persistence are outside this change.

## Behavior and path

`AppDelegate.beginDictationSession` snapshots settings and optional recording
retention into `DictationDelivery.Configuration`. `DictationDelivery` allocates
the dictation generation and owns its pipeline session. At release, AppDelegate
passes the recorder's paired audio result to `DictationDelivery.release`.

`DictationSessionPipeline.release` retains original audio before applying
`DictationAudioPreparation`. Captures with less than 0.3 seconds of detected
voice produce `insufficientVoice` without recognition or retry. That outcome
returns immediately even while an earlier dictation is waiting. The UI reports
heard-nothing, and archives keep the existing cancelled status. Command mode and
CLI replay use the same preparation rules; replay rejects silence before model
loading. Voiced time uses the existing analysis windows, not total clip duration.

The pipeline retries an empty full result once when the supplied audio has at
least 0.3 seconds of detected voice. Chunk/tail fallback consumes the same recovery
attempt. Requests contain prepared samples and the low-energy decision, so live
and replay callers do not repeat trimming or energy checks. Recovered text goes
through formatting and cleanup once. A second empty result emits `emptyTranscript`;
a thrown error emits `failed`. An unchanged decode can return empty again.

`DictationDelivery` correlates pipeline generations with mixed-mode injection
sequences. Success records transcript history and recent text before dispatch.
Empty and failed results skip injection and retain the latest three originals
in memory. `retryFailedDictations` drains them oldest first through the same
pipeline with current settings. Failed manual attempts are retained again;
manual retries never create personal voice clips. Quitting loses retry audio.
Optional [diagnostic recordings](diagnostic-recordings.md) keep independent disk
copies and do not restore the retry queue.

The pipeline and injection coordinator retain their distinct stall rules.
Injection-side cancellation removes the correlated dictation and cancels its
pipeline work; late outcomes cannot write history, refill retry audio, or inject
text. Pipeline timeout remains a recoverable failure. Commands share injection
ordering and their completion is accepted once.

Delivery remains busy until the text injector's completion callback, including
clipboard restoration. AppDelegate also refuses Quit during recording and queued
audio handoff. A dispatch callback alone does not make delivery idle and does
not establish visible insertion in the target app.

## Architecture implementation verification

The user requested implementation of all four architecture-review candidates on
September 10, 2026. Owner: LocalFlow maintainers. Base: `4f4526a`, with uncommitted
changes. This refactor preserves recognition settings, retry limits, ordering,
retention policies, login/update policy, and microphone implementation.

- `DictationDeliveryTests` covers delayed delivery completion, duplicate callbacks,
  bounded FIFO retry with current corrections, failed manual retry, immediate
  silence rejection, both stall paths, and late results after cancellation.
- `DictationAudioPreparationTests` exercises admission and low-energy decisions,
  exact original retention, prepared retry audio, incremental requests, and an
  empty tail through the pipeline's transcription interface.
- `AudioCaptureLifecycleTests` exercises queued samples and native audio through
  the recorder's real start/stop path using a synthetic input adapter.
- Settings routing checks cover window/menu effects, no-op suppression, rollback,
  login failure/retry, and correction identity. See [settings](settings.md).

Verified on macOS 26.6.2, arm64, Apple Swift 6.3.3:

- PASS: `swift test --disable-automatic-resolution --filter
  'DictationDeliveryTests|DictationAudioPreparationTests|AudioCaptureLifecycleTests|DictationSession|DictationDiagnosticPipelineTests|DictationTraceTests|SettingsApplication|RemainingSettings|SettingsModelCorrection|UpdateController|AppTerminationTests'`,
  70 tests before the additional runtime-error capture test.
- PASS: `swift test -c release --disable-automatic-resolution`, 282 tests with
  zero failures, including the added runtime-error recovery/stale-input test.
  This command also built the changed application in release mode.
- PASS: `python3 -B Tests/LocalAppIdleTests.py`, six tests;
  `python3 -B Tests/StartupReadinessTests.py`, four tests; `git diff --check`.
- PASS: fresh independent source review found no blocking regression. Its
  runtime-error test gap was covered by the added capture test and release run.
- NOT RUN: live microphone capture, actual model inference, target-app insertion,
  installed settings interactions, packaging, or installation. Tests use
  synthetic input and isolated recording folders. No commit or push was made.

Logs are `localflow-architecture-implementation-focused.log` and
`localflow-architecture-release-tests.log` in the OS temporary directory.
The final source and documentation diff is
`/tmp/localflow-architecture-implementation-20260910.diff`.
Two existing compiler warnings remain in StartupModelSequenceTests and
InjectionCoordinatorTests.

The domain names are recorded in [CONTEXT.md](../../CONTEXT.md). Audio admission
uses trimmed analysis windows; empty-result retry and tail fallback retain their
original-window rules. A regression test covers the half-frame alignment case.


## Acceptance and verification

Base commit: `2102c80b9644b1dc1509d4068994bdd762446d4e`, with the uncommitted
recovery diff in `/tmp/localflow-empty-recovery.diff`. macOS 26.6.2, Apple M5 Pro,
Swift 6.3.3. Evidence paths are local temporary files.

Tests in `Tests/LocalFlowTests/DictationSessionPipelineTests.swift` cover:

- `testEmptyFullUtteranceRetriesOnceAndCleansOnlyRecoveredText`: same audio retried,
  recovered text delivered, cleanup receives only recovered text.
- `testRepeatedEmptyFullUtteranceStopsAndUnblocksLaterDictation`: two attempts,
  one empty outcome, subsequent dictation delivered in order.
- `testFailedAutomaticRetryEmitsFailureWithoutFurtherAttempts`: a thrown retry
  emits failure after two calls, without cleanup.
- `testEmptySilentFullUtteranceDoesNotRetry`: silence adds no retry.
- `testEmptyChunkRecoveryDoesNotRetryFullUtteranceAgain`: chunk fallback uses
  the recovery budget.
- `testCancelledEmptyResultRetryCannotDeliverLateText`: cancelled retry output
  cannot reach cleanup or delivery; the next dictation proceeds.

Results on September 9, 2026:

- PASS: new regression tests failed against the prior implementation, with five
  assertions exposing the missing full-result retry. Evidence:
  `/tmp/localflow-empty-recovery-red.log`.
- PASS: `swift test --disable-automatic-resolution --filter
  'DictationSessionPipelineTests|DictationSessionStallTests|DictationTraceTests'`,
  20 tests before the additional thrown-retry test. Evidence:
  `/tmp/localflow-empty-recovery-focused.log`.
- PASS: `swift test --disable-automatic-resolution`, 213 tests, zero failures.
  Evidence: `/tmp/localflow-empty-recovery-tests.log`. This command also built
  the changed application source and tests.
- PASS: independent source review and `git diff --check`.
- NOT RUN: installed-app menu retry, microphone capture, target-app insertion,
  and real Whisper recovery. The tests substitute recognition results and do
  not establish decoder accuracy or actual menu behavior. Maintainers should
  verify the installed retry flow in a designated test document when the app
  can be replaced. The running app was not rebuilt or relaunched by this task.

## Installed follow-up

The user subsequently requested all usage-review follow-ups, including local
installation and a live microphone check. The recovery change is now installed
in LocalFlow Local 1.3.0. `scripts/local-app.sh install` observed model readiness
in 0.98 seconds; code-signature verification passed. The installed executable
matches the packaged executable before its embedded signature. The existing
runtime theme-icon rebake changes the signature after launch.

PASS: final follow-up release suite, 215 tests, zero failures, in
`/tmp/localflow-usage-release-tests.log`. This supersedes the earlier note that
the running app had not been updated. The application retains the same source
base plus uncommitted changes. See the [usage review](../usage-review-2026-09-09.md)
for controlled replay results, new diagnostic context, paste warning semantics,
and remaining real-device checks. No test forces the installed app to produce
an empty decoder result; manual retry UI remains a separate verification gap.

The later install-safety fix refuses Quit across recording, audio handoff,
processing, and injection completion. It was prompted by an interrupted recording
during the first rebuild. The final release suite contains 217 passing tests;
the installer preflight has six passing Python tests. Details and limitations
are recorded in the usage review.

## Architecture local installation

The user subsequently requested rebuilding the local app, then committing and
pushing these changes. On September 10, 2026, `./scripts/local-app.sh install`
built and installed LocalFlow Local 1.5.0. The installer passed its idle check,
preserved the previous local bundle, and observed speech recognition ready in
0.97 seconds. Post-launch `codesign --verify --deep --strict` passed, and the
installed local executable was running.

The app was built before the commit, as requested. Its metadata reports base
revision `4f4526a` with a modified tree and build time
`2026-09-11T02:49:36Z`. The source matched the reviewed implementation diff and
the 282-test release run. Installation evidence is
`localflow-architecture-install-20260910.log` in the OS temporary directory.
No live microphone dictation or target-app insertion was performed during
installation. This installation supersedes the earlier not-installed status.
