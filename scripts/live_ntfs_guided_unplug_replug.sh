#!/bin/bash
set -euo pipefail

usage() {
  cat <<'USAGE'
usage: live_ntfs_guided_unplug_replug.sh <device> <expected-volume-name>

Guided physical unplug/replug validation for one NTFS Access volume.
Run as the signed-in user, not root. The script writes a small marker,
asks you to unplug/replug the drive, then verifies the same volume returns
as a single writable NTFS Access/macFUSE mount with intact marker hashes.
USAGE
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

[[ "$#" -ge 2 ]] || { usage >&2; exit 64; }

DEVICE="$1"
EXPECTED_NAME="$2"
NTFSACCESSCTL="${NTFSACCESSCTL:-/usr/local/bin/ntfsaccessctl}"
DEVICE_ID="${DEVICE##*/}"
STAMP="$(/bin/date +%Y%m%d-%H%M%S)"
LOCAL_ROOT="/tmp/ntfsaccess-guided-replug-$STAMP"
SUMMARY="$LOCAL_ROOT/summary.txt"
FINAL_SUMMARY="/tmp/ntfsaccess-guided-replug-$STAMP-summary.txt"
CURRENT_STEP="startup"
MOUNT_POINT=""
MARKER_DIR="NTFSAccess_guided_replug_$STAMP"
MARKER_RELATIVE="$MARKER_DIR/marker.bin"
MARKER_SHA256=""
MARKER_MD5=""
INITIAL_STABLE_KEY=""
INITIAL_VOLUME_NAME=""
INITIAL_NTFS3G_PIDS=""

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

sha256_file() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{ print $1 }'
}

md5_file() {
  /sbin/md5 -q "$1"
}

ntfs3g_volname_for() {
  /usr/bin/perl -CS -Mutf8 -e '$s=shift; $s=~s/[^A-Za-z0-9_. -]/_/g; $s=~s/^\s+|\s+$//g; $s=~s/ /_/g; print length($s) ? $s : "NTFS-Volume"' "$1"
}

plist_value() {
  /usr/libexec/PlistBuddy -c "Print $2" "$1" 2>/dev/null || true
}

capture_diskutil_info_plist() {
  local device="$1"
  local output_path="$2"
  local temp_output="$LOCAL_ROOT/diskutil-info-$$.tmp"
  if ! run_with_timeout_to_file 12 "$temp_output" /usr/sbin/diskutil info -plist "$device"; then
    /bin/rm -f "$temp_output"
    return 1
  fi
  /bin/mv "$temp_output" "$output_path"
}

stable_key_from_plist() {
  local plist="$1"
  local value
  for key in :VolumeUUID :DiskUUID :MediaUUID; do
    value="$(plist_value "$plist" "$key")"
    if [[ -n "$value" ]]; then
      printf '%s\n' "$key=$value"
      return 0
    fi
  done

  local size
  local name
  size="$(plist_value "$plist" :TotalSize)"
  name="$(plist_value "$plist" :VolumeName)"
  printf 'fallback-name-size=%s:%s\n' "$name" "$size"
}

request_scan() {
  run_with_timeout 120 "$NTFSACCESSCTL" scan-now --wait >/dev/null 2>&1 || true
}

request_retry() {
  run_with_timeout 180 "$NTFSACCESSCTL" retry-mounts --wait >/dev/null 2>&1 || true
}

volume_line_for_name() {
  "$NTFSACCESSCTL" list-volumes 2>/dev/null \
    | /usr/bin/awk -F '\t' -v name="$EXPECTED_NAME" 'NR > 1 && $4 == name { print; exit }'
}

volume_line_for_device_id() {
  "$NTFSACCESSCTL" list-volumes 2>/dev/null \
    | /usr/bin/awk -F '\t' -v id="$1" 'NR > 1 && $1 == id { print; exit }'
}

current_ntfs3g_pids() {
  local id="$1"
  /bin/ps aux \
    | /usr/bin/awk -v id="$id" '/ntfs-3g/ && index($0, id) > 0 { print $2 }' \
    | /usr/bin/sort \
    | /usr/bin/tr '\n' ' '
}

assert_single_ntfs3g_process() {
  local id="$1"
  local label="$2"
  local process_list
  local process_count
  local expected_volname

  process_list="$(/bin/ps aux | /usr/bin/grep -F 'ntfs-3g' | /usr/bin/grep -F "$id" | /usr/bin/grep -v grep || true)"
  process_count="$(/usr/bin/printf '%s\n' "$process_list" | /usr/bin/awk 'NF { count += 1 } END { print count + 0 }')"
  expected_volname="$(ntfs3g_volname_for "$EXPECTED_NAME")"

  log "$label ntfs-3g process count=$process_count"
  log "$process_list"

  [[ "$process_count" == "1" ]] || fail "$label expected exactly one ntfs-3g process for $id, found $process_count"
  /usr/bin/printf '%s\n' "$process_list" | /usr/bin/grep -Fq "volname=$expected_volname" \
    || fail "$label ntfs-3g process does not include volname=$expected_volname"
}

assert_mount_root_user_accessible() {
  local mount_point="$1"
  local label="$2"
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

assert_read_write_state_for_line() {
  local line="$1"
  local label="$2"
  local id
  local mode
  local mount_point
  local name
  local info_plist="$LOCAL_ROOT/${label//[^A-Za-z0-9_.-]/_}-diskutil.plist"
  local diskutil_name
  local diskutil_mount
  local diskutil_writable
  local mount_entry

  id="$(/usr/bin/printf '%s\n' "$line" | /usr/bin/awk -F '\t' '{ print $1 }')"
  mode="$(/usr/bin/printf '%s\n' "$line" | /usr/bin/awk -F '\t' '{ print $2 }')"
  mount_point="$(/usr/bin/printf '%s\n' "$line" | /usr/bin/awk -F '\t' '{ print $3 }')"
  name="$(/usr/bin/printf '%s\n' "$line" | /usr/bin/awk -F '\t' '{ print $4 }')"

  [[ "$mode" == "readWrite" ]] || fail "$label expected readWrite mode, got $mode"
  [[ "$name" == "$EXPECTED_NAME" ]] || fail "$label expected name $EXPECTED_NAME, got $name"
  [[ -d "$mount_point" ]] || fail "$label Finder-style mount point disappeared: $mount_point"
  assert_mount_root_user_accessible "$mount_point" "$label"

  capture_diskutil_info_plist "/dev/$id" "$info_plist" || fail "$label diskutil info failed for /dev/$id"
  diskutil_name="$(plist_value "$info_plist" :VolumeName)"
  diskutil_mount="$(plist_value "$info_plist" :MountPoint)"
  diskutil_writable="$(plist_value "$info_plist" :Writable)"
  [[ -n "$diskutil_writable" ]] || diskutil_writable="$(plist_value "$info_plist" :WritableVolume)"

  log "$label diskutil: id=$id name=$diskutil_name mount=$diskutil_mount writable=$diskutil_writable"
  [[ "$diskutil_name" == "$EXPECTED_NAME" ]] || fail "$label Disk Utility name mismatch: $diskutil_name"
  [[ "$diskutil_writable" == "true" || "$diskutil_writable" == "1" ]] || fail "$label Disk Utility does not report writable"

  mount_entry="$(/sbin/mount | /usr/bin/grep -E "(^/dev/$id|$id|$mount_point)" | /usr/bin/head -n 1 || true)"
  log "$label mount entry: $mount_entry"
  [[ -n "$mount_entry" ]] || fail "$label mount entry missing"
  /usr/bin/printf '%s\n' "$mount_entry" | /usr/bin/grep -qi 'macfuse' \
    || fail "$label mount entry is not macFUSE-backed"
  if /usr/bin/printf '%s\n' "$mount_entry" | /usr/bin/grep -qi 'read-only'; then
    fail "$label mount entry switched to read-only"
  fi

  assert_single_ntfs3g_process "$id" "$label"
  MOUNT_POINT="$mount_point"
  DEVICE_ID="$id"
}

assert_current_read_write_state() {
  local line
  request_scan
  line="$(volume_line_for_device_id "$DEVICE_ID")"
  [[ -n "$line" ]] || line="$(volume_line_for_name)"
  [[ -n "$line" ]] || fail "$1 NTFS Access is not managing $EXPECTED_NAME"
  assert_read_write_state_for_line "$line" "$1"
}

wait_for_disappear() {
  local attempt
  local line

  for attempt in $(/usr/bin/seq 1 120); do
    line="$(volume_line_for_device_id "$DEVICE_ID")"
    if [[ -z "$line" ]] || ! /usr/sbin/diskutil info "$DEVICE" >/dev/null 2>&1; then
      log "disappear observed attempt=$attempt"
      return 0
    fi
    /bin/sleep 1
  done

  return 1
}

wait_for_reappear() {
  local attempt
  local line
  local id
  local info_plist="$LOCAL_ROOT/reappeared-diskutil.plist"
  local stable_key

  for attempt in $(/usr/bin/seq 1 180); do
    request_scan
    line="$(volume_line_for_name)"
    if [[ -n "$line" ]]; then
      id="$(/usr/bin/printf '%s\n' "$line" | /usr/bin/awk -F '\t' '{ print $1 }')"
      if capture_diskutil_info_plist "/dev/$id" "$info_plist"; then
        stable_key="$(stable_key_from_plist "$info_plist")"
        log "reappear candidate attempt=$attempt id=$id stableKey=$stable_key"
        if [[ "$INITIAL_STABLE_KEY" == fallback-name-size=* || "$stable_key" == "$INITIAL_STABLE_KEY" ]]; then
          assert_read_write_state_for_line "$line" "post-replug"
          return 0
        fi
      fi
    fi
    /bin/sleep 2
  done

  return 1
}

write_initial_marker() {
  local marker="$MOUNT_POINT/$MARKER_RELATIVE"
  /bin/mkdir -p "$MOUNT_POINT/$MARKER_DIR"
  /usr/bin/printf 'guided-replug marker %s %s\n' "$DEVICE_ID" "$STAMP" > "$marker"
  /bin/dd if=/dev/urandom bs=1024 count=64 >> "$marker" 2>> "$SUMMARY"
  MARKER_SHA256="$(sha256_file "$marker")"
  MARKER_MD5="$(md5_file "$marker")"
  log "marker=pre-replug path=$marker sha256=$MARKER_SHA256 md5=$MARKER_MD5"
  /bin/sync
}

verify_marker_after_replug() {
  local marker="$MOUNT_POINT/$MARKER_RELATIVE"
  local sha
  local md5
  [[ -f "$marker" ]] || fail "post-replug marker missing: $marker"
  sha="$(sha256_file "$marker")"
  md5="$(md5_file "$marker")"
  log "marker=post-replug path=$marker sha256=$sha md5=$md5"
  [[ "$sha" == "$MARKER_SHA256" ]] || fail "post-replug SHA-256 mismatch"
  [[ "$md5" == "$MARKER_MD5" ]] || fail "post-replug MD5 mismatch"
}

post_replug_file_ops() {
  local work_dir="$MOUNT_POINT/NTFSAccess_post_replug_ops_$STAMP"
  local file="$work_dir/original.txt"
  local renamed="$work_dir/renamed.txt"
  local trash_dir="$MOUNT_POINT/.Trashes/$(/usr/bin/id -u)"
  local trashed="$trash_dir/ntfsaccess-post-replug-$STAMP.txt"

  /bin/mkdir -p "$work_dir"
  /usr/bin/printf 'post-replug write %s\n' "$STAMP" > "$file"
  /usr/bin/grep -q "$STAMP" "$file" || fail "post-replug readback failed"
  /bin/mv "$file" "$renamed"
  [[ -f "$renamed" ]] || fail "post-replug rename failed"
  /bin/mkdir -p "$trash_dir"
  /bin/mv "$renamed" "$trashed"
  [[ -f "$trashed" ]] || fail "post-replug trash move failed"
  /bin/rm -f "$trashed"
  /bin/rmdir "$work_dir"
  /bin/rm -rf "$MOUNT_POINT/$MARKER_DIR"
  log "post-replug file operations passed"
}

prompt_enter() {
  local message="$1"
  if [[ ! -t 0 ]]; then
    fail "guided prompt requires an interactive terminal: $message"
  fi
  printf '%s\n' "$message"
  read -r _
}

if [[ "$EUID" -eq 0 ]]; then
  fail "live_ntfs_guided_unplug_replug.sh must run as the logged-in user, not root"
fi

/bin/mkdir -p "$LOCAL_ROOT"
log "guided=unplug-replug device=$DEVICE expectedName=$EXPECTED_NAME started=$STAMP"
[[ -x "$NTFSACCESSCTL" ]] || fail "missing ntfsaccessctl: $NTFSACCESSCTL"

CURRENT_STEP="preflight"
assert_current_read_write_state "preflight"
INITIAL_NTFS3G_PIDS="$(current_ntfs3g_pids "$DEVICE_ID")"
initial_info="$LOCAL_ROOT/initial-diskutil.plist"
capture_diskutil_info_plist "/dev/$DEVICE_ID" "$initial_info" || fail "initial diskutil info failed"
INITIAL_STABLE_KEY="$(stable_key_from_plist "$initial_info")"
INITIAL_VOLUME_NAME="$(plist_value "$initial_info" :VolumeName)"
log "initial stableKey=$INITIAL_STABLE_KEY volumeName=$INITIAL_VOLUME_NAME mountPoint=$MOUNT_POINT ntfs3gPids=$INITIAL_NTFS3G_PIDS"
write_initial_marker

CURRENT_STEP="manual-unplug"
prompt_enter "Unplug the physical NTFS drive now, then press Return. The script will wait until macOS reports it disappeared."
wait_for_disappear || fail "drive did not disappear after unplug prompt"

CURRENT_STEP="manual-replug"
prompt_enter "Replug the same physical NTFS drive now, then press Return. The script will wait for NTFS Access readWrite recovery."
request_retry
wait_for_reappear || fail "drive did not return as the same readWrite NTFS Access volume"

CURRENT_STEP="post-replug-marker"
verify_marker_after_replug

CURRENT_STEP="post-replug-file-ops"
post_replug_file_ops

log "PASS guided unplug/replug validation"
log "summary=$SUMMARY"
