#!/bin/bash
#
# Builds Vitals and assembles it into a .app bundle.
#
#   ./Scripts/build.sh            build and install to /Applications
#   ./Scripts/build.sh --no-install    build the bundle only
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Vitals"
BUNDLE_ID="com.ashakur.vitals"
VERSION="1.0"
BUILD_DIR="$ROOT/.build/release"
APP="$ROOT/.build/$APP_NAME.app"
INSTALL_DIR="/Applications"

INSTALL=1
[[ "${1:-}" == "--no-install" ]] && INSTALL=0

echo "==> Building (release, arm64)"
cd "$ROOT"
swift build -c release --arch arm64

echo "==> Assembling $APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"

# LSUIElement is what keeps this out of the Dock and the app switcher. Without
# it the app is a normal windowless application with a permanent Dock tile.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>$APP_NAME</string>
	<key>CFBundleDisplayName</key>
	<string>$APP_NAME</string>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleExecutable</key>
	<string>$APP_NAME</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$VERSION</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST

# Ad-hoc signature. Enough for a locally built app: it never crosses a
# quarantine boundary, so Gatekeeper is not involved, and SMAppService will
# accept it as a login item.
echo "==> Signing (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP" 2>&1 | sed 's/^/    /'

if [[ $INSTALL -eq 1 ]]; then
    echo "==> Installing to $INSTALL_DIR"
    # Stop the running copy first; replacing the binary underneath a live
    # process leaves a status item that is still drawing but backed by a
    # deleted executable.
    pkill -x "$APP_NAME" 2>/dev/null || true
    sleep 0.5
    rm -rf "$INSTALL_DIR/$APP_NAME.app"
    cp -R "$APP" "$INSTALL_DIR/$APP_NAME.app"
    echo "==> Launching"
    open "$INSTALL_DIR/$APP_NAME.app"
    echo "    Installed at $INSTALL_DIR/$APP_NAME.app"
else
    echo "    Bundle at $APP"
fi

echo "==> Done"
