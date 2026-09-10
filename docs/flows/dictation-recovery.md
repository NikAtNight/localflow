# Dictation recovery

## Requirement and owner

Owner: LocalFlow maintainers. Requested September 9, 2026 after the user confirmed
speaking during a recording whose final recognition result was empty. Recover
empty dictations before discarding audio. Command mode, decoder settings, voice
gates, model selection, and audio persistence are outside this change.

## Behavior and path

`AppDelegate.process` in `Sources/LocalFlow/AppDelegate.swift` rejects recordings
with less than 0.3 seconds of detected voice before entering the session pipeline.
`DictationSessionPipeline.transcribeFullUtterance` in
`Sources/LocalFlow/DictationSessionPipeline.swift` retries an empty full result
once when the supplied audio has at least 0.3 seconds of detected voice. Existing
chunk/tail fallback consumes this same recovery attempt. A retry emits `fullRetry`
and uses the same audio, decoder, cancellation checks, and spoken-order delivery.
An unchanged decode can return empty again; this is a bounded recovery attempt,
not a guarantee that recognition will succeed.

Recovered text goes through formatting and cleanup once, then normal history and
paste dispatch. A second empty result emits `emptyTranscript`; a thrown error
emits `failed`. Neither outcome pastes text or writes transcript history.
`AppDelegate.handleDictationOutcome` routes both outcomes through the existing
failure path: skip injection, keep audio in `retrySamples`, and show an error
explaining Retry Dictation. The retry queue retains the latest three failed recordings
in memory. Quitting loses the queue. Optional [diagnostic recordings](diagnostic-recordings.md)
preserve separate disk copies for replay; they do not restore the menu retry queue. `retryFailedDictation` drains the queue oldest
first into `process`, using current settings and the usual voice gate. A failed
manual attempt is retained again. Cancellation discards stale results.

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
