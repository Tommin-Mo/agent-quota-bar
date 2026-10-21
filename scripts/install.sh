#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="/Applications/AgentQuotaBar.app"

"$ROOT/scripts/build_app.sh"

pkill -f "$TARGET/Contents/MacOS/AgentQuotaBar" 2>/dev/null || true
pkill -f "$ROOT/dist/AgentQuotaBar.app/Contents/MacOS/AgentQuotaBar" 2>/dev/null || true
sleep 1

echo "==> install to $TARGET"
rm -rf "$TARGET"
cp -R "$ROOT/dist/AgentQuotaBar.app" "$TARGET"

echo "==> launch"
open "$TARGET"
echo "==> done. 开机自启动可在 App 设置里打开。"
