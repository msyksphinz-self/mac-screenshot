#!/bin/bash
# Build QuickMark.app (menu bar app) into ./build
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="build/QuickMark.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/QuickMark" "$APP/Contents/MacOS/QuickMark"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>QuickMark</string>
    <key>CFBundleDisplayName</key><string>QuickMark</string>
    <key>CFBundleIdentifier</key><string>local.quickmark.QuickMark</string>
    <key>CFBundleExecutable</key><string>QuickMark</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature so macOS can remember the Screen Recording permission.
codesign --force --sign - "$APP"

echo "Built $APP"
echo "Install:  cp -R $APP /Applications/"
