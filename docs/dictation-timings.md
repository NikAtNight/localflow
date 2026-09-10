# Measuring dictation latency

Use a release build from the current checkout. `swift build -c release` builds
the binary; `scripts/make-app.sh` packages it and stamps the Git revision and
dirty-tree status before signing. The script replaces `build/LocalFlow.app`.
Use the app bundle for microphone/hotkey testing so permissions belong to
LocalFlow. Building does not update the running `/Applications` copy.

## Local events

The app appends `timing {JSON}` events to
`~/Library/Logs/LocalFlow-diag.log`. `timing_environment {JSON}` records app/build
identity, macOS, Mac model, chip, CPU count, and memory. Unbundled binaries and
older app bundles report an unknown commit instead of guessing.

Every event has schema version 1, a random `traceID`, an `ordinal`, a `source`
of `dictation`, `replay`, or `modelLoad`, and a monotonic `uptimeNs`. `sinceStartMs` is relative
to the trace origin. `sinceReleaseMs` exists after release. `startedAt` is a wall
clock anchor for matching a test session to notes. Calculate durations from
monotonic fields, not the outer log timestamp, which reflects asynchronous
disk writing. Order events within a trace by ordinal.

The allowed metadata is model and microphone names, event/status codes, sample
counts, queue counts, durations, and token counts. Events contain no audio,
transcript, selected text, clipboard content, vocabulary, corrections, snippets,
or backend error messages. They stay local and are never uploaded. Existing
dictation history is a separate feature controlled by its existing setting.

| Interval or event | What it measures |
|---|---|
| `hotkeyPressed` to `microphoneLive` | Recognized event-tap callback to sustained usable audio, including main/control queue waiting |
| `captureEnqueued` to `captureStarted` | Recorder control queue wait |
| `captureReady` | Capture start returned or a warm session was reused; does not assert audio is usable |
| `hotkeyReleased` to `audioHandoff` | Release through conversion drain, detachment, and the main-queue handoff |
| `incrementalAttempt` / `incrementalSkipped` | Available samples or why a tick did not submit work |
| `audioReleased` | Full/tail counts and submitted versus completed source-sample boundaries at handoff |
| `engineWaitStarted` to `engineAcquired` | Shared Whisper engine wait |
| `inferenceStarted` to `inferenceFinished` | WhisperKit call, with success/failure/cancellation status |
| `transcriptionRequested` to `transcriptionFinished` | Whole request including adapter work, engine waiting, and text finalization; segment identifies chunk/tail/full |
| `cleanupStarted` to `cleanupFinished` | Complete cleanup policy including discovery and sequential fallback |
| `appleStarted` / `appleFinished` | Apple generation and validation attempt |
| `ollamaDiscoveryStarted` / `ollamaDiscoveryFinished` | Local installed-model lookup before generation |
| `ollamaStarted` / `ollamaFinished` | Ollama generation request |
| `ollamaServerMetrics` | Optional server-reported load, prompt, generation, total milliseconds, and token counts |
| `prewarmStarted` / `prewarmReturned` | Prewarm API call, or coalescing/cooldown; return does not prove Apple finished loading |
| `resultReady` to `resultDelivered` | Session pipeline's spoken-order wait |
| `injectionQueued` to `injectionStarted` | Injection coordinator wait, including its 400 ms spacing |
| `pasteDispatched` | Command-V posting succeeded or failed; success is not confirmation from the target app |
| `typingStarted` / `typingDispatched` | Secure Input fallback's separate serial typing queue |
| `clipboardWindowResolved` | Restore/supersession bookkeeping, not visible insertion |

Sample-based inference events also record the exact submitted sample count,
voiced seconds, finite voiced dBFS, and the low-energy flag. Finish events report
raw character count, result-container count, decoded segment count, and whether
canonical-phrase filtering removed the output. These counts contain no text.
Zero returned characters identify an empty decoder result, but do not expose
Whisper's internal no-speech decision for discarded segments.

Sample inference and Ollama cleanup events include host thermal state and the
one-minute system load average when available. Thermal values are 0 nominal,
1 fair, 2 serious, and 3 critical. Load average is not GPU utilization, this
app's CPU usage, or proof of contention. Pair these fields with existing Ollama
load, prompt, generation, and token measurements when investigating slow runs.
The separate `--transcribe` file path does not emit the sample diagnostics;
use `--replay` for these checks. Inference finish timestamps still bracket the
Whisper call, excluding analysis of the returned text.

Cancellation requests and eventual request returns are separate events. A
cancelled result cannot prove an in-flight CoreML prediction stopped immediately.
No prediction-abort policy is changed by this instrumentation. Hardware event
delivery before the tap callback and target-app rendering after dispatch remain
outside these measurements. Automatic cap releases use callback-time fallback.

The former `end-to-end` message was measured after queue submission and could
exclude injection waiting. It is now named `release-to-result-delivery`; the
menu's latency number updates on successful dispatch. Neither represents visible
insertion. Clipboard restoration retains its existing 2.5-second window.

To share only structured measurements, extract the JSON events locally:

```bash
python3 - <<'PY' > /tmp/localflow-timings.jsonl
import json
from pathlib import Path
for line in (Path.home() / 'Library/Logs/LocalFlow-diag.log').open():
    for marker in (' timing ', ' timing_environment '):
        if marker in line:
            value = json.loads(line.split(marker, 1)[1])
            print(json.dumps(value))
            break
PY
```

Review the export before sharing. Model/microphone names and recording times
are useful metadata but can still be personal. There is no automatic upload or
feedback submission.

## Reusing identical audio

Opt-in [diagnostic recordings](flows/diagnostic-recordings.md) now retain live
dictation audio, transcript stages, and a copy of the timing events. The normal
log remains content-free. Use a saved `original.wav` with the replay commands
below, or an `inference-*.wav` with `--transcribe` to isolate one recognition
attempt.

Supply an explicit local path. WAV, AIFF, and other formats supported by the
existing WhisperKit audio loader can be used. Replay rejects audio longer than
300 seconds and gates insufficient voiced audio using the app's current rules.

```bash
APP=build/LocalFlow.app/Contents/MacOS/LocalFlow
"$APP" --replay /path/to/test.wav --runs 5 --no-cleanup > /tmp/raw-output.txt 2> /tmp/raw-timing.log
"$APP" --replay /path/to/test.wav --runs 5 --cleanup > /tmp/clean-output.txt 2> /tmp/clean-timing.log
```

`--runs` is required and accepts 1 through 100. `--whisper-model NAME` and
`--ollama-model NAME` override only this invocation. Defaults come from settings;
`--cleanup` and `--no-cleanup` explicitly override the cleanup toggle. Run known
local models only for private test audio. Normal Whisper model loading may
download missing model weights. It never uploads the recording.

Replay loads Whisper once, reports model-load time separately, and uses the
same session pipeline and incremental cut logic as the app. It supplies audio
prefixes in real time at the existing 8-second first tick and 4-second subsequent
ticks. It also invokes the usual cleanup prewarm at the start of each run.
No microphone, event tap, target app, injection, or history is involved. No audio
is automatically saved. Each completed transcript is printed to stdout as a
JSON line with its run number, trace ID, and release-to-result milliseconds.
This preserves paragraph breaks for accuracy scoring; never send that output
to a telemetry log.

Use `--no-timing` to disable detailed events in a comparison run and measure
their overhead on identical audio. The stdout release-to-result duration is
still available, and settings, chunking, and cleanup remain the same. Compare
matched first/later runs across multiple alternating trials, not one launch
against another. This measures processing instrumentation overhead, not the
capture/injection hooks. Replay waits for outstanding prewarm calls before
exiting and flushing logs; that final wait is excluded from result latency.

The first run means first inference in that process. Later runs reuse that
engine, but neither label proves cache or backend residency. File replay does
not simulate the microphone's startup noise/silence gate. It cannot reproduce
an 8-second incremental tick missed because the microphone became live late.
The one-file CLI covers sequential repetitions, not overlapping dictations.
Test overlapping dictations through the real hotkey path.

## Comparison protocol

Record the commit/dirty state, release binary identity, hardware/macOS, microphone,
keep-warm setting, Whisper model, cleanup backend/model, and background load.
Do not compile or run another inference workload during timing trials. Keep the
repo's default Large v3 Turbo baseline; the user's selected 626 MB model and
smaller models are separate comparison groups. Do not pool their results.

Use supplied reference transcripts and audio for a 3–5-second message, a
10–15-second sentence, a paragraph with natural pauses, continuous speech,
technical terms/proper names, quiet speech, and trailing silence. Compare
identical files with cleanup off/on. Start with five repeated runs per condition
and three fresh-launch runs. Test idle separately, including beyond the
120-second microphone warm window; record actual capture reuse and backend
loading. Apple-only comparisons require an available Apple backend and separate
controlled testing; `--cleanup` uses the normal Apple-first fallback policy.

For every condition report run count, median, range, and failures. Do not report
p95 from these small samples; collect at least 100 comparable observations
before reporting it. Preserve per-run records so a tail event remains visible.
Score missing/duplicated words, names, technical terms, punctuation, paragraph
breaks, and changes to meaning. Timing diagnostics cannot score accuracy.

Separately test hotkey release to visible insertion in a designated local
document as the normal signed-in Mac user. Record the observation method and
its resolution. Test two quick dictations, order, clipboard restoration, and
copying new content during the restoration window. Use only a designated test
document and test clipboard contents. Do not infer visible insertion from the
completion cue or clipboard restoration.

## Whisper startup

Each call to `Transcriber.load` creates a separate `modelLoad` trace, including
already-loaded and superseded requests. No microphone or transcript is needed.

- `modelLoadRequested` to `modelLoadFinished` measures the whole request.
- `modelLoadWaitStarted` to `modelLoadAcquired` measures the serialization gate.
- `modelCacheChecked.cachePresent` reports directory completeness, not whether
  Core ML has a usable hardware-specialization cache.
- Each `modelAttemptStarted` to `modelAttemptFinished` brackets construction of
  a WhisperKit pipeline. `modelLoadFallback` marks a retry through the registry.
- Attempt start to `modelInitializationStarted` includes pipeline setup and model-folder
  resolution. On the registry path it can include network/download work; this
  interval does not prove a download occurred.
- `modelInitializationStarted` to `modelInitializationFinished` includes all model components AND
  tokenizer loading. On success, `decoderLoadMs`, `encoderLoadMs`, and
  `tokenizerLoadMs` expose WhisperKit's existing stage measurements in milliseconds.
  Those fields use WhisperKit's clock, not our monotonic event clock. They are
  emitted only after success and do not isolate file reads from compilation.
- `tokenizerLoadStarted` to `tokenizerLoadFinished` separately brackets tokenizer
  resolution, including any existing local-cache or network fallback.

The adapter calls the original WhisperKit loading methods. It does not change
compute units, prewarming, model choice, loading order, downloads, or retries.
It does not enable verbose dependency logs. There is no separate mel-extractor
measurement or per-component start event. A stalled Core ML load still needs
Apple's Core ML Instruments trace to distinguish specialization from cached loading.

For startup comparisons, use the same release app bundle and unchanged model
paths. Record the selected model and process launch for every run; test the
saved 626MB model and Turbo separately. Keep first observed launch and repeated
launches separate, and do not label the first observed run a specialization-cache
miss without an Instruments trace. Do not clear caches to manufacture a cold run.
The running installed app must be replaced/relaunched before it can emit these
new events. Existing historical timings are not a benchmark of this patch.
