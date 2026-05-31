#!/bin/bash
set -euo pipefail

SKIP_INSTALL=0
RUN_WRITE_VALIDATORS=0
if [[ "${1:-}" == "--skip-install" ]]; then
  SKIP_INSTALL=1
  shift
fi
if [[ "${1:-}" == "--run-write-validators" ]]; then
  RUN_WRITE_VALIDATORS=1
  shift
fi

PKG_PATH="${1:?usage: live_multi_device_admin_batch.sh [--skip-install] [--run-write-validators] <pkg-path> <repo-root> <device:name> [device:name ...]}"
REPO_ROOT="${2:?usage: live_multi_device_admin_batch.sh [--skip-install] [--run-write-validators] <pkg-path> <repo-root> <device:name> [device:name ...]}"
shift 2

if [[ "$#" -lt 1 ]]; then
  echo "usage: live_multi_device_admin_batch.sh [--skip-install] [--run-write-validators] <pkg-path> <repo-root> <device:name> [device:name ...]" >&2
  exit 64
fi

STAMP="$(/bin/date +%Y%m%d-%H%M%S)"
ROOT="/tmp/ntfsaccess-live-multi-admin-$STAMP"
SUMMARY="$ROOT/summary.txt"
CONSOLE_USER="$(/usr/bin/stat -f '%Su' /dev/console)"
CONSOLE_UID="$(/usr/bin/stat -f '%u' /dev/console)"
NTFSACCESSCTL="/usr/local/bin/ntfsaccessctl"
APP_PATH="/Applications/NTFS Access.app"
DAEMON_PLIST="/Library/LaunchDaemons/com.ntfsaccess.mountd.plist"
LIVEJOB_PLIST="/Library/LaunchDaemons/com.ntfsaccess.livejob.plist"
AGENT_PLIST="/Library/LaunchAgents/com.ntfsaccess.menu.plist"
FILESYSTEM_BUNDLE="/Library/Filesystems/ntfsaccess.fs"
TOOLCHAIN_ROOT="/Library/NTFSAccess"
REMOUNT_CYCLES="${NTFSACCESS_REMOUNT_CYCLES:-8}"
SOAK_CYCLES="${NTFSACCESS_SOAK_CYCLES:-20}"
MULTI_CYCLES="${NTFSACCESS_MULTI_CYCLES:-8}"
VALIDATION_LOCK_DIR="${NTFSACCESS_VALIDATION_LOCK_DIR:-/Users/Shared/NTFSAccessLiveBatch/.validation.lock}"
VALIDATION_LOCK_PID="$VALIDATION_LOCK_DIR/pid"
FAILURES=0
FAILED_VALIDATORS=()
READWRITE_TARGET_COUNT=0
READWRITE_TARGETS=()
BLOCKED_TARGETS=()

FULL_VALIDATOR="$REPO_ROOT/scripts/live_ntfs_full_validation.sh"
REMOUNT_VALIDATOR="$REPO_ROOT/scripts/live_ntfs_remount_churn.sh"
MULTI_VALIDATOR="$REPO_ROOT/scripts/live_ntfs_multi_volume_flow.sh"
SOAK_VALIDATOR="$REPO_ROOT/scripts/live_ntfs_filesystem_soak.sh"
FINDER_WORKFLOW_VALIDATOR="$REPO_ROOT/scripts/live_ntfs_finder_workflow_probe.sh"
METADATA_PACKAGE_VALIDATOR="$REPO_ROOT/scripts/live_ntfs_metadata_package_matrix.sh"
FILENAME_MATRIX_VALIDATOR="$REPO_ROOT/scripts/live_ntfs_filename_matrix.sh"

mkdir -p "$ROOT"
: > "$SUMMARY"

log() {
  printf '%s\n' "$*" | /usr/bin/tee -a "$SUMMARY"
}

run() {
  log ""
  log "== $* =="
  "$@" >> "$SUMMARY" 2>&1
  local status=$?
  log "[exit $status]"
  return "$status"
}

run_allow_fail() {
  log ""
  log "== $* =="
  local status=$?
  if "$@" >> "$SUMMARY" 2>&1; then
    status=0
  else
    status=$?
  fi
  log "[exit $status]"
  return 0
}

run_in_console_user_gui_session_allow_fail() {
  log ""
  log "== console-user-gui validator ($CONSOLE_USER uid=$CONSOLE_UID) $* =="
  local status=0
  if /bin/launchctl asuser "$CONSOLE_UID" /usr/bin/sudo -u "$CONSOLE_USER" /usr/bin/env \
    NTFSACCESS_LARGE_FILE_MIB="${NTFSACCESS_LARGE_FILE_MIB:-}" \
    NTFSACCESS_RANDOM_FILE_COUNT="${NTFSACCESS_RANDOM_FILE_COUNT:-}" \
    NTFSACCESS_RANDOM_FILE_MIB="${NTFSACCESS_RANDOM_FILE_MIB:-}" \
    NTFSACCESS_MULTI_SOURCE_MIB="${NTFSACCESS_MULTI_SOURCE_MIB:-}" \
    "$@" >> "$SUMMARY" 2>&1; then
    status=0
  else
    status=$?
  fi
  log "[exit $status]"
  return "$status"
}

take_validation_lock() {
  if /bin/mkdir "$VALIDATION_LOCK_DIR" 2>/dev/null; then
    printf '%s\n' "$$" > "$VALIDATION_LOCK_PID"
    trap 'rm -rf "$VALIDATION_LOCK_DIR"' EXIT
    return 0
  fi

  local existing_pid=""
  if [[ -f "$VALIDATION_LOCK_PID" ]]; then
    existing_pid="$(/bin/cat "$VALIDATION_LOCK_PID" 2>/dev/null || true)"
  fi

  if [[ "$existing_pid" =~ ^[0-9]+$ ]] && /bin/kill -0 "$existing_pid" >/dev/null 2>&1; then
    log "Another NTFS Access live validation is already running as pid $existing_pid"
    exit 75
  fi

  log "Removing stale live validation lock"
  /bin/rm -rf "$VALIDATION_LOCK_DIR"
  if ! /bin/mkdir "$VALIDATION_LOCK_DIR" 2>/dev/null; then
    log "Unable to acquire live validation lock: $VALIDATION_LOCK_DIR"
    exit 75
  fi
  printf '%s\n' "$$" > "$VALIDATION_LOCK_PID"
  trap 'rm -rf "$VALIDATION_LOCK_DIR"' EXIT
}

record_validator_failure() {
  local label="$1"
  FAILURES=$((FAILURES + 1))
  FAILED_VALIDATORS+=("$label")
  log "VALIDATOR_FAILED: $label"
}

record_readwrite_target() {
  local device="$1"
  local name="$2"
  local id
  id="$(device_id_for "$device")"

  if is_readwrite "$device"; then
    READWRITE_TARGET_COUNT=$((READWRITE_TARGET_COUNT + 1))
    READWRITE_TARGETS+=("$device:$name")
    log "READWRITE_TARGET: $device ($name)"
    return 0
  fi

  BLOCKED_TARGETS+=("$device:$name")
  log "BLOCKED_RAW_ACCESS_OR_MOUNT: $device ($name) did not become readWrite"
  "$NTFSACCESSCTL" list-volumes 2>/dev/null | /usr/bin/awk -F '\t' -v id="$id" '$1 == id { print "state=" $0 }' >> "$SUMMARY" || true
  return 1
}

assess_readwrite_targets() {
  local spec
  READWRITE_TARGET_COUNT=0
  READWRITE_TARGETS=()
  BLOCKED_TARGETS=()

  for spec in "$@"; do
    record_readwrite_target "$(device_for_spec "$spec")" "$(name_for_spec "$spec")" || true
  done

  if [[ "$READWRITE_TARGET_COUNT" -eq 0 ]]; then
    log "NO_READWRITE_TARGETS"
    record_validator_failure "mount-readwrite:none"
    return 1
  fi

  if [[ "${#BLOCKED_TARGETS[@]}" -gt 0 ]]; then
    for spec in "${BLOCKED_TARGETS[@]}"; do
      record_validator_failure "mount-readwrite:${spec%%:*}"
    done
    return 1
  fi

  return 0
}

run_with_timeout() {
  local seconds="$1"
  shift
  local pid
  local waited=0
  "$@" >> "$SUMMARY" 2>&1 &
  pid=$!

  while /bin/kill -0 "$pid" >/dev/null 2>&1; do
    if [[ "$waited" -ge "$seconds" ]]; then
      log "timeout after ${seconds}s: $*"
      /bin/kill -TERM "$pid" >/dev/null 2>&1 || true
      /bin/sleep 1
      /bin/kill -KILL "$pid" >/dev/null 2>&1 || true
      return 124
    fi
    /bin/sleep 1
    waited=$((waited + 1))
  done

  wait "$pid"
}

run_with_timeout_allow_fail() {
  local seconds="$1"
  shift
  run_with_timeout "$seconds" "$@" || true
}

validate_positive_integer() {
  local label="$1"
  local value="$2"
  if ! [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
    log "Invalid $label: $value"
    exit 64
  fi
}

raw_device_for() {
  local device="$1"
  if [[ "$device" == /dev/disk* ]]; then
    printf '/dev/rdisk%s\n' "${device#/dev/disk}"
  else
    printf '%s\n' "$device"
  fi
}

device_id_for() {
  local device="$1"
  printf '%s\n' "${device##*/}"
}

name_for_spec() {
  local spec="$1"
  printf '%s\n' "${spec#*:}"
}

device_for_spec() {
  local spec="$1"
  printf '%s\n' "${spec%%:*}"
}

stop_existing_menu_app() {
  local menu_binary="/Applications/NTFS Access.app/Contents/MacOS/NTFSMenuApp"
  local pid=""
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    log "Stopping existing NTFSMenuApp process $pid"
    /bin/kill "$pid" >/dev/null 2>&1 || true
  done < <(/usr/bin/pgrep -f "$menu_binary" 2>/dev/null || true)
}

repair_installed_identity_for_daemon() {
  log ""
  log "--- repairing installed app identity for daemon/privacy ---"
  if [[ -d "$APP_PATH" ]]; then
    run_allow_fail /usr/sbin/chown -R root:wheel "$APP_PATH"
    run_allow_fail /bin/chmod -R a+rX "$APP_PATH"
    run_allow_fail /usr/bin/find "$APP_PATH/Contents/MacOS" -type f -maxdepth 1 -exec /bin/chmod 755 {} +
    run_allow_fail /usr/bin/xattr -cr "$APP_PATH"
  fi

  if [[ -d "$FILESYSTEM_BUNDLE" ]]; then
    run_allow_fail /usr/sbin/chown -R root:wheel "$FILESYSTEM_BUNDLE"
    run_allow_fail /bin/chmod -R a+rX "$FILESYSTEM_BUNDLE"
    run_allow_fail /usr/bin/xattr -cr "$FILESYSTEM_BUNDLE"
  fi

  if [[ -d "$TOOLCHAIN_ROOT" ]]; then
    run_allow_fail /usr/sbin/chown -R root:wheel "$TOOLCHAIN_ROOT"
    run_allow_fail /bin/chmod -R a+rX "$TOOLCHAIN_ROOT"
    run_allow_fail /usr/bin/xattr -cr "$TOOLCHAIN_ROOT"
  fi

  if [[ -f "$DAEMON_PLIST" ]]; then
    run_allow_fail /usr/sbin/chown root:wheel "$DAEMON_PLIST"
    run_allow_fail /bin/chmod 644 "$DAEMON_PLIST"
    run_allow_fail /usr/bin/xattr -c "$DAEMON_PLIST"
  fi

  if [[ -f "$LIVEJOB_PLIST" ]]; then
    run_allow_fail /usr/sbin/chown root:wheel "$LIVEJOB_PLIST"
    run_allow_fail /bin/chmod 644 "$LIVEJOB_PLIST"
    run_allow_fail /usr/bin/xattr -c "$LIVEJOB_PLIST"
  fi

  if [[ -f "$AGENT_PLIST" ]]; then
    run_allow_fail /usr/sbin/chown root:wheel "$AGENT_PLIST"
    run_allow_fail /bin/chmod 644 "$AGENT_PLIST"
    run_allow_fail /usr/bin/xattr -c "$AGENT_PLIST"
  fi
}

reload_mount_daemon() {
  log ""
  log "--- reloading mount daemon ---"
  run_with_timeout_allow_fail 20 /bin/launchctl bootout system/com.ntfsaccess.mountd
  if [[ -f "$DAEMON_PLIST" ]]; then
    run_with_timeout_allow_fail 20 /bin/launchctl bootout system "$DAEMON_PLIST"
  fi
  wait_for_mount_daemon_unloaded 30 || return 75

  if [[ -f "$DAEMON_PLIST" ]]; then
    bootstrap_mount_daemon_with_retry || return 75
  else
    log "Mount daemon plist missing: $DAEMON_PLIST"
    return 75
  fi
  run_with_timeout_allow_fail 20 /bin/launchctl enable system/com.ntfsaccess.mountd
  run_with_timeout_allow_fail 20 /bin/launchctl kickstart -k system/com.ntfsaccess.mountd
  run_with_timeout_allow_fail 20 /bin/launchctl print system/com.ntfsaccess.mountd
  wait_for_mount_daemon_ready 45 || return 75
}

wait_for_mount_daemon_unloaded() {
  local seconds="$1"
  local waited=0

  while /bin/launchctl print system/com.ntfsaccess.mountd >/dev/null 2>&1; do
    if [[ "$waited" -ge "$seconds" ]]; then
      log "Mount daemon did not unload within ${seconds}s"
      run_with_timeout_allow_fail 20 /bin/launchctl print system/com.ntfsaccess.mountd
      return 1
    fi
    /bin/sleep 1
    waited=$((waited + 1))
  done
}

bootstrap_mount_daemon_with_retry() {
  local attempt=1
  local max_attempts=5

  while [[ "$attempt" -le "$max_attempts" ]]; do
    log "launchd bootstrap attempt $attempt/$max_attempts for com.ntfsaccess.mountd"
    if run_with_timeout 20 /bin/launchctl bootstrap system "$DAEMON_PLIST"; then
      return 0
    fi

    log "launchd bootstrap attempt $attempt failed; waiting for any stale service state to clear"
    run_with_timeout_allow_fail 20 /bin/launchctl bootout system/com.ntfsaccess.mountd
    run_with_timeout_allow_fail 20 /bin/launchctl bootout system "$DAEMON_PLIST"
    wait_for_mount_daemon_unloaded 10 || true
    /bin/sleep 2
    attempt=$((attempt + 1))
  done

  log "Unable to bootstrap com.ntfsaccess.mountd after $max_attempts attempts"
  return 1
}

wait_for_mount_daemon_ready() {
  local seconds="$1"
  local waited=0

  while [[ "$waited" -lt "$seconds" ]]; do
    if "$NTFSACCESSCTL" status >/tmp/ntfsaccess-mountd-ready.$$ 2>&1; then
      /bin/rm -f /tmp/ntfsaccess-mountd-ready.$$
      return 0
    fi
    /bin/sleep 1
    waited=$((waited + 1))
  done

  log "Mount daemon did not answer XPC status requests within ${seconds}s"
  if [[ -f /tmp/ntfsaccess-mountd-ready.$$ ]]; then
    log "last ntfsaccessctl status output:"
    /bin/cat /tmp/ntfsaccess-mountd-ready.$$ >> "$SUMMARY" 2>&1 || true
    /bin/rm -f /tmp/ntfsaccess-mountd-ready.$$
  fi
  run_with_timeout_allow_fail 20 /bin/launchctl print system/com.ntfsaccess.mountd
  /bin/ps aux | /usr/bin/grep -E 'ntfs-3g|mountd|NTFS Access|NTFSMenuApp' | /usr/bin/grep -v grep >> "$SUMMARY" 2>&1 || true
  return 1
}

stop_stale_ntfs3g_for_device() {
  local id="$1"
  local pid
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    log "Stopping stale ntfs-3g process $pid for $id"
    /bin/kill -TERM "$pid" >/dev/null 2>&1 || true
  done < <(/usr/bin/pgrep -f "ntfs-3g .*${id}" 2>/dev/null || true)

  /bin/sleep 2
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    log "Force-killing stale ntfs-3g process $pid for $id"
    /bin/kill -KILL "$pid" >/dev/null 2>&1 || true
  done < <(/usr/bin/pgrep -f "ntfs-3g .*${id}" 2>/dev/null || true)
}

print_state() {
  local label="$1"
  log ""
  log "--- $label status ---"
  "$NTFSACCESSCTL" status >> "$SUMMARY" 2>&1 || true
  "$NTFSACCESSCTL" list-volumes >> "$SUMMARY" 2>&1 || true
  /usr/sbin/diskutil list external physical >> "$SUMMARY" 2>&1 || true
  /sbin/mount | /usr/bin/grep -Ei 'ntfs|fuse|macfuse|NTFSAccess|HP_NTFS|NTFS_STRESS' >> "$SUMMARY" 2>&1 || true
  /bin/ps aux | /usr/bin/grep -E 'ntfs-3g|mountd|NTFS Access|NTFSMenuApp' | /usr/bin/grep -v grep >> "$SUMMARY" 2>&1 || true
}

is_readwrite() {
  local device="$1"
  local id
  id="$(device_id_for "$device")"
  "$NTFSACCESSCTL" list-volumes 2>/dev/null | /usr/bin/awk -F '\t' -v id="$id" '$1 == id && $2 == "readWrite" { found = 1 } END { exit found ? 0 : 1 }'
}

mountpoint_for() {
  local device="$1"
  local id
  id="$(device_id_for "$device")"
  "$NTFSACCESSCTL" list-volumes 2>/dev/null | /usr/bin/awk -F '\t' -v id="$id" '$1 == id { print $3; exit }'
}

print_installed_identity() {
  log ""
  log "--- installed identity ---"
  run_allow_fail /usr/sbin/pkgutil --pkg-info com.ntfsaccess.pkg.component
  run_allow_fail /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "/Applications/NTFS Access.app/Contents/Info.plist"
  run_allow_fail /usr/bin/codesign -dv --verbose=2 "/Applications/NTFS Access.app"
  run_allow_fail /bin/ls -leO@ "/Applications/NTFS Access.app" "/Applications/NTFS Access.app/Contents/MacOS/NTFSMenuApp" "/Library/Filesystems/ntfsaccess.fs/Contents/Resources/mount_ntfsaccess"
  run_allow_fail /usr/bin/head -20 "/Library/Filesystems/ntfsaccess.fs/Contents/Resources/mount_ntfsaccess"
  run_allow_fail "$NTFSACCESSCTL" doctor
}

probe_raw_access() {
  local device="$1"
  local name="$2"
  local raw
  raw="$(raw_device_for "$device")"

  log ""
  log "--- raw access probe $device $name ---"
  run_allow_fail /usr/sbin/diskutil info "$device"
  run_with_timeout_allow_fail 20 /usr/sbin/diskutil unmount force "$device"
  run_allow_fail /bin/ls -l "$device" "$raw"
  run_allow_fail /bin/dd if="$device" of=/dev/null bs=512 count=1
  run_allow_fail /bin/dd if="$raw" of=/dev/null bs=512 count=1
  run_with_timeout_allow_fail 30 /usr/sbin/diskutil mount readOnly "$device"
}

request_scans() {
  local attempt
  for attempt in 1 2; do
    log "scan attempt $attempt"
    run_with_timeout 120 "$NTFSACCESSCTL" retry-mounts --wait || run_with_timeout 120 "$NTFSACCESSCTL" scan-now --wait || true
    /bin/sleep 4
  done
}

run_writable_validators() {
  local device="$1"
  local name="$2"
  local id
  id="$(device_id_for "$device")"

  if ! is_readwrite "$device"; then
    log "SKIP validators for $device ($name): not readWrite"
    record_validator_failure "validators-skipped-not-readwrite:$id"
    return 1
  fi

  if ! run_in_console_user_gui_session_allow_fail "$FINDER_WORKFLOW_VALIDATOR" "$device" "$name"; then
    record_validator_failure "finder-workflow:$id"
  fi
  if ! run_in_console_user_gui_session_allow_fail "$METADATA_PACKAGE_VALIDATOR" "$device" "$name"; then
    record_validator_failure "metadata-package:$id"
  fi
  if ! run_in_console_user_gui_session_allow_fail "$FILENAME_MATRIX_VALIDATOR" "$device" "$name"; then
    record_validator_failure "filename-matrix:$id"
  fi
  if ! run_in_console_user_gui_session_allow_fail "$FULL_VALIDATOR" "$device" "$name"; then
    record_validator_failure "full-validation:$id"
  fi
  if ! run_in_console_user_gui_session_allow_fail "$REMOUNT_VALIDATOR" "$device" "$name" "$REMOUNT_CYCLES"; then
    record_validator_failure "remount-churn:$id"
  fi
  if ! run_in_console_user_gui_session_allow_fail "$SOAK_VALIDATOR" "$device" "$name" "$SOAK_CYCLES"; then
    record_validator_failure "filesystem-soak:$id"
  fi
  log "validator block completed for $id"
}

run_two_volume_flow_if_possible() {
  local first_spec=""
  local second_spec=""
  local spec

  for spec in "$@"; do
    local device
    device="$(device_for_spec "$spec")"
    if is_readwrite "$device"; then
      if [[ -z "$first_spec" ]]; then
        first_spec="$spec"
      elif [[ -z "$second_spec" ]]; then
        second_spec="$spec"
        break
      fi
    fi
  done

  if [[ -z "$first_spec" || -z "$second_spec" ]]; then
    log "SKIP two-volume flow: fewer than two readWrite NTFS Access volumes"
    return 0
  fi

  if ! run_in_console_user_gui_session_allow_fail "$MULTI_VALIDATOR" \
    "$(device_for_spec "$first_spec")" "$(name_for_spec "$first_spec")" \
    "$(device_for_spec "$second_spec")" "$(name_for_spec "$second_spec")" \
    "$MULTI_CYCLES"; then
    record_validator_failure "multi-volume-flow:$(device_id_for "$(device_for_spec "$first_spec")")-$(device_id_for "$(device_for_spec "$second_spec")")"
  fi
}

log "NTFS Access live multi-device admin batch"
log "pkg=$PKG_PATH"
log "repo=$REPO_ROOT"
log "skipInstall=$SKIP_INSTALL"
log "runWriteValidators=$RUN_WRITE_VALIDATORS"
log "consoleUser=$CONSOLE_USER"
log "summary=$SUMMARY"
log "remountCycles=$REMOUNT_CYCLES"
log "soakCycles=$SOAK_CYCLES"
log "multiCycles=$MULTI_CYCLES"
for spec in "$@"; do
  log "target=$spec"
done

validate_positive_integer "NTFSACCESS_REMOUNT_CYCLES" "$REMOUNT_CYCLES"
validate_positive_integer "NTFSACCESS_SOAK_CYCLES" "$SOAK_CYCLES"
validate_positive_integer "NTFSACCESS_MULTI_CYCLES" "$MULTI_CYCLES"

if [[ "$SKIP_INSTALL" -eq 0 && ! -f "$PKG_PATH" ]]; then
  log "Package not found: $PKG_PATH"
  exit 66
fi

for script in "$FULL_VALIDATOR" "$REMOUNT_VALIDATOR" "$MULTI_VALIDATOR" "$SOAK_VALIDATOR" "$FINDER_WORKFLOW_VALIDATOR" "$METADATA_PACKAGE_VALIDATOR" "$FILENAME_MATRIX_VALIDATOR"; do
  if [[ ! -x "$script" ]]; then
    log "Validator not executable: $script"
    exit 66
  fi
done

print_state "initial"

for spec in "$@"; do
  stop_stale_ntfs3g_for_device "$(device_id_for "$(device_for_spec "$spec")")"
done

log ""
if [[ "$SKIP_INSTALL" -eq 1 ]]; then
  log "--- skipping package install ---"
else
  log "--- installing package ---"
  run /usr/sbin/installer -pkg "$PKG_PATH" -target /
fi

log ""
log "--- restarting services ---"
stop_existing_menu_app
repair_installed_identity_for_daemon
if ! reload_mount_daemon; then
  record_validator_failure "mount-daemon-reload"
  print_state "daemon-reload-failed"
  log "FAILED"
  log "summary=$SUMMARY"
  exit 75
fi
run_with_timeout_allow_fail 20 /bin/launchctl kickstart -k "gui/$CONSOLE_UID/com.ntfsaccess.menu"

request_scans
print_installed_identity
print_state "after-install-scans"

for spec in "$@"; do
  probe_raw_access "$(device_for_spec "$spec")" "$(name_for_spec "$spec")"
done

request_scans
print_state "after-raw-probes"
assess_readwrite_targets "$@" || true

if [[ "$RUN_WRITE_VALIDATORS" -eq 1 ]]; then
  take_validation_lock
  for spec in "$@"; do
    run_writable_validators "$(device_for_spec "$spec")" "$(name_for_spec "$spec")"
    request_scans
  done

  run_two_volume_flow_if_possible "$@"
else
  log "SKIP write-heavy validators in admin/root batch; run scripts/run_live_user_validation_batch.sh as the logged-in user after setup is readWrite."
fi
print_state "final"

log ""
if [[ "$FAILURES" -gt 0 ]]; then
  log "FAILED_VALIDATOR_COUNT=$FAILURES"
  for failed in "${FAILED_VALIDATORS[@]}"; do
    log "failed=$failed"
  done
  log "FAILED"
  log "summary=$SUMMARY"
  exit 75
fi

log "DONE"
log "summary=$SUMMARY"
