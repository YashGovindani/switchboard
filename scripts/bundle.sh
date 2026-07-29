#!/bin/zsh
# Builds Switchboard.app from the SwiftPM SwitchboardApp executable
# and (with --install) copies it to /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP=build/Switchboard.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/SwitchboardApp "$APP/Contents/MacOS/Switchboard"

if [[ ! -f Resources/AppIcon.icns ]]; then
    ./scripts/make-icon.sh
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>Switchboard</string>
    <key>CFBundleDisplayName</key>       <string>Switchboard</string>
    <key>CFBundleIdentifier</key>        <string>com.yashgovindani.switchboard</string>
    <key>CFBundleVersion</key>           <string>0.2.0</string>
    <key>CFBundleShortVersionString</key><string>0.2.0</string>
    <key>CFBundleExecutable</key>        <string>Switchboard</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>LSMinimumSystemVersion</key>    <string>13.0</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>LSUIElement</key>               <true/>
    <key>NSHighResolutionCapable</key>   <true/>
</dict>
</plist>
PLIST

# Prefer the stable "Switchboard Signing" identity (created by
# scripts/setup-signing.sh) so macOS privacy grants survive rebuilds;
# fall back to ad-hoc when it doesn't exist.
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Switchboard Signing"; then
    codesign --force --sign "Switchboard Signing" "$APP"
else
    codesign --force --sign - "$APP"
fi

echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    # Quit a running instance before replacing it.
    pkill -x Switchboard 2>/dev/null || true
    rm -rf /Applications/Switchboard.app
    cp -R "$APP" /Applications/Switchboard.app
    echo "Installed to /Applications/Switchboard.app"
fi
