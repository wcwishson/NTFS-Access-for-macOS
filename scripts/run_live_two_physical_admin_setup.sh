#!/bin/bash
set -euo pipefail

TARGET_DISK="${1:-/dev/disk12}"
NTFS_NAME="${2:-SAMSUNG_NTFS}"
RESTORE_DEADLINE="${3:-${NTFSACCESS_APFS_RESTORE_DEADLINE:-}}"
USER_STRESS_DEADLINE="${4:-${NTFSACCESS_USER_STRESS_DEADLINE:-}}"
HP_A_SPEC="${NTFSACCESS_HP_A_SPEC:-/dev/disk13s2:HP_NTFS_A}"
HP_B_SPEC="${NTFSACCESS_HP_B_SPEC:-/dev/disk13s3:HP_NTFS_B}"
APFS_NAME="${NTFSACCESS_APFS_NAME:-APFS_TOMORROW}"
STAGE_ROOT="${NTFSACCESS_STAGE_ROOT:-/Users/Shared/NTFSAccessLiveBatch}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
LOG_ROOT="${NTFSACCESS_TWO_PHYSICAL_LOG_ROOT:-$STAGE_ROOT/logs}"
STOP_FILE="${NTFSACCESS_STOP_FILE:-$STAGE_ROOT/two-physical.stop}"
NTFSACCESSCTL="${NTFSACCESSCTL:-/usr/local/bin/ntfsaccessctl}"
STAMP="$(/bin/date +%Y%m%d-%H%M%S)"
LOG_PATH="$LOG_ROOT/two-physical-admin-setup-$STAMP.log"
LATEST_LOG="$LOG_ROOT/latest-two-physical-admin-setup.log"
RESTORE_GUARD="$SCRIPT_DIR/run_live_apfs_restore_guard.sh"
USER_STRESS="$SCRIPT_DIR/run_live_two_physical_user_stress.sh"
EXPECTED_MIN_SIZE="${NTFSACCESS_TARGET_MIN_SIZE:-100000000000}"
EXPECTED_MAX_SIZE="${NTFSACCESS_TARGET_MAX_SIZE:-160000000000}"
EXPECTED_MEDIA_REGEX="${NTFSACCESS_TARGET_MEDIA_REGEX:-Flash Drive FIT|Samsung Flash Drive FIT}"
CONSOLE_USER="$(/usr/bin/stat -f '%Su' /dev/console)"
CONSOLE_UID="$(/usr/bin/stat -f '%u' /dev/console)"
RESTORE_PID=""

log() {
  printf '%s\n' "$*"
}

fail() {
  log "ERROR: $*"
  exit 1
}

run_with_timeout() {
  local seconds="$1"
  shift
  local pid
  local waited=0
  "$@" &
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

plist_value() {
  local key="$1"
  local file="$2"
  /usr/libexec/PlistBuddy -c "Print :$key" "$file" 2>/dev/null || true
}

assert_whole_disk_identity() {
  local disk="$1"
  local plist="$LOG_ROOT/setup-identity-${disk##*/}-$STAMP.plist"
  /usr/sbin/diskutil info -plist "$disk" > "$plist"

  local whole internal writable size media registry
  whole="$(plist_value WholeDisk "$plist")"
  internal="$(plist_value Internal "$plist")"
  writable="$(plist_value WritableMedia "$plist")"
  size="$(plist_value TotalSize "$plist")"
  media="$(plist_value MediaName "$plist")"
  registry="$(plist_value IORegistryEntryName "$plist")"

  [[ "$whole" == "true" || "$whole" == "1" ]] || fail "$disk is not a whole disk"
  [[ "$internal" == "false" || "$internal" == "0" ]] || fail "$disk is internal; refusing"
  [[ "$writable" == "true" || "$writable" == "1" ]] || fail "$disk is not writable media"
  [[ "$size" =~ ^[0-9]+$ ]] || fail "could not read target disk size"
  [[ "$size" -ge "$EXPECTED_MIN_SIZE" && "$size" -le "$EXPECTED_MAX_SIZE" ]] || fail "$disk size $size does not match expected sacrificial 128GB range"
  if ! /usr/bin/printf '%s\n%s\n' "$media" "$registry" | /usr/bin/grep -Eq "$EXPECTED_MEDIA_REGEX"; then
    fail "$disk media identity mismatch: media=$media registry=$registry"
  fi
}

find_ntfs_partition() {
  /usr/sbin/diskutil list "$TARGET_DISK" \
    | /usr/bin/awk '/Microsoft Basic Data|Windows_NTFS|NTFS Access/ { print "/dev/" $NF }' \
    | /usr/bin/head -1
}

wait_for_readwrite() {
  local device="$1"
  local name="$2"
  local id="${device##*/}"
  local attempt
  for attempt in $(/usr/bin/jot 60); do
    "$NTFSACCESSCTL" scan-now >/dev/null 2>&1 || true
    if "$NTFSACCESSCTL" list-volumes 2>/dev/null | /usr/bin/awk -F '\t' -v id="$id" -v name="$name" '$1 == id && $2 == "readWrite" && $4 == name { found = 1 } END { exit found ? 0 : 1 }'; then
      log "$device $name is readWrite"
      return 0
    fi
    /bin/sleep 4
  done
  "$NTFSACCESSCTL" list-volumes || true
  fail "$device $name did not become readWrite"
}

start_restore_guard() {
  /bin/bash "$RESTORE_GUARD" "$TARGET_DISK" "$APFS_NAME" "$RESTORE_DEADLINE" \
    >> "$LOG_ROOT/restore-guard-launch-$STAMP.log" 2>&1 &
  RESTORE_PID=$!
  log "restoreGuardPid=$RESTORE_PID"
  /bin/sleep 2
  if ! /bin/kill -0 "$RESTORE_PID" >/dev/null 2>&1; then
    fail "restore guard failed to stay running"
  fi
}

run_user_stress() {
  local samsung_spec="$1"
  cd "$STAGE_ROOT"
  NTFSACCESS_STOP_BUFFER_SECONDS="${NTFSACCESS_STOP_BUFFER_SECONDS:-1800}" \
  NTFSACCESS_STOP_FILE="$STOP_FILE" \
  /bin/launchctl asuser "$CONSOLE_UID" /usr/bin/sudo -u "$CONSOLE_USER" \
    /bin/bash "$USER_STRESS" "$HP_A_SPEC" "$HP_B_SPEC" "$samsung_spec" "$USER_STRESS_DEADLINE"
}

usage() {
  cat <<'USAGE'
usage: run_live_two_physical_admin_setup.sh <target-whole-disk> <ntfs-name> <restore-deadline> <user-stress-deadline>

Runs as root. It confirms the sacrificial whole disk identity, erases it to
NTFS Access, starts a root APFS restore guard, then runs write-heavy stress as
the logged-in user.
USAGE
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

if [[ "$EUID" -ne 0 ]]; then
  fail "run_live_two_physical_admin_setup.sh must run as root"
fi
if [[ -z "$RESTORE_DEADLINE" || -z "$USER_STRESS_DEADLINE" ]]; then
  usage
  fail "restore and user-stress deadlines are required"
fi
[[ -x "$RESTORE_GUARD" ]] || fail "missing restore guard: $RESTORE_GUARD"
[[ -x "$USER_STRESS" ]] || fail "missing user stress: $USER_STRESS"

/bin/mkdir -p "$LOG_ROOT"
: > "$LOG_PATH"
/bin/ln -sf "$LOG_PATH" "$LATEST_LOG" 2>/dev/null || true
exec > >(/usr/bin/tee -a "$LOG_PATH") 2>&1

log "NTFS Access two-physical admin setup"
log "targetDisk=$TARGET_DISK"
log "ntfsName=$NTFS_NAME"
log "restoreDeadline=$RESTORE_DEADLINE"
log "userStressDeadline=$USER_STRESS_DEADLINE"
log "consoleUser=$CONSOLE_USER uid=$CONSOLE_UID"
log "hpA=$HP_A_SPEC"
log "hpB=$HP_B_SPEC"
log "stopFile=$STOP_FILE"
log "log=$LOG_PATH"

rm -f "$STOP_FILE" 2>/dev/null || true
assert_whole_disk_identity "$TARGET_DISK"
/usr/sbin/diskutil list external physical || true
start_restore_guard

log ""
log "--- erasing sacrificial disk to NTFS Access ---"
run_with_timeout 60 /usr/sbin/diskutil unmountDisk force "$TARGET_DISK" >/dev/null 2>&1 || true
/usr/sbin/diskutil eraseDisk "NTFS Access" "$NTFS_NAME" GPT "$TARGET_DISK"
run_with_timeout 30 /usr/sbin/diskutil unmountDisk force "$TARGET_DISK" >/dev/null 2>&1 || true

log ""
log "--- waiting for NTFS Access mount ---"
"$NTFSACCESSCTL" scan-now >/dev/null 2>&1 || true
ntfs_partition="$(find_ntfs_partition)"
[[ -n "$ntfs_partition" ]] || fail "could not find NTFS partition on $TARGET_DISK after erase"
wait_for_readwrite "$ntfs_partition" "$NTFS_NAME"

log ""
log "--- running user-session two-physical stress ---"
if run_user_stress "$ntfs_partition:$NTFS_NAME"; then
  stress_status=0
else
  stress_status=$?
fi
log "userStressExit=$stress_status"

log ""
log "--- waiting for restore guard ---"
if [[ -n "$RESTORE_PID" ]]; then
  wait "$RESTORE_PID"
fi

log "DONE"
exit "$stress_status"
