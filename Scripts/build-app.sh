#!/bin/bash
#
# Builds PenBridge.app from the Swift package.
#
# The app bundle is not cosmetic: macOS hangs privacy grants off a bundle identity,
# so Input Monitoring and Accessibility can only be granted to a real .app, and the
# grant survives rebuilds only if the code signature stays stable.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
APP="${1:-$ROOT/build/PenBridge.app}"
VERSION="$(git -C "$ROOT" describe --tags --always 2>/dev/null || echo "0.1.0")"

echo "==> Building ($CONFIGURATION)"
swift build --package-path "$ROOT" -c "$CONFIGURATION" --product PenBridgeApp
swift build --package-path "$ROOT" -c "$CONFIGURATION" --product penbridge

BIN="$(swift build --package-path "$ROOT" -c "$CONFIGURATION" --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN/PenBridgeApp" "$APP/Contents/MacOS/PenBridge"
# Ship the diagnostics tool inside the bundle so it runs under the same code identity
# as the app, and therefore under the same privacy grants.
#
# The "-cli" suffix is load-bearing: macOS volumes are case-insensitive by default, so
# a file named "penbridge" would be the same name as "PenBridge" and would silently
# overwrite the app binary, leaving a bundle that launches the wrong program.
cp "$BIN/penbridge" "$APP/Contents/MacOS/penbridge-cli"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>PenBridge</string>
    <key>CFBundleDisplayName</key>       <string>PenBridge</string>
    <key>CFBundleIdentifier</key>        <string>io.github.penbridge.PenBridge</string>
    <key>CFBundleExecutable</key>        <string>PenBridge</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key>           <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>    <string>13.0</string>
    <!-- Background app: status-bar item only, no Dock icon and no menu bar. -->
    <key>LSUIElement</key>               <true/>
    <key>NSHumanReadableCopyright</key>  <string>MIT licensed</string>
</dict>
</plist>
PLIST

echo "==> Signing (ad-hoc)"
# An ad-hoc signature is enough for privacy grants to stick to this bundle on the
# machine that built it. It is not a Developer ID signature, so a copy handed to
# someone else still trips Gatekeeper — see README.
codesign --force --deep --sign - --options runtime "$APP"

echo "==> Verifying"
# Guard against the case-collision failure above, and against shipping a binary that
# would not run natively — the whole reason this project exists.
for tool in PenBridge penbridge-cli; do
    path="$APP/Contents/MacOS/$tool"
    [ -x "$path" ] || { echo "missing $tool in bundle" >&2; exit 1; }
    arch="$(lipo -archs "$path")"
    [ "$arch" = "arm64" ] || { echo "$tool built for '$arch', expected arm64" >&2; exit 1; }
done
# The app must be the AppKit binary, not the CLI.
otool -L "$APP/Contents/MacOS/PenBridge" | grep -q AppKit \
    || { echo "PenBridge does not link AppKit — wrong binary in bundle" >&2; exit 1; }
codesign --verify --strict "$APP"

echo
echo "Built $APP  (arm64, ad-hoc signed)"
echo
echo "Next:"
echo "  open $APP"
echo "  Grant Input Monitoring and Accessibility when prompted, then relaunch."
echo
echo "Diagnostics:"
echo "  $APP/Contents/MacOS/penbridge-cli info"
echo "  $APP/Contents/MacOS/penbridge-cli calibrate"
