#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APPS_DIR="/Applications"
TARGET="$APPS_DIR/AgentQuotaBar.app"
APP_ID="com.tommin.agentquotabar"

fail() {
  echo "error: $*" >&2
  exit 1
}

info() {
  echo "==> $*"
}

[ -d "$APPS_DIR" ] || fail "$APPS_DIR not found"
[ -w "$APPS_DIR" ] || fail "no write permission for $APPS_DIR (run as a user who can install apps; this script intentionally does not use sudo)"

info "build"
"$ROOT/scripts/build_app.sh"

SOURCE="$ROOT/dist/AgentQuotaBar.app"
[ -d "$SOURCE" ] || fail "build output missing: $SOURCE"

# 校验一个候选 App：plist、bundle id、资源齐全、签名有效。
verify_app() {
  local app="$1" plist id
  plist="$app/Contents/Info.plist"
  [ -d "$app" ] || return 1
  plutil -lint "$plist" >/dev/null 2>&1 || { echo "  invalid Info.plist" >&2; return 1; }
  [ -x "$app/Contents/MacOS/AgentQuotaBar" ] || { echo "  missing executable" >&2; return 1; }
  id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null || true)"
  [ "$id" = "$APP_ID" ] || { echo "  unexpected CFBundleIdentifier: ${id:-<empty>}" >&2; return 1; }
  [ -f "$app/Contents/Resources/collector.js" ] || { echo "  missing collector.js" >&2; return 1; }
  [ -f "$app/Contents/Resources/workbuddy-key/main.js" ] || { echo "  missing workbuddy-key/main.js" >&2; return 1; }
  [ -x "$app/Contents/Resources/checkin-background.sh" ] || { echo "  checkin-background.sh not executable" >&2; return 1; }
  codesign --verify --strict "$app" >/dev/null 2>&1 || { echo "  code signature invalid" >&2; return 1; }
  return 0
}

info "verify built bundle"
verify_app "$SOURCE" || fail "build output failed verification; existing app left untouched"

STAGE_ROOT="$(mktemp -d "$APPS_DIR/.agentquotabar-install.XXXXXX")" \
  || fail "cannot create staging directory in $APPS_DIR"
STAGE_APP="$STAGE_ROOT/AgentQuotaBar.app"
BACKUP=""
TARGET_WRITTEN=0
INSTALLED=0

cleanup() {
  # 只有“还没装好”时才回滚；装好之后绝不动现有 App
  if [ "$INSTALLED" -ne 1 ]; then
    if [ "$TARGET_WRITTEN" -eq 1 ]; then
      rm -rf "$TARGET" 2>/dev/null || true
    fi
    if [ -n "$BACKUP" ] && [ -d "$BACKUP" ]; then
      mv "$BACKUP" "$TARGET" 2>/dev/null || true
    fi
  fi
  rm -rf "$STAGE_ROOT" 2>/dev/null || true
}
trap cleanup EXIT

info "stage copy"
ditto "$SOURCE" "$STAGE_APP" || fail "failed to copy build output to staging area"
verify_app "$STAGE_APP" || fail "staged copy failed verification; existing app left untouched"

# 复制并校验成功之后才停掉正在运行的实例（旧 App 从未在未验证时被删除）
for pattern in "$TARGET/Contents/MacOS/AgentQuotaBar" \
               "$ROOT/dist/AgentQuotaBar.app/Contents/MacOS/AgentQuotaBar"; do
  if pgrep -f "$pattern" >/dev/null 2>&1; then
    info "quit running instance: $pattern"
    pkill -f "$pattern" >/dev/null 2>&1 || true
    for _ in {1..20}; do
      pgrep -f "$pattern" >/dev/null 2>&1 || break
      sleep 0.2
    done
  fi
done

if [ -d "$TARGET" ]; then
  BACKUP="$APPS_DIR/.AgentQuotaBar.app.backup.$$"
  info "backup existing app -> $(basename "$BACKUP")"
  mv "$TARGET" "$BACKUP" || fail "cannot move existing app aside; nothing was replaced"
fi

if ! mv "$STAGE_APP" "$TARGET"; then
  fail "install failed; restoring previous app"
fi
TARGET_WRITTEN=1

# 本机构建没有下载隔离属性；万一继承到 quarantine，也只清理刚装好的这一份
if xattr -p com.apple.quarantine "$TARGET" >/dev/null 2>&1; then
  info "clear quarantine on locally built app"
  xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true
fi

# 装好后、删备份前再验一次：这一步失败仍会回滚到旧 App
info "verify installed app"
verify_app "$TARGET" || fail "installed app failed verification; rolling back"
INSTALLED=1

if [ -n "$BACKUP" ]; then
  rm -rf "$BACKUP" || true
  BACKUP=""
fi

NODE_FOUND=0
if command -v node >/dev/null 2>&1; then NODE_FOUND=1; fi
for candidate in "$HOME/.nvm/current/bin/node" "$HOME"/.nvm/versions/node/*/bin/node "$HOME/.volta/bin/node" "$HOME/.asdf/shims/node" "$HOME/.local/bin/node" /opt/local/bin/node /opt/homebrew/bin/node /usr/local/bin/node; do
  if [ -x "$candidate" ]; then NODE_FOUND=1; break; fi
done
if [ "$NODE_FOUND" -eq 0 ]; then
  echo "warning: 未找到 Node.js。App 需要 node 才能读取额度（brew install node）。" >&2
fi

info "launch"
if ! open "$TARGET"; then
  echo "warning: installed to $TARGET, but launch failed. Open it manually." >&2
fi

echo "==> done. 后台签到 / 用量采样 LaunchAgent 会在 App 首次启动时自动安装。"
echo "    卸载：$ROOT/scripts/uninstall.sh [--app] [--purge] [--all] [--dry-run]"
