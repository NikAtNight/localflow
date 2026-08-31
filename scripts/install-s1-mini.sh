#!/bin/bash
set -euo pipefail

MODEL_NAME="s1-mini"
MODEL_REVISION="34add00a48a2e5d24e5a4ee5405a99620a3a240c"
MODEL_SHA256="3b41ebe2502cbd03e811d5d16b022f5ab551eda58d62597d152f89535003c634"
MODEL_DIR="$HOME/Library/Application Support/LocalFlow/Models/S1-mini-by-Superwhisper"
GGUF="$MODEL_DIR/s1-mini-q4_k_m.gguf"
MODELFILE="$MODEL_DIR/Modelfile"
MODEL_URL="https://huggingface.co/superwhisper/s1-mini-GGUF/resolve/$MODEL_REVISION/s1-mini-q4_k_m.gguf"

if ! command -v ollama >/dev/null 2>&1; then
    printf '%s\n' "Ollama is required. Install it with: brew install ollama" >&2
    exit 1
fi

mkdir -p "$MODEL_DIR"
if [[ ! -f "$GGUF" ]] || ! printf '%s  %s\n' "$MODEL_SHA256" "$GGUF" | shasum -a 256 -c - >/dev/null 2>&1; then
    DOWNLOAD="$(mktemp "$MODEL_DIR/.s1-mini.XXXXXX")"
    trap 'rm -f "${DOWNLOAD:-}"' EXIT INT TERM
    printf '%s\n' "Downloading S1-mini by Superwhisper (Q4_K_M, 462 MiB)..."
    curl --fail --location --proto '=https' --proto-redir '=https' --progress-bar "$MODEL_URL" --output "$DOWNLOAD"
    printf '%s  %s\n' "$MODEL_SHA256" "$DOWNLOAD" | shasum -a 256 -c -
    mv "$DOWNLOAD" "$GGUF"
    trap - EXIT INT TERM
fi

{
    printf 'FROM %s\n\n' "$GGUF"
    cat <<'EOF'
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
} > "$MODELFILE"

printf '%s\n' "Creating the local Ollama model..."
ollama create "$MODEL_NAME" -f "$MODELFILE"
printf '%s\n' "Installed S1-mini by Superwhisper as Ollama model '$MODEL_NAME'."
