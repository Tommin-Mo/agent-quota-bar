#!/bin/zsh
# 由 LaunchAgent 每小时调用；是否真正签到由 collector --scheduled 判断。
set -u
setopt NULL_GLOB 2>/dev/null || true
RES="$(cd "$(dirname "$0")" && pwd)"
NODE="$(command -v node 2>/dev/null || true)"
if [ -z "$NODE" ]; then
  for candidate in \
    "$HOME/.nvm/current/bin/node" \
    "$HOME"/.nvm/versions/node/*/bin/node \
    "$HOME/.volta/bin/node" \
    "$HOME/.asdf/shims/node" \
    "$HOME/.local/bin/node" \
    /opt/local/bin/node /opt/homebrew/bin/node /usr/local/bin/node /usr/bin/node; do
    if [ -x "$candidate" ]; then NODE="$candidate"; break; fi
  done
fi
if [ -z "$NODE" ]; then
  echo "checkin: node not found (nvm/fnm/asdf/volta/homebrew). See README troubleshooting." >&2
  exit 1
fi
exec "$NODE" "$RES/collector.js" --checkin --scheduled --write-config
