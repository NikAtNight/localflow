#!/bin/bash
# Builds LocalFlow in release mode and packages it as a proper .app bundle
# so macOS TCC permissions (Microphone, Accessibility) attach to LocalFlow
# itself instead of your terminal.
set -euo pipefail

cd "$(dirname "$0")/.."

echo "Building (release)…"
swift build -c release

APP="build/LocalFlow.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/LocalFlow "$APP/Contents/MacOS/LocalFlow"
cp Resources/Info.plist "$APP/Contents/Info.plist"

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
SIGN_ID="Talix Dev Signing"
if security find-identity -v -p codesigning | grep -q "$SIGN_ID"; then
    codesign --force --sign "$SIGN_ID" --identifier app.talix.localflow "$APP"
else
    echo "warning: '$SIGN_ID' identity not found — ad-hoc signing with pinned requirement"
    codesign --force --sign - \
        --identifier app.talix.localflow \
        -r='designated => identifier "app.talix.localflow"' \
        "$APP"
fi

echo
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    echo "Installing to /Applications…"
    pkill -f 'LocalFlow.app/Contents/MacOS/LocalFlow' 2>/dev/null || true
    sleep 1
    rm -rf /Applications/LocalFlow.app
    cp -R "$APP" /Applications/
    open /Applications/LocalFlow.app
    echo "Installed and relaunched /Applications/LocalFlow.app"
else
    echo "Install + relaunch: ./scripts/make-app.sh --install"
    echo "On first launch, grant Microphone and Accessibility when prompted."
fi
