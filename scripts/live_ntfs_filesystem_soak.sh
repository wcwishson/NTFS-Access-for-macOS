#!/bin/bash
set -euo pipefail

DEVICE="${1:-/dev/disk12s1}"
EXPECTED_NAME="${2:-NTFS_STRESS}"
CYCLES="${3:-120}"
NTFSACCESSCTL="${NTFSACCESSCTL:-/usr/local/bin/ntfsaccessctl}"
DEVICE_ID="${DEVICE##*/}"
STAMP="$(/bin/date +%Y%m%d-%H%M%S)"
ROOT="/tmp/ntfsaccess-filesystem-soak-$STAMP"
SUMMARY="$ROOT/summary.txt"
FINAL_SUMMARY="/tmp/ntfsaccess-filesystem-soak-$STAMP-summary.txt"
MOUNT_POINT=""
CURRENT_STEP="startup"
KEEP_ROOT=0

mkdir -p "$ROOT"
: > "$SUMMARY"

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
    KEEP_ROOT=1
  fi
  if [[ "$KEEP_ROOT" -eq 0 ]]; then
    /bin/rm -rf "$ROOT" >/dev/null 2>&1 || true
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

current_ntfs3g_pids() {
  /bin/ps aux \
    | /usr/bin/awk -v id="$DEVICE_ID" '/ntfs-3g/ && index($0, id) > 0 { print $2 }' \
    | /usr/bin/sort \
    | /usr/bin/tr '\n' ' '
}

request_scan() {
  run_with_timeout 120 "$NTFSACCESSCTL" scan-now --wait >/dev/null 2>&1 || true
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

read_diskutil_state() {
  local label="$1"
  local plist="$ROOT/${label//[^A-Za-z0-9_.-]/_}-diskutil.plist"
  run_with_timeout_to_file 12 "$plist" /usr/sbin/diskutil info -plist "$DEVICE" || return 1
  DISKUTIL_NAME="$(/usr/libexec/PlistBuddy -c 'Print :VolumeName' "$plist" 2>/dev/null || true)"
  DISKUTIL_MOUNT="$(/usr/libexec/PlistBuddy -c 'Print :MountPoint' "$plist" 2>/dev/null || true)"
  DISKUTIL_WRITABLE="$(/usr/libexec/PlistBuddy -c 'Print :Writable' "$plist" 2>/dev/null || /usr/libexec/PlistBuddy -c 'Print :WritableVolume' "$plist" 2>/dev/null || true)"
}

assert_mount_state() {
  local label="$1"
  local mount_entry
  local process_list
  local worker_count
  local expected_volname

  read_diskutil_state "$label" || fail "$label diskutil info timed out or failed"
  [[ "$DISKUTIL_NAME" == "$EXPECTED_NAME" ]] || fail "$label volume name mismatch: $DISKUTIL_NAME"
  [[ -n "$DISKUTIL_MOUNT" && -d "$DISKUTIL_MOUNT" ]] || fail "$label mount point missing: $DISKUTIL_MOUNT"
  assert_mount_root_user_accessible "$DISKUTIL_MOUNT" "$label"
  [[ "$DISKUTIL_WRITABLE" == "true" || "$DISKUTIL_WRITABLE" == "1" ]] || fail "$label Disk Utility reports non-writable"

  mount_entry="$(/sbin/mount | /usr/bin/grep -E "(^$DEVICE|$DEVICE_ID|$DISKUTIL_MOUNT)" | /usr/bin/head -n 1 || true)"
  [[ -n "$mount_entry" ]] || fail "$label mount entry missing"
  /usr/bin/printf '%s\n' "$mount_entry" | /usr/bin/grep -qi 'macfuse' || fail "$label mount is not macFUSE-backed: $mount_entry"
  if /usr/bin/printf '%s\n' "$mount_entry" | /usr/bin/grep -qi 'read-only'; then
    fail "$label mount switched read-only: $mount_entry"
  fi

  process_list="$(/bin/ps aux | /usr/bin/grep -F 'ntfs-3g' | /usr/bin/grep -F "$DEVICE_ID" | /usr/bin/grep -v grep || true)"
  worker_count="$(/usr/bin/printf '%s\n' "$process_list" | /usr/bin/awk 'NF { c += 1 } END { print c + 0 }')"
  expected_volname="$(ntfs3g_volname_for "$EXPECTED_NAME")"
  [[ "$worker_count" == "1" ]] || fail "$label expected one ntfs-3g worker, found $worker_count"
  /usr/bin/printf '%s\n' "$process_list" | /usr/bin/grep -Fq "volname=$expected_volname" \
    || fail "$label ntfs-3g process does not include volname=$expected_volname"
  MOUNT_POINT="$DISKUTIL_MOUNT"
  log "$label ok: $mount_entry"
}

is_mount_state_ready() {
  local label="$1"
  local mount_entry
  local process_list
  local worker_count

  read_diskutil_state "$label" || return 1
  [[ "$DISKUTIL_NAME" == "$EXPECTED_NAME" ]] || return 1
  [[ -n "$DISKUTIL_MOUNT" && -d "$DISKUTIL_MOUNT" ]] || return 1
  /bin/ls "$DISKUTIL_MOUNT" >/dev/null 2>> "$SUMMARY" || return 1
  [[ -x "$DISKUTIL_MOUNT" && -w "$DISKUTIL_MOUNT" ]] || return 1
  [[ "$DISKUTIL_WRITABLE" == "true" || "$DISKUTIL_WRITABLE" == "1" ]] || return 1

  mount_entry="$(/sbin/mount | /usr/bin/grep -E "(^$DEVICE|$DEVICE_ID|$DISKUTIL_MOUNT)" | /usr/bin/head -n 1 || true)"
  [[ -n "$mount_entry" ]] || return 1
  /usr/bin/printf '%s\n' "$mount_entry" | /usr/bin/grep -qi 'macfuse' || return 1
  if /usr/bin/printf '%s\n' "$mount_entry" | /usr/bin/grep -qi 'read-only'; then
    return 1
  fi

  process_list="$(/bin/ps aux | /usr/bin/grep -F 'ntfs-3g' | /usr/bin/grep -F "$DEVICE_ID" | /usr/bin/grep -v grep || true)"
  worker_count="$(/usr/bin/printf '%s\n' "$process_list" | /usr/bin/awk 'NF { c += 1 } END { print c + 0 }')"
  [[ "$worker_count" == "1" ]] || return 1
  /usr/bin/printf '%s\n' "$process_list" | /usr/bin/grep -Fq "volname=$(ntfs3g_volname_for "$EXPECTED_NAME")" || return 1
  MOUNT_POINT="$DISKUTIL_MOUNT"
}

wait_for_mount_state() {
  local label="$1"
  local attempts="${2:-45}"
  local attempt
  for attempt in $(/usr/bin/jot "$attempts"); do
    if is_mount_state_ready "$label-wait-$attempt"; then
      if [[ "$attempt" -gt 45 ]]; then
        log "$label slow remount recovered after $((attempt * 3))s"
      fi
      return 0
    fi
    /bin/sleep 3
  done
  assert_mount_state "$label-final"
}

unmount_or_remount_observed() {
  local before_pids="$1"
  local label="$2"
  local current_pids

  read_diskutil_state "$label" || return 1
  current_pids="$(current_ntfs3g_pids)"

  if [[ -z "$DISKUTIL_MOUNT" ]]; then
    log "$label unmount observed: no diskutil mount point"
    return 0
  fi

  if [[ -n "$current_pids" && "$current_pids" != "$before_pids" ]] && is_mount_state_ready "$label-remounted"; then
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

file_ops() {
  local cycle="$1"
  local base="$MOUNT_POINT/NTFSAccess_filesystem_soak_$STAMP"
  local work="$base/work-$cycle"
  local payload="cycle=$cycle stamp=$STAMP utc=$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"
  local hash_a
  local hash_b
  local md5_a
  local md5_b
  local small_start
  local small_end

  /bin/mkdir -p "$work/nested/space dir" "$work/many"
  printf '%s\n' "$payload" > "$work/nested/space dir/source.txt"
  /bin/cp "$work/nested/space dir/source.txt" "$work/copied.txt"
  /usr/bin/cmp "$work/nested/space dir/source.txt" "$work/copied.txt" >/dev/null
  printf 'append cycle %s\n' "$cycle" >> "$work/copied.txt"
  /bin/mv "$work/copied.txt" "$work/renamed.txt"
  /usr/bin/grep -q "append cycle $cycle" "$work/renamed.txt"

  local i
  small_start="$(now_epoch)"
  for i in $(/usr/bin/jot 50); do
    printf 'cycle=%s file=%s payload=%s\n' "$cycle" "$i" "$payload" > "$work/many/file-$i.txt"
  done
  small_end="$(now_epoch)"
  small_seconds=$((small_end - small_start))
  small_rate=""
  if [[ "$small_seconds" -gt 0 ]]; then
    small_rate=" files_per_sec=$(/usr/bin/awk -v files=50 -v seconds="$small_seconds" 'BEGIN { printf "%.2f", files / seconds }')"
  fi
  log "timing=soak-small-create cycle=$cycle metric=files=50 start=$small_start end=$small_end seconds=$small_seconds status=0$small_rate"

  time_step "soak-medium-write" "cycle=$cycle bytes=4194304" /bin/dd if=/dev/zero of="$work/medium.bin" bs=1024k count=4 >> "$SUMMARY" 2>&1
  time_step "soak-medium-copy" "cycle=$cycle bytes=4194304" /bin/cp "$work/medium.bin" "$work/medium-copy.bin" >> "$SUMMARY" 2>&1
  /usr/bin/cmp "$work/medium.bin" "$work/medium-copy.bin" >/dev/null
  hash_a="$(sha256_file "$work/medium.bin")"
  hash_b="$(sha256_file "$work/medium-copy.bin")"
  md5_a="$(md5_file "$work/medium.bin")"
  md5_b="$(md5_file "$work/medium-copy.bin")"
  log "integrity=soak-medium cycle=$cycle source_sha256=$hash_a copy_sha256=$hash_b source_md5=$md5_a copy_md5=$md5_b"
  [[ "$hash_a" == "$hash_b" ]] || fail "cycle-$cycle checksum mismatch"
  [[ "$md5_a" == "$md5_b" ]] || fail "cycle-$cycle MD5 mismatch"

  printf '%s\n' "$payload" >> "$base/progress.log"
  /bin/sync
  /usr/bin/grep -q "cycle=$cycle" "$base/progress.log"
  time_step "soak-work-delete" "cycle=$cycle files=50" /bin/rm -rf "$work" >> "$SUMMARY" 2>&1
  /bin/sync
}

remount() {
  local cycle="$1"
  local before_pids
  local start
  local end
  before_pids="$(current_ntfs3g_pids)"

  log "cycle-$cycle: unmount/remount"
  start="$(now_epoch)"
  if ! run_with_timeout 30 /usr/sbin/diskutil unmount force "$DEVICE"; then
    log "cycle-$cycle: diskutil force unmount failed; checking observed state"
    if ! wait_for_unmount_or_remount "$before_pids" "cycle-$cycle-force"; then
      if [[ -n "${MOUNT_POINT:-}" && -d "$MOUNT_POINT" ]]; then
        log "cycle-$cycle: retrying direct root umount"
        run_with_timeout 20 /sbin/umount -f "$MOUNT_POINT" || true
      fi
      wait_for_unmount_or_remount "$before_pids" "cycle-$cycle-umount" || fail "cycle-$cycle unmount failed"
    fi
  fi
  /bin/sleep 2
  request_scan
  wait_for_mount_state "cycle-$cycle" 90
  assert_mount_state "cycle-$cycle"
  end="$(now_epoch)"
  log "timing=soak-remount metric=cycle=$cycle start=$start end=$end seconds=$((end - start)) status=0"
}

log "NTFS Access filesystem soak"
log "device=$DEVICE"
log "expectedName=$EXPECTED_NAME"
log "cycles=$CYCLES"
log "startedAt=$STAMP"
log "pid=$$"

require_tool() {
  local tool="$1"
  if [[ ! -x "$tool" ]] && ! /usr/bin/command -v "$tool" >/dev/null 2>&1; then
    fail "missing required tool: $tool"
  fi
}

require_tool "$NTFSACCESSCTL"
require_tool /usr/bin/shasum
require_tool /sbin/md5
require_tool /usr/bin/cmp
request_scan
assert_mount_state "initial"
for cycle in $(/usr/bin/jot "$CYCLES"); do
  CURRENT_STEP="cycle-$cycle file ops"
  file_ops "$cycle"
  CURRENT_STEP="cycle-$cycle remount"
  remount "$cycle"
done

MARKER="$MOUNT_POINT/NTFSAccess_filesystem_soak_${STAMP}_PASS.txt"
{
  printf 'NTFS Access filesystem soak passed\n'
  printf 'timestamp=%s\n' "$STAMP"
  printf 'device=%s\n' "$DEVICE"
  printf 'volume=%s\n' "$EXPECTED_NAME"
  printf 'cycles=%s\n' "$CYCLES"
} > "$MARKER"
/bin/sync

log "PASS"
log "marker=$MARKER"
log "summary=$SUMMARY"
KEEP_ROOT=1
