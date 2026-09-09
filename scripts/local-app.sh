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
