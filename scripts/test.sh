#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
node --check collector/collector.js
node --check scripts/quota
node --check scripts/quota-server.js
node --test tests/*.test.js
echo "all checks passed"
