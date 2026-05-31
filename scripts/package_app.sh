#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
export COPYFILE_DISABLE=1

strip_metadata() {
  local target_path="$1"
  /usr/bin/find "$target_path" -exec /usr/bin/xattr -d com.apple.provenance {} + >/dev/null 2>&1 || true
  /usr/bin/xattr -cr "$target_path" 2>/dev/null || true
}

./scripts/build.sh

APP_DIR="$ROOT_DIR/dist/NTFS Access.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
HELPERS_DIR="$CONTENTS_DIR/Helpers"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
TOOLCHAIN_DIR="$CONTENTS_DIR/Library/NTFSAccess/toolchain"
TOOLCHAIN_BIN_DIR="$TOOLCHAIN_DIR/bin"
TOOLCHAIN_SBIN_DIR="$TOOLCHAIN_DIR/sbin"
TOOLCHAIN_LIB_DIR="$TOOLCHAIN_DIR/lib"
MANAGED_TOOLCHAIN_ROOT="${NTFSACCESS_SOURCE_TOOLCHAIN_ROOT:-/Library/NTFSAccess/toolchain}"
MANAGED_TOOLCHAIN_BIN_DIR="$MANAGED_TOOLCHAIN_ROOT/bin"
MANAGED_TOOLCHAIN_SBIN_DIR="$MANAGED_TOOLCHAIN_ROOT/sbin"
MANAGED_TOOLCHAIN_LIB_DIR="$MANAGED_TOOLCHAIN_ROOT/lib"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$HELPERS_DIR" "$TOOLCHAIN_BIN_DIR" "$TOOLCHAIN_SBIN_DIR" "$TOOLCHAIN_LIB_DIR"

copy_toolchain_binary() {
  local source_dir="$1"
  local target_dir="$2"
  local binary="$3"
  local source_path="$source_dir/$binary"
  local target_path="$target_dir/$binary"

  if [[ ! -x "$source_path" ]]; then
    echo "Required NTFS tool not found: $source_path" >&2
    exit 66
  fi

  /usr/bin/ditto --noextattr --noqtn "$source_path" "$target_path"
  chmod 755 "$target_path"
  /usr/bin/install_name_tool \
    -change "$MANAGED_TOOLCHAIN_LIB_DIR/libntfs-3g.89.dylib" \
    "@loader_path/../lib/libntfs-3g.89.dylib" \
    "$target_path" 2>/dev/null || true
}

if [[ ! -f "$MANAGED_TOOLCHAIN_LIB_DIR/libntfs-3g.89.dylib" ]]; then
  echo "Required NTFS library not found: $MANAGED_TOOLCHAIN_LIB_DIR/libntfs-3g.89.dylib" >&2
  exit 66
fi

/usr/bin/ditto --noextattr --noqtn "$ROOT_DIR/.build/release/NTFSMenuApp" "$MACOS_DIR/NTFSMenuApp"
chmod 755 "$MACOS_DIR/NTFSMenuApp"
/usr/bin/ditto --noextattr --noqtn "$ROOT_DIR/.build/release/ntfsaccessctl" "$MACOS_DIR/ntfsaccessctl"
/usr/bin/ditto --noextattr --noqtn "$ROOT_DIR/.build/release/newfs_ntfsaccess" "$MACOS_DIR/newfs_ntfsaccess"
chmod 755 "$MACOS_DIR/ntfsaccessctl" "$MACOS_DIR/newfs_ntfsaccess"

/usr/bin/ditto --noextattr --noqtn "$ROOT_DIR/Sources/NTFSMenuApp/Resources/MenuBarIdle.pdf" "$RESOURCES_DIR/MenuBarIdle.pdf"
/usr/bin/ditto --noextattr --noqtn "$ROOT_DIR/Sources/NTFSMenuApp/Resources/MenuBarDegraded.pdf" "$RESOURCES_DIR/MenuBarDegraded.pdf"
/usr/bin/ditto --noextattr --noqtn "$ROOT_DIR/Sources/NTFSMenuApp/Resources/MenuBarError.pdf" "$RESOURCES_DIR/MenuBarError.pdf"
swift "$ROOT_DIR/scripts/generate_app_icon.swift" >/dev/null
/usr/bin/ditto --noextattr --noqtn "$ROOT_DIR/Sources/NTFSMenuApp/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"

/usr/bin/ditto --noextattr --noqtn "$MANAGED_TOOLCHAIN_LIB_DIR/libntfs-3g.89.dylib" "$TOOLCHAIN_LIB_DIR/libntfs-3g.89.dylib"
chmod 755 "$TOOLCHAIN_LIB_DIR/libntfs-3g.89.dylib"
/usr/bin/install_name_tool -id "@loader_path/libntfs-3g.89.dylib" "$TOOLCHAIN_LIB_DIR/libntfs-3g.89.dylib"

for binary in ntfs-3g ntfs-3g.probe ntfsfix; do
  copy_toolchain_binary "$MANAGED_TOOLCHAIN_BIN_DIR" "$TOOLCHAIN_BIN_DIR" "$binary"
done

for binary in mkntfs ntfslabel; do
  copy_toolchain_binary "$MANAGED_TOOLCHAIN_SBIN_DIR" "$TOOLCHAIN_SBIN_DIR" "$binary"
done

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>NTFS Access</string>
  <key>CFBundleDisplayName</key>
  <string>NTFS Access</string>
  <key>CFBundleIdentifier</key>
  <string>com.ntfsaccess.menu</string>
  <key>CFBundleVersion</key>
  <string>1.0.0</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0.0</string>
  <key>CFBundleExecutable</key>
  <string>NTFSMenuApp</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
</dict>
</plist>
PLIST

find "$APP_DIR" \( -name '._*' -o -name '.DS_Store' \) -delete
strip_metadata "$APP_DIR"

/usr/bin/codesign --force --sign - "$TOOLCHAIN_LIB_DIR/libntfs-3g.89.dylib"
for binary in ntfs-3g ntfs-3g.probe ntfsfix; do
  /usr/bin/codesign --force --sign - "$TOOLCHAIN_BIN_DIR/$binary"
done
for binary in mkntfs ntfslabel; do
  /usr/bin/codesign --force --sign - "$TOOLCHAIN_SBIN_DIR/$binary"
done
/usr/bin/codesign --force --sign - "$MACOS_DIR/ntfsaccessctl"
/usr/bin/codesign --force --sign - "$MACOS_DIR/newfs_ntfsaccess"
/usr/bin/codesign --force --sign - "$APP_DIR"
/usr/bin/codesign --verify --deep --strict "$APP_DIR"

echo "Packaged app: $APP_DIR"
