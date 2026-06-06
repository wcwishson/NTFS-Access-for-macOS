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

./scripts/package_app.sh

DIST_DIR="$ROOT_DIR/dist"
PKGROOT="$DIST_DIR/pkgroot"
COMPONENT_PKG="$DIST_DIR/ntfsaccess-component.pkg"
FINAL_PKG="$DIST_DIR/NTFSAccess-installer.pkg"
COMPONENT_PLIST="$ROOT_DIR/Packaging/component-properties.plist"

cleanup_path() {
  local path="$1"
  rm -rf "$path" 2>/dev/null || true
}

cleanup_path "$PKGROOT"
cleanup_path "$COMPONENT_PKG"
cleanup_path "$FINAL_PKG"
cleanup_path "$DIST_DIR/component-expanded"
cleanup_path "$DIST_DIR/final-expanded"
cleanup_path "$DIST_DIR/installer-expanded"

mkdir -p "$PKGROOT/Applications" \
         "$PKGROOT/Library/Application Support/NTFSAccess" \
         "$PKGROOT/Library/Application Support/NTFSAccess/live-tests/scripts" \
         "$PKGROOT/Library/Filesystems/ntfsaccess.fs/Contents/Resources" \
         "$PKGROOT/Library/LaunchDaemons" \
         "$PKGROOT/Library/LaunchAgents" \
         "$PKGROOT/usr/local/bin"

/usr/bin/ditto --noextattr --noqtn "$DIST_DIR/NTFS Access.app" "$PKGROOT/Applications/NTFS Access.app"
/usr/bin/install -m 755 "$ROOT_DIR/scripts/live_job_runner.sh" "$PKGROOT/Library/Application Support/NTFSAccess/live_job_runner.sh"
for live_script in \
  run_live_multi_device_admin_batch.sh \
  run_live_user_validation_batch.sh \
  run_live_deadline_guarded_stress.sh \
  run_live_two_physical_admin_setup.sh \
  run_live_two_physical_user_stress.sh \
  run_live_apfs_restore_guard.sh \
  live_multi_device_admin_batch.sh \
  live_ntfs_full_validation.sh \
  live_ntfs_finder_metadata_probe.sh \
  live_ntfs_downloads_copy_probe.sh \
  live_ntfs_finder_workflow_probe.sh \
  live_ntfs_metadata_package_matrix.sh \
  live_ntfs_filename_matrix.sh \
  live_ntfs_format_matrix_probe.sh \
  live_ntfs_special_feature_probe.sh \
  live_ntfs_remount_churn.sh \
  live_ntfs_guided_unplug_replug.sh \
  live_ntfs_guided_sleep_wake.sh \
  live_ntfs_multi_volume_flow.sh \
  live_ntfs_overnight_stress.sh \
  live_ntfs_filesystem_soak.sh \
  live_ntfs_performance_probe.sh
do
  /usr/bin/install -m 755 "$ROOT_DIR/scripts/$live_script" "$PKGROOT/Library/Application Support/NTFSAccess/live-tests/scripts/$live_script"
done
/usr/bin/install -m 755 "$ROOT_DIR/Packaging/Filesystems/ntfsaccess.fs/Contents/Resources/mount_ntfsaccess" "$PKGROOT/Library/Filesystems/ntfsaccess.fs/Contents/Resources/mount_ntfsaccess"
/usr/bin/install -m 755 "$ROOT_DIR/.build/release/ntfsaccessctl" "$PKGROOT/usr/local/bin/ntfsaccessctl"
/usr/bin/install -m 755 "$ROOT_DIR/.build/release/newfs_ntfsaccess" "$PKGROOT/usr/local/bin/newfs_ntfsaccess"
/usr/bin/install -m 755 "$ROOT_DIR/Packaging/Scripts/uninstall.sh" "$PKGROOT/Library/Application Support/NTFSAccess/uninstall.sh"
/usr/bin/install -m 644 "$ROOT_DIR/Packaging/LaunchDaemons/com.ntfsaccess.mountd.plist" "$PKGROOT/Library/LaunchDaemons/com.ntfsaccess.mountd.plist"
/usr/bin/install -m 644 "$ROOT_DIR/Packaging/LaunchDaemons/com.ntfsaccess.livejob.plist" "$PKGROOT/Library/LaunchDaemons/com.ntfsaccess.livejob.plist"
/usr/bin/install -m 644 "$ROOT_DIR/Packaging/LaunchAgents/com.ntfsaccess.menu.plist" "$PKGROOT/Library/LaunchAgents/com.ntfsaccess.menu.plist"
/usr/bin/install -m 644 "$ROOT_DIR/Packaging/Filesystems/ntfsaccess.fs/Contents/Info.plist" "$PKGROOT/Library/Filesystems/ntfsaccess.fs/Contents/Info.plist"
/usr/bin/install -m 755 "$ROOT_DIR/Packaging/Filesystems/ntfsaccess.fs/Contents/Resources/ntfsaccess.util" "$PKGROOT/Library/Filesystems/ntfsaccess.fs/Contents/Resources/ntfsaccess.util"
/usr/bin/install -m 755 "$ROOT_DIR/.build/release/newfs_ntfsaccess" "$PKGROOT/Library/Filesystems/ntfsaccess.fs/Contents/Resources/newfs_ntfsaccess"

mkdir -p "$PKGROOT/Library/NTFSAccess/toolchain/bin" \
         "$PKGROOT/Library/NTFSAccess/toolchain/sbin" \
         "$PKGROOT/Library/NTFSAccess/toolchain/lib"
/usr/bin/ditto --noextattr --noqtn "$DIST_DIR/NTFS Access.app/Contents/Library/NTFSAccess/toolchain/bin/ntfs-3g" "$PKGROOT/Library/NTFSAccess/toolchain/bin/ntfs-3g"
/usr/bin/ditto --noextattr --noqtn "$DIST_DIR/NTFS Access.app/Contents/Library/NTFSAccess/toolchain/bin/ntfs-3g.probe" "$PKGROOT/Library/NTFSAccess/toolchain/bin/ntfs-3g.probe"
/usr/bin/ditto --noextattr --noqtn "$DIST_DIR/NTFS Access.app/Contents/Library/NTFSAccess/toolchain/bin/ntfsfix" "$PKGROOT/Library/NTFSAccess/toolchain/bin/ntfsfix"
/usr/bin/ditto --noextattr --noqtn "$DIST_DIR/NTFS Access.app/Contents/Library/NTFSAccess/toolchain/sbin/mkntfs" "$PKGROOT/Library/NTFSAccess/toolchain/sbin/mkntfs"
/usr/bin/ditto --noextattr --noqtn "$DIST_DIR/NTFS Access.app/Contents/Library/NTFSAccess/toolchain/sbin/ntfslabel" "$PKGROOT/Library/NTFSAccess/toolchain/sbin/ntfslabel"
/usr/bin/ditto --noextattr --noqtn "$DIST_DIR/NTFS Access.app/Contents/Library/NTFSAccess/toolchain/lib/libntfs-3g.89.dylib" "$PKGROOT/Library/NTFSAccess/toolchain/lib/libntfs-3g.89.dylib"

chmod 755 "$PKGROOT/Library/Application Support/NTFSAccess/live_job_runner.sh"
chmod 755 "$PKGROOT/Library/Application Support/NTFSAccess/live-tests"
chmod 755 "$PKGROOT/Library/Application Support/NTFSAccess/live-tests/scripts"
chmod 755 "$PKGROOT/Library/Application Support/NTFSAccess/live-tests/scripts/"*.sh
chmod 755 "$PKGROOT/Library/Filesystems/ntfsaccess.fs/Contents/Resources/mount_ntfsaccess"
chmod 755 "$PKGROOT/usr/local/bin/ntfsaccessctl"
chmod 755 "$PKGROOT/usr/local/bin/newfs_ntfsaccess"
chmod 755 "$PKGROOT/Library/Application Support/NTFSAccess/uninstall.sh"
chmod 755 "$PKGROOT/Library/Filesystems/ntfsaccess.fs/Contents/Resources/mount_ntfsaccess"
chmod 755 "$PKGROOT/Library/Filesystems/ntfsaccess.fs/Contents/Resources/ntfsaccess.util"
chmod 755 "$PKGROOT/Library/Filesystems/ntfsaccess.fs/Contents/Resources/newfs_ntfsaccess"
chmod 755 "$PKGROOT/Library/NTFSAccess/toolchain/bin/ntfs-3g"
chmod 755 "$PKGROOT/Library/NTFSAccess/toolchain/bin/ntfs-3g.probe"
chmod 755 "$PKGROOT/Library/NTFSAccess/toolchain/bin/ntfsfix"
chmod 755 "$PKGROOT/Library/NTFSAccess/toolchain/sbin/mkntfs"
chmod 755 "$PKGROOT/Library/NTFSAccess/toolchain/sbin/ntfslabel"
chmod 755 "$PKGROOT/Library/NTFSAccess/toolchain/lib/libntfs-3g.89.dylib"
chmod 644 "$PKGROOT/Library/LaunchDaemons/com.ntfsaccess.mountd.plist"
chmod 644 "$PKGROOT/Library/LaunchDaemons/com.ntfsaccess.livejob.plist"
chmod 644 "$PKGROOT/Library/LaunchAgents/com.ntfsaccess.menu.plist"
chmod 644 "$PKGROOT/Library/Filesystems/ntfsaccess.fs/Contents/Info.plist"

find "$PKGROOT" \( -name '._*' -o -name '.DS_Store' \) -delete
strip_metadata "$PKGROOT"

pkgbuild \
  --root "$PKGROOT" \
  --component-plist "$COMPONENT_PLIST" \
  --scripts "$ROOT_DIR/Packaging/Scripts" \
  --identifier "com.ntfsaccess.pkg.component" \
  --version "1.0.1" \
  --ownership recommended \
  --filter '\.DS_Store$' \
  --filter '(^|/)\._' \
  "$COMPONENT_PKG"

productbuild \
  --distribution "$ROOT_DIR/Packaging/distribution.xml" \
  --package-path "$DIST_DIR" \
  "$FINAL_PKG"

echo "Created installer: $FINAL_PKG"
