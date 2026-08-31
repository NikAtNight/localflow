#!/bin/bash
# Builds LocalFlow in release mode and packages it as a proper .app bundle
# so macOS TCC permissions (Microphone, Accessibility) attach to LocalFlow
# itself instead of your terminal.
#
# Environment overrides (used by the release workflow; all optional):
#   SIGN_IDENTITY   codesign identity, e.g. "Developer ID Application: ... (TEAMID)".
#                   Defaults to the local self-signed identity.
#   APP_VERSION         version used in archive names and logs.
#   APP_SHORT_VERSION   CFBundleShortVersionString value.
#   APP_BUNDLE_VERSION  CFBundleVersion value.
#   UPDATER_ENABLED     true for a release with a signed Sparkle appcast.
#   SKIP_PREWARM=1  skip the CoreML warm-up (no model cache on CI runners).
set -euo pipefail

cd "$(dirname "$0")/.."

echo "Building (release)..."
swift build -c release

APP="build/LocalFlow.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/LocalFlow "$APP/Contents/MacOS/LocalFlow"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if [[ -n "${APP_SHORT_VERSION:-}" && -n "${APP_BUNDLE_VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_SHORT_VERSION" "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_BUNDLE_VERSION" "$APP/Contents/Info.plist"
    echo "Stamped version ${APP_VERSION:-$APP_SHORT_VERSION} ($APP_BUNDLE_VERSION)"
elif [[ -n "${APP_VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_VERSION" "$APP/Contents/Info.plist"
    echo "Stamped version $APP_VERSION"
fi

UPDATES_ACTIVE="${UPDATER_ENABLED:-true}"
if [[ "$UPDATES_ACTIVE" != "1" && "$UPDATES_ACTIVE" != "true" ]]; then
    /usr/libexec/PlistBuddy -c 'Set :SUEnableAutomaticChecks false' "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Delete :SUFeedURL' "$APP/Contents/Info.plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c 'Delete :SUPublicEDKey' "$APP/Contents/Info.plist" 2>/dev/null || true
    echo "Disabled updates for this development build"
fi

# LaunchAgent (SMAppService.agent): relaunches the app after a crash.
mkdir -p "$APP/Contents/Library/LaunchAgents"
cp Resources/app.talix.localflow.plist "$APP/Contents/Library/LaunchAgents/"

# Sparkle ships as a binary framework. `swift build` links against it but
# does not embed it, so the bundle has to carry its own copy and the binary
# needs an rpath pointing at it. Without this the app dies at launch with a
# dyld "Library not loaded" error.
SPARKLE_FRAMEWORK="$(find .build/artifacts -type d -name 'Sparkle.framework' -path '*macos*' -print -quit || true)"
if [[ -n "$SPARKLE_FRAMEWORK" ]]; then
    mkdir -p "$APP/Contents/Frameworks"
    # ditto preserves the framework's symlink layout and signature xattrs.
    ditto "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"
    # SwiftPM usually emits this rpath already; add it only when missing so a
    # real install_name_tool failure is not swallowed by an "already exists".
    if ! otool -l "$APP/Contents/MacOS/LocalFlow" | grep -q '@executable_path/../Frameworks'; then
        install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/LocalFlow"
    fi
    echo "Embedded Sparkle.framework"
else
    if [[ "$UPDATES_ACTIVE" == "1" || "$UPDATES_ACTIVE" == "true" ]]; then
        echo "error: Sparkle.framework not found; release updates would not launch" >&2
        exit 1
    fi
    echo "warning: Sparkle.framework not found; updates are disabled"
fi

# App icon - rendered on demand; re-run scripts/make-icon.sh to redesign.
if [ ! -f Resources/AppIcon.icns ]; then
    ./scripts/make-icon.sh
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Sign with the stable self-signed identity so TCC grants (Microphone,
# Accessibility) survive rebuilds. Fallback: ad-hoc with an explicit
# identifier-based designated requirement - same effect, but any unsigned
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
        # Nested code signs first, inside out. Sparkle carries an XPC pair,
        # the Autoupdate helper, and Updater.app; each is independently
        # verified at install time, and an unsigned one fails notarization.
        if [[ -d "$APP/Contents/Frameworks/Sparkle.framework" ]]; then
            while IFS= read -r nested; do
                codesign --force --sign "$SIGN_ID" --options runtime --timestamp "$nested"
            done < <(find "$APP/Contents/Frameworks/Sparkle.framework" \
                \( -name '*.xpc' -o -name '*.app' -o -name 'Autoupdate' -o -name 'Updater' \) -print)
            codesign --force --sign "$SIGN_ID" --options runtime --timestamp \
                "$APP/Contents/Frameworks/Sparkle.framework"
        fi
        codesign --force --sign "$SIGN_ID" \
            --identifier app.talix.localflow \
            --options runtime \
            --timestamp \
            --entitlements "$ENTITLEMENTS" \
            "$APP"
        echo "Signed for distribution: $SIGN_ID"
    else
        if [[ -d "$APP/Contents/Frameworks/Sparkle.framework" ]]; then
            codesign --force --sign "$SIGN_ID" --deep "$APP/Contents/Frameworks/Sparkle.framework" 2>/dev/null || true
        fi
        codesign --force --sign "$SIGN_ID" --identifier app.talix.localflow "$APP"
    fi
elif [[ -n "${SIGN_IDENTITY:-}" ]]; then
    # An explicitly requested identity that is missing is a build error:
    # silently shipping an ad-hoc build would fail notarization later.
    echo "error: requested signing identity '$SIGN_ID' not found in the keychain" >&2
    exit 1
else
    echo "warning: '$SIGN_ID' identity not found - ad-hoc signing with pinned requirement"
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

echo "Pre-warming CoreML model cache (can take a few minutes on a new binary)..."
WARM_BASE="$(mktemp -t localflow-warm)"
WARM_AIFF="$WARM_BASE.aiff"
if say -o "$WARM_AIFF" "warm up" 2>/dev/null &&
   "$APP/Contents/MacOS/LocalFlow" --transcribe "$WARM_AIFF" --no-cleanup >/dev/null 2>&1; then
    echo "Model cache warm."
else
    echo "warning: pre-warm skipped/failed - first in-app dictation will be slow"
fi
rm -f "$WARM_AIFF" "$WARM_BASE"

echo
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    echo "Installing to /Applications..."
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
