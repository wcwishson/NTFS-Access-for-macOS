#!/bin/bash
set -euo pipefail

DEVICE="${1:-/dev/disk12s1}"
EXPECTED_NAME="${2:-NTFS_STRESS}"
CYCLES="${3:-12}"

NTFSACCESSCTL="${NTFSACCESSCTL:-/usr/local/bin/ntfsaccessctl}"
DEVICE_ID="${DEVICE##*/}"
STAMP="$(/bin/date +%Y%m%d-%H%M%S)"
LOCAL_ROOT="/tmp/ntfsaccess-remount-churn-$STAMP"
SUMMARY="$LOCAL_ROOT/summary.txt"
FINAL_SUMMARY="/tmp/ntfsaccess-remount-churn-$STAMP-summary.txt"
CURRENT_STEP="startup"
MOUNT_POINT=""
KEEP_LOCAL_ROOT=0

log() {
  printf '%s\n' "$*" | /usr/bin/tee -a "$SUMMARY"
}

fail() {
  log "FAIL: $*"
  if [[ -f "$SUMMARY" ]]; then
    /bin/cp "$SUMMARY" "$FINAL_SUMMARY" >/dev/null 2>&1 || true
    printf 'summary=%s\n' "$FINAL_SUMMARY" >&2
  fi
  exit 1
}

cleanup() {
  local status=$?
  if [[ "$status" -ne 0 && -f "$SUMMARY" ]]; then
    log "FAILED_STEP=$CURRENT_STEP"
    /bin/cp "$SUMMARY" "$FINAL_SUMMARY" >/dev/null 2>&1 || true
    printf 'summary=%s\n' "$FINAL_SUMMARY" >&2
    KEEP_LOCAL_ROOT=1
  fi
  if [[ "$KEEP_LOCAL_ROOT" -eq 0 ]]; then
    /bin/rm -rf "$LOCAL_ROOT" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT

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

run_with_timeout_to_file() {
  local seconds="$1"
  local output_path="$2"
  shift 2
  local pid
  local waited=0
  "$@" > "$output_path" 2>> "$SUMMARY" &
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

now_epoch() {
  /bin/date +%s
}

sha256_file() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{ print $1 }'
}

md5_file() {
  /sbin/md5 -q "$1"
}

ntfs3g_volname_for() {
  /usr/bin/perl -CS -Mutf8 -e '$s=shift; $s=~s/[^A-Za-z0-9_. -]/_/g; $s=~s/^\s+|\s+$//g; $s=~s/ /_/g; print length($s) ? $s : "NTFS-Volume"' "$1"
}

require_tool() {
  local tool="$1"
  if [[ ! -x "$tool" ]] && ! /usr/bin/command -v "$tool" >/dev/null 2>&1; then
    fail "missing required tool: $tool"
  fi
}

assert_single_ntfs3g_process() {
  local label="$1"
  local process_list
  local process_count
  local expected_volname

  process_list="$(/bin/ps aux | /usr/bin/grep -F 'ntfs-3g' | /usr/bin/grep -F "$DEVICE_ID" | /usr/bin/grep -v grep || true)"
  process_count="$(/usr/bin/printf '%s\n' "$process_list" | /usr/bin/awk 'NF { count += 1 } END { print count + 0 }')"
  expected_volname="$(ntfs3g_volname_for "$EXPECTED_NAME")"

  log "$label ntfs-3g process count=$process_count"
  log "$process_list"

  [[ "$process_count" == "1" ]] || fail "$label expected exactly one ntfs-3g process for $DEVICE_ID, found $process_count"
  if ! /usr/bin/printf '%s\n' "$process_list" | /usr/bin/grep -Fq "volname=$expected_volname"; then
    fail "$label ntfs-3g process does not include volname=$expected_volname"
  fi
}

current_ntfs3g_pids() {
  /bin/ps aux \
    | /usr/bin/awk -v id="$DEVICE_ID" '/ntfs-3g/ && index($0, id) > 0 { print $2 }' \
    | /usr/bin/sort \
    | /usr/bin/tr '\n' ' '
}

request_scan() {
  local label="${1:-scan}"
  local start
  local end
  local status

  start="$(now_epoch)"
  set +e
  run_with_timeout 120 "$NTFSACCESSCTL" scan-now --wait >/dev/null 2>&1
  status=$?
  set -e
  end="$(now_epoch)"
  log "timing=daemon-scan metric=label=$label start=$start end=$end seconds=$((end - start)) status=$status"
  return 0
}

assert_mount_root_user_accessible() {
  local mount_point="$1"
  local label="${2:-mount-root}"
  local probe_dir="$mount_point/.ntfsaccess-user-access-probe-$STAMP"
  local marker="$probe_dir/marker.txt"

  /bin/ls -ldOe@ "$mount_point" >> "$SUMMARY" 2>&1 || true
  /bin/ls "$mount_point" >/dev/null 2>> "$SUMMARY" \
    || fail "$label signed-in user cannot enter mount root: $mount_point"
  [[ -x "$mount_point" && -w "$mount_point" ]] \
    || fail "$label signed-in user cannot write mount root: $mount_point"
  /bin/mkdir -p "$probe_dir" >> "$SUMMARY" 2>&1 \
    || fail "$label could not create mount-root probe directory: $probe_dir"
  printf 'mount-root-access %s %s\n' "$DEVICE_ID" "$STAMP" > "$marker" \
    || fail "$label could not write mount-root probe file: $marker"
  /usr/bin/grep -q "$STAMP" "$marker" \
    || fail "$label could not read mount-root probe file: $marker"
  /bin/rm -rf "$probe_dir" >> "$SUMMARY" 2>&1 \
    || fail "$label could not remove mount-root probe directory: $probe_dir"
}

assert_read_write_state() {
  local label="$1"
  local scan_mode="${2:-scan}"
  local volumes
  local line
  local mode
  local name
  local mount_point
  local info_plist="$LOCAL_ROOT/${label//[^A-Za-z0-9_.-]/_}-diskutil.plist"
  local diskutil_name
  local diskutil_mount
  local diskutil_writable
  local mount_entry

  if [[ "$scan_mode" != "no-scan" ]]; then
    request_scan "$label"
  fi

  volumes="$("$NTFSACCESSCTL" list-volumes)"
  log "$label list-volumes:"
  log "$volumes"

  line="$(/usr/bin/printf '%s\n' "$volumes" | /usr/bin/awk -F '\t' -v id="$DEVICE_ID" '$1 == id { print; exit }')"
  [[ -n "$line" ]] || fail "$label NTFS Access is not managing $DEVICE_ID"

  mode="$(/usr/bin/printf '%s\n' "$line" | /usr/bin/awk -F '\t' '{ print $2 }')"
  mount_point="$(/usr/bin/printf '%s\n' "$line" | /usr/bin/awk -F '\t' '{ print $3 }')"
  name="$(/usr/bin/printf '%s\n' "$line" | /usr/bin/awk -F '\t' '{ print $4 }')"

  [[ "$mode" == "readWrite" ]] || fail "$label expected readWrite mode, got $mode"
  [[ "$name" == "$EXPECTED_NAME" ]] || fail "$label expected name $EXPECTED_NAME, got $name"
  [[ -d "$mount_point" ]] || fail "$label Finder-style mount point disappeared: $mount_point"
  assert_mount_root_user_accessible "$mount_point" "$label"

  run_with_timeout_to_file 12 "$info_plist" /usr/sbin/diskutil info -plist "$DEVICE" || fail "$label diskutil info timed out or failed"
  diskutil_name="$(/usr/libexec/PlistBuddy -c 'Print :VolumeName' "$info_plist" 2>/dev/null || true)"
  diskutil_mount="$(/usr/libexec/PlistBuddy -c 'Print :MountPoint' "$info_plist" 2>/dev/null || true)"
  diskutil_writable="$(/usr/libexec/PlistBuddy -c 'Print :Writable' "$info_plist" 2>/dev/null || /usr/libexec/PlistBuddy -c 'Print :WritableVolume' "$info_plist" 2>/dev/null || true)"

  log "$label diskutil: name=$diskutil_name mount=$diskutil_mount writable=$diskutil_writable"
  [[ "$diskutil_name" == "$EXPECTED_NAME" ]] || fail "$label Disk Utility name mismatch: $diskutil_name"
  [[ "$diskutil_writable" == "true" || "$diskutil_writable" == "1" ]] || fail "$label Disk Utility does not report writable"

  mount_entry="$(/sbin/mount | /usr/bin/grep -E "(^$DEVICE|$DEVICE_ID|$mount_point)" | /usr/bin/head -n 1 || true)"
  log "$label mount entry: $mount_entry"
  [[ -n "$mount_entry" ]] || fail "$label mount entry missing"
  if ! /usr/bin/printf '%s\n' "$mount_entry" | /usr/bin/grep -qi 'macfuse'; then
    fail "$label mount entry is not macFUSE-backed"
  fi
  if /usr/bin/printf '%s\n' "$mount_entry" | /usr/bin/grep -qi 'read-only'; then
    fail "$label mount entry switched to read-only"
  fi

  MOUNT_POINT="$mount_point"
  assert_single_ntfs3g_process "$label"
}

read_write_mount_is_verified() {
  local volumes
  local line
  local mode
  local name
  local mount_point
  local mount_entry
  local process_list
  local process_count

  volumes="$("$NTFSACCESSCTL" list-volumes 2>/dev/null || true)"
  line="$(/usr/bin/printf '%s\n' "$volumes" | /usr/bin/awk -F '\t' -v id="$DEVICE_ID" '$1 == id { print; exit }')"
  [[ -n "$line" ]] || return 1

  mode="$(/usr/bin/printf '%s\n' "$line" | /usr/bin/awk -F '\t' '{ print $2 }')"
  mount_point="$(/usr/bin/printf '%s\n' "$line" | /usr/bin/awk -F '\t' '{ print $3 }')"
  name="$(/usr/bin/printf '%s\n' "$line" | /usr/bin/awk -F '\t' '{ print $4 }')"
  [[ "$mode" == "readWrite" ]] || return 1
  [[ "$name" == "$EXPECTED_NAME" ]] || return 1
  [[ -d "$mount_point" ]] || return 1
  /bin/ls "$mount_point" >/dev/null 2>> "$SUMMARY" || return 1
  [[ -x "$mount_point" && -w "$mount_point" ]] || return 1

  mount_entry="$(/sbin/mount | /usr/bin/grep -E "(^$DEVICE|$DEVICE_ID|$mount_point)" | /usr/bin/head -n 1 || true)"
  [[ -n "$mount_entry" ]] || return 1
  /usr/bin/printf '%s\n' "$mount_entry" | /usr/bin/grep -qi 'macfuse' || return 1
  if /usr/bin/printf '%s\n' "$mount_entry" | /usr/bin/grep -qi 'read-only'; then
    return 1
  fi

  process_list="$(/bin/ps aux | /usr/bin/grep -F 'ntfs-3g' | /usr/bin/grep -F "$DEVICE_ID" | /usr/bin/grep -v grep || true)"
  process_count="$(/usr/bin/printf '%s\n' "$process_list" | /usr/bin/awk 'NF { count += 1 } END { print count + 0 }')"
  [[ "$process_count" == "1" ]] || return 1
  /usr/bin/printf '%s\n' "$process_list" | /usr/bin/grep -Fq "volname=$(ntfs3g_volname_for "$EXPECTED_NAME")" || return 1

  MOUNT_POINT="$mount_point"
  return 0
}

unmount_or_remount_observed() {
  local before_pids="$1"
  local label="$2"
  local info_plist="$LOCAL_ROOT/${label//[^A-Za-z0-9_.-]/_}-diskutil.plist"
  local diskutil_mount
  local current_pids

  run_with_timeout_to_file 12 "$info_plist" /usr/sbin/diskutil info -plist "$DEVICE" || return 1
  diskutil_mount="$(/usr/libexec/PlistBuddy -c 'Print :MountPoint' "$info_plist" 2>/dev/null || true)"
  current_pids="$(current_ntfs3g_pids)"

  if [[ -z "$diskutil_mount" ]]; then
    log "$label unmount observed: no diskutil mount point"
    return 0
  fi

  if [[ -n "$current_pids" && "$current_pids" != "$before_pids" ]] && read_write_mount_is_verified; then
    log "$label remount observed: mount=$MOUNT_POINT pids=$current_pids"
    return 0
  fi

  return 1
}

wait_for_unmount_or_remount() {
  local before_pids="$1"
  local label="$2"
  local attempt

  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    if unmount_or_remount_observed "$before_pids" "$label-$attempt"; then
      return 0
    fi
    /bin/sleep 2
  done

  return 1
}

write_and_verify_cycle_marker() {
  local cycle="$1"
  local dir="$MOUNT_POINT/NTFSAccess_remount_churn_$STAMP"
  local marker="$dir/cycle-$cycle.txt"
  local payload="cycle-$cycle $(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"
  local hash_before
  local hash_after
  local md5_before
  local md5_after

  CURRENT_STEP="cycle-$cycle write marker"
  /bin/mkdir -p "$dir"
  printf '%s\n' "$payload" > "$marker"
  /bin/sync
  /usr/bin/grep -q "$payload" "$marker" || fail "post-remount write/read failed for cycle-$cycle"
  hash_before="$(sha256_file "$marker")"
  md5_before="$(md5_file "$marker")"
  /bin/sync
  hash_after="$(sha256_file "$marker")"
  md5_after="$(md5_file "$marker")"
  log "integrity=remount-marker cycle=$cycle before_sha256=$hash_before after_sha256=$hash_after before_md5=$md5_before after_md5=$md5_after"
  [[ "$hash_before" == "$hash_after" ]] || fail "cycle-$cycle marker checksum changed"
  [[ "$md5_before" == "$md5_after" ]] || fail "cycle-$cycle marker MD5 changed"
}

remount_once() {
  local cycle="$1"
  local before_pids
  local start
  local end

  CURRENT_STEP="cycle-$cycle diskutil unmount"
  log ""
  log "cycle-$cycle: requesting unmount"
  start="$(now_epoch)"
  before_pids="$(current_ntfs3g_pids)"
  [[ -n "$before_pids" ]] || fail "cycle-$cycle had no ntfs-3g worker before remount"
  if ! run_with_timeout 30 /usr/sbin/diskutil unmount force "$DEVICE"; then
    log "cycle-$cycle: diskutil force unmount failed; checking observed state"
  fi
  if ! wait_for_unmount_or_remount "$before_pids" "cycle-$cycle-force"; then
    if [[ -n "${MOUNT_POINT:-}" && -d "$MOUNT_POINT" ]]; then
      log "cycle-$cycle: retrying direct root umount"
      run_with_timeout 20 /sbin/umount -f "$MOUNT_POINT" || true
    fi
    wait_for_unmount_or_remount "$before_pids" "cycle-$cycle-umount" || fail "cycle-$cycle unmount failed"
  fi

  /bin/sleep 2
  CURRENT_STEP="cycle-$cycle scan-now"
  request_scan "cycle-$cycle-initial"

  CURRENT_STEP="cycle-$cycle wait for readWrite remount"
  local attempt
  for attempt in $(/usr/bin/jot 30); do
    if read_write_mount_is_verified; then
      end="$(now_epoch)"
      log "timing=remount-cycle metric=cycle=$cycle start=$start end=$end seconds=$((end - start)) status=0"
      log "cycle-$cycle verified remount on attempt $attempt at $MOUNT_POINT"
      return 0
    fi
    if [[ "$attempt" == "10" || "$attempt" == "20" ]]; then
      log "cycle-$cycle still waiting after attempt $attempt; requesting another daemon scan"
      request_scan "cycle-$cycle-followup-$attempt"
    fi
    /bin/sleep 2
  done

  log "cycle-$cycle still not verified after cheap polling; requesting final daemon scan"
  request_scan "cycle-$cycle-final"
  if read_write_mount_is_verified; then
    end="$(now_epoch)"
    log "timing=remount-cycle metric=cycle=$cycle start=$start end=$end seconds=$((end - start)) status=0"
    log "cycle-$cycle verified remount after final scan at $MOUNT_POINT"
    return 0
  fi

  fail "cycle-$cycle did not remount readWrite"
}

mkdir -p "$LOCAL_ROOT"
: > "$SUMMARY"

require_tool "$NTFSACCESSCTL"
require_tool /usr/sbin/diskutil
require_tool /usr/bin/shasum
require_tool /sbin/md5
require_tool /usr/bin/jot

log "NTFS Access remount churn validation"
log "device=$DEVICE"
log "expectedName=$EXPECTED_NAME"
log "cycles=$CYCLES"
log "startedAt=$STAMP"

assert_read_write_state "initial"
write_and_verify_cycle_marker "initial"

for cycle in $(/usr/bin/jot "$CYCLES"); do
  remount_once "$cycle"
  assert_read_write_state "cycle-$cycle" no-scan
  write_and_verify_cycle_marker "$cycle"
done

MARKER="$MOUNT_POINT/NTFSAccess_remount_churn_passed_$STAMP.txt"
{
  printf 'NTFS Access remount churn validation passed\n'
  printf 'timestamp=%s\n' "$STAMP"
  printf 'device=%s\n' "$DEVICE"
  printf 'volume=%s\n' "$EXPECTED_NAME"
  printf 'cycles=%s\n' "$CYCLES"
  printf 'mountPoint=%s\n' "$MOUNT_POINT"
} > "$MARKER"
/bin/sync

log ""
log "PASS"
log "marker=$MARKER"
log "summary=$SUMMARY"
KEEP_LOCAL_ROOT=1
