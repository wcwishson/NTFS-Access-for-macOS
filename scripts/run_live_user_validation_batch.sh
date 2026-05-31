#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
NTFSACCESSCTL="${NTFSACCESSCTL:-/usr/local/bin/ntfsaccessctl}"
STAGE_ROOT="${NTFSACCESS_STAGE_ROOT:-/Users/Shared/NTFSAccessLiveBatch}"
LOG_ROOT="${NTFSACCESS_USER_VALIDATION_LOG_ROOT:-$STAGE_ROOT/logs}"
REMOUNT_CYCLES="${NTFSACCESS_REMOUNT_CYCLES:-12}"
SOAK_CYCLES="${NTFSACCESS_SOAK_CYCLES:-40}"
MULTI_CYCLES="${NTFSACCESS_MULTI_CYCLES:-12}"
STAMP="$(/bin/date +%Y%m%d-%H%M%S)"
ROOT="/tmp/ntfsaccess-live-user-validation-$STAMP"
SUMMARY="$ROOT/summary.txt"
LOG_PATH="$LOG_ROOT/user-validation-$STAMP.log"
LATEST_LOG="$LOG_ROOT/latest-user-validation.log"
VALIDATION_LOCK_DIR="${NTFSACCESS_VALIDATION_LOCK_DIR:-$STAGE_ROOT/.validation.lock}"
VALIDATION_LOCK_PID="$VALIDATION_LOCK_DIR/pid"

FULL_VALIDATOR="$SCRIPT_DIR/live_ntfs_full_validation.sh"
REMOUNT_VALIDATOR="$SCRIPT_DIR/live_ntfs_remount_churn.sh"
MULTI_VALIDATOR="$SCRIPT_DIR/live_ntfs_multi_volume_flow.sh"
SOAK_VALIDATOR="$SCRIPT_DIR/live_ntfs_filesystem_soak.sh"
FINDER_WORKFLOW_VALIDATOR="$SCRIPT_DIR/live_ntfs_finder_workflow_probe.sh"
METADATA_PACKAGE_VALIDATOR="$SCRIPT_DIR/live_ntfs_metadata_package_matrix.sh"
FILENAME_MATRIX_VALIDATOR="$SCRIPT_DIR/live_ntfs_filename_matrix.sh"

declare -a TARGETS=()
FAILURES=0

usage() {
  cat <<'USAGE'
usage: run_live_user_validation_batch.sh [options] [<device:name> ...]

Runs write-heavy NTFS Access validators from the logged-in user session.
This intentionally must not run as root: macOS privacy can block removable
volume writes for root LaunchDaemon descendants even after they drop to a user.

options:
  --remount-cycles N
  --soak-cycles N
  --multi-cycles N
USAGE
}

log() {
  printf '%s\n' "$*"
}

fail() {
  log "ERROR: $*"
  exit 1
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
    fail "Another NTFS Access live validation is already running as pid $existing_pid"
  fi

  log "Removing stale live validation lock"
  /bin/rm -rf "$VALIDATION_LOCK_DIR"
  if ! /bin/mkdir "$VALIDATION_LOCK_DIR" 2>/dev/null; then
    fail "Unable to acquire live validation lock: $VALIDATION_LOCK_DIR"
  fi
  printf '%s\n' "$$" > "$VALIDATION_LOCK_PID"
  trap 'rm -rf "$VALIDATION_LOCK_DIR"' EXIT
}

validate_positive_integer() {
  local label="$1"
  local value="$2"
  if ! [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
    fail "Invalid $label: $value"
  fi
}

require_tool() {
  local tool="$1"
  if [[ ! -x "$tool" ]] && ! /usr/bin/command -v "$tool" >/dev/null 2>&1; then
    fail "missing required tool: $tool"
  fi
}

device_for_spec() {
  local spec="$1"
  printf '%s\n' "${spec%%:*}"
}

name_for_spec() {
  local spec="$1"
  printf '%s\n' "${spec#*:}"
}

device_id_for() {
  local device="$1"
  printf '%s\n' "${device##*/}"
}

mountpoint_for() {
  local device="$1"
  local id
  id="$(device_id_for "$device")"
  "$NTFSACCESSCTL" list-volumes 2>/dev/null | /usr/bin/awk -F '\t' -v id="$id" '$1 == id { print $3; exit }'
}

request_scan() {
  run_with_timeout 120 "$NTFSACCESSCTL" scan-now --wait >/dev/null 2>&1 || true
}

discover_targets() {
  request_scan
  "$NTFSACCESSCTL" list-volumes 2>/dev/null \
    | /usr/bin/awk -F '\t' 'NR > 1 && $2 == "readWrite" && $3 ~ /^\/Volumes\// { print "/dev/" $1 ":" $4 }'
}

direct_user_write_probe() {
  local device="$1"
  local name="$2"
  local mount_point
  local probe_dir
  local marker

  mount_point="$(mountpoint_for "$device")"
  [[ -n "$mount_point" && -d "$mount_point" ]] || fail "no mounted readWrite path for $device ($name)"
  /bin/ls -ldOe@ "$mount_point" >> "$SUMMARY" 2>&1 || true
  /bin/ls "$mount_point" >/dev/null 2>> "$SUMMARY" \
    || fail "signed-in user cannot enter mount root for $device ($name): $mount_point"
  [[ -x "$mount_point" && -w "$mount_point" ]] \
    || fail "signed-in user cannot write mount root for $device ($name): $mount_point"

  probe_dir="$mount_point/NTFSAccess_user_write_probe_$STAMP"
  marker="$probe_dir/marker.txt"
  /bin/mkdir -p "$probe_dir"
  printf 'user-write-probe %s %s\n' "$device" "$STAMP" > "$marker"
  /usr/bin/grep -q "$STAMP" "$marker" || fail "direct user write probe could not read back $marker"
  /bin/rm -rf "$probe_dir"
  log "direct user write probe passed for $device ($name) at $mount_point"
}

run_validator_allow_fail() {
  log ""
  log "== user validator $* =="
  if "$@"; then
    log "[exit 0]"
  else
    local status=$?
    FAILURES=$((FAILURES + 1))
    log "[exit $status]"
  fi
}

run_validator_stop_on_fail() {
  log ""
  log "== user validator $* =="
  if "$@"; then
    log "[exit 0]"
    return 0
  fi

  local status=$?
  FAILURES=$((FAILURES + 1))
  log "[exit $status]"
  log "STOP: destructive validator failed; stopping this batch to avoid cascading stale mount state"
  return "$status"
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --remount-cycles)
      [[ "$#" -ge 2 ]] || fail "Missing value after --remount-cycles"
      REMOUNT_CYCLES="$2"
      shift 2
      ;;
    --soak-cycles)
      [[ "$#" -ge 2 ]] || fail "Missing value after --soak-cycles"
      SOAK_CYCLES="$2"
      shift 2
      ;;
    --multi-cycles)
      [[ "$#" -ge 2 ]] || fail "Missing value after --multi-cycles"
      MULTI_CYCLES="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --*)
      fail "Unknown option: $1"
      ;;
    *)
      TARGETS+=("$1")
      shift
      ;;
  esac
done

if [[ "$EUID" -eq 0 ]]; then
  fail "run_live_user_validation_batch.sh must run as the logged-in user, not root"
fi

validate_positive_integer "NTFSACCESS_REMOUNT_CYCLES" "$REMOUNT_CYCLES"
validate_positive_integer "NTFSACCESS_SOAK_CYCLES" "$SOAK_CYCLES"
validate_positive_integer "NTFSACCESS_MULTI_CYCLES" "$MULTI_CYCLES"

require_tool "$NTFSACCESSCTL"
for validator in "$FULL_VALIDATOR" "$REMOUNT_VALIDATOR" "$MULTI_VALIDATOR" "$SOAK_VALIDATOR" "$FINDER_WORKFLOW_VALIDATOR" "$METADATA_PACKAGE_VALIDATOR" "$FILENAME_MATRIX_VALIDATOR"; do
  [[ -x "$validator" ]] || fail "validator not executable: $validator"
done

take_validation_lock

/bin/mkdir -p "$ROOT" "$LOG_ROOT"
: > "$SUMMARY"
: > "$LOG_PATH"
/bin/ln -sf "$LOG_PATH" "$LATEST_LOG" 2>/dev/null || true
exec > >(/usr/bin/tee -a "$SUMMARY" "$LOG_PATH") 2>&1

if [[ "${#TARGETS[@]}" -eq 0 ]]; then
  while IFS= read -r target; do
    [[ -n "$target" ]] || continue
    TARGETS+=("$target")
  done < <(discover_targets)
fi

log "NTFS Access live user validation batch"
log "scriptDir=$SCRIPT_DIR"
log "summary=$SUMMARY"
log "log=$LOG_PATH"
log "user=$(/usr/bin/id -un) uid=$EUID"
log "remountCycles=$REMOUNT_CYCLES"
log "soakCycles=$SOAK_CYCLES"
log "multiCycles=$MULTI_CYCLES"

if [[ "${#TARGETS[@]}" -eq 0 ]]; then
  log "No readWrite NTFS Access volumes found."
  "$NTFSACCESSCTL" list-volumes || true
  exit 75
fi

request_scan

for target in "${TARGETS[@]}"; do
  log "target=$target"
  direct_user_write_probe "$(device_for_spec "$target")" "$(name_for_spec "$target")"
done

for target in "${TARGETS[@]}"; do
  device="$(device_for_spec "$target")"
  name="$(name_for_spec "$target")"
  run_validator_stop_on_fail "$FINDER_WORKFLOW_VALIDATOR" "$device" "$name" || break
  run_validator_stop_on_fail "$METADATA_PACKAGE_VALIDATOR" "$device" "$name" || break
  run_validator_stop_on_fail "$FILENAME_MATRIX_VALIDATOR" "$device" "$name" || break
  run_validator_stop_on_fail "$FULL_VALIDATOR" "$device" "$name" || break
  run_validator_stop_on_fail "$REMOUNT_VALIDATOR" "$device" "$name" "$REMOUNT_CYCLES" || break
  run_validator_stop_on_fail "$SOAK_VALIDATOR" "$device" "$name" "$SOAK_CYCLES" || break
done

if [[ "$FAILURES" -eq 0 && "${#TARGETS[@]}" -ge 2 ]]; then
  run_validator_allow_fail "$MULTI_VALIDATOR" \
    "$(device_for_spec "${TARGETS[0]}")" "$(name_for_spec "${TARGETS[0]}")" \
    "$(device_for_spec "${TARGETS[1]}")" "$(name_for_spec "${TARGETS[1]}")" \
    "$MULTI_CYCLES"
elif [[ "$FAILURES" -ne 0 ]]; then
  log "SKIP two-volume flow: an earlier destructive validator failed"
else
  log "SKIP two-volume flow: fewer than two readWrite NTFS Access volumes"
fi

log ""
if [[ "$FAILURES" -eq 0 ]]; then
  log "PASS"
  log "summary=$SUMMARY"
  log "log=$LOG_PATH"
  exit 0
fi

log "FAILURES=$FAILURES"
log "summary=$SUMMARY"
log "log=$LOG_PATH"
exit 1
