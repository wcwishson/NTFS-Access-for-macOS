#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
SUPPORT_ROOT="/Library/Application Support/NTFSAccess"
LIVE_TESTS_ROOT="$SUPPORT_ROOT/live-tests/scripts"
STAGE_ROOT="/Users/Shared/NTFSAccessLiveBatch"
REQUEST_ROOT="$STAGE_ROOT/requests"
LIVEJOB_PLIST="/Library/LaunchDaemons/com.ntfsaccess.livejob.plist"

if [[ "$EUID" -ne 0 ]]; then
  echo "install_live_job_support.sh must run as root." >&2
  exit 77
fi

install_script() {
  local source="$1"
  local destination="$2"
  /usr/bin/install -m 755 "$source" "$destination"
}

prepare_root_directory() {
  local path="$1"
  local mode="$2"

  if [[ -L "$path" ]]; then
    /bin/rm -f "$path"
  fi
  /bin/mkdir -p "$path"
  /usr/sbin/chown root:wheel "$path" 2>/dev/null || true
  /bin/chmod "$mode" "$path"
}

/bin/mkdir -p "$SUPPORT_ROOT" "$LIVE_TESTS_ROOT"
/bin/chmod 755 "$SUPPORT_ROOT" "$SUPPORT_ROOT/live-tests" "$LIVE_TESTS_ROOT"
prepare_root_directory "$STAGE_ROOT" 755
prepare_root_directory "$REQUEST_ROOT" 1777
prepare_root_directory "$STAGE_ROOT/logs" 755
if [[ -e "$STAGE_ROOT/live-job.conf" && ! -e "$REQUEST_ROOT/live-job.conf" ]]; then
  /bin/mv "$STAGE_ROOT/live-job.conf" "$REQUEST_ROOT/live-job.conf" 2>/dev/null || true
fi
if [[ -e "$STAGE_ROOT/live-job.trigger" && ! -e "$REQUEST_ROOT/live-job.trigger" ]]; then
  /bin/mv "$STAGE_ROOT/live-job.trigger" "$REQUEST_ROOT/live-job.trigger" 2>/dev/null || true
fi
if [[ -f "$REQUEST_ROOT/live-job.conf" ]]; then
  /bin/chmod 644 "$REQUEST_ROOT/live-job.conf" 2>/dev/null || true
fi
if [[ -f "$REQUEST_ROOT/live-job.trigger" ]]; then
  /bin/chmod 644 "$REQUEST_ROOT/live-job.trigger" 2>/dev/null || true
fi
/bin/rm -f "$REQUEST_ROOT/live-job.trigger" 2>/dev/null || true

install_script "$ROOT_DIR/scripts/live_job_runner.sh" "$SUPPORT_ROOT/live_job_runner.sh"
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
  install_script "$ROOT_DIR/scripts/$live_script" "$LIVE_TESTS_ROOT/$live_script"
done

install_script "$ROOT_DIR/.build/release/ntfsaccessctl" "/usr/local/bin/ntfsaccessctl"
/usr/bin/install -m 644 "$ROOT_DIR/Packaging/LaunchDaemons/com.ntfsaccess.livejob.plist" "$LIVEJOB_PLIST"

/bin/launchctl bootout system "$LIVEJOB_PLIST" >/dev/null 2>&1 || true
/bin/launchctl bootstrap system "$LIVEJOB_PLIST"
/bin/launchctl enable system/com.ntfsaccess.livejob >/dev/null 2>&1 || true

echo "Installed NTFS Access live-job support without replacing /Applications/NTFS Access.app"
echo "Trigger path: $REQUEST_ROOT/live-job.trigger"
echo "Config path: $REQUEST_ROOT/live-job.conf"
