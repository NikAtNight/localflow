#!/bin/bash
# Registers Superwhisper's s1-mini transcript normalizer (0.6B, Apache 2.0)
# with the local Ollama server under the name "s1-mini", which is LocalFlow's
# default cleanup model. Uses the Modelfile from the official model card: the
# model was trained with thinking off and greedy decoding, so the template
# bakes in an empty <think> block and temperature 0. A plain
# `ollama pull hf.co/superwhisper/s1-mini-GGUF` would keep Qwen3's default
# template, which leaves thinking on and produces blank output.
set -euo pipefail

if ! command -v ollama >/dev/null; then
    echo "ollama is not installed. Install it first (brew install ollama, or" >&2
    echo "https://ollama.com/download), make sure the server is running, then re-run." >&2
    exit 1
fi

if ollama show s1-mini >/dev/null 2>&1; then
    echo "s1-mini is already registered with Ollama; nothing to do."
    exit 0
fi

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

echo "Downloading s1-mini Q4_K_M (~460 MB)..."
curl -fL --progress-bar -o "$workdir/s1-mini-q4_k_m.gguf" \
    "https://huggingface.co/superwhisper/s1-mini-GGUF/resolve/main/s1-mini-q4_k_m.gguf"

cat > "$workdir/Modelfile" <<'EOF'
FROM ./s1-mini-q4_k_m.gguf

SYSTEM """You are a text normalizer for speech-to-text transcripts. The input begins with a control line specifying the styling, structure, and context settings; clean the transcript to match those settings and output only the cleaned text."""

TEMPLATE """<|im_start|>system
{{ .System }}<|im_end|>
<|im_start|>user
{{ .Prompt }}<|im_end|>
<|im_start|>assistant
<think>

</think>

"""

PARAMETER temperature 0
PARAMETER num_ctx 4096
EOF

(cd "$workdir" && ollama create s1-mini -f Modelfile)

echo
echo "Done. With 'Clean up' enabled in LocalFlow's settings (and Apple"
echo "Intelligence unavailable), dictations now run through s1-mini."
