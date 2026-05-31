#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE_DIR="$ROOT_DIR/Packaging/Filesystems/ntfsaccess.fs"
INFO_PLIST="$BUNDLE_DIR/Contents/Info.plist"

for path in \
  "$INFO_PLIST" \
  "$BUNDLE_DIR/Contents/Resources/ntfsaccess.util"; do
  if [[ ! -f "$path" ]]; then
    echo "Missing filesystem bundle resource: $path" >&2
    exit 1
  fi
done

if [[ ! -x "$BUNDLE_DIR/Contents/Resources/mount_ntfsaccess" ]]; then
  echo "Missing executable filesystem mount wrapper: $BUNDLE_DIR/Contents/Resources/mount_ntfsaccess" >&2
  exit 1
fi

if ! grep -Fq '/Applications/NTFS Access.app/Contents/MacOS/NTFSMenuApp' "$BUNDLE_DIR/Contents/Resources/mount_ntfsaccess"; then
  echo "Filesystem mount wrapper must delegate through the installed NTFS Access.app helper identity" >&2
  exit 1
fi

if ! grep -Fq -- '--mount-helper' "$BUNDLE_DIR/Contents/Resources/mount_ntfsaccess"; then
  echo "Filesystem mount wrapper must pass --mount-helper to NTFSMenuApp" >&2
  exit 1
fi

python3 - "$INFO_PLIST" <<'PY'
import plistlib
import sys

path = sys.argv[1]
with open(path, "rb") as f:
    data = plistlib.load(f)

if data.get("CFBundlePackageType") != "fs  ":
    raise SystemExit(f"Invalid CFBundlePackageType in {path}")

if "FSImplementation" in data:
    raise SystemExit(
        "NTFS Access uses classic mount helper scripts; "
        "do not declare FSImplementation unless a real FSKit/UserFS module is bundled"
    )

personality = data.get("FSPersonalities", {}).get("NTFS Access")
if not personality:
    raise SystemExit(f"Missing NTFS Access personality in {path}")

if personality.get("FSName") != "Windows NT File System (NTFS Access)":
    raise SystemExit(f"Unexpected FSName in {path}")
PY

echo "Filesystem bundle validated"
