# Local voice trial

This optional developer script makes a short synthetic voice sample using one
reference recording. It does not train a model or change LocalFlow's dictation
pipeline. Listen to the result to judge whether it resembles your voice.

The script uses the English Chatterbox model and keeps its built-in Perth
watermark. Resemble AI provides a [Mac example](https://github.com/resemble-ai/chatterbox/blob/master/example_for_mac.py)
using MPS or CPU. The [model repository](https://huggingface.co/ResembleAI/chatterbox)
and [Python package](https://pypi.org/project/chatterbox-tts/0.1.7/) are pinned in
the script and requirements file.

## Setup

Use an existing Python 3.12 installation. Setup creates a virtual environment
inside the ignored `build/voice-clone/` directory. It does not install global
packages. Allow several GB for dependencies and the 3.2 GB model download.

```bash
bash scripts/setup-voice-clone.sh
```

Set `PYTHON_BIN=/path/to/python3.12` if needed. The initial run downloads public
model weights from Hugging Face. Reference audio and synthesis text remain on
the machine. Hugging Face telemetry is disabled. Once cached, use `--offline`
to prohibit model downloads.

The requirements pin Perth and setuptools because Perth 1.0.1 still imports
`pkg_resources`, which setuptools 81 removed. The script fails if the real
watermarker cannot load.

## Generate a sample

Choose one of your own original WAV recordings, five to thirty seconds long,
with a single speaker and little background noise. Listen to the reference
first. The script checks duration and basic signal validity; it cannot verify
speaker identity or recording quality.

Use `original.wav` from the diagnostic archive, or a retained microphone WAV
from the personal voice archive. Avoid recognition chunks and retries. For a
longer recording, trim a separate copy. Keep the original unchanged.

```bash
build/voice-clone/.venv/bin/python scripts/voice-clone-trial.py \
  --reference "/absolute/path/to/your/original.wav" \
  --text "This is a synthetic voice test made from my own recordings. I am checking how naturally it speaks." \
  --output build/voice-clone/trial.wav

afplay build/voice-clone/trial.wav
```

The default device is MPS when available, otherwise CPU. Pass `--device cpu`
if MPS fails. CPU can be slower. The trial has a nine-minute timeout and limits
text to 400 characters. Each output path must be new. Downloads completed
before a timeout remain cached for another attempt.

The adjacent JSON file records the model revision, every installed dependency
version, device, seed, generation settings, reference path and SHA-256, output
text, sample rate, duration, and elapsed time. Audio and JSON files are created
with owner-only permissions. Keep them under `build/voice-clone/`, which is
ignored by git. They are not managed by either archive's retention policy.

The same seed does not guarantee identical audio across hardware or package
versions. The script preserves the model's watermarked floating-point waveform
without normalization or resampling.

## Dataset limits

The current diagnostic originals are 16 kHz recordings. They can support a first
experiment, but they do not contain frequencies discarded during capture's
conversion for Whisper. Higher-rate microphone recordings preserve more detail
for future experiments.

Voice cloning from a reference clip does not teach an agent your vocabulary or
writing style. Reviewed verbatim transcripts can support that separate work.
More recordings alone do not improve this reference-based model: compare
references, record what sounds wrong, and decide whether fine-tuning is useful.

## Local validation

A cached offline run on Apple Silicon with 64 GB memory produced a 5.58-second,
24 kHz WAV in 46.14 seconds using MPS, seed 42, and a 9.35-second diagnostic
original. The reference was selected by duration and measured signal level.
Its voice identity and clarity were not manually verified. The output passed
finite-sample and non-silence checks, and Perth returned a detection score of
1.0. Audio and metadata permissions were both `0600`.

Setup, dependency consistency, Python and shell syntax, and refusal of missing
references, empty text, and existing output paths were checked. CPU inference
has not been tested. Voice resemblance and spoken-word accuracy still need a
listening check.

The installed LocalFlow CLI also transcribed the generated WAV with cleanup
disabled. Its transcript matched the requested sentence except that `I am`
became `I'm`. This automated check cannot distinguish a spoken contraction
from recognition normalization. The private transcript and timing log are
saved next to the trial output.
