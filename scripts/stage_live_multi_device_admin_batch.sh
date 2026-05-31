#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
STAGE_ROOT="/Users/Shared/NTFSAccessLiveBatch"
REQUEST_ROOT="$STAGE_ROOT/requests"
STAGE_SCRIPTS="$STAGE_ROOT/scripts"
SUPPORT_INSTALL_ROOT="$STAGE_ROOT/support-install"
SUPPORT_INSTALL_SCRIPTS="$SUPPORT_INSTALL_ROOT/scripts"
SUPPORT_INSTALL_LAUNCHDAEMONS="$SUPPORT_INSTALL_ROOT/Packaging/LaunchDaemons"
STAGE_DIST="$STAGE_ROOT/dist"
STAGE_CONFIG="$REQUEST_ROOT/live-job.conf"
DEADLINE_DATE="$(/bin/date +%Y-%m-%d)"
if [[ "$(/bin/date +%H%M)" -ge 0545 ]]; then
  DEADLINE_DATE="$(/bin/date -v+1d +%Y-%m-%d)"
fi

safe_chmod() {
  /bin/chmod "$@" 2>/dev/null || true
}

mkdir -p "$STAGE_SCRIPTS" "$SUPPORT_INSTALL_SCRIPTS" "$SUPPORT_INSTALL_LAUNCHDAEMONS" "$STAGE_DIST" "$REQUEST_ROOT" "$STAGE_ROOT/logs"

/usr/bin/ditto --noqtn "$REPO_ROOT/dist/NTFSAccess-installer.pkg" "$STAGE_DIST/NTFSAccess-installer.pkg"

for script in \
  live_job_runner.sh \
  stage_live_multi_device_admin_batch.sh \
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
  /usr/bin/ditto --noqtn "$SCRIPT_DIR/$script" "$STAGE_SCRIPTS/$script"
  /usr/bin/ditto --noqtn "$SCRIPT_DIR/$script" "$SUPPORT_INSTALL_SCRIPTS/$script"
  /bin/chmod 755 "$STAGE_SCRIPTS/$script"
  /bin/chmod 755 "$SUPPORT_INSTALL_SCRIPTS/$script"
done

/usr/bin/ditto --noqtn "$SCRIPT_DIR/install_live_job_support.sh" "$SUPPORT_INSTALL_SCRIPTS/install_live_job_support.sh"
/bin/chmod 755 "$SUPPORT_INSTALL_SCRIPTS/install_live_job_support.sh"
/usr/bin/ditto --noqtn "$REPO_ROOT/Packaging/LaunchDaemons/com.ntfsaccess.livejob.plist" "$SUPPORT_INSTALL_LAUNCHDAEMONS/com.ntfsaccess.livejob.plist"
if [[ -x "$REPO_ROOT/.build/release/ntfsaccessctl" ]]; then
  mkdir -p "$SUPPORT_INSTALL_ROOT/.build/release" "$STAGE_ROOT/bin"
  /usr/bin/ditto --noqtn "$REPO_ROOT/.build/release/ntfsaccessctl" "$SUPPORT_INSTALL_ROOT/.build/release/ntfsaccessctl"
  /usr/bin/ditto --noqtn "$REPO_ROOT/.build/release/ntfsaccessctl" "$STAGE_ROOT/bin/ntfsaccessctl"
  /bin/chmod 755 "$SUPPORT_INSTALL_ROOT/.build/release/ntfsaccessctl" "$STAGE_ROOT/bin/ntfsaccessctl"
fi

if [[ ! -f "$STAGE_CONFIG" ]]; then
  /usr/bin/printf '%s\n' \
    "# NTFS Access live-test job config" \
    "# Keep this file as plain KEY=VALUE lines. The root runner only accepts this allow-list." \
    "SKIP_INSTALL=1" \
    "NTFSACCESS_REMOUNT_CYCLES=12" \
    "NTFSACCESS_SOAK_CYCLES=40" \
    "NTFSACCESS_MULTI_CYCLES=12" \
    "NTFSACCESS_LARGE_FILE_MIB=64" \
    "NTFSACCESS_RANDOM_FILE_COUNT=4" \
    "NTFSACCESS_RANDOM_FILE_MIB=16" \
    "NTFSACCESS_MULTI_SOURCE_MIB=32" \
    > "$STAGE_CONFIG"
fi

safe_chmod 755 "$STAGE_ROOT" "$STAGE_ROOT/logs"
safe_chmod 1777 "$REQUEST_ROOT"
/bin/chmod 644 "$STAGE_CONFIG"
if [[ -f "$REQUEST_ROOT/live-job.trigger" ]]; then
  safe_chmod 644 "$REQUEST_ROOT/live-job.trigger"
fi

printf '%s\n' "Staged NTFS Access live batch at $STAGE_ROOT"
printf '%s\n' "Config file:"
printf '%s\n' "$STAGE_CONFIG"
printf '%s\n' "Dry run:"
printf '%s\n' "/bin/bash '$STAGE_SCRIPTS/run_live_multi_device_admin_batch.sh' --dry-run"
printf '%s\n' "Restart/probe only, preserving the current installed app identity:"
printf '%s\n' "osascript -e 'do shell script \"/bin/bash \" & quoted form of \"$STAGE_SCRIPTS/run_live_multi_device_admin_batch.sh\" & \" --skip-install\" with administrator privileges'"
printf '%s\n' "One-prompt long live job:"
printf '%s\n' "osascript -e 'do shell script \"/bin/bash \" & quoted form of \"/Library/Application Support/NTFSAccess/live_job_runner.sh\" with administrator privileges'"
printf '%s\n' "No-password launchd live job after the live-job daemon is installed:"
printf '%s\n' "/usr/local/bin/ntfsaccessctl stage-live-job --skip-install --start"
printf '%s\n' "Write-heavy user-session validation, after setup/remount is healthy:"
printf '%s\n' "/bin/bash '$STAGE_SCRIPTS/run_live_user_validation_batch.sh' --remount-cycles 12 --soak-cycles 40 --multi-cycles 12"
printf '%s\n' "Guided physical unplug/replug validation:"
printf '%s\n' "/bin/bash '$STAGE_SCRIPTS/live_ntfs_guided_unplug_replug.sh' /dev/diskXsY EXPECTED_VOLUME_NAME"
printf '%s\n' "Guided sleep/wake validation:"
printf '%s\n' "/bin/bash '$STAGE_SCRIPTS/live_ntfs_guided_sleep_wake.sh' /dev/diskXsY EXPECTED_VOLUME_NAME"
printf '%s\n' "Read-only NTFS format variant inventory:"
printf '%s\n' "/bin/bash '$STAGE_SCRIPTS/live_ntfs_format_matrix_probe.sh' --all"
printf '%s\n' "Read/copy-out special NTFS feature fixture probe:"
printf '%s\n' "/bin/bash '$STAGE_SCRIPTS/live_ntfs_special_feature_probe.sh' /Volumes/EXPECTED_VOLUME_NAME"
printf '%s\n' "Deadline-guarded overnight stress, preserving APFS_TOMORROW:"
printf '%s\n' "/bin/bash '$STAGE_SCRIPTS/run_live_deadline_guarded_stress.sh' /dev/disk13s2 HP_NTFS_A /dev/disk13s3 HP_NTFS_B \"$DEADLINE_DATE 05:45:00\""
printf '%s\n' "One-prompt two-physical-drive overnight roundtrip, restoring APFS_TOMORROW before morning:"
printf '%s\n' "osascript -e 'do shell script \"/bin/bash \" & quoted form of \"$STAGE_SCRIPTS/run_live_two_physical_admin_setup.sh\" & \" /dev/disk12 SAMSUNG_NTFS \\\"$DEADLINE_DATE 05:30:00\\\" \\\"$DEADLINE_DATE 05:00:00\\\"\" with administrator privileges'"
printf '%s\n' "Admin run:"
printf '%s\n' "osascript -e 'do shell script \"/bin/bash \" & quoted form of \"$STAGE_SCRIPTS/run_live_multi_device_admin_batch.sh\" with administrator privileges'"
