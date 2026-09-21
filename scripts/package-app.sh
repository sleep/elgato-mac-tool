#!/usr/bin/env bash
# Builds "Elgato Capture.app" (the SwiftUI GUI) and wraps it in a drag-to-Applications DMG.
#
#   scripts/package-app.sh [version]
#
# Output: dist/Elgato Capture.app and dist/ElgatoCapture-<version>.dmg
# Signing: ad-hoc only (no developer identity).
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

VERSION="${1:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')}"
VERSION="${VERSION:-0.0.0}"
BUILD_NUMBER="$(git rev-list --count HEAD)"
APP_NAME="Elgato Capture"
BUNDLE_ID="com.benstc.elgato-capture"
EXECUTABLE="elgato-capture-gui"
RESOURCE_BUNDLE="ElgatoCapture_elgato-capture-gui.bundle"

DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
DMG="$DIST/ElgatoCapture-$VERSION.dmg"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Building $APP_NAME $VERSION ($BUILD_NUMBER), universal release"
swift build -c release --product "$EXECUTABLE" --arch arm64 --arch x86_64
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

echo "==> Assembling app bundle"
rm -rf "$APP" "$DMG"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$EXECUTABLE" "$APP/Contents/MacOS/$EXECUTABLE"
# Contents/Resources, not the bundle root: RemoteController looks here first.
cp -R "$BIN_DIR/$RESOURCE_BUNDLE" "$APP/Contents/Resources/"

echo "==> Rendering icon"
# Top-level code is only allowed in a file named main.swift in multi-file builds.
cp scripts/export-icon.swift "$WORK/main.swift"
swiftc -O -o "$WORK/export-icon" \
    Sources/ElgatoCaptureGUI/AppIconRenderer.swift "$WORK/main.swift"
"$WORK/export-icon" "$WORK/icon-1024.png"
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z $size $size "$WORK/icon-1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z $double $double "$WORK/icon-1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "==> Writing Info.plist"
PLIST="$APP/Contents/Info.plist"
# Start from the source plist so the usage descriptions stay in one place.
cp Sources/ElgatoCaptureGUI/Info.plist "$PLIST"
pb() { /usr/libexec/PlistBuddy -c "$1" "$PLIST"; }
pb "Add :CFBundleName string $APP_NAME"
pb "Add :CFBundleDisplayName string $APP_NAME"
pb "Add :CFBundleIdentifier string $BUNDLE_ID"
pb "Add :CFBundleExecutable string $EXECUTABLE"
pb "Add :CFBundleIconFile string AppIcon"
pb "Add :CFBundlePackageType string APPL"
pb "Add :CFBundleShortVersionString string $VERSION"
pb "Add :CFBundleVersion string $BUILD_NUMBER"
pb "Add :CFBundleInfoDictionaryVersion string 6.0"
pb "Add :LSMinimumSystemVersion string 13.0"
pb "Add :LSApplicationCategoryType string public.app-category.video"
pb "Add :NSHighResolutionCapable bool true"
pb "Add :NSPrincipalClass string NSApplication"
plutil -lint "$PLIST" >/dev/null

echo "==> Ad-hoc signing"
# No identity: Apple Silicon refuses to run completely unsigned code, and an
# ad-hoc seal over the whole bundle keeps Gatekeeper from calling it "damaged".
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

echo "==> Creating DMG"
STAGE="$WORK/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" \
    -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null

echo "==> Done"
echo "    $APP"
echo "    $DMG ($(du -h "$DMG" | cut -f1))"
