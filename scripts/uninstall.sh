#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="/Applications/AgentQuotaBar.app"
SUPPORT="$HOME/.config/agent-quota"
LABELS=("com.agentquota.checkin" "com.agentquota.usage")

REMOVE_APP=0
PURGE=0
DRY_RUN=0

usage() {
  cat <<'EOF'
用法: scripts/uninstall.sh [选项]

  （无选项）   注销并删除 com.agentquota.checkin / com.agentquota.usage 两个 LaunchAgent，保留 App 与配置
  --app        同时删除 /Applications/AgentQuotaBar.app（会先停止运行中的实例）
  --purge      同时删除 ~/.config/agent-quota（配置、用量、日志、WorkBuddy 密钥缓存）
  --all        --app + --purge
  --dry-run    只打印将执行的动作，不修改任何东西
  -h, --help   显示本帮助

注意：开机自启动使用 SMAppService 登录项，与 LaunchAgent 无关；
      卸载前可在 App 设置 → 通用里关闭“开机自启动”。
EOF
}

for arg in "$@"; do
  case "$arg" in
    --app) REMOVE_APP=1 ;;
    --purge) PURGE=1 ;;
    --all) REMOVE_APP=1; PURGE=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown option: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

info() {
  echo "==> $*"
}

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '    would run:'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

UID_NUM="$(id -u)"

info "remove LaunchAgents"
for label in "${LABELS[@]}"; do
  plist="$HOME/Library/LaunchAgents/$label.plist"
  if launchctl print "gui/$UID_NUM/$label" >/dev/null 2>&1; then
    run launchctl bootout "gui/$UID_NUM/$label" \
      || echo "warning: launchctl bootout $label failed（可能已停止）" >&2
  fi
  if [ -e "$plist" ]; then
    run rm -f "$plist"
  fi
done

if [ "$REMOVE_APP" -eq 1 ]; then
  if pgrep -f "$TARGET/Contents/MacOS/AgentQuotaBar" >/dev/null 2>&1; then
    info "quit running AgentQuotaBar"
    if [ "$DRY_RUN" -eq 1 ]; then
      echo "    would run: pkill -f $TARGET/Contents/MacOS/AgentQuotaBar"
    else
      pkill -f "$TARGET/Contents/MacOS/AgentQuotaBar" >/dev/null 2>&1 || true
      for _ in {1..20}; do
        pgrep -f "$TARGET/Contents/MacOS/AgentQuotaBar" >/dev/null 2>&1 || break
        sleep 0.2
      done
    fi
  fi
  if [ -d "$TARGET" ]; then
    info "remove $TARGET"
    run rm -rf "$TARGET"
  fi
fi

if [ "$PURGE" -eq 1 ] && [ -d "$SUPPORT" ]; then
  info "remove $SUPPORT"
  run rm -rf "$SUPPORT"
fi

echo "==> done."
if [ "$REMOVE_APP" -ne 1 ] && [ -d "$TARGET" ]; then
  echo "    App 仍在：$TARGET。要删除请加 --app。"
fi
if [ "$PURGE" -ne 1 ] && [ -d "$SUPPORT" ]; then
  echo "    配置 / 用量 / 日志仍在：$SUPPORT。要删除请加 --purge。"
fi
if [ "$REMOVE_APP" -eq 1 ]; then
  echo "    提示：再次打开 App 会重新安装两个后台 LaunchAgent。"
fi
