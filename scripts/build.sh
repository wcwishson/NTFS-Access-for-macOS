#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

./scripts/validate_menu_assets.sh
./scripts/validate_filesystem_bundle.sh
./scripts/sync_menu_assets.sh

swift build -c release --disable-sandbox -Xswiftc -gnone -Xlinker -S

echo "Build complete"
