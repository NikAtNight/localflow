#!/usr/bin/env python3
"""Generate a local, watermarked Chatterbox voice sample from a reference WAV."""

import argparse
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import platform
import random
import signal
import sys
import time


MODEL_ID = "ResembleAI/chatterbox"
MODEL_REVISION = "5bb1f6ee58e50c3b8d408bc82a6d3740c2db6e18"
ROOT = Path(__file__).resolve().parents[1]
WORK_DIR = ROOT / "build" / "voice-clone"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference", type=Path, required=True)
    parser.add_argument("--text", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--device", choices=("auto", "mps", "cpu"), default="auto")
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--offline", action="store_true", help="Use cached model files only.")
    args = parser.parse_args()
    reference = args.reference.expanduser().resolve()
    output = args.output.expanduser().resolve()
    metadata_path = output.with_suffix(".json")
    if not reference.is_file():
        parser.error("Reference WAV does not exist.")
    if output.suffix.lower() != ".wav":
        parser.error("Output must have a .wav extension.")
    if output.exists() or metadata_path.exists():
        parser.error("Output or metadata already exists. Choose a new output path.")
    if not args.text.strip() or len(args.text) > 400:
        parser.error("Use 1 to 400 characters for this short voice trial.")

    os.umask(0o077)
    WORK_DIR.mkdir(parents=True, exist_ok=True)
    WORK_DIR.chmod(0o700)
    os.environ["HF_HOME"] = str(WORK_DIR / "huggingface")
    os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
    os.environ["HF_HUB_DISABLE_IMPLICIT_TOKEN"] = "1"
    os.environ["DO_NOT_TRACK"] = "1"
    os.environ["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"
    os.environ["NUMBA_CACHE_DIR"] = str(WORK_DIR / "numba")
    if args.offline:
        os.environ["HF_HUB_OFFLINE"] = "1"

    def timed_out(_signum, _frame):
        raise TimeoutError("Voice trial exceeded its nine-minute limit. Cached downloads can be reused.")

    signal.signal(signal.SIGALRM, timed_out)
    signal.alarm(540)
    started = time.monotonic()
    import numpy as np
    import perth
    import soundfile as sf
    import torch
    from huggingface_hub import snapshot_download
    from chatterbox.tts import ChatterboxTTS

    if perth.PerthImplicitWatermarker is None:
        raise RuntimeError("Perth watermark dependency is unavailable. Run scripts/setup-voice-clone.sh.")

    info = sf.info(reference)
    if info.format not in ("WAV", "WAVEX") or not 5 <= info.duration <= 30:
        parser.error("Use a WAV reference between 5 and 30 seconds. Trim a copy of longer recordings first.")
    samples, _ = sf.read(reference, dtype="float32", always_2d=True)
    if not np.isfinite(samples).all() or np.max(np.abs(samples)) < 0.001:
        parser.error("Reference is silent or contains invalid samples.")
    device = args.device
    if device == "auto":
        device = "mps" if torch.backends.mps.is_available() else "cpu"
    if device == "mps" and not torch.backends.mps.is_available():
        parser.error("MPS is unavailable. Use --device cpu.")
    random.seed(args.seed)
    np.random.seed(args.seed)
    torch.manual_seed(args.seed)
    torch.set_num_threads(min(8, os.cpu_count() or 1))
    print(f"Loading pinned Chatterbox model on {device}. Reference stays on this Mac.", flush=True)
    model_dir = snapshot_download(
        repo_id=MODEL_ID,
        revision=MODEL_REVISION,
        allow_patterns=["ve.safetensors", "t3_cfg.safetensors", "s3gen.safetensors", "tokenizer.json"],
        local_files_only=args.offline,
    )
    model = ChatterboxTTS.from_local(model_dir, device=device)
    settings = {"exaggeration": 0.5, "cfg_weight": 0.5, "temperature": 0.8,
                "repetition_penalty": 1.2, "min_p": 0.05, "top_p": 1.0}
    waveform = model.generate(args.text, audio_prompt_path=str(reference), **settings)
    generated = waveform.squeeze(0).detach().cpu().numpy()
    if not generated.size or not np.isfinite(generated).all() or np.max(np.abs(generated)) < 0.001:
        raise RuntimeError("Model returned empty, silent, or invalid audio.")
    output.parent.mkdir(parents=True, exist_ok=True)
    # Chatterbox applies Perth before returning the waveform. Keep that output intact.
    with output.open("xb") as audio_file:
        sf.write(audio_file, generated, model.sr, format="WAV", subtype="FLOAT")
    metadata = {
        "synthetic": True,
        "model": MODEL_ID,
        "model_revision": MODEL_REVISION,
        "reference": str(reference),
        "reference_sha256": hashlib.sha256(reference.read_bytes()).hexdigest(),
        "reference_sample_rate": info.samplerate,
        "reference_duration_seconds": info.duration,
        "text": args.text,
        "device": device,
        "seed": args.seed,
        "generation_settings": settings,
        "watermark": "Chatterbox built-in Perth watermark retained",
        "output_sample_rate": model.sr,
        "output_duration_seconds": len(generated) / model.sr,
        "elapsed_seconds": round(time.monotonic() - started, 2),
        "python": sys.version,
        "platform": platform.platform(),
        "dependencies": dict(sorted((d.metadata["Name"], d.version) for d in importlib.metadata.distributions())),
    }
    with metadata_path.open("x") as f:
        json.dump(metadata, f, indent=2)
        f.write("\n")
    signal.alarm(0)
    print(f"Saved {output} and {metadata_path}. Listen to assess resemblance.")


if __name__ == "__main__":
    try:
        main()
    except (TimeoutError, OSError, RuntimeError) as error:
        print(f"Voice trial failed: {error}", file=sys.stderr)
        sys.exit(1)
