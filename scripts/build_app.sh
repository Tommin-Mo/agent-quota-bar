#!/bin/bash
set -euo pipefail

# ── 版本号唯一来源 ───────────────────────────────────────────────
# Info.plist 的 CFBundleShortVersionString / CFBundleVersion 由这两个变量生成。
# 注意：设置窗口左上角的 "v0.4" 仍是 Swift 源码里的静态文案
# （SettingsWindowController.swift），不归本脚本管，发版时需同步。
VERSION="0.4.0"
BUILD="4"

BUNDLE_ID="com.tommin.agentquotabar"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/AgentQuotaBar.app"
RES_SRC="$ROOT/Resources"

fail() {
  echo "error: $*" >&2
  exit 1
}

echo "==> swift build -c release"
swift build -c release --package-path "$ROOT"

BIN="$ROOT/.build/release/AgentQuotaBar"
[ -x "$BIN" ] || fail "release binary not found: $BIN"

# 先装到同卷临时目录，全部校验通过后再替换 dist，避免留下半成品。
STAGE_ROOT="$DIST/.staging.$$"
STAGE="$STAGE_ROOT/AgentQuotaBar.app"
cleanup() { rm -rf "$STAGE_ROOT"; }
trap cleanup EXIT

echo "==> assemble ${APP#"$ROOT"/} (version $VERSION, build $BUILD)"
rm -rf "$STAGE_ROOT"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"

cp "$BIN" "$STAGE/Contents/MacOS/AgentQuotaBar"
chmod +x "$STAGE/Contents/MacOS/AgentQuotaBar"

# collector 运行时用 __dirname 找 workbuddy-key，必须整个目录进 Resources
cp "$ROOT/collector/collector.js" "$ROOT/collector/trae-crypto.js" "$STAGE/Contents/Resources/"
[ -d "$ROOT/collector/workbuddy-key" ] || fail "missing collector/workbuddy-key (WorkBuddy key helper)"
cp -R "$ROOT/collector/workbuddy-key" "$STAGE/Contents/Resources/workbuddy-key"
for file in main.js package.json; do
  [ -f "$STAGE/Contents/Resources/workbuddy-key/$file" ] \
    || fail "workbuddy-key/$file missing from bundled Resources"
done

cp "$RES_SRC/checkin-background.sh" "$STAGE/Contents/Resources/"
chmod +x "$STAGE/Contents/Resources/checkin-background.sh"
cp "$RES_SRC/AppIcon.icns" "$STAGE/Contents/Resources/"

# logo 资源必须显式校验，不能用 `|| true` 把 glob 失败吞掉
shopt -s nullglob
logos=("$RES_SRC"/*.svg "$RES_SRC"/*.png)
shopt -u nullglob
[ "${#logos[@]}" -gt 0 ] || fail "no logo assets (*.svg/*.png) found in Resources/"
cp "${logos[@]}" "$STAGE/Contents/Resources/"

cat > "$STAGE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>AgentQuotaBar</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>AgentQuotaBar</string>
    <key>CFBundleDisplayName</key>
    <string>Agent 额度</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo "==> plutil -lint"
plutil -lint "$STAGE/Contents/Info.plist" >/dev/null \
  || fail "Info.plist failed plutil lint"

# 只有 App 主可执行文件是 Mach-O，Resources 里是 JS/脚本/图片，不需要 --deep。
# 签名失败必须让构建失败，不能 `|| true` 吞掉。
echo "==> codesign (ad-hoc)"
codesign --force --sign - "$STAGE"
codesign --verify --strict --verbose=2 "$STAGE" \
  || fail "codesign verification failed after signing"

rm -rf "$APP"
mv "$STAGE" "$APP"

# 移动后再校验一次，确认最终产物和签名的完全一致
codesign --verify --strict "$APP" >/dev/null 2>&1 \
  || fail "installed bundle failed signature verification: $APP"
[ -f "$APP/Contents/Resources/workbuddy-key/main.js" ] \
  || fail "workbuddy-key missing from final bundle: $APP"

echo "==> done: $APP"
