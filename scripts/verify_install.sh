#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE_PATH="$ROOT_DIR/dist/NTFSAccess-installer.pkg"
COMPONENT_PACKAGE_PATH="$ROOT_DIR/dist/ntfsaccess-component.pkg"
DO_INSTALL=0
DO_STAGED_INSTALL=0
DO_HOST_READINESS=0
UNINSTALL_AFTER=0
KEEP_STAGED_VOLUME=0
ALLOW_LIMITED_INSTALL=0
STAGED_DMG=""
STAGED_MOUNT=""
STAGED_DEVICE=""
DEFAULT_TOOLCHAIN_ROOT="/Library/NTFSAccess/toolchain"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

usage() {
  cat <<'EOF'
usage: ./scripts/verify_install.sh [--host-readiness] [--staged-install] [--install] [--allow-limited-install] [--uninstall-after] [--keep-staged-volume]

Default mode performs dry-run package verification only.
Use --host-readiness to report whether the current machine can perform live host verification.
Use --staged-install to verify install, upgrade, and uninstall against a temporary mounted volume without mutating the host.
This replays the expanded component payload plus its install scripts against the staged target because Apple `installer` itself requires root even for alternate volumes.
Use --install to perform a real system install; requires root.
Use --allow-limited-install with --install to perform a manual root-side replay of the packaged payload and scripts so host install verification can proceed without macFUSE/ntfs-3g/mkntfs/ntfsfix.
Use --uninstall-after with --install to remove the package after verification.
Use --keep-staged-volume with --staged-install to retain the temporary disk image for inspection on failure.
EOF
}

cleanup() {
  if [[ -n "$STAGED_DEVICE" ]]; then
    hdiutil detach "$STAGED_DEVICE" >/dev/null 2>&1 || true
  elif [[ -n "$STAGED_MOUNT" ]]; then
    hdiutil detach "$STAGED_MOUNT" >/dev/null 2>&1 || true
  fi

  if [[ "$KEEP_STAGED_VOLUME" -eq 0 ]]; then
    if [[ -n "$STAGED_MOUNT" ]]; then
      rm -rf "$STAGED_MOUNT"
    fi
    if [[ -n "$STAGED_DMG" ]]; then
      rm -f "$STAGED_DMG"
    fi
  fi

  return 0
}

trap cleanup EXIT

cleanup_workspace_bundle_conflicts() {
  local expanded_root=""
  for expanded_root in \
    "$ROOT_DIR/dist/component-expanded" \
    "$ROOT_DIR/dist/final-expanded" \
    "$ROOT_DIR/dist/installer-expanded"; do
    if [[ -d "$expanded_root" ]]; then
      if [[ -x "$LSREGISTER" && -d "$expanded_root/Payload/Applications/NTFS Access.app" ]]; then
        "$LSREGISTER" -u "$expanded_root/Payload/Applications/NTFS Access.app" >/dev/null 2>&1 || true
      fi
      rm -rf "$expanded_root"
    fi
  done
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host-readiness)
      DO_HOST_READINESS=1
      ;;
    --staged-install)
      DO_STAGED_INSTALL=1
      ;;
    --install)
      DO_INSTALL=1
      ;;
    --allow-limited-install)
      ALLOW_LIMITED_INSTALL=1
      ;;
    --uninstall-after)
      UNINSTALL_AFTER=1
      ;;
    --keep-staged-volume)
      KEEP_STAGED_VOLUME=1
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
  shift
done

if [[ "$DO_INSTALL" -eq 1 && "$DO_STAGED_INSTALL" -eq 1 ]]; then
  echo "--install and --staged-install are mutually exclusive." >&2
  exit 64
fi

if [[ "$ALLOW_LIMITED_INSTALL" -eq 1 && "$DO_INSTALL" -eq 0 ]]; then
  echo "--allow-limited-install requires --install." >&2
  exit 64
fi

require_payload_entry() {
  local payload="$1"
  local entry="$2"
  if ! grep -Fqx "$entry" <<<"$payload"; then
    echo "Missing payload entry: $entry" >&2
    exit 1
  fi
}

join_target_path() {
  local target_root="$1"
  local path="$2"
  if [[ "$target_root" == "/" ]]; then
    printf '%s\n' "$path"
  else
    printf '%s%s\n' "${target_root%/}" "$path"
  fi
}

require_installed_path() {
  local target_root="$1"
  local path="$2"
  local full_path
  full_path="$(join_target_path "$target_root" "$path")"
  if [[ ! -e "$full_path" ]]; then
    echo "Installed path missing: $full_path" >&2
    exit 1
  fi
}

require_removed_path() {
  local target_root="$1"
  local path="$2"
  local full_path
  full_path="$(join_target_path "$target_root" "$path")"
  if [[ -e "$full_path" ]]; then
    echo "Installed path still present after uninstall: $full_path" >&2
    exit 1
  fi
}

verify_expanded_payload() {
  local expanded_parent
  local expanded_dir
  expanded_parent="$(mktemp -d /tmp/ntfsaccess-expand-parent.XXXXXX)"
  expanded_dir="$expanded_parent/component"
  pkgutil --expand-full "$COMPONENT_PACKAGE_PATH" "$expanded_dir" >/dev/null
  if find "$expanded_dir/Payload" -name '._*' -print -quit | grep -q .; then
    echo "Expanded payload contains AppleDouble metadata files." >&2
    rm -rf "$expanded_parent"
    exit 1
  fi
  rm -rf "$expanded_parent"
}

create_staged_volume() {
  STAGED_DMG="$(mktemp -u /tmp/ntfsaccess-verify.XXXXXX).dmg"
  STAGED_MOUNT="$(mktemp -d /tmp/ntfsaccess-verify-mount.XXXXXX)"
  hdiutil create -size 256m -fs APFS -volname NTFSAccessVerify "$STAGED_DMG" >/dev/null
  STAGED_DEVICE="$(hdiutil attach -mountpoint "$STAGED_MOUNT" -nobrowse -noverify "$STAGED_DMG" | awk 'NR==1 {print $1; exit}')"
}

verify_installed_paths() {
  local target_root="$1"
  require_installed_path "$target_root" "/Library/Filesystems/ntfsaccess.fs/Contents/Info.plist"
  require_installed_path "$target_root" "/Library/Filesystems/ntfsaccess.fs/Contents/Resources/mount_ntfsaccess"
  require_installed_path "$target_root" "/Library/Filesystems/ntfsaccess.fs/Contents/Resources/newfs_ntfsaccess"
  require_installed_path "$target_root" "/Library/Application Support/NTFSAccess/live_job_runner.sh"
  require_installed_path "$target_root" "/Library/Application Support/NTFSAccess/live-tests/scripts/run_live_multi_device_admin_batch.sh"
  require_installed_path "$target_root" "/Library/Application Support/NTFSAccess/live-tests/scripts/run_live_user_validation_batch.sh"
  require_installed_path "$target_root" "/Library/Application Support/NTFSAccess/live-tests/scripts/run_live_deadline_guarded_stress.sh"
  require_installed_path "$target_root" "/Library/Application Support/NTFSAccess/live-tests/scripts/run_live_two_physical_admin_setup.sh"
  require_installed_path "$target_root" "/Library/Application Support/NTFSAccess/live-tests/scripts/run_live_two_physical_user_stress.sh"
  require_installed_path "$target_root" "/Library/Application Support/NTFSAccess/live-tests/scripts/run_live_apfs_restore_guard.sh"
  require_installed_path "$target_root" "/Library/Application Support/NTFSAccess/live-tests/scripts/live_multi_device_admin_batch.sh"
  require_installed_path "$target_root" "/Library/Application Support/NTFSAccess/live-tests/scripts/live_ntfs_full_validation.sh"
  require_installed_path "$target_root" "/Library/Application Support/NTFSAccess/live-tests/scripts/live_ntfs_finder_metadata_probe.sh"
  require_installed_path "$target_root" "/Library/Application Support/NTFSAccess/live-tests/scripts/live_ntfs_downloads_copy_probe.sh"
  require_installed_path "$target_root" "/Library/Application Support/NTFSAccess/live-tests/scripts/live_ntfs_finder_workflow_probe.sh"
  require_installed_path "$target_root" "/Library/Application Support/NTFSAccess/live-tests/scripts/live_ntfs_metadata_package_matrix.sh"
  require_installed_path "$target_root" "/Library/Application Support/NTFSAccess/live-tests/scripts/live_ntfs_filename_matrix.sh"
  require_installed_path "$target_root" "/Library/Application Support/NTFSAccess/live-tests/scripts/live_ntfs_format_matrix_probe.sh"
  require_installed_path "$target_root" "/Library/Application Support/NTFSAccess/live-tests/scripts/live_ntfs_special_feature_probe.sh"
  require_installed_path "$target_root" "/Library/Application Support/NTFSAccess/live-tests/scripts/live_ntfs_remount_churn.sh"
  require_installed_path "$target_root" "/Library/Application Support/NTFSAccess/live-tests/scripts/live_ntfs_guided_unplug_replug.sh"
  require_installed_path "$target_root" "/Library/Application Support/NTFSAccess/live-tests/scripts/live_ntfs_guided_sleep_wake.sh"
  require_installed_path "$target_root" "/Library/Application Support/NTFSAccess/live-tests/scripts/live_ntfs_multi_volume_flow.sh"
  require_installed_path "$target_root" "/Library/Application Support/NTFSAccess/live-tests/scripts/live_ntfs_overnight_stress.sh"
  require_installed_path "$target_root" "/Library/Application Support/NTFSAccess/live-tests/scripts/live_ntfs_filesystem_soak.sh"
  require_installed_path "$target_root" "/Library/Application Support/NTFSAccess/live-tests/scripts/live_ntfs_performance_probe.sh"
  require_installed_path "$target_root" "/Library/Application Support/NTFSAccess/uninstall.sh"
  require_installed_path "$target_root" "/Applications/NTFS Access.app/Contents/MacOS/NTFSMenuApp"
  require_installed_path "$target_root" "/Library/NTFSAccess/toolchain/bin/ntfs-3g"
  require_installed_path "$target_root" "/Library/NTFSAccess/toolchain/bin/ntfs-3g.probe"
  require_installed_path "$target_root" "/Library/NTFSAccess/toolchain/bin/ntfsfix"
  require_installed_path "$target_root" "/Library/NTFSAccess/toolchain/sbin/mkntfs"
  require_installed_path "$target_root" "/Library/NTFSAccess/toolchain/sbin/ntfslabel"
  require_installed_path "$target_root" "/Library/NTFSAccess/toolchain/lib/libntfs-3g.89.dylib"
  require_installed_path "$target_root" "/usr/local/bin/ntfsaccessctl"
  require_installed_path "$target_root" "/usr/local/bin/newfs_ntfsaccess"
  require_installed_path "$target_root" "/Applications/NTFS Access.app/Contents/MacOS/ntfsaccessctl"
  require_installed_path "$target_root" "/Applications/NTFS Access.app/Contents/MacOS/newfs_ntfsaccess"
}

verify_mount_wrapper_routes_through_app() {
  local target_root="$1"
  local wrapper
  wrapper="$(join_target_path "$target_root" "/Library/Filesystems/ntfsaccess.fs/Contents/Resources/mount_ntfsaccess")"
  if ! grep -Fq "/Applications/NTFS Access.app/Contents/MacOS/NTFSMenuApp" "$wrapper"; then
    echo "Filesystem mount wrapper does not delegate through NTFS Access.app: $wrapper" >&2
    exit 1
  fi
  if ! grep -Fq -- "--mount-helper" "$wrapper"; then
    echo "Filesystem mount wrapper does not pass --mount-helper: $wrapper" >&2
    exit 1
  fi
}

verify_removed_paths() {
  local target_root="$1"
  require_removed_path "$target_root" "/Library/Filesystems/ntfsaccess.fs"
  require_removed_path "$target_root" "/Library/NTFSAccess"
  require_removed_path "$target_root" "/Library/Application Support/NTFSAccess"
  require_removed_path "$target_root" "/Applications/NTFS Access.app"
  require_removed_path "$target_root" "/usr/local/bin/ntfsaccessctl"
  require_removed_path "$target_root" "/usr/local/bin/newfs_ntfsaccess"
  require_removed_path "$target_root" "/Library/LaunchDaemons/com.ntfsaccess.mountd.plist"
  require_removed_path "$target_root" "/Library/LaunchDaemons/com.ntfsaccess.livejob.plist"
  require_removed_path "$target_root" "/Library/LaunchAgents/com.ntfsaccess.menu.plist"
}

have_tool() {
  local tool_name="$1"
  shift
  local candidate=""

  if [[ -n "${NTFSACCESS_TOOLCHAIN_BIN:-}" && -x "${NTFSACCESS_TOOLCHAIN_BIN%/}/$tool_name" ]]; then
    return 0
  fi

  if [[ -n "${NTFSACCESS_TOOLCHAIN_ROOT:-}" ]]; then
    for candidate in "${NTFSACCESS_TOOLCHAIN_ROOT%/}/bin/$tool_name" "${NTFSACCESS_TOOLCHAIN_ROOT%/}/sbin/$tool_name"; do
      if [[ -x "$candidate" ]]; then
        return 0
      fi
    done
  fi

  for candidate in "$DEFAULT_TOOLCHAIN_ROOT/bin/$tool_name" "$DEFAULT_TOOLCHAIN_ROOT/sbin/$tool_name"; do
    if [[ -x "$candidate" ]]; then
      return 0
    fi
  done

  if command -v "$tool_name" >/dev/null 2>&1; then
    return 0
  fi

  for candidate in "$@"; do
    if [[ -x "$candidate" ]]; then
      return 0
    fi
  done
  return 1
}

print_host_readiness() {
  local have_root=0
  local have_ntfs3g=0
  local have_mkntfs=0
  local have_ntfsfix=0
  local have_macfuse=0
  local existing_personality=0
  local diskutil_available=1
  local diskutil_output=""

  if [[ "$EUID" -eq 0 ]]; then
    have_root=1
  elif sudo -n true >/dev/null 2>&1; then
    have_root=1
  fi

  if have_tool ntfs-3g /opt/homebrew/bin/ntfs-3g /usr/local/bin/ntfs-3g; then
    have_ntfs3g=1
  fi
  if have_tool mkntfs /opt/homebrew/bin/mkntfs /usr/local/bin/mkntfs; then
    have_mkntfs=1
  fi
  if have_tool ntfsfix /opt/homebrew/bin/ntfsfix /usr/local/bin/ntfsfix; then
    have_ntfsfix=1
  fi
  if [[ -x /Library/Filesystems/macfuse.fs/Contents/Resources/mount_macfuse ]] || command -v mount_macfuse >/dev/null 2>&1; then
    have_macfuse=1
  fi
  diskutil_output="$(
    /usr/sbin/diskutil listFilesystems 2>/dev/null || true
  )"
  if [[ -z "$diskutil_output" ]]; then
    diskutil_available=0
  fi
  if grep -Fq "NTFS Access" <<<"$diskutil_output"; then
    existing_personality=1
  fi

  echo "Host readiness:"
  if [[ "$have_root" -eq 1 ]]; then
    echo "- root access: available"
  else
    echo "- root access: unavailable for non-interactive runs"
  fi
  if [[ "$have_ntfs3g" -eq 1 ]]; then
    echo "- ntfs-3g: present"
  else
    echo "- ntfs-3g: missing"
  fi
  if [[ "$have_mkntfs" -eq 1 ]]; then
    echo "- mkntfs: present"
  else
    echo "- mkntfs: missing"
  fi
  if [[ "$have_ntfsfix" -eq 1 ]]; then
    echo "- ntfsfix: present"
  else
    echo "- ntfsfix: missing"
  fi
  if [[ "$have_macfuse" -eq 1 ]]; then
    echo "- macFUSE: present"
  else
    echo "- macFUSE: missing"
  fi
  if [[ "$diskutil_available" -eq 0 ]]; then
    echo "- NTFS Access filesystem personality: unable to check because diskutil/DiskManagement is unavailable in this execution context"
  elif [[ "$existing_personality" -eq 1 ]]; then
    echo "- NTFS Access filesystem personality: already visible in diskutil"
  else
    echo "- NTFS Access filesystem personality: not currently visible in diskutil"
  fi

  if [[ "$have_root" -eq 1 ]]; then
    if [[ "$have_ntfs3g" -eq 1 && "$have_mkntfs" -eq 1 && "$have_ntfsfix" -eq 1 && "$have_macfuse" -eq 1 ]]; then
      echo "Recommended live verification command:"
      echo "  sudo ./scripts/verify_install.sh --install --uninstall-after"
    else
      if [[ "$have_ntfs3g" -eq 0 || "$have_mkntfs" -eq 0 || "$have_ntfsfix" -eq 0 ]]; then
        echo "Recommended managed toolchain bootstrap:"
        echo "  ./scripts/bootstrap_ntfs_toolchain.sh --install-build-deps"
        echo "  sudo ./scripts/bootstrap_ntfs_toolchain.sh"
      fi
      if [[ "$have_macfuse" -eq 0 ]]; then
        echo "Recommended macFUSE install:"
        echo "  brew install --cask macfuse"
      fi
      echo "Recommended live verification command with limited mode:"
      echo "  sudo ./scripts/verify_install.sh --install --allow-limited-install --uninstall-after"
    fi
  else
    echo "Live host verification is blocked until root access is available."
  fi

  return 0
}

run_component_script() {
  local expanded_dir="$1"
  local script_name="$2"
  local target_root="$3"
  local script_path="$expanded_dir/Scripts/$script_name"
  if [[ -x "$script_path" ]]; then
    if [[ "$ALLOW_LIMITED_INSTALL" -eq 1 ]]; then
      env ALLOW_LIMITED_INSTALL=1 "$script_path" "$COMPONENT_PACKAGE_PATH" "/" "$target_root"
    else
      "$script_path" "$COMPONENT_PACKAGE_PATH" "/" "$target_root"
    fi
  fi
}

perform_component_install_cycle() {
  local target_root="$1"
  local expanded_parent
  local expanded_dir
  expanded_parent="$(mktemp -d /tmp/ntfsaccess-staged-component.XXXXXX)"
  expanded_dir="$expanded_parent/component"
  pkgutil --expand-full "$COMPONENT_PACKAGE_PATH" "$expanded_dir" >/dev/null

  run_component_script "$expanded_dir" "preinstall" "$target_root"
  /usr/bin/ditto "$expanded_dir/Payload" "$target_root"
  run_component_script "$expanded_dir" "postinstall" "$target_root"
  verify_installed_paths "$target_root"
  verify_mount_wrapper_routes_through_app "$target_root"

  run_component_script "$expanded_dir" "preinstall" "$target_root"
  /usr/bin/ditto "$expanded_dir/Payload" "$target_root"
  run_component_script "$expanded_dir" "postinstall" "$target_root"
  verify_installed_paths "$target_root"
  verify_mount_wrapper_routes_through_app "$target_root"

  rm -rf "$expanded_parent"
}

if [[ ! -f "$PACKAGE_PATH" ]]; then
  echo "Installer package not found: $PACKAGE_PATH" >&2
  exit 1
fi

if [[ ! -f "$COMPONENT_PACKAGE_PATH" ]]; then
  echo "Component package not found: $COMPONENT_PACKAGE_PATH" >&2
  exit 1
fi

payload="$(pkgutil --payload-files "$COMPONENT_PACKAGE_PATH")"
require_payload_entry "$payload" "./Library/Filesystems/ntfsaccess.fs/Contents/Info.plist"
require_payload_entry "$payload" "./Library/Filesystems/ntfsaccess.fs/Contents/Resources/mount_ntfsaccess"
require_payload_entry "$payload" "./Library/Filesystems/ntfsaccess.fs/Contents/Resources/newfs_ntfsaccess"
require_payload_entry "$payload" "./Library/Application Support/NTFSAccess/live_job_runner.sh"
require_payload_entry "$payload" "./Library/Application Support/NTFSAccess/live-tests/scripts/run_live_multi_device_admin_batch.sh"
require_payload_entry "$payload" "./Library/Application Support/NTFSAccess/live-tests/scripts/run_live_user_validation_batch.sh"
require_payload_entry "$payload" "./Library/Application Support/NTFSAccess/live-tests/scripts/run_live_deadline_guarded_stress.sh"
require_payload_entry "$payload" "./Library/Application Support/NTFSAccess/live-tests/scripts/run_live_two_physical_admin_setup.sh"
require_payload_entry "$payload" "./Library/Application Support/NTFSAccess/live-tests/scripts/run_live_two_physical_user_stress.sh"
require_payload_entry "$payload" "./Library/Application Support/NTFSAccess/live-tests/scripts/run_live_apfs_restore_guard.sh"
require_payload_entry "$payload" "./Library/Application Support/NTFSAccess/live-tests/scripts/live_multi_device_admin_batch.sh"
require_payload_entry "$payload" "./Library/Application Support/NTFSAccess/live-tests/scripts/live_ntfs_full_validation.sh"
require_payload_entry "$payload" "./Library/Application Support/NTFSAccess/live-tests/scripts/live_ntfs_finder_metadata_probe.sh"
require_payload_entry "$payload" "./Library/Application Support/NTFSAccess/live-tests/scripts/live_ntfs_downloads_copy_probe.sh"
require_payload_entry "$payload" "./Library/Application Support/NTFSAccess/live-tests/scripts/live_ntfs_finder_workflow_probe.sh"
require_payload_entry "$payload" "./Library/Application Support/NTFSAccess/live-tests/scripts/live_ntfs_metadata_package_matrix.sh"
require_payload_entry "$payload" "./Library/Application Support/NTFSAccess/live-tests/scripts/live_ntfs_filename_matrix.sh"
require_payload_entry "$payload" "./Library/Application Support/NTFSAccess/live-tests/scripts/live_ntfs_format_matrix_probe.sh"
require_payload_entry "$payload" "./Library/Application Support/NTFSAccess/live-tests/scripts/live_ntfs_special_feature_probe.sh"
require_payload_entry "$payload" "./Library/Application Support/NTFSAccess/live-tests/scripts/live_ntfs_remount_churn.sh"
require_payload_entry "$payload" "./Library/Application Support/NTFSAccess/live-tests/scripts/live_ntfs_guided_unplug_replug.sh"
require_payload_entry "$payload" "./Library/Application Support/NTFSAccess/live-tests/scripts/live_ntfs_guided_sleep_wake.sh"
require_payload_entry "$payload" "./Library/Application Support/NTFSAccess/live-tests/scripts/live_ntfs_multi_volume_flow.sh"
require_payload_entry "$payload" "./Library/Application Support/NTFSAccess/live-tests/scripts/live_ntfs_overnight_stress.sh"
require_payload_entry "$payload" "./Library/Application Support/NTFSAccess/live-tests/scripts/live_ntfs_filesystem_soak.sh"
require_payload_entry "$payload" "./Library/Application Support/NTFSAccess/live-tests/scripts/live_ntfs_performance_probe.sh"
require_payload_entry "$payload" "./Library/LaunchDaemons/com.ntfsaccess.livejob.plist"
require_payload_entry "$payload" "./Applications/NTFS Access.app/Contents/MacOS/NTFSMenuApp"
require_payload_entry "$payload" "./Applications/NTFS Access.app/Contents/MacOS/ntfsaccessctl"
require_payload_entry "$payload" "./Applications/NTFS Access.app/Contents/MacOS/newfs_ntfsaccess"
require_payload_entry "$payload" "./Library/NTFSAccess/toolchain/bin/ntfs-3g"
require_payload_entry "$payload" "./Library/NTFSAccess/toolchain/bin/ntfs-3g.probe"
require_payload_entry "$payload" "./Library/NTFSAccess/toolchain/bin/ntfsfix"
require_payload_entry "$payload" "./Library/NTFSAccess/toolchain/sbin/mkntfs"
require_payload_entry "$payload" "./Library/NTFSAccess/toolchain/sbin/ntfslabel"
require_payload_entry "$payload" "./Library/NTFSAccess/toolchain/lib/libntfs-3g.89.dylib"
require_payload_entry "$payload" "./usr/local/bin/ntfsaccessctl"
require_payload_entry "$payload" "./usr/local/bin/newfs_ntfsaccess"
verify_expanded_payload

echo "Package payload contains expected NTFS Access files."

metadata_noise_count="$(grep -Ec '(^|/)\._' <<<"$payload" || true)"
if [[ "$metadata_noise_count" -gt 0 ]]; then
  echo "Note: pkgutil --payload-files reports $metadata_noise_count AppleDouble BOM entries from com.apple.provenance metadata; the expanded payload tree itself is clean."
fi

if [[ "$DO_INSTALL" -eq 0 && "$DO_STAGED_INSTALL" -eq 0 ]]; then
  if [[ "$DO_HOST_READINESS" -eq 1 ]]; then
    print_host_readiness
  fi
  echo "Dry-run verification complete. Use --staged-install for a non-root install cycle or --install as root for live host verification."
  exit 0
fi

if [[ "$DO_STAGED_INSTALL" -eq 1 ]]; then
  cleanup_workspace_bundle_conflicts
  create_staged_volume
  perform_component_install_cycle "$STAGED_MOUNT"
  NTFSACCESS_TARGET_ROOT="$STAGED_MOUNT" /bin/bash "$(join_target_path "$STAGED_MOUNT" "/Library/Application Support/NTFSAccess/uninstall.sh")"
  verify_removed_paths "$STAGED_MOUNT"
  echo "Staged install, upgrade, and uninstall verification succeeded at $STAGED_MOUNT."
  exit 0
fi

if [[ "$EUID" -ne 0 ]]; then
  echo "--install requires root privileges." >&2
  exit 1
fi

cleanup_workspace_bundle_conflicts

if [[ "$ALLOW_LIMITED_INSTALL" -eq 1 ]]; then
  perform_component_install_cycle "/"
else
  /usr/sbin/installer -pkg "$PACKAGE_PATH" -target /
fi

verify_installed_paths "/"
verify_mount_wrapper_routes_through_app "/"

if ! /usr/sbin/diskutil listFilesystems | grep -Fq "NTFS Access"; then
  echo "Disk Utility personality registration check failed: NTFS Access not listed." >&2
  exit 1
fi

echo "Live install verification succeeded."

if [[ "$UNINSTALL_AFTER" -eq 1 ]]; then
  /bin/bash "/Library/Application Support/NTFSAccess/uninstall.sh"
  verify_removed_paths "/"
  echo "Uninstall verification completed."
fi
