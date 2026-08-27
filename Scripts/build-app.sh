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

SIGNING_IDENTITY="${SIGNING_IDENTITY:-PenBridge Local Signing}"
# No -v: a self-signed identity is reported untrusted, but signs fine.
if security find-identity -p codesigning 2>/dev/null | grep -qF "$SIGNING_IDENTITY"; then
    echo "==> Signing as '$SIGNING_IDENTITY'"
    codesign --force --deep --sign "$SIGNING_IDENTITY" --options runtime "$APP"
else
    echo "==> Signing (ad-hoc)"
    codesign --force --deep --sign - --options runtime "$APP"
    cat <<'WARNING'

    Note: this build is ad-hoc signed, so macOS identifies it by the hash of its
    contents. That hash changes every time you rebuild, and Input Monitoring and
    Accessibility are granted against it — so you will be asked to grant them again
    after every build.

    Run Scripts/make-signing-cert.sh once to stop that happening.

WARNING
fi

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

SIGNED_BY="$(codesign -dvv "$APP" 2>&1 | grep -E '^Authority=|^Signature=' | head -1 | cut -d= -f2)"
echo
echo "Built $APP  (arm64, signed as: $SIGNED_BY)"

# LaunchServices refuses to start an app from a volume mounted nosuid — which most
# external drives are — and reports it as a launch timeout (-1712) rather than as a
# permissions problem. Running the app from a checkout on an external disk therefore
# looks like the app is broken. Install it somewhere it can actually run.
INSTALL_DIR="$HOME/Applications"
INSTALLED="$INSTALL_DIR/PenBridge.app"
if [ "${NO_INSTALL:-0}" != "1" ]; then
    mkdir -p "$INSTALL_DIR"
    # Replace only our own previous install, never a path given from outside.
    if [ -d "$INSTALLED" ]; then
        rm -rf "$INSTALLED"
    fi
    cp -R "$APP" "$INSTALLED"
    echo "Installed to $INSTALLED"
fi

echo
echo "Next:"
echo "  open \"$INSTALLED\""
echo "  Grant Input Monitoring and Accessibility when prompted, then relaunch."
echo
echo "Diagnostics:"
echo "  \"$INSTALLED/Contents/MacOS/penbridge-cli\" info"
echo "  \"$INSTALLED/Contents/MacOS/penbridge-cli\" calibrate"
