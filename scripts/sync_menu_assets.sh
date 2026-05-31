#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

cp "$ROOT_DIR/App/Assets.xcassets/MenuBarIdle.imageset/MenuBarIdle.pdf" "$ROOT_DIR/Sources/NTFSMenuApp/Resources/MenuBarIdle.pdf"
cp "$ROOT_DIR/App/Assets.xcassets/MenuBarDegraded.imageset/MenuBarDegraded.pdf" "$ROOT_DIR/Sources/NTFSMenuApp/Resources/MenuBarDegraded.pdf"
cp "$ROOT_DIR/App/Assets.xcassets/MenuBarError.imageset/MenuBarError.pdf" "$ROOT_DIR/Sources/NTFSMenuApp/Resources/MenuBarError.pdf"

echo "Menu bar assets synced"
