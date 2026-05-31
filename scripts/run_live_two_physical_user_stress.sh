#!/bin/bash
set -euo pipefail

TARGET_A="${1:?usage: run_live_two_physical_user_stress.sh <device-a:name-a> <device-b:name-b> [device-c:name-c] <deadline>}"
TARGET_B="${2:?usage: run_live_two_physical_user_stress.sh <device-a:name-a> <device-b:name-b> [device-c:name-c] <deadline>}"
if [[ "$#" -ge 4 ]]; then
  TARGET_C="${3:-}"
  DEADLINE="${4:-}"
else
  TARGET_C=""
  DEADLINE="${3:-}"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
NTFSACCESSCTL="${NTFSACCESSCTL:-/usr/local/bin/ntfsaccessctl}"
STAGE_ROOT="${NTFSACCESS_STAGE_ROOT:-/Users/Shared/NTFSAccessLiveBatch}"
LOG_ROOT="${NTFSACCESS_TWO_PHYSICAL_LOG_ROOT:-$STAGE_ROOT/logs}"
STOP_FILE="${NTFSACCESS_STOP_FILE:-$STAGE_ROOT/two-physical.stop}"
STOP_BUFFER_SECONDS="${NTFSACCESS_STOP_BUFFER_SECONDS:-1800}"
STAMP="$(/bin/date +%Y%m%d-%H%M%S)"
LOG_PATH="$LOG_ROOT/two-physical-user-stress-$STAMP.log"
LATEST_LOG="$LOG_ROOT/latest-two-physical-user-stress.log"
OVERNIGHT_VALIDATOR="$SCRIPT_DIR/live_ntfs_overnight_stress.sh"
MULTI_VALIDATOR="$SCRIPT_DIR/live_ntfs_multi_volume_flow.sh"
ROUND=0
cd /tmp

log() {
  printf '%s\n' "$*"
}

fail() {
  log "ERROR: $*"
  exit 1
}

device_for_spec() {
  printf '%s\n' "${1%%:*}"
}

name_for_spec() {
  printf '%s\n' "${1#*:}"
}

deadline_epoch() {
  /bin/date -j -f '%Y-%m-%d %H:%M:%S' "$DEADLINE" '+%s'
}

now_epoch() {
  /bin/date '+%s'
}

seconds_left() {
  printf '%s\n' "$(( $(deadline_epoch) - $(now_epoch) ))"
}

require_tool() {
  local tool="$1"
  if [[ ! -x "$tool" ]] && ! /usr/bin/command -v "$tool" >/dev/null 2>&1; then
    fail "missing required tool: $tool"
  fi
}

mountpoint_for() {
  local device="$1"
  local id="${device##*/}"
  "$NTFSACCESSCTL" list-volumes 2>/dev/null | /usr/bin/awk -F '\t' -v id="$id" '$1 == id { print $3; exit }'
}

assert_target_ready() {
  local spec="$1"
  local device name id volumes
  device="$(device_for_spec "$spec")"
  name="$(name_for_spec "$spec")"
  id="${device##*/}"
  volumes="$("$NTFSACCESSCTL" list-volumes)"
  /usr/bin/printf '%s\n' "$volumes" | /usr/bin/awk -F '\t' -v id="$id" -v name="$name" '$1 == id && $2 == "readWrite" && $4 == name { found = 1 } END { exit found ? 0 : 1 }' \
    || fail "$device $name is not readWrite"
}

log_disk_state() {
  log ""
  log "--- disk state $(/bin/date '+%Y-%m-%d %H:%M:%S') ---"
  /usr/sbin/diskutil list external physical || true
  "$NTFSACCESSCTL" status || true
  "$NTFSACCESSCTL" list-volumes || true
  /sbin/mount | /usr/bin/grep -Ei 'NTFSAccess|macfuse|HP_NTFS|SAMSUNG_NTFS|APFS_TOMORROW|disk12|disk13' || true
}

purge_transient_test_dirs() {
  local spec mount_point
  for spec in "$TARGET_A" "$TARGET_B" ${TARGET_C:+"$TARGET_C"}; do
    mount_point="$(mountpoint_for "$(device_for_spec "$spec")")"
    [[ -n "$mount_point" && -d "$mount_point" ]] || continue
    /bin/rm -rf \
      "$mount_point"/multi-flow-* \
      "$mount_point"/NTFSAccess_user_write_probe_* \
      "$mount_point"/NTFSAccess_overnight_* \
      "$mount_point"/NTFSAccess_filesystem_soak_* \
      "$mount_point"/NTFSAccess_remount_churn_* \
      >/dev/null 2>&1 || true
  done
  /bin/sync
}

deadline_allows_next_chunk() {
  local left
  left="$(seconds_left)"
  if [[ -f "$STOP_FILE" ]]; then
    log "stop file observed: $STOP_FILE"
    return 1
  fi
  if [[ "$left" -le "$STOP_BUFFER_SECONDS" ]]; then
    log "deadline guard stopping: ${left}s left <= buffer ${STOP_BUFFER_SECONDS}s"
    return 1
  fi
  return 0
}

run_chunk() {
  local label="$1"
  shift
  log ""
  log "== $label =="
  log "secondsLeft=$(seconds_left)"
  "$@"
  log "== $label passed =="
  log_disk_state
  purge_transient_test_dirs
}

run_pair_flow() {
  local label="$1"
  local left="$2"
  local right="$3"
  run_chunk "$label" "$MULTI_VALIDATOR" \
    "$(device_for_spec "$left")" "$(name_for_spec "$left")" \
    "$(device_for_spec "$right")" "$(name_for_spec "$right")" \
    1
}

if [[ "$EUID" -eq 0 ]]; then
  fail "run_live_two_physical_user_stress.sh must run as the logged-in user"
fi
if [[ -z "$DEADLINE" ]]; then
  fail "deadline is required"
fi
if ! [[ "$STOP_BUFFER_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
  fail "NTFSACCESS_STOP_BUFFER_SECONDS must be a positive whole number"
fi

require_tool "$NTFSACCESSCTL"
require_tool /usr/sbin/diskutil
[[ -x "$OVERNIGHT_VALIDATOR" ]] || fail "missing validator: $OVERNIGHT_VALIDATOR"
[[ -x "$MULTI_VALIDATOR" ]] || fail "missing validator: $MULTI_VALIDATOR"
deadline_epoch >/dev/null || fail "deadline must use YYYY-MM-DD HH:MM:SS"

/bin/mkdir -p "$LOG_ROOT"
: > "$LOG_PATH"
/bin/ln -sf "$LOG_PATH" "$LATEST_LOG" 2>/dev/null || true
exec > >(/usr/bin/tee -a "$LOG_PATH") 2>&1

log "NTFS Access two-physical user stress"
log "targetA=$TARGET_A"
log "targetB=$TARGET_B"
log "targetC=$TARGET_C"
log "deadline=$DEADLINE"
log "stopFile=$STOP_FILE"
log "stopBufferSeconds=$STOP_BUFFER_SECONDS"
log "log=$LOG_PATH"

rm -f "$STOP_FILE" 2>/dev/null || true
log_disk_state
assert_target_ready "$TARGET_A"
assert_target_ready "$TARGET_B"
if [[ -n "$TARGET_C" ]]; then
  assert_target_ready "$TARGET_C"
fi

purge_transient_test_dirs

while deadline_allows_next_chunk; do
  ROUND=$((ROUND + 1))
  log ""
  log "### round=$ROUND ###"

  run_chunk "overnight A round $ROUND" "$OVERNIGHT_VALIDATOR" "$(device_for_spec "$TARGET_A")" "$(name_for_spec "$TARGET_A")" 1
  deadline_allows_next_chunk || break

  run_chunk "overnight B round $ROUND" "$OVERNIGHT_VALIDATOR" "$(device_for_spec "$TARGET_B")" "$(name_for_spec "$TARGET_B")" 1
  deadline_allows_next_chunk || break

  if [[ -n "$TARGET_C" ]]; then
    run_chunk "overnight C round $ROUND" "$OVERNIGHT_VALIDATOR" "$(device_for_spec "$TARGET_C")" "$(name_for_spec "$TARGET_C")" 1
    deadline_allows_next_chunk || break
  fi

  run_pair_flow "pair A-B round $ROUND" "$TARGET_A" "$TARGET_B"
  deadline_allows_next_chunk || break

  if [[ -n "$TARGET_C" ]]; then
    run_pair_flow "pair A-C round $ROUND" "$TARGET_A" "$TARGET_C"
    deadline_allows_next_chunk || break
    run_pair_flow "pair B-C round $ROUND" "$TARGET_B" "$TARGET_C"
  fi
done

log ""
log "STOPPED_BEFORE_DEADLINE"
log "roundsCompleted=$ROUND"
log "endedAt=$(/bin/date '+%Y-%m-%d %H:%M:%S')"
log "secondsLeft=$(seconds_left)"
log "log=$LOG_PATH"
