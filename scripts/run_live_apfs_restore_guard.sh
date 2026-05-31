#!/bin/bash
set -euo pipefail

TARGET_DISK="${1:-/dev/disk12}"
APFS_NAME="${2:-APFS_TOMORROW}"
DEADLINE="${3:-${NTFSACCESS_APFS_RESTORE_DEADLINE:-}}"
STAGE_ROOT="${NTFSACCESS_STAGE_ROOT:-/Users/Shared/NTFSAccessLiveBatch}"
STOP_FILE="${NTFSACCESS_STOP_FILE:-$STAGE_ROOT/two-physical.stop}"
LOG_ROOT="${NTFSACCESS_RESTORE_LOG_ROOT:-$STAGE_ROOT/logs}"
STAMP="$(/bin/date +%Y%m%d-%H%M%S)"
LOG_PATH="$LOG_ROOT/apfs-restore-guard-$STAMP.log"
LATEST_LOG="$LOG_ROOT/latest-apfs-restore-guard.log"
EXPECTED_MIN_SIZE="${NTFSACCESS_TARGET_MIN_SIZE:-100000000000}"
EXPECTED_MAX_SIZE="${NTFSACCESS_TARGET_MAX_SIZE:-160000000000}"
EXPECTED_MEDIA_REGEX="${NTFSACCESS_TARGET_MEDIA_REGEX:-Flash Drive FIT|Samsung Flash Drive FIT}"
EXPECTED_WHOLE_DISK_ID="${TARGET_DISK##*/}"

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

deadline_epoch() {
  /bin/date -j -f '%Y-%m-%d %H:%M:%S' "$DEADLINE" '+%s'
}

now_epoch() {
  /bin/date '+%s'
}

seconds_until_deadline() {
  printf '%s\n' "$(( $(deadline_epoch) - $(now_epoch) ))"
}

plist_value() {
  local key="$1"
  local file="$2"
  /usr/libexec/PlistBuddy -c "Print :$key" "$file" 2>/dev/null || true
}

assert_whole_disk_identity() {
  local disk="$1"
  local plist="$LOG_ROOT/restore-identity-${disk##*/}-$STAMP.plist"
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

is_already_apfs_tomorrow() {
  apfs_volume_matches_target_disk
}

apfs_volume_matches_target_disk() {
  local mount_point="/Volumes/$APFS_NAME"
  local plist="$LOG_ROOT/apfs-match-${EXPECTED_WHOLE_DISK_ID}-$STAMP.plist"
  local whole_disk
  local volume_name
  local fs_type
  local actual_mount

  [[ -d "$mount_point" ]] || return 1
  /usr/sbin/diskutil info -plist "$mount_point" > "$plist" 2>/dev/null || return 1
  whole_disk="$(plist_value ParentWholeDisk "$plist")"
  volume_name="$(plist_value VolumeName "$plist")"
  fs_type="$(plist_value FilesystemType "$plist")"
  actual_mount="$(plist_value MountPoint "$plist")"

  [[ "$whole_disk" == "$EXPECTED_WHOLE_DISK_ID" ]] || return 1
  [[ "$volume_name" == "$APFS_NAME" ]] || return 1
  [[ "$fs_type" == "apfs" || "$fs_type" == "APFS" ]] || return 1
  [[ "$actual_mount" == "$mount_point" ]] || return 1

  if /sbin/mount | /usr/bin/awk -v target="$EXPECTED_WHOLE_DISK_ID" -v mp="$mount_point" '
    index($1, "/dev/") == 1 && $3 == mp && index($1, target "s") > 0 && index($0, "apfs") > 0 { found = 1 }
    END { exit found ? 0 : 1 }
  '; then
    return 0
  fi

  return 1
}

stop_matching_ntfs_workers() {
  local disk_id="${TARGET_DISK##*/}"
  local pid
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    log "Stopping ntfs-3g worker $pid for $disk_id"
    /bin/kill -TERM "$pid" >/dev/null 2>&1 || true
  done < <(/bin/ps aux | /usr/bin/awk -v disk="$disk_id" '/ntfs-3g/ && index($0, disk) > 0 { print $2 }')

  /bin/sleep 3
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    log "Force-killing ntfs-3g worker $pid for $disk_id"
    /bin/kill -KILL "$pid" >/dev/null 2>&1 || true
  done < <(/bin/ps aux | /usr/bin/awk -v disk="$disk_id" '/ntfs-3g/ && index($0, disk) > 0 { print $2 }')
}

restore_apfs() {
  log ""
  log "--- APFS restore $(/bin/date '+%Y-%m-%d %H:%M:%S') ---"
  assert_whole_disk_identity "$TARGET_DISK"

  if is_already_apfs_tomorrow; then
    log "APFS restore not needed; $APFS_NAME already present"
    return 0
  fi

  /usr/bin/touch "$STOP_FILE" || true
  stop_matching_ntfs_workers
  run_with_timeout 45 /usr/sbin/diskutil unmountDisk force "$TARGET_DISK" >/dev/null 2>&1 || true
  /usr/sbin/diskutil eraseDisk APFS "$APFS_NAME" GPT "$TARGET_DISK"

  local attempt
  for attempt in $(/usr/bin/jot 30); do
    if apfs_volume_matches_target_disk; then
      log "RESTORE_SUCCEEDED"
      /usr/sbin/diskutil list external physical || true
      /sbin/mount | /usr/bin/grep -F "$APFS_NAME" || true
      return 0
    fi
    /bin/sleep 2
  done

  fail "APFS restore command completed but /Volumes/$APFS_NAME did not appear"
}

usage() {
  cat <<'USAGE'
usage: run_live_apfs_restore_guard.sh <whole-disk> <apfs-name> "YYYY-MM-DD HH:MM:SS"

Runs as root, waits until the deadline, then stops live stress and erases the
confirmed sacrificial disk back to APFS.
USAGE
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

if [[ "$EUID" -ne 0 ]]; then
  fail "run_live_apfs_restore_guard.sh must run as root"
fi
if [[ -z "$DEADLINE" ]]; then
  usage
  fail "restore deadline is required"
fi

/bin/mkdir -p "$LOG_ROOT"
: > "$LOG_PATH"
/bin/ln -sf "$LOG_PATH" "$LATEST_LOG" 2>/dev/null || true
exec > >(/usr/bin/tee -a "$LOG_PATH") 2>&1

log "NTFS Access APFS restore guard"
log "targetDisk=$TARGET_DISK"
log "apfsName=$APFS_NAME"
log "deadline=$DEADLINE"
log "stopFile=$STOP_FILE"
log "log=$LOG_PATH"

assert_whole_disk_identity "$TARGET_DISK"

while [[ "$(seconds_until_deadline)" -gt 0 ]]; do
  log "secondsUntilRestore=$(seconds_until_deadline)"
  /bin/sleep 30
done

restore_apfs
