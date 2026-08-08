#!/bin/bash
# Builds LocalFlow in release mode and packages it as a proper .app bundle
# so macOS TCC permissions (Microphone, Accessibility) attach to LocalFlow
# itself instead of your terminal.
#
# Environment overrides (used by the release workflow; all optional):
#   SIGN_IDENTITY   codesign identity, e.g. "Developer ID Application: … (TEAMID)".
#                   Defaults to the local self-signed identity.
#   APP_VERSION     stamped into CFBundleShortVersionString / CFBundleVersion.
#   SKIP_PREWARM=1  skip the CoreML warm-up (no model cache on CI runners).
set -euo pipefail

cd "$(dirname "$0")/.."

echo "Building (release)…"
swift build -c release

APP="build/LocalFlow.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/LocalFlow "$APP/Contents/MacOS/LocalFlow"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if [[ -n "${APP_VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_VERSION" "$APP/Contents/Info.plist"
    echo "Stamped version $APP_VERSION"
fi

# LaunchAgent (SMAppService.agent): relaunches the app after a crash.
mkdir -p "$APP/Contents/Library/LaunchAgents"
cp Resources/app.talix.localflow.plist "$APP/Contents/Library/LaunchAgents/"

# App icon — rendered on demand; re-run scripts/make-icon.sh to redesign.
if [ ! -f Resources/AppIcon.icns ]; then
    ./scripts/make-icon.sh
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Sign with the stable self-signed identity so TCC grants (Microphone,
# Accessibility) survive rebuilds. Fallback: ad-hoc with an explicit
# identifier-based designated requirement — same effect, but any unsigned
# binary claiming the identifier could inherit the grants.
SIGN_ID="${SIGN_IDENTITY:-Talix Dev Signing}"
ENTITLEMENTS="Resources/LocalFlow.entitlements"
# Capture instead of piping into grep -q: with pipefail, grep exiting early
# can SIGPIPE `security` and fail the build even when the identity exists.
IDENTITIES="$(security find-identity -v -p codesigning || true)"
if [[ "$IDENTITIES" == *"$SIGN_ID"* ]]; then
    # Distribution builds need the hardened runtime (a notarization
    # requirement); the local self-signed identity does not, and enabling it
    # there would only add a way for dev builds to differ from shipped ones.
    if [[ "$SIGN_ID" == "Developer ID Application"* ]]; then
        codesign --force --sign "$SIGN_ID" \
            --identifier app.talix.localflow \
            --options runtime \
            --timestamp \
            --entitlements "$ENTITLEMENTS" \
            "$APP"
        echo "Signed for distribution: $SIGN_ID"
    else
        codesign --force --sign "$SIGN_ID" --identifier app.talix.localflow "$APP"
    fi
elif [[ -n "${SIGN_IDENTITY:-}" ]]; then
    # An explicitly requested identity that is missing is a build error:
    # silently shipping an ad-hoc build would fail notarization later.
    echo "error: requested signing identity '$SIGN_ID' not found in the keychain" >&2
    exit 1
else
    echo "warning: '$SIGN_ID' identity not found — ad-hoc signing with pinned requirement"
    codesign --force --sign - \
        --identifier app.talix.localflow \
        -r='designated => identifier "app.talix.localflow"' \
        "$APP"
fi

# CoreML specializes the Whisper model once per binary (takes minutes, and
# the hotkey is dead until it finishes). Pay that cost here, against the
# signed binary, so the installed app's first dictation is instant. Skipped
# gracefully if the model isn't downloaded yet (true first install).
if [[ "${SKIP_PREWARM:-0}" == "1" ]]; then
    echo "Skipping CoreML pre-warm (SKIP_PREWARM=1)."
    echo
    echo "Built $APP"
    exit 0
fi

echo "Pre-warming CoreML model cache (can take a few minutes on a new binary)…"
WARM_BASE="$(mktemp -t localflow-warm)"
WARM_AIFF="$WARM_BASE.aiff"
if say -o "$WARM_AIFF" "warm up" 2>/dev/null &&
   "$APP/Contents/MacOS/LocalFlow" --transcribe "$WARM_AIFF" --no-cleanup >/dev/null 2>&1; then
    echo "Model cache warm."
else
    echo "warning: pre-warm skipped/failed — first in-app dictation will be slow"
fi
rm -f "$WARM_AIFF" "$WARM_BASE"

echo
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    echo "Installing to /Applications…"
    # Stop through launchd, not pkill: a SIGTERM'd agent counts as an
    # unsuccessful exit, so KeepAlive would relaunch the OLD binary during
    # the sleep below and the fresh copy would exit at its already-running
    # guard. bootout both stops the process and stops supervision.
    launchctl bootout "gui/$(id -u)/app.talix.localflow" 2>/dev/null || true
    # Belt for instances launched outside the agent (Finder, `open`, dev runs).
    pkill -f '/Applications/LocalFlow.app/Contents/MacOS/LocalFlow' 2>/dev/null || true
    # Verify the old instance is actually gone before swapping the bundle:
    # if bootout failed (label variants, transient launchctl errors),
    # KeepAlive can respawn it and the copy would race a running process.
    for _ in 1 2 3 4 5; do
        pgrep -f '/Applications/LocalFlow.app/Contents/MacOS/LocalFlow' >/dev/null || break
        sleep 1
    done
    pkill -9 -f '/Applications/LocalFlow.app/Contents/MacOS/LocalFlow' 2>/dev/null || true
    rm -rf /Applications/LocalFlow.app
    cp -R "$APP" /Applications/
    open /Applications/LocalFlow.app
    echo "Installed and relaunched /Applications/LocalFlow.app"
else
    echo "Install + relaunch: ./scripts/make-app.sh --install"
    echo "On first launch, grant Microphone and Accessibility when prompted."
fi
