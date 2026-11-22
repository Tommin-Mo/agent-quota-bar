#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
export AGENT_QUOTA_CONFIG="$scratch/regression-config.json"
swift build -c release
node --check collector/collector.js
node --check scripts/quota
node --check scripts/quota-server.js
node --test tests/*.test.js
sources=(Sources/AgentQuotaBar/*.swift)
bundle="$scratch/Regression.app/Contents"
mkdir -p "$bundle/MacOS"
cat >"$bundle/Info.plist" <<'PLIST'
<?xml version="1.0"?><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.agentquota.regression</string>
<key>CFBundleExecutable</key><string>regression</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
swiftc -o "$bundle/MacOS/regression" ${sources:#*/main.swift} tests/regression/main.swift
codesign --force --sign - "$scratch/Regression.app"
cat >"$scratch/offline.sb" <<PROFILE
(version 1)
(allow default)
(deny network-outbound)
(deny file-write* (subpath "$HOME"))
(deny file-read* (subpath "$HOME/.config/agent-quota") (subpath "$HOME/.codex") (subpath "$HOME/Library/Keychains") (subpath "$HOME/Library/Application Support/WorkBuddy") (subpath "$HOME/Library/Application Support/Google/Chrome"))
(deny process-exec (literal "/bin/launchctl") (literal "/usr/bin/security") (literal "/usr/bin/curl"))
PROFILE
CFFIXED_USER_HOME="$scratch" /usr/bin/sandbox-exec -f "$scratch/offline.sb" "$bundle/MacOS/regression"
echo "all checks passed"
