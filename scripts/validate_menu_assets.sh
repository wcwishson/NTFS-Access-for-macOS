#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

assets=(
  "MenuBarIdle"
  "MenuBarDegraded"
  "MenuBarError"
)

for name in "${assets[@]}"; do
  image_dir="$ROOT_DIR/App/Assets.xcassets/${name}.imageset"
  pdf_path="$image_dir/${name}.pdf"
  contents_path="$image_dir/Contents.json"

  if [[ ! -f "$pdf_path" ]]; then
    echo "Missing icon PDF: $pdf_path" >&2
    exit 1
  fi

  if [[ ! -f "$contents_path" ]]; then
    echo "Missing imageset metadata: $contents_path" >&2
    exit 1
  fi

  python3 - "$contents_path" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, 'r', encoding='utf-8') as f:
    data = json.load(f)

props = data.get('properties', {})
if props.get('template-rendering-intent') != 'template':
    raise SystemExit(f"Invalid template-rendering-intent in {path}")

if props.get('preserves-vector-representation') is not True:
    raise SystemExit(f"preserves-vector-representation must be true in {path}")
PY

done

echo "Menu bar icon assets validated"
