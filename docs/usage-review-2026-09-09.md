# Local usage review, September 9, 2026

Owner: LocalFlow maintainers. The user requested review of daily voice usage,
then implementation and investigation of recovery, empty segments, cleanup
latency, paste warnings, and transcription accuracy.

## Daily observations

Retained LocalFlow Local diagnostics covered 128 recording attempts from 11:45
a.m. through 5:29 p.m. Toronto time. There were 123 saved transcripts and
successful paste dispatches, four insufficient-voice skips, and one final empty
result. The user confirmed speaking during that empty recording. Captured audio
totaled 25 minutes, 16 seconds. Median release-to-paste dispatch was 1.00 second;
110 of 123 dispatches finished within 1.5 seconds. Dispatch does not establish
visible insertion or accuracy.

Configuration: LocalFlow Local 1.2.0, Whisper Large v3 626 MB, s1-mini cleanup,
Realtek USB audio, Apple M5 Pro. Today's ordinary recordings were not saved as
audio, so historical recognition accuracy and exact failure causes cannot be
reconstructed.

Four earlier empty results recovered through full-recording fallback: two
incremental chunks and two release tails. Three incurred 2.57 to 2.97 seconds
of release-to-paste delay. All five empty results had zero raw characters and
were flagged low energy. This rules out cleanup and canonical-phrase filtering
as their cause. Failed incremental inputs were not shortened by trimming.
Whisper's internal no-speech rejection is a possibility, not a demonstrated
cause. No voice, trimming, or decoder thresholds were changed.

The two longest dispatch delays were 3.80 and 3.82 seconds. Ollama generation
consumed 2.75 and 2.09 seconds, compared with typical cleanup around 0.18 seconds.
Model load was only 1.05 and 1.61 milliseconds. Local Ollama HTTP logs confirm
those server delays. The records do not establish thermal throttling, competing
GPU work, or another specific cause, so model choice and timeouts were preserved.

A clipboard change after the 5:19 p.m. paste triggered an uncertain-delivery
warning. The text was saved. Neither the changed clipboard nor the successful
paste event proves whether the target app inserted it.

## Changes and checks

- Empty full results get one bounded retry for voiced audio; unsuccessful
  recordings join the existing memory-only manual retry queue. See
  [dictation recovery](flows/dictation-recovery.md) for contracts and tests.
- `TextInjector.InjectionResult` distinguishes dispatched events, clipboard
  disturbance, and dispatch failure. Paste and secure typing share the result
  type; `AppDelegate.injectCompletedText` displays its specific issue. Existing
  clipboard restoration behavior is preserved.
- `Transcriber.transcribe(samples:)` reports actual input voice measurements,
  output character and segment counts, and canonical filtering. Raw text is not
  written to diagnostics. The old plain log mislabeled result containers as
  segments; it now says results.
- `DictationTrace.runtimeFields` is shared by sample inference and Ollama
  cleanup. It records thermal state and system load without collecting process
  names or content. See [timing definitions](dictation-timings.md).

PASS: `swift test --disable-automatic-resolution`, 215 tests. PASS:
`swift test -c release --disable-automatic-resolution`, 215 tests. The debug build
reported an existing weak-variable warning in `InjectionCoordinatorTests.swift`.
Evidence: `/tmp/localflow-usage-followup-tests.log` and
`/tmp/localflow-usage-release-tests.log`.

PASS: independent source review found no blocking findings. PASS:
`./scripts/local-app.sh install` installed the local build and observed model
readiness in 0.98 seconds. The prior local bundle was retained at
`/Applications/.localflow-local.kzmipB/Previous LocalFlow Local.app`.
Evidence: `/tmp/localflow-usage-install.log`. Installed source base is
`2102c80b9644b1dc1509d4068994bdd762446d4e` with uncommitted changes. The local build
also includes the user's pre-existing ThemeIcon changes. No commit or push was
made.

## Accuracy method

Fixtures use macOS Samantha speech at 180 words per minute, converted to mono
16 kHz PCM. The short sentence, technical terms, and paragraph each have a known
reference. A quiet paragraph scales the same waveform toward -43 dBFS voiced
RMS. Paused variants extend three existing silent spans by 0.65 seconds without
changing speech samples. Five repeats per condition test consistency; they are
not five independent speech samples.

The existing `--replay` path exercises incremental scheduling, recognition,
formatting, and optional cleanup. It does not capture the microphone, paste, or
save dictation history. Models are explicitly Large v3 626 MB and s1-mini.
Cleanup-off output still includes deterministic formatting and saved corrections;
it is not an unprocessed Whisper hypothesis. Runs use the installed local app.

Word scoring lowercases text, extracts alphanumeric word tokens, and computes
Levenshtein distance. Punctuation and capitalization are ignored; split product
names count as word differences. This small synthetic set cannot establish the
user's real-world word error rate. First and later inference runs share each
condition's process; no cold-cache claim or p95 is made.

Fixtures, exact references, commands, per-run outputs, timing events, and scorer
are local at:
`/var/folders/s7/6ctmdy055ml8vds23sr3qtnc0000gn/T/localflow-usage-20260909-66_r0z5i`.

## Controlled results

All 55 replays produced text, with no empty results or full retries.
Each row contains five runs. Times measure release to result, not paste.

| Fixture | Cleanup | Word errors per run | Median ms | Range ms |
|---|---|---:|---:|---:|
| Short sentence | Off | 0 | 707 | 704 to 1368 |
| Short sentence | On | 0 | 795 | 790 to 824 |
| Technical terms | Off | 3 | 863 | 843 to 888 |
| Technical terms | On | 3 | 1016 | 1000 to 1066 |
| Paragraph | Off | 0 | 1132 | 1108 to 1145 |
| Paragraph | On | 0 | 1324 | 1305 to 1362 |
| Quiet paragraph | Off | 0 | 1110 | 1082 to 1133 |
| Quiet paragraph | On | 0 | 1305 | 1269 to 1330 |
| Paused paragraph | Off | 0 | 853 | 848 to 887 |
| Paused quiet paragraph | Off | 0 | 866 | 836 to 907 |
| Technical terms with hints | Off | 0 | 997 | 971 to 1018 |

Technical speech consistently became "Local flow" and "Alima" without vocabulary
hints. Cleanup preserved those errors. A process-only `-customVocabulary
'LocalFlow, Ollama'` override before `--replay` corrected both names in all five
runs of identical audio. The local vocabulary was initially empty. After that
comparison, those two tested hints were saved to LocalFlow Local and the idle
app was reopened. No global replacement rule or production preference changed.
The prior value is retained privately in the fixture directory.

The quiet fixture measured about -41.96 dBFS voiced energy and set lowEnergy=1.
It still produced all expected words. Cleanup restored a sentence boundary in
that fixture. Paused output also changed sentence punctuation while preserving
words. These differences are outside the word score.

The initial 40 runs emitted all expected content-free sample metadata. Across
20 cleanup requests, server time had median 167 ms and maximum 218 ms. Thermal
state stayed nominal; one-minute load ranged from 3.79 to 8.11. These runs did
not reproduce the historical generation spikes or establish their cause.

## Install safety follow-up

The first install at 5:43 p.m. interrupted a recording that began during the
build. The pre-build idle check was insufficient. Its old-process trace ended
at an incremental inference start before the replacement app launched. No result
was recorded for that attempt, and its audio cannot be recovered from logs.

`AppDelegate.applicationShouldTerminate` now refuses normal quit while recording,
audio handoff, processing, typing, or clipboard restoration remains active.
The existing recording UI remains visible and Last Error explains the refusal.
The handoff and injection counters cover gaps between the recording flag and
processing count. `scripts/local-app.sh` also checks only the current process's
session after the build and before quitting, protecting upgrades from older
builds and ignoring stale incomplete traces from earlier launches.

PASS: `swift test -c release --disable-automatic-resolution`, 217 tests, zero
failures, in `/tmp/localflow-quit-guard-tests.log`. PASS:
`python3 Tests/LocalAppIdleTests.py`, six tests; CI now runs that command. PASS:
`bash -n scripts/*.sh`. Independent source review found balanced lifecycle
counters. The tests cover the quit predicate and installer preflight; actual
installed quit refusal is a separate live check.

PASS: the guarded local build was installed and reached model readiness in
1.07 seconds. Evidence: `/tmp/localflow-guard-install.log`. The prior local bundle
is retained in `/Applications/.localflow-local.dVSbRj`. The subsequent vocabulary
restart is recorded in `/tmp/localflow-vocabulary-ready.log`.

A stuck inference can keep normal Quit blocked. Force Quit still exits the app
and loses in-memory recordings. The guard does not change the existing inference
stall policy.

Two further smoke replays used the final installed guard build and saved vocabulary,
without process-only hints. Technical speech with cleanup preserved both product
names, with release-to-result 1.167 seconds. The paused quiet paragraph preserved
all words, with release-to-result 0.946 seconds. These bring the total to 57
successful replay runs. Neither smoke run needed recovery.

The focused uncommitted patch is `/tmp/localflow-usage-followup.diff`. It excludes
the pre-existing ThemeIcon and .claude changes. No new dependency was introduced.

## Observed microphone and quit check

A real microphone recording at about 6:03 p.m. overlapped the live-check monitor.
The user confirmed this was dictation into another thread for another app,
not the supplied reference sentence. It establishes real capture and quit-guard
behavior, but is not scored for accuracy. Its content is not included in this
report or fixtures.

PASS: the Quit request was refused, the app stayed running, and the same trace
completed with a successful paste dispatch 1.321 seconds after release. The log
contains `quit refused: dictation is still active`. The clipboard window resolved
unchanged. Two recognition inputs measured -42.45 and -44.32 dBFS voiced energy,
both low energy, and returned text without filtering or retry. Evidence:
`live-events.json` in the fixture directory, containing numeric events only.

PASS: a separate reference recording at 6:06:07 p.m. matched the supplied
sentence exactly in both saved history and the user's unedited reply, including
LocalFlow and Ollama. Microphone-live timing was 17.29 ms; release-to-paste
dispatch was 1.128 seconds. Voiced level was -42.33 dBFS, lowEnergy=1, and no retry
was needed. The clipboard restoration window resolved unchanged. Evidence:
`reference-live-events.json` in the fixture directory.

The user clarified that the earlier 6:03 output was expected speech for other
work. There is no observed unrelated-text substitution in these live checks.
NOT RUN: deliberately disturbed clipboard warning in the installed UI, secure
input failure, and a forced empty-result/manual retry lifecycle. Unit tests and
source inspection cover those contracts, not a complete real-device proof.
