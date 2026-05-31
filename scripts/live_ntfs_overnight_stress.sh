#!/bin/bash
set -euo pipefail

DEVICE="${1:-/dev/disk12s1}"
EXPECTED_NAME="${2:-NTFS_STRESS}"
CYCLES="${3:-720}"

NTFSACCESSCTL="${NTFSACCESSCTL:-/usr/local/bin/ntfsaccessctl}"
DEVICE_ID="${DEVICE##*/}"
STAMP="$(/bin/date +%Y%m%d-%H%M%S)"
LOCAL_ROOT="/tmp/ntfsaccess-overnight-$STAMP"
SUMMARY="$LOCAL_ROOT/summary.txt"
FINAL_SUMMARY="/tmp/ntfsaccess-overnight-$STAMP-summary.txt"
CURRENT_STEP="startup"
MOUNT_POINT=""
KEEP_LOCAL_ROOT=0

mkdir -p "$LOCAL_ROOT"
: > "$SUMMARY"
cd /tmp

log() {
  printf '%s\n' "$*" | /usr/bin/tee -a "$SUMMARY"
}

fail() {
  log "FAIL: $*"
  /bin/cp "$SUMMARY" "$FINAL_SUMMARY" >/dev/null 2>&1 || true
  printf 'summary=%s\n' "$FINAL_SUMMARY" >&2
  exit 1
}

cleanup() {
  local status=$?
  if [[ "$status" -ne 0 ]]; then
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

time_step() {
  local label="$1"
  local metric="$2"
  shift 2
  local start
  local end
  local duration
  local status
  local rate_suffix=""

  start="$(now_epoch)"
  set +e
  "$@"
  status=$?
  set -e
  end="$(now_epoch)"
  duration=$((end - start))
  if [[ "$duration" -gt 0 && "$metric" =~ bytes=([0-9]+) ]]; then
    rate_suffix=" mib_per_sec=$(/usr/bin/awk -v bytes="${BASH_REMATCH[1]}" -v seconds="$duration" 'BEGIN { printf "%.2f", bytes / 1048576 / seconds }')"
  elif [[ "$duration" -gt 0 && "$metric" =~ files=([0-9]+) ]]; then
    rate_suffix=" files_per_sec=$(/usr/bin/awk -v files="${BASH_REMATCH[1]}" -v seconds="$duration" 'BEGIN { printf "%.2f", files / seconds }')"
  fi
  log "timing=$label metric=$metric start=$start end=$end seconds=$duration status=$status$rate_suffix"
  return "$status"
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

request_scan() {
  run_with_timeout 20 "$NTFSACCESSCTL" scan-now >/dev/null 2>&1 || true
}

volume_line_for_device() {
  local attempts="${1:-1}"
  local attempt
  local volumes
  local line

  for attempt in $(/usr/bin/jot "$attempts"); do
    volumes="$("$NTFSACCESSCTL" list-volumes 2>> "$SUMMARY" || true)"
    line="$(/usr/bin/printf '%s\n' "$volumes" | /usr/bin/awk -F '\t' -v id="$DEVICE_ID" '$1 == id { print; exit }')"
    if [[ -n "$line" ]]; then
      /usr/bin/printf '%s\n' "$line"
      return 0
    fi

    if [[ "$attempt" -lt "$attempts" ]]; then
      request_scan
      /bin/sleep 3
    fi
  done

  return 1
}

read_diskutil_state() {
  local label="$1"
  local info_plist="$LOCAL_ROOT/${label//[^A-Za-z0-9_.-]/_}-diskutil.plist"
  run_with_timeout_to_file 12 "$info_plist" /usr/sbin/diskutil info -plist "$DEVICE" || return 1
  DISKUTIL_NAME="$(/usr/libexec/PlistBuddy -c 'Print :VolumeName' "$info_plist" 2>/dev/null || true)"
  DISKUTIL_MOUNT="$(/usr/libexec/PlistBuddy -c 'Print :MountPoint' "$info_plist" 2>/dev/null || true)"
  DISKUTIL_WRITABLE="$(/usr/libexec/PlistBuddy -c 'Print :Writable' "$info_plist" 2>/dev/null || /usr/libexec/PlistBuddy -c 'Print :WritableVolume' "$info_plist" 2>/dev/null || true)"
}

assert_read_write_state() {
  local label="$1"
  local volumes
  local line
  local mode
  local name
  local mount_point
  local mount_entry

  request_scan
  /bin/sleep 2

  line="$(volume_line_for_device 8 || true)"
  [[ -n "$line" ]] || fail "$label NTFS Access is not managing $DEVICE_ID"

  mode="$(/usr/bin/printf '%s\n' "$line" | /usr/bin/awk -F '\t' '{ print $2 }')"
  mount_point="$(/usr/bin/printf '%s\n' "$line" | /usr/bin/awk -F '\t' '{ print $3 }')"
  name="$(/usr/bin/printf '%s\n' "$line" | /usr/bin/awk -F '\t' '{ print $4 }')"

  [[ "$mode" == "readWrite" ]] || fail "$label expected readWrite mode, got $mode"
  [[ "$name" == "$EXPECTED_NAME" ]] || fail "$label expected name $EXPECTED_NAME, got $name"
  [[ -d "$mount_point" ]] || fail "$label Finder-style mount point disappeared: $mount_point"
  assert_mount_root_user_accessible "$mount_point" "$label"

  read_diskutil_state "$label" || fail "$label diskutil info timed out or failed"
  [[ "$DISKUTIL_NAME" == "$EXPECTED_NAME" ]] || fail "$label Disk Utility name mismatch: $DISKUTIL_NAME"
  [[ "$DISKUTIL_MOUNT" == "$mount_point" ]] || fail "$label Disk Utility mount mismatch: $DISKUTIL_MOUNT vs $mount_point"
  [[ "$DISKUTIL_WRITABLE" == "true" || "$DISKUTIL_WRITABLE" == "1" ]] || fail "$label Disk Utility does not report writable"

  mount_entry="$(/sbin/mount | /usr/bin/grep -E "(^$DEVICE|$DEVICE_ID|$mount_point)" | /usr/bin/head -n 1 || true)"
  [[ -n "$mount_entry" ]] || fail "$label mount entry missing"
  if ! /usr/bin/printf '%s\n' "$mount_entry" | /usr/bin/grep -qi 'macfuse'; then
    fail "$label mount entry is not macFUSE-backed: $mount_entry"
  fi
  if /usr/bin/printf '%s\n' "$mount_entry" | /usr/bin/grep -qi 'read-only'; then
    fail "$label mount entry switched to read-only: $mount_entry"
  fi

  MOUNT_POINT="$mount_point"
  log "$label ok: mount=$mount_point worker=1"
  assert_single_ntfs3g_process "$label"
}

wait_for_read_write_state() {
  local label="$1"
  local attempt

  for attempt in $(/usr/bin/jot 30); do
    if [[ "$((attempt % 3))" -eq 1 ]]; then
      request_scan
    fi

    local line
    line="$(volume_line_for_device 1 || true)"
    if /usr/bin/printf '%s\n' "$line" | /usr/bin/grep -Eq "^$DEVICE_ID[[:space:]]+readWrite[[:space:]]"; then
      read_diskutil_state "$label-wait-$attempt" || true
      if [[ "$DISKUTIL_NAME" == "$EXPECTED_NAME" && "$DISKUTIL_WRITABLE" =~ ^(true|1)$ && -n "$DISKUTIL_MOUNT" ]] \
        && /bin/ls "$DISKUTIL_MOUNT" >/dev/null 2>> "$SUMMARY" \
        && [[ -x "$DISKUTIL_MOUNT" && -w "$DISKUTIL_MOUNT" ]] \
        && /sbin/mount | /usr/bin/grep -E "(^$DEVICE|$DEVICE_ID|$DISKUTIL_MOUNT)" | /usr/bin/grep -qi 'macfuse'; then
        return 0
      fi
    fi
    /bin/sleep 4
  done

  fail "$label did not return to readWrite macFUSE state"
}

read_write_mount_is_verified() {
  local line
  local mode
  local name
  local mount_point
  local mount_entry
  local process_count
  local process_list

  line="$(volume_line_for_device 1 || true)"
  [[ -n "$line" ]] || return 1
  mode="$(/usr/bin/printf '%s\n' "$line" | /usr/bin/awk -F '\t' '{ print $2 }')"
  mount_point="$(/usr/bin/printf '%s\n' "$line" | /usr/bin/awk -F '\t' '{ print $3 }')"
  name="$(/usr/bin/printf '%s\n' "$line" | /usr/bin/awk -F '\t' '{ print $4 }')"
  [[ "$mode" == "readWrite" ]] || return 1
  [[ "$name" == "$EXPECTED_NAME" ]] || return 1
  [[ -d "$mount_point" ]] || return 1
  /bin/ls "$mount_point" >/dev/null 2>> "$SUMMARY" || return 1
  [[ -x "$mount_point" && -w "$mount_point" ]] || return 1

  read_diskutil_state "verified-$DEVICE_ID" || return 1
  [[ "$DISKUTIL_NAME" == "$EXPECTED_NAME" ]] || return 1
  [[ "$DISKUTIL_MOUNT" == "$mount_point" ]] || return 1
  [[ "$DISKUTIL_WRITABLE" == "true" || "$DISKUTIL_WRITABLE" == "1" ]] || return 1

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

file_operation_cycle() {
  local cycle="$1"
  local root="$MOUNT_POINT/NTFSAccess_overnight_$STAMP"
  local work="$root/work-cycle-$cycle"
  local progress="$root/progress.log"
  local payload
  local hash_a
  local hash_b
  local md5_a
  local md5_b
  local small_start
  local small_end

  CURRENT_STEP="cycle-$cycle file operations"
  /bin/mkdir -p "$work/many" "$work/nested/a b/c"

  payload="cycle=$cycle stamp=$STAMP utc=$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '%s\n' "$payload" > "$work/nested/a b/c/source.txt"
  /bin/cp "$work/nested/a b/c/source.txt" "$work/copied.txt"
  /usr/bin/cmp "$work/nested/a b/c/source.txt" "$work/copied.txt" >/dev/null
  printf 'append %s\n' "$cycle" >> "$work/copied.txt"
  /bin/mv "$work/copied.txt" "$work/renamed.txt"
  /bin/chmod u+rw "$work/renamed.txt"
  /usr/bin/touch -t 202605170101 "$work/renamed.txt"
  /usr/bin/grep -q "append $cycle" "$work/renamed.txt"

  local i
  small_start="$(now_epoch)"
  for i in $(/usr/bin/jot 40); do
    printf 'cycle=%s file=%s payload=%s\n' "$cycle" "$i" "$payload" > "$work/many/file-$i.txt"
  done
  small_end="$(now_epoch)"
  small_seconds=$((small_end - small_start))
  small_rate=""
  if [[ "$small_seconds" -gt 0 ]]; then
    small_rate=" files_per_sec=$(/usr/bin/awk -v files=40 -v seconds="$small_seconds" 'BEGIN { printf "%.2f", files / seconds }')"
  fi
  log "timing=overnight-small-create cycle=$cycle metric=files=40 start=$small_start end=$small_end seconds=$small_seconds status=0$small_rate"
  [[ "$(/bin/ls "$work/many" | /usr/bin/wc -l | /usr/bin/tr -d ' ')" == "40" ]] || fail "cycle-$cycle small-file count mismatch"

  time_step "overnight-medium-write" "cycle=$cycle bytes=4194304" /bin/dd if=/dev/zero of="$work/medium.bin" bs=1024k count=4 >> "$SUMMARY" 2>&1
  time_step "overnight-medium-copy" "cycle=$cycle bytes=4194304" /bin/cp "$work/medium.bin" "$work/medium-copy.bin" >> "$SUMMARY" 2>&1
  /usr/bin/cmp "$work/medium.bin" "$work/medium-copy.bin" >/dev/null
  hash_a="$(sha256_file "$work/medium.bin")"
  hash_b="$(sha256_file "$work/medium-copy.bin")"
  md5_a="$(md5_file "$work/medium.bin")"
  md5_b="$(md5_file "$work/medium-copy.bin")"
  log "integrity=overnight-medium cycle=$cycle source_sha256=$hash_a copy_sha256=$hash_b source_md5=$md5_a copy_md5=$md5_b"
  [[ "$hash_a" == "$hash_b" ]] || fail "cycle-$cycle medium file checksum mismatch"
  [[ "$md5_a" == "$md5_b" ]] || fail "cycle-$cycle medium file MD5 mismatch"

  if [[ "$((cycle % 10))" -eq 0 ]]; then
    time_step "overnight-large-write" "cycle=$cycle bytes=33554432" /bin/dd if=/dev/zero of="$work/large-$cycle.bin" bs=1024k count=32 >> "$SUMMARY" 2>&1
    log "integrity=overnight-large cycle=$cycle sha256=$(sha256_file "$work/large-$cycle.bin") md5=$(md5_file "$work/large-$cycle.bin")"
  fi

  printf '%s\n' "$payload" >> "$progress"
  /bin/sync
  /usr/bin/grep -q "cycle=$cycle" "$progress"
  time_step "overnight-work-delete" "cycle=$cycle files=40" /bin/rm -rf "$work" >> "$SUMMARY" 2>&1
  /bin/sync
}

remount_cycle() {
  local cycle="$1"
  local before_pids
  local start
  local end

  CURRENT_STEP="cycle-$cycle diskutil unmount"
  log "cycle-$cycle: unmount/remount"
  start="$(now_epoch)"
  before_pids="$(current_ntfs3g_pids)"
  [[ -n "$before_pids" ]] || fail "cycle-$cycle had no ntfs-3g worker before remount"
  if ! run_with_timeout 35 /usr/sbin/diskutil unmount force "$DEVICE"; then
    log "cycle-$cycle: diskutil force unmount failed; checking observed state"
  fi
  if ! wait_for_unmount_or_remount "$before_pids" "cycle-$cycle-force"; then
    if [[ -n "${MOUNT_POINT:-}" && -d "$MOUNT_POINT" ]]; then
      log "cycle-$cycle: retrying direct root umount"
      run_with_timeout 20 /sbin/umount -f "$MOUNT_POINT" || fail "cycle-$cycle unmount failed"
    else
      fail "cycle-$cycle unmount failed"
    fi
    wait_for_unmount_or_remount "$before_pids" "cycle-$cycle-umount" || fail "cycle-$cycle unmount failed"
  fi

  /bin/sleep 2
  CURRENT_STEP="cycle-$cycle wait readWrite"
  wait_for_read_write_state "cycle-$cycle"
  assert_read_write_state "cycle-$cycle"
  end="$(now_epoch)"
  log "timing=overnight-remount metric=cycle=$cycle start=$start end=$end seconds=$((end - start)) status=0"
}

require_tool "$NTFSACCESSCTL"
require_tool /usr/sbin/diskutil
require_tool /usr/bin/shasum
require_tool /sbin/md5
require_tool /usr/bin/jot
require_tool /usr/bin/cmp

log "NTFS Access overnight stress"
log "device=$DEVICE"
log "expectedName=$EXPECTED_NAME"
log "cycles=$CYCLES"
log "startedAt=$STAMP"
log "pid=$$"

assert_read_write_state "initial"

for cycle in $(/usr/bin/jot "$CYCLES"); do
  CURRENT_STEP="cycle-$cycle"
  file_operation_cycle "$cycle"
  remount_cycle "$cycle"
done

FINAL_MARKER="$MOUNT_POINT/NTFSAccess_overnight_${STAMP}_PASS.txt"
{
  printf 'NTFS Access overnight stress passed\n'
  printf 'timestamp=%s\n' "$STAMP"
  printf 'device=%s\n' "$DEVICE"
  printf 'volume=%s\n' "$EXPECTED_NAME"
  printf 'cycles=%s\n' "$CYCLES"
  printf 'summary=%s\n' "$SUMMARY"
} > "$FINAL_MARKER"
/bin/sync

log "PASS"
log "marker=$FINAL_MARKER"
log "summary=$SUMMARY"
KEEP_LOCAL_ROOT=1
