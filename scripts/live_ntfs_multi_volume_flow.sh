#!/bin/bash
set -euo pipefail

DEVICE_A="${1:?usage: live_ntfs_multi_volume_flow.sh <device-a> <name-a> <device-b> <name-b> [cycles]}"
NAME_A="${2:?usage: live_ntfs_multi_volume_flow.sh <device-a> <name-a> <device-b> <name-b> [cycles]}"
DEVICE_B="${3:?usage: live_ntfs_multi_volume_flow.sh <device-a> <name-a> <device-b> <name-b> [cycles]}"
NAME_B="${4:?usage: live_ntfs_multi_volume_flow.sh <device-a> <name-a> <device-b> <name-b> [cycles]}"
CYCLES="${5:-8}"

NTFSACCESSCTL="${NTFSACCESSCTL:-/usr/local/bin/ntfsaccessctl}"
ID_A="${DEVICE_A##*/}"
ID_B="${DEVICE_B##*/}"
STAMP="$(/bin/date +%Y%m%d-%H%M%S)"
ROOT="/tmp/ntfsaccess-multi-volume-flow-$STAMP"
SUMMARY="$ROOT/summary.txt"
FINAL_SUMMARY="/tmp/ntfsaccess-multi-volume-flow-$STAMP-summary.txt"
MOUNT_A=""
MOUNT_B=""
CURRENT_STEP="startup"
KEEP_ROOT=0

mkdir -p "$ROOT"
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

require_tool() {
  local tool="$1"
  if [[ ! -x "$tool" ]] && ! /usr/bin/command -v "$tool" >/dev/null 2>&1; then
    fail "missing required tool: $tool"
  fi
}

ntfs3g_count_for() {
  local id="$1"
  /bin/ps aux \
    | /usr/bin/awk -v id="$id" '/ntfs-3g/ && index($0, id) > 0 { count += 1 } END { print count + 0 }'
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
  local id="$2"
  local label="${3:-mount-root}"
  local probe_dir="$mount_point/.ntfsaccess-user-access-probe-$STAMP-$id"
  local marker="$probe_dir/marker.txt"

  /bin/ls -ldOe@ "$mount_point" >> "$SUMMARY" 2>&1 || true
  /bin/ls "$mount_point" >/dev/null 2>> "$SUMMARY" \
    || fail "$label signed-in user cannot enter mount root for $id: $mount_point"
  [[ -x "$mount_point" && -w "$mount_point" ]] \
    || fail "$label signed-in user cannot write mount root for $id: $mount_point"
  /bin/mkdir -p "$probe_dir" >> "$SUMMARY" 2>&1 \
    || fail "$label could not create mount-root probe directory: $probe_dir"
  printf 'mount-root-access %s %s\n' "$id" "$STAMP" > "$marker" \
    || fail "$label could not write mount-root probe file: $marker"
  /usr/bin/grep -q "$STAMP" "$marker" \
    || fail "$label could not read mount-root probe file: $marker"
  /bin/rm -rf "$probe_dir" >> "$SUMMARY" 2>&1 \
    || fail "$label could not remove mount-root probe directory: $probe_dir"
}

assert_volume_ready() {
  local device="$1"
  local id="$2"
  local expected_name="$3"
  local out_var="$4"
  local label="$5"
  local volumes
  local line
  local mode
  local mount_point
  local name
  local plist="$ROOT/${label//[^A-Za-z0-9_.-]/_}-${id}.plist"
  local diskutil_name
  local diskutil_writable
  local mount_entry
  local worker_count

  request_scan "$label"
  /bin/sleep 2
  volumes="$("$NTFSACCESSCTL" list-volumes 2>/dev/null || true)"
  log "$label list-volumes:"
  log "$volumes"

  line="$(/usr/bin/printf '%s\n' "$volumes" | /usr/bin/awk -F '\t' -v id="$id" '$1 == id { print; exit }')"
  [[ -n "$line" ]] || fail "$label NTFS Access is not managing $id"
  mode="$(/usr/bin/printf '%s\n' "$line" | /usr/bin/awk -F '\t' '{ print $2 }')"
  mount_point="$(/usr/bin/printf '%s\n' "$line" | /usr/bin/awk -F '\t' '{ print $3 }')"
  name="$(/usr/bin/printf '%s\n' "$line" | /usr/bin/awk -F '\t' '{ print $4 }')"
  [[ "$mode" == "readWrite" ]] || fail "$label expected $id readWrite, got $mode"
  [[ "$name" == "$expected_name" ]] || fail "$label expected $id name $expected_name, got $name"
  [[ -d "$mount_point" ]] || fail "$label mount point missing for $id: $mount_point"
  assert_mount_root_user_accessible "$mount_point" "$id" "$label"

  run_with_timeout_to_file 12 "$plist" /usr/sbin/diskutil info -plist "$device" || fail "$label diskutil info failed for $id"
  diskutil_name="$(/usr/libexec/PlistBuddy -c 'Print :VolumeName' "$plist" 2>/dev/null || true)"
  diskutil_writable="$(/usr/libexec/PlistBuddy -c 'Print :Writable' "$plist" 2>/dev/null || /usr/libexec/PlistBuddy -c 'Print :WritableVolume' "$plist" 2>/dev/null || true)"
  [[ "$diskutil_name" == "$expected_name" ]] || fail "$label Disk Utility name mismatch for $id: $diskutil_name"
  [[ "$diskutil_writable" == "true" || "$diskutil_writable" == "1" ]] || fail "$label Disk Utility reports non-writable for $id"

  mount_entry="$(/sbin/mount | /usr/bin/grep -E "(^$device|$id|$mount_point)" | /usr/bin/head -n 1 || true)"
  [[ -n "$mount_entry" ]] || fail "$label mount entry missing for $id"
  /usr/bin/printf '%s\n' "$mount_entry" | /usr/bin/grep -qi 'macfuse' || fail "$label mount is not macFUSE-backed for $id: $mount_entry"
  if /usr/bin/printf '%s\n' "$mount_entry" | /usr/bin/grep -qi 'read-only'; then
    fail "$label mount switched read-only for $id: $mount_entry"
  fi

  worker_count="$(ntfs3g_count_for "$id")"
  [[ "$worker_count" == "1" ]] || fail "$label expected one ntfs-3g worker for $id, found $worker_count"
  printf -v "$out_var" '%s' "$mount_point"
}

volume_ready_probe() {
  local device="$1"
  local id="$2"
  local expected_name="$3"
  local out_var="$4"
  local label="$5"
  local volumes
  local line
  local mode
  local mount_point
  local name
  local plist="$ROOT/${label//[^A-Za-z0-9_.-]/_}-${id}.plist"
  local diskutil_name
  local diskutil_writable
  local mount_entry
  local worker_count

  if [[ "${6:-scan}" != "no-scan" ]]; then
    request_scan "$label"
    /bin/sleep 2
  fi
  volumes="$("$NTFSACCESSCTL" list-volumes 2>/dev/null || true)"
  line="$(/usr/bin/printf '%s\n' "$volumes" | /usr/bin/awk -F '\t' -v id="$id" '$1 == id { print; exit }')"
  [[ -n "$line" ]] || return 1
  mode="$(/usr/bin/printf '%s\n' "$line" | /usr/bin/awk -F '\t' '{ print $2 }')"
  mount_point="$(/usr/bin/printf '%s\n' "$line" | /usr/bin/awk -F '\t' '{ print $3 }')"
  name="$(/usr/bin/printf '%s\n' "$line" | /usr/bin/awk -F '\t' '{ print $4 }')"
  [[ "$mode" == "readWrite" ]] || return 1
  [[ "$name" == "$expected_name" ]] || return 1
  [[ -d "$mount_point" ]] || return 1
  /bin/ls "$mount_point" >/dev/null 2>> "$SUMMARY" || return 1
  [[ -x "$mount_point" && -w "$mount_point" ]] || return 1

  run_with_timeout_to_file 12 "$plist" /usr/sbin/diskutil info -plist "$device" || return 1
  diskutil_name="$(/usr/libexec/PlistBuddy -c 'Print :VolumeName' "$plist" 2>/dev/null || true)"
  diskutil_writable="$(/usr/libexec/PlistBuddy -c 'Print :Writable' "$plist" 2>/dev/null || /usr/libexec/PlistBuddy -c 'Print :WritableVolume' "$plist" 2>/dev/null || true)"
  [[ "$diskutil_name" == "$expected_name" ]] || return 1
  [[ "$diskutil_writable" == "true" || "$diskutil_writable" == "1" ]] || return 1

  mount_entry="$(/sbin/mount | /usr/bin/grep -E "(^$device|$id|$mount_point)" | /usr/bin/head -n 1 || true)"
  [[ -n "$mount_entry" ]] || return 1
  /usr/bin/printf '%s\n' "$mount_entry" | /usr/bin/grep -qi 'macfuse' || return 1
  if /usr/bin/printf '%s\n' "$mount_entry" | /usr/bin/grep -qi 'read-only'; then
    return 1
  fi

  worker_count="$(ntfs3g_count_for "$id")"
  [[ "$worker_count" == "1" ]] || return 1
  printf -v "$out_var" '%s' "$mount_point"
}

assert_both_ready() {
  local label="$1"
  assert_volume_ready "$DEVICE_A" "$ID_A" "$NAME_A" MOUNT_A "$label-a"
  assert_volume_ready "$DEVICE_B" "$ID_B" "$NAME_B" MOUNT_B "$label-b"
}

sha256_file() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{ print $1 }'
}

md5_file() {
  /sbin/md5 -q "$1"
}

copy_verify() {
  local src="$1"
  local dst="$2"
  local src_sha
  local dst_sha
  local src_md5
  local dst_md5

  /bin/mkdir -p "$(/usr/bin/dirname "$dst")"
  time_step "multi-copy" "bytes=$(/usr/bin/stat -f %z "$src")" /usr/bin/env COPYFILE_DISABLE=1 /bin/cp -X "$src" "$dst"
  /usr/bin/cmp "$src" "$dst" >/dev/null
  src_sha="$(sha256_file "$src")"
  dst_sha="$(sha256_file "$dst")"
  src_md5="$(md5_file "$src")"
  dst_md5="$(md5_file "$dst")"
  log "integrity=multi-copy source=$src dest=$dst source_sha256=$src_sha dest_sha256=$dst_sha source_md5=$src_md5 dest_md5=$dst_md5"
  [[ "$src_sha" == "$dst_sha" ]] || fail "checksum mismatch: $src -> $dst"
  [[ "$src_md5" == "$dst_md5" ]] || fail "MD5 mismatch: $src -> $dst"
}

current_pids_for() {
  local id="$1"
  /bin/ps aux \
    | /usr/bin/awk -v id="$id" '/ntfs-3g/ && index($0, id) > 0 { print $2 }' \
    | /usr/bin/sort \
    | /usr/bin/tr '\n' ' '
}

unmount_or_remount_observed() {
  local device="$1"
  local id="$2"
  local expected_name="$3"
  local before_pids="$4"
  local label="$5"
  local plist="$ROOT/${label//[^A-Za-z0-9_.-]/_}-${id}.plist"
  local diskutil_mount
  local current_pids
  local ready_mount

  run_with_timeout_to_file 12 "$plist" /usr/sbin/diskutil info -plist "$device" || return 1
  diskutil_mount="$(/usr/libexec/PlistBuddy -c 'Print :MountPoint' "$plist" 2>/dev/null || true)"
  current_pids="$(current_pids_for "$id")"

  if [[ -z "$diskutil_mount" ]]; then
    log "$label unmount observed: no diskutil mount point"
    return 0
  fi

  if [[ -n "$current_pids" && "$current_pids" != "$before_pids" ]] \
    && volume_ready_probe "$device" "$id" "$expected_name" ready_mount "$label-remounted" no-scan; then
    log "$label remount observed: mount=$ready_mount pids=$current_pids"
    return 0
  fi

  return 1
}

wait_for_unmount_or_remount() {
  local device="$1"
  local id="$2"
  local expected_name="$3"
  local before_pids="$4"
  local label="$5"
  local attempt

  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    if unmount_or_remount_observed "$device" "$id" "$expected_name" "$before_pids" "$label-$attempt"; then
      return 0
    fi
    /bin/sleep 2
  done

  return 1
}

wait_until_volume_ready() {
  local device="$1"
  local id="$2"
  local expected_name="$3"
  local out_var="$4"
  local label="$5"
  local attempt
  for attempt in $(/usr/bin/jot 60); do
    if volume_ready_probe "$device" "$id" "$expected_name" "$out_var" "$label-attempt-$attempt" no-scan; then
      log "$label recovered on attempt $attempt"
      return 0
    fi
    if [[ "$attempt" == "15" || "$attempt" == "30" || "$attempt" == "45" ]]; then
      log "$label still waiting after attempt $attempt; requesting another daemon scan"
      request_scan "$label-followup-$attempt"
    fi
    /bin/sleep 3
  done
  log "$label still not ready after cheap polling; requesting final daemon scan"
  request_scan "$label-final"
  assert_volume_ready "$device" "$id" "$expected_name" "$out_var" "$label-final"
}

remount_one_volume_while_other_is_busy() {
  local device="$1"
  local id="$2"
  local expected_name="$3"
  local mount_var="$4"
  local other_mount="$5"
  local label="$6"
  local busy_file="$other_mount/multi-flow-$STAMP/busy-$label.bin"
  local before_pids
  local start
  local end

  log "$label: writing busy file on sibling while remounting $id"
  start="$(now_epoch)"
  /bin/mkdir -p "$(/usr/bin/dirname "$busy_file")"
  /bin/dd if=/dev/zero of="$busy_file" bs=1024k count=32 >> "$SUMMARY" 2>&1 &
  local busy_pid=$!

  before_pids="$(current_pids_for "$id")"
  [[ -n "$before_pids" ]] || fail "$label had no ntfs-3g worker before remount"
  if ! run_with_timeout 30 /usr/sbin/diskutil unmount force "$device"; then
    log "$label diskutil force unmount failed; checking observed state"
  fi
  wait "$busy_pid"
  if ! wait_for_unmount_or_remount "$device" "$id" "$expected_name" "$before_pids" "$label-force"; then
    if [[ -n "${!mount_var:-}" && -d "${!mount_var}" ]]; then
      log "$label retrying direct root umount"
      run_with_timeout 20 /sbin/umount -f "${!mount_var}" || true
    fi
    wait_for_unmount_or_remount "$device" "$id" "$expected_name" "$before_pids" "$label-umount" || fail "$label unmount failed"
  fi

  request_scan "$label-initial"
  wait_until_volume_ready "$device" "$id" "$expected_name" "$mount_var" "$label"
  /usr/bin/cmp "$busy_file" "$busy_file" >/dev/null
  end="$(now_epoch)"
  log "timing=multi-sibling-remount metric=id=$id start=$start end=$end seconds=$((end - start)) status=0"
}

require_tool "$NTFSACCESSCTL"
require_tool /usr/sbin/diskutil
require_tool /usr/bin/jot
require_tool /usr/bin/shasum
require_tool /sbin/md5
require_tool /usr/bin/cmp
require_tool /bin/dd
require_tool /bin/df

log "NTFS Access multi-volume flow validation"
log "deviceA=$DEVICE_A nameA=$NAME_A"
log "deviceB=$DEVICE_B nameB=$NAME_B"
log "cycles=$CYCLES"
log "startedAt=$STAMP"

CURRENT_STEP="initial readiness"
assert_both_ready "initial"

cleanup_previous_flow_dirs() {
  /bin/rm -rf "$MOUNT_A"/multi-flow-* "$MOUNT_B"/multi-flow-* >/dev/null 2>&1 || true
  /bin/sync
}

available_kib() {
  /bin/df -k "$1" | /usr/bin/awk 'NR == 2 { print $4 }'
}

choose_source_mib() {
  local free_a
  local free_b
  local smaller_free
  local reserve_kib=262144
  local chosen

  free_a="$(available_kib "$MOUNT_A")"
  free_b="$(available_kib "$MOUNT_B")"
  [[ "$free_a" =~ ^[0-9]+$ && "$free_b" =~ ^[0-9]+$ ]] || fail "could not determine free space for multi-volume flow"
  smaller_free="$free_a"
  [[ "$free_b" -lt "$smaller_free" ]] && smaller_free="$free_b"

  if [[ -n "${NTFSACCESS_MULTI_SOURCE_MIB:-}" ]]; then
    [[ "$NTFSACCESS_MULTI_SOURCE_MIB" =~ ^[1-9][0-9]*$ ]] || fail "NTFSACCESS_MULTI_SOURCE_MIB must be a positive whole number"
    printf '%s\n' "$NTFSACCESS_MULTI_SOURCE_MIB"
    return 0
  fi

  if [[ "$smaller_free" -le "$reserve_kib" ]]; then
    fail "not enough free space for multi-volume flow: smaller free space is ${smaller_free}KiB"
  fi

  chosen=$(( (smaller_free - reserve_kib) / 1024 / 5 ))
  if [[ "$chosen" -gt 96 ]]; then
    chosen=96
  elif [[ "$chosen" -lt 8 ]]; then
    chosen=8
  fi
  printf '%s\n' "$chosen"
}

cleanup_previous_flow_dirs
LOCAL_SOURCE="$ROOT/local-source"
SOURCE_MIB="$(choose_source_mib)"
log "sourceMiB=$SOURCE_MIB"
/usr/sbin/mkfile "${SOURCE_MIB}m" "$LOCAL_SOURCE"
HASH_SOURCE="$(sha256_file "$LOCAL_SOURCE")"
MD5_SOURCE="$(md5_file "$LOCAL_SOURCE")"
BASE_A="$MOUNT_A/multi-flow-$STAMP"
BASE_B="$MOUNT_B/multi-flow-$STAMP"
/bin/mkdir -p "$BASE_A" "$BASE_B" "$ROOT/mac-hop"

CURRENT_STEP="local to both volumes"
copy_verify "$LOCAL_SOURCE" "$BASE_A/local-to-a.bin"
copy_verify "$LOCAL_SOURCE" "$BASE_B/local-to-b.bin"

CURRENT_STEP="a to mac to b"
copy_verify "$BASE_A/local-to-a.bin" "$ROOT/mac-hop/a-to-mac.bin"
copy_verify "$ROOT/mac-hop/a-to-mac.bin" "$BASE_B/a-to-mac-to-b.bin"

CURRENT_STEP="b to mac to a"
copy_verify "$BASE_B/local-to-b.bin" "$ROOT/mac-hop/b-to-mac.bin"
copy_verify "$ROOT/mac-hop/b-to-mac.bin" "$BASE_A/b-to-mac-to-a.bin"

CURRENT_STEP="direct mounted volume copies"
copy_verify "$BASE_A/local-to-a.bin" "$BASE_B/direct-a-to-b.bin"
copy_verify "$BASE_B/local-to-b.bin" "$BASE_A/direct-b-to-a.bin"

CURRENT_STEP="parallel bidirectional writes"
for cycle in $(/usr/bin/jot "$CYCLES"); do
  log "parallel-cycle=$cycle"
  /bin/mkdir -p "$BASE_A/parallel-$cycle" "$BASE_B/parallel-$cycle"
  /bin/dd if=/dev/zero of="$BASE_A/parallel-$cycle/a.bin" bs=1024k count=8 >> "$SUMMARY" 2>&1 &
  pid_a=$!
  /bin/dd if=/dev/zero of="$BASE_B/parallel-$cycle/b.bin" bs=1024k count=8 >> "$SUMMARY" 2>&1 &
  pid_b=$!
  wait "$pid_a"
  wait "$pid_b"
  copy_verify "$BASE_A/parallel-$cycle/a.bin" "$BASE_B/parallel-$cycle/a-copy.bin"
  copy_verify "$BASE_B/parallel-$cycle/b.bin" "$BASE_A/parallel-$cycle/b-copy.bin"
  /bin/mv "$BASE_B/parallel-$cycle/a-copy.bin" "$BASE_B/parallel-$cycle/a-copy-renamed.bin"
  /bin/mv "$BASE_A/parallel-$cycle/b-copy.bin" "$BASE_A/parallel-$cycle/b-copy-renamed.bin"
  assert_both_ready "parallel-cycle-$cycle"
done

CURRENT_STEP="single-volume remount while sibling busy"
remount_one_volume_while_other_is_busy "$DEVICE_A" "$ID_A" "$NAME_A" MOUNT_A "$MOUNT_B" "remount-a"
remount_one_volume_while_other_is_busy "$DEVICE_B" "$ID_B" "$NAME_B" MOUNT_B "$MOUNT_A" "remount-b"

CURRENT_STEP="post-remount checksum verification"
log "integrity=multi-post-remount-a sha256=$(sha256_file "$BASE_A/local-to-a.bin") md5=$(md5_file "$BASE_A/local-to-a.bin")"
log "integrity=multi-post-remount-b sha256=$(sha256_file "$BASE_B/local-to-b.bin") md5=$(md5_file "$BASE_B/local-to-b.bin")"
[[ "$(sha256_file "$BASE_A/local-to-a.bin")" == "$HASH_SOURCE" ]] || fail "A source checksum changed"
[[ "$(sha256_file "$BASE_B/local-to-b.bin")" == "$HASH_SOURCE" ]] || fail "B source checksum changed"
[[ "$(md5_file "$BASE_A/local-to-a.bin")" == "$MD5_SOURCE" ]] || fail "A source MD5 changed"
[[ "$(md5_file "$BASE_B/local-to-b.bin")" == "$MD5_SOURCE" ]] || fail "B source MD5 changed"
assert_both_ready "final"

MARKER_A="$MOUNT_A/NTFSAccess_multi_volume_flow_${STAMP}_A_PASS.txt"
MARKER_B="$MOUNT_B/NTFSAccess_multi_volume_flow_${STAMP}_B_PASS.txt"
printf 'multi-volume flow passed %s\n' "$STAMP" > "$MARKER_A"
printf 'multi-volume flow passed %s\n' "$STAMP" > "$MARKER_B"
/bin/sync

log "PASS"
log "markerA=$MARKER_A"
log "markerB=$MARKER_B"
log "summary=$SUMMARY"
KEEP_ROOT=1
