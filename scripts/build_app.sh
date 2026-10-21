#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/AgentQuotaBar.app"

echo "==> swift build -c release"
swift build -c release --package-path "$ROOT"

echo "==> assemble $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/AgentQuotaBar" "$APP/Contents/MacOS/AgentQuotaBar"
cp "$ROOT/collector/collector.js" "$ROOT/collector/trae-crypto.js" "$APP/Contents/Resources/"
cp "$ROOT/Resources/checkin-background.sh" "$APP/Contents/Resources/"
chmod +x "$APP/Contents/Resources/checkin-background.sh"
cp "$ROOT/Resources/"*.svg "$ROOT/Resources/"*.png "$APP/Contents/Resources/" 2>/dev/null || true
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>AgentQuotaBar</string>
    <key>CFBundleIdentifier</key>
    <string>com.tommin.agentquotabar</string>
    <key>CFBundleName</key>
    <string>AgentQuotaBar</string>
    <key>CFBundleDisplayName</key>
    <string>Agent 额度</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleShortVersionString</key>
    <string>0.4.0</string>
    <key>CFBundleVersion</key>
    <string>4</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

plutil -lint "$APP/Contents/Info.plist" >/dev/null
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
echo "==> done: $APP"
