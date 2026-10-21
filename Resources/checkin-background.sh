#!/bin/zsh
# 由 LaunchAgent 每小时调用；是否真正签到由 collector --scheduled 判断。
set -u
RES="$(cd "$(dirname "$0")" && pwd)"
NODE="$(command -v node 2>/dev/null || true)"
if [ -z "$NODE" ]; then
  for candidate in /opt/homebrew/bin/node /usr/local/bin/node /usr/bin/node; do
    if [ -x "$candidate" ]; then NODE="$candidate"; break; fi
  done
fi
[ -z "$NODE" ] && exit 1
exec "$NODE" "$RES/collector.js" --checkin --scheduled --write-config
