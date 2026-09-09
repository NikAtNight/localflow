#!/bin/bash
# Build/install the local test app, or switch between installed channels.
set -euo pipefail
cd "$(dirname "$0")/.."

ACTION="${1:-install}"
case "$ACTION" in
    install|local|production) ;;
    *) echo "Usage: $0 [install|local|production]" >&2; exit 2 ;;
esac

LOCAL_APP="/Applications/LocalFlow Local.app"
PRODUCTION_APP="/Applications/LocalFlow.app"
if [[ "$ACTION" == "install" ]]; then
    VERSION="$(python3 -c 'import json; print(json.load(open(".github/.release-please-manifest.json"))["."])')"
    LOCAL_BUILD=1 UPDATER_ENABLED=false SKIP_PREWARM=1 APP_VERSION="$VERSION" ./scripts/make-app.sh
    codesign --verify --deep --strict "build/LocalFlow Local.app"
fi

if [[ "$ACTION" == "production" ]]; then
    TARGET_APP="$PRODUCTION_APP"
else
    TARGET_APP="$LOCAL_APP"
fi
if [[ "$ACTION" != "install" && ! -d "$TARGET_APP" ]]; then
    echo "error: $TARGET_APP is not installed" >&2
    exit 1
fi

# Older installed builds lack the app's quit guard. Check their current
# session after building, immediately before requesting termination.
python3 - <<'PY_CHECK_IDLE'
import json
from pathlib import Path
import subprocess

for name, log_name in (("LocalFlow", "LocalFlow-diag.log"), ("LocalFlow Local", "LocalFlow-Local-diag.log")):
    running = subprocess.run(["pgrep", "-f", rf"^/Applications/{name}\.app/Contents/MacOS/LocalFlow$"], capture_output=True, text=True)
    if running.returncode != 0:
        continue
    pid = running.stdout.strip()
    lines = (Path.home() / "Library/Logs" / log_name).read_text().splitlines()
    starts = [i for i, line in enumerate(lines) if f"session start (pid {pid})" in line]
    if not starts:
        raise SystemExit(f"error: cannot verify {name} is idle; finish dictating and quit it before switching")
    traces = {}
    for line in lines[starts[-1]:]:
        if " timing " not in line:
            continue
        event = json.loads(line.split(" timing ", 1)[1])
        if event.get("source") == "dictation":
            traces.setdefault(event["traceID"], []).append(event)
    for events in traces.values():
        names = {event["name"] for event in events}
        resolved = bool(names & {"cancellationRequested", "injectionSkipped", "clipboardWindowResolved", "typingDispatched"})
        resolved |= any(event["name"] == "resultReady" and event.get("status") in ("empty", "failed", "insufficientVoice", "cancelled") for event in events)
        resolved |= any(event["name"] == "pasteDispatched" and event.get("status") == "failed" for event in events)
        if "hotkeyPressed" in names and not resolved:
            raise SystemExit(f"error: {name} has an active dictation; finish it and retry switching")
PY_CHECK_IDLE

# Clean termination keeps the production KeepAlive agent from restarting.
# Never force-quit a recording or overwrite an app that is still running.
for APP_NAME in LocalFlow "LocalFlow Local"; do
    BUNDLE_ID="app.talix.localflow"
    if [[ "$APP_NAME" == "LocalFlow Local" ]]; then
        BUNDLE_ID="app.talix.localflow.local"
    fi
    if pgrep -f "^/Applications/$APP_NAME\\.app/Contents/MacOS/LocalFlow$" >/dev/null; then
        osascript -e "tell application id \"$BUNDLE_ID\" to quit"
    fi
done
for _ in 1 2 3 4 5; do
    if ! pgrep -f '^/Applications/LocalFlow( Local)?\.app/Contents/MacOS/LocalFlow$' >/dev/null; then
        break
    fi
    sleep 1
done
if pgrep -f '^/Applications/LocalFlow( Local)?\.app/Contents/MacOS/LocalFlow$' >/dev/null; then
    echo "error: LocalFlow is still running; finish dictating and quit it before switching" >&2
    exit 1
fi

if [[ "$ACTION" == "install" ]]; then
    # Seed preferences once. Later installs preserve local settings; history
    # stays separate. Do not print vocabulary, corrections, or other values.
    python3 - <<'PY'
import plistlib
import subprocess
import tempfile

local_id = 'app.talix.localflow.local'
existing = subprocess.run(['/usr/bin/defaults', 'export', local_id, '-'], capture_output=True)
if existing.returncode != 0 or not plistlib.loads(existing.stdout):
    production = subprocess.run(['/usr/bin/defaults', 'export', 'app.talix.localflow', '-'], capture_output=True)
    settings = plistlib.loads(production.stdout) if production.returncode == 0 else {}
    settings = {k: v for k, v in settings.items() if not k.startswith('SU') and k not in ('loginItemSetupDone', 'diagLogPrivacyVersion')}
    settings['automaticUpdates'] = False
    with tempfile.NamedTemporaryFile(suffix='.plist') as f:
        plistlib.dump(settings, f)
        f.flush()
        subprocess.run(['/usr/bin/defaults', 'import', local_id, f.name], check=True, stdout=subprocess.DEVNULL)
PY
    # Stage on the same volume. Preserve the previous local app for recovery.
    STAGING="$(mktemp -d /Applications/.localflow-local.XXXXXX)"
    ditto "build/LocalFlow Local.app" "$STAGING/LocalFlow Local.app"
    codesign --verify --deep --strict "$STAGING/LocalFlow Local.app"
    if [[ -e "$LOCAL_APP" ]]; then
        mv "$LOCAL_APP" "$STAGING/Previous LocalFlow Local.app"
        echo "Previous local build saved in $STAGING"
    fi
    mv "$STAGING/LocalFlow Local.app" "$LOCAL_APP"
    rmdir "$STAGING" 2>/dev/null || true
fi

if [[ "$ACTION" == "install" ]]; then
    python3 scripts/wait-for-local-ready.py
else
    open "$TARGET_APP"
    echo "Opened $TARGET_APP"
fi
echo "Local diagnostics: ~/Library/Logs/LocalFlow-Local-diag.log"
