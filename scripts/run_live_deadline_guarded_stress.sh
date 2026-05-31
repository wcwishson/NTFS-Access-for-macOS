#!/bin/bash
set -euo pipefail

DEVICE_A="${1:-/dev/disk13s2}"
NAME_A="${2:-HP_NTFS_A}"
DEVICE_B="${3:-/dev/disk13s3}"
NAME_B="${4:-HP_NTFS_B}"
DEADLINE="${5:-${NTFSACCESS_DEADLINE:-}}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
NTFSACCESSCTL="${NTFSACCESSCTL:-/usr/local/bin/ntfsaccessctl}"
LOG_ROOT="${NTFSACCESS_DEADLINE_LOG_ROOT:-/Users/Shared/NTFSAccessLiveBatch/logs}"
STAMP="$(/bin/date +%Y%m%d-%H%M%S)"
LOG_PATH="$LOG_ROOT/deadline-stress-$STAMP.log"
LATEST_LOG="$LOG_ROOT/latest-deadline-stress.log"
STOP_BUFFER_SECONDS="${NTFSACCESS_STOP_BUFFER_SECONDS:-900}"

OVERNIGHT_VALIDATOR="$SCRIPT_DIR/live_ntfs_overnight_stress.sh"
MULTI_VALIDATOR="$SCRIPT_DIR/live_ntfs_multi_volume_flow.sh"
ROUND=0

usage() {
  cat <<'USAGE'
usage: run_live_deadline_guarded_stress.sh <device-a> <name-a> <device-b> <name-b> "YYYY-MM-DD HH:MM:SS"

Runs small NTFS Access stress chunks until the deadline approaches. This must
run as the logged-in user, not root, so macOS privacy treats file operations
like normal Finder/user writes. Use a deadline before the real handoff time.
USAGE
}

log() {
  printf '%s\n' "$*"
}

fail() {
  log "ERROR: $*"
  exit 1
}

require_tool() {
  local tool="$1"
  if [[ ! -x "$tool" ]] && ! /usr/bin/command -v "$tool" >/dev/null 2>&1; then
    fail "missing required tool: $tool"
  fi
}

deadline_epoch() {
  /bin/date -j -f '%Y-%m-%d %H:%M:%S' "$DEADLINE" '+%s'
}

now_epoch() {
  /bin/date '+%s'
}

seconds_left() {
  local deadline_now
  deadline_now="$(deadline_epoch)"
  printf '%s\n' "$((deadline_now - $(now_epoch)))"
}

mountpoint_for() {
  local device="$1"
  local id="${device##*/}"
  "$NTFSACCESSCTL" list-volumes 2>/dev/null | /usr/bin/awk -F '\t' -v id="$id" '$1 == id { print $3; exit }'
}

assert_targets_ready() {
  local volumes
  volumes="$("$NTFSACCESSCTL" list-volumes)"
  log "$volumes"
  /usr/bin/printf '%s\n' "$volumes" | /usr/bin/awk -F '\t' -v id="${DEVICE_A##*/}" -v name="$NAME_A" '$1 == id && $2 == "readWrite" && $4 == name { found = 1 } END { exit found ? 0 : 1 }' \
    || fail "$DEVICE_A $NAME_A is not readWrite"
  /usr/bin/printf '%s\n' "$volumes" | /usr/bin/awk -F '\t' -v id="${DEVICE_B##*/}" -v name="$NAME_B" '$1 == id && $2 == "readWrite" && $4 == name { found = 1 } END { exit found ? 0 : 1 }' \
    || fail "$DEVICE_B $NAME_B is not readWrite"
}

log_disk_state() {
  log ""
  log "--- disk state $(/bin/date '+%Y-%m-%d %H:%M:%S') ---"
  /usr/sbin/diskutil list external physical || true
  "$NTFSACCESSCTL" status || true
  "$NTFSACCESSCTL" list-volumes || true
  /sbin/mount | /usr/bin/grep -Ei 'NTFSAccess|macfuse|APFS_TOMORROW|disk13|disk12' || true
}

purge_transient_test_dirs() {
  local mount_point
  for mount_point in "$(mountpoint_for "$DEVICE_A")" "$(mountpoint_for "$DEVICE_B")"; do
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

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

if [[ "$EUID" -eq 0 ]]; then
  fail "run_live_deadline_guarded_stress.sh must run as the logged-in user, not root"
fi
if [[ -z "$DEADLINE" ]]; then
  usage
  fail "deadline is required"
fi
if ! [[ "$STOP_BUFFER_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
  fail "NTFSACCESS_STOP_BUFFER_SECONDS must be a positive whole number"
fi

require_tool "$NTFSACCESSCTL"
require_tool /usr/sbin/diskutil
require_tool /bin/date
[[ -x "$OVERNIGHT_VALIDATOR" ]] || fail "missing validator: $OVERNIGHT_VALIDATOR"
[[ -x "$MULTI_VALIDATOR" ]] || fail "missing validator: $MULTI_VALIDATOR"
deadline_epoch >/dev/null || fail "deadline must use YYYY-MM-DD HH:MM:SS"

/bin/mkdir -p "$LOG_ROOT"
: > "$LOG_PATH"
/bin/ln -sf "$LOG_PATH" "$LATEST_LOG" 2>/dev/null || true
exec > >(/usr/bin/tee -a "$LOG_PATH") 2>&1

log "NTFS Access live deadline guarded stress"
log "startedAt=$STAMP"
log "user=$(/usr/bin/id -un) uid=$EUID"
log "deviceA=$DEVICE_A nameA=$NAME_A"
log "deviceB=$DEVICE_B nameB=$NAME_B"
log "deadline=$DEADLINE"
log "stopBufferSeconds=$STOP_BUFFER_SECONDS"
log "apfsTomorrow=$([[ -d /Volumes/APFS_TOMORROW ]] && printf ready || printf missing)"
log "log=$LOG_PATH"

log_disk_state
assert_targets_ready
purge_transient_test_dirs

while deadline_allows_next_chunk; do
  ROUND=$((ROUND + 1))
  log ""
  log "### round=$ROUND ###"
  run_chunk "overnight A round $ROUND" "$OVERNIGHT_VALIDATOR" "$DEVICE_A" "$NAME_A" 1
  deadline_allows_next_chunk || break
  run_chunk "overnight B round $ROUND" "$OVERNIGHT_VALIDATOR" "$DEVICE_B" "$NAME_B" 1
  deadline_allows_next_chunk || break
  run_chunk "multi-volume round $ROUND" "$MULTI_VALIDATOR" "$DEVICE_A" "$NAME_A" "$DEVICE_B" "$NAME_B" 1
done

log ""
log "STOPPED_BEFORE_DEADLINE"
log "roundsCompleted=$ROUND"
log "endedAt=$(/bin/date '+%Y-%m-%d %H:%M:%S')"
log "secondsLeft=$(seconds_left)"
log "log=$LOG_PATH"
