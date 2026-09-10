#!/bin/bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
python_bin="${PYTHON_BIN:-python3.12}"
if ! command -v "$python_bin" >/dev/null; then
    echo "Python 3.12 is required. Set PYTHON_BIN to an existing Python 3.12 executable." >&2
    exit 1
fi
umask 077
mkdir -p "$repo_dir/build/voice-clone"
chmod 700 "$repo_dir/build/voice-clone"
"$python_bin" - "$repo_dir" <<'PY'
import pathlib
import subprocess
import sys

if sys.version_info[:2] != (3, 12):
    raise SystemExit("Use Python 3.12 for the tested voice trial dependencies.")
root = pathlib.Path(sys.argv[1])
venv = root / "build/voice-clone/.venv"
subprocess.run([sys.executable, "-m", "venv", str(venv)], check=True, timeout=60)
subprocess.run([str(venv / "bin/python"), "-m", "pip", "install", "-r",
                str(root / "scripts/voice-clone-requirements.txt")], check=True, timeout=480)
PY
echo "Ready. Run build/voice-clone/.venv/bin/python scripts/voice-clone-trial.py --help"
