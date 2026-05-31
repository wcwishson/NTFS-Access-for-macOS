#!/bin/bash
set -euo pipefail

DEVICE="${1:-/dev/disk12s1}"
EXPECTED_NAME="${2:-NTFS_STRESS}"

NTFSACCESSCTL="${NTFSACCESSCTL:-/usr/local/bin/ntfsaccessctl}"
DEVICE_ID="${DEVICE##*/}"
STAMP="$(/bin/date +%Y%m%d-%H%M%S)"
LOCAL_ROOT="/tmp/ntfsaccess-live-validation-$STAMP"
SUMMARY="$LOCAL_ROOT/summary.txt"
FINAL_SUMMARY="/tmp/ntfsaccess-live-validation-$STAMP-summary.txt"
STRESS_DIR=""
KEEP_LOCAL_ROOT=0
CURRENT_STEP="startup"
CLEANUP_TIMEOUT_SECONDS="${NTFSACCESS_CLEANUP_TIMEOUT_SECONDS:-60}"

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

run_step() {
  CURRENT_STEP="$1"
  shift
  log "step=$CURRENT_STEP"
  "$@" >> "$SUMMARY" 2>&1 || fail "$CURRENT_STEP failed: $*"
}

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

capture_diskutil_info_plist() {
  local output_path="$1"
  local temp_output="$LOCAL_ROOT/diskutil-info-capture-$$.tmp"
  if ! run_with_timeout_to_file 12 "$temp_output" /usr/sbin/diskutil info -plist "$DEVICE"; then
    /bin/rm -f "$temp_output"
    return 1
  fi
  /bin/mv "$temp_output" "$output_path"
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

log_integrity_pair() {
  local label="$1"
  local left="$2"
  local right="$3"
  local left_sha
  local right_sha
  local left_md5
  local right_md5

  left_sha="$(sha256_file "$left")"
  right_sha="$(sha256_file "$right")"
  left_md5="$(md5_file "$left")"
  right_md5="$(md5_file "$right")"
  log "integrity=$label left_sha256=$left_sha right_sha256=$right_sha left_md5=$left_md5 right_md5=$right_md5"
  [[ "$left_sha" == "$right_sha" ]] || fail "$label SHA-256 mismatch"
  [[ "$left_md5" == "$right_md5" ]] || fail "$label MD5 mismatch"
}

relative_path() {
  local root="$1"
  local path="$2"
  local relative="${path#$root/}"

  if [[ "$path" == "$root" ]]; then
    printf '.\n'
  else
    printf '%s\n' "$relative"
  fi
}

assert_tree_shape_ignoring_appledouble() {
  local label="$1"
  local expected="$2"
  local actual="$3"
  local path
  local relative
  local counterpart

  [[ -d "$expected" ]] || fail "$label expected tree missing: $expected"
  [[ -d "$actual" ]] || fail "$label actual tree missing: $actual"

  while IFS= read -r -d '' path; do
    relative="$(relative_path "$expected" "$path")"
    counterpart="$actual/$relative"
    if [[ -d "$path" ]]; then
      [[ -d "$counterpart" ]] || fail "$label missing directory: $relative"
    elif [[ -f "$path" ]]; then
      [[ -f "$counterpart" ]] || fail "$label missing file: $relative"
      /usr/bin/cmp "$path" "$counterpart" >/dev/null || fail "$label byte comparison failed for $relative"
    else
      fail "$label unsupported fixture entry type: $relative"
    fi
  done < <(/usr/bin/find "$expected" -name '._*' -prune -o -print0)

  while IFS= read -r -d '' path; do
    relative="$(relative_path "$actual" "$path")"
    counterpart="$expected/$relative"
    if [[ "$relative" == "." ]]; then
      continue
    fi
    [[ -e "$counterpart" ]] || fail "$label unexpected non-AppleDouble entry: $relative"
  done < <(/usr/bin/find "$actual" -name '._*' -prune -o -print0)

  local appledouble_count
  appledouble_count="$(/usr/bin/find "$actual" -name '._*' -print | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
  log "appledouble_count label=$label count=$appledouble_count"
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

unmount_or_remount_observed() {
  local before_pids="$1"
  local label="$2"
  local info_plist="$LOCAL_ROOT/${label//[^A-Za-z0-9_.-]/_}-unmount-check.plist"
  local diskutil_mount
  local diskutil_writable
  local current_pids
  local mount_entry

  capture_diskutil_info_plist "$info_plist" || return 1
  diskutil_mount="$(/usr/libexec/PlistBuddy -c 'Print :MountPoint' "$info_plist" 2>/dev/null || true)"
  diskutil_writable="$(/usr/libexec/PlistBuddy -c 'Print :Writable' "$info_plist" 2>/dev/null || /usr/libexec/PlistBuddy -c 'Print :WritableVolume' "$info_plist" 2>/dev/null || true)"
  current_pids="$(current_ntfs3g_pids)"

  if [[ -z "$diskutil_mount" ]]; then
    log "$label unmount observed: no diskutil mount point"
    return 0
  fi

  mount_entry="$(/sbin/mount | /usr/bin/grep -E "(^$DEVICE|$DEVICE_ID|$diskutil_mount)" | /usr/bin/head -n 1 || true)"
  if [[ -n "$current_pids" && "$current_pids" != "$before_pids" ]] \
    && [[ "$diskutil_writable" == "true" || "$diskutil_writable" == "1" ]] \
    && /usr/bin/printf '%s\n' "$mount_entry" | /usr/bin/grep -qi 'macfuse'; then
    log "$label remount observed: mount=$diskutil_mount pids=$current_pids"
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

unmount_device_with_retries() {
  local before_pids
  local attempt
  before_pids="$(current_ntfs3g_pids)"

  if [[ -n "${MOUNT_POINT:-}" && -d "$MOUNT_POINT" ]]; then
    log "trying direct root umount before diskutil for managed macFUSE mount"
    for attempt in 1 2; do
      if run_with_timeout 20 /sbin/umount -f "$MOUNT_POINT"; then
        return 0
      fi
      if wait_for_unmount_or_remount "$before_pids" "initial-umount-$attempt"; then
        return 0
      fi
      /bin/sleep "$attempt"
    done
  fi

  for attempt in 1 2; do
    if run_with_timeout 30 /usr/sbin/diskutil unmount force "$DEVICE"; then
      return 0
    fi
    if wait_for_unmount_or_remount "$before_pids" "force-unmount-$attempt"; then
      return 0
    fi
    /bin/sleep "$attempt"
  done

  if [[ -n "${MOUNT_POINT:-}" && -d "$MOUNT_POINT" ]]; then
    log "diskutil force unmount failed; retrying direct root umount"
    for attempt in 1 2; do
      if run_with_timeout 20 /sbin/umount -f "$MOUNT_POINT"; then
        return 0
      fi
      if wait_for_unmount_or_remount "$before_pids" "umount-$attempt"; then
        return 0
      fi
      /bin/sleep "$attempt"
    done
  fi

  if [[ -n "$before_pids" ]]; then
    log "unmount helpers failed; terminating stale ntfs-3g worker(s): $before_pids"
    /bin/kill -TERM $before_pids >/dev/null 2>&1 || true
    /bin/sleep 2
    /bin/kill -KILL $before_pids >/dev/null 2>&1 || true
    if wait_for_unmount_or_remount "$before_pids" "worker-kill"; then
      return 0
    fi
  fi

  return 1
}

assert_single_ntfs3g_process() {
  local label="$1"
  local process_list
  local process_count
  local expected_volname

  process_list="$(/bin/ps aux | /usr/bin/grep -F 'ntfs-3g' | /usr/bin/grep -F "$DEVICE_ID" | /usr/bin/grep -v grep || true)"
  process_count="$(/usr/bin/printf '%s\n' "$process_list" | /usr/bin/awk 'NF { count += 1 } END { print count + 0 }')"
  expected_volname="$(ntfs3g_volname_for "$EXPECTED_NAME")"

  log ""
  log "$label ntfs-3g process count=$process_count"
  log "$process_list"

  [[ "$process_count" == "1" ]] || fail "$label expected exactly one ntfs-3g process for $DEVICE_ID, found $process_count"
  if ! /usr/bin/printf '%s\n' "$process_list" | /usr/bin/grep -Fq "volname=$expected_volname"; then
    fail "$label ntfs-3g process does not include volname=$expected_volname"
  fi
}

copy_data_file() {
  CURRENT_STEP="$1"
  local src="$2"
  local dst="$3"
  log "step=$CURRENT_STEP"
  COPYFILE_DISABLE=1 /bin/cp -X "$src" "$dst" >> "$SUMMARY" 2>&1 || fail "$CURRENT_STEP failed: cp -X $src $dst"
}

FINDER_INFO_HEX="4649445200000000000000000000000000000000000000000000000000000000"

assert_finder_metadata_copy() {
  local source_dir="$LOCAL_ROOT/finder-metadata-source"
  local destination_dir="$STRESS_DIR/Finder-style metadata copy"
  local source_file="$source_dir/plain.txt"
  local destination_file="$destination_dir/plain.txt"
  local source_finder_info
  local destination_finder_info

  run_step "create Finder-style metadata copy source" mkdir -p "$source_dir/nested"
  printf 'Finder metadata copy probe %s\n' "$STAMP" > "$source_file"
  printf 'nested Finder metadata copy probe %s\n' "$STAMP" > "$source_dir/nested/file.txt"
  /usr/bin/xattr -w com.apple.quarantine "0081;00000000;NTFSAccess;finder-metadata-probe" "$source_file" >> "$SUMMARY" 2>&1 \
    || fail "could not prepare Finder metadata quarantine xattr"
  /usr/bin/xattr -wx com.apple.FinderInfo "$FINDER_INFO_HEX" "$source_file" >> "$SUMMARY" 2>&1 \
    || fail "could not prepare Finder metadata FinderInfo xattr"

  CURRENT_STEP="Finder-style metadata copy"
  log "step=$CURRENT_STEP"
  if ! /bin/cp -R "$source_dir" "$destination_dir" >> "$SUMMARY" 2>&1; then
    fail "could not preserve Finder metadata during folder copy"
  fi

  /usr/bin/grep -q "$STAMP" "$destination_file" || fail "Finder-style metadata copy content missing"
  if ! /usr/bin/xattr -p com.apple.quarantine "$destination_file" >> "$SUMMARY" 2>&1; then
    fail "Finder-style metadata copy lost quarantine xattr"
  fi
  if ! /usr/bin/xattr -p com.apple.FinderInfo "$destination_file" >> "$SUMMARY" 2>&1; then
    fail "Finder-style metadata copy lost FinderInfo xattr"
  fi
  source_finder_info="$(/usr/bin/xattr -px com.apple.FinderInfo "$source_file" | /usr/bin/tr -d '[:space:]')"
  destination_finder_info="$(/usr/bin/xattr -px com.apple.FinderInfo "$destination_file" | /usr/bin/tr -d '[:space:]')"
  [[ "$source_finder_info" == "$destination_finder_info" ]] \
    || fail "Finder-style metadata copy changed FinderInfo xattr"
}

large_file_size_mib() {
  if [[ -n "${NTFSACCESS_LARGE_FILE_MIB:-}" ]]; then
    if ! [[ "$NTFSACCESS_LARGE_FILE_MIB" =~ ^[1-9][0-9]*$ ]]; then
      fail "NTFSACCESS_LARGE_FILE_MIB must be a positive whole number"
    fi
    printf '%s\n' "$NTFSACCESS_LARGE_FILE_MIB"
    return 0
  fi

  local available_kib
  available_kib="$(/bin/df -k "$MOUNT_POINT" | /usr/bin/awk 'NR == 2 { print $4 }')"
  if ! [[ "$available_kib" =~ ^[0-9]+$ ]] || [[ "$available_kib" -lt 262144 ]]; then
    printf '64\n'
    return 0
  fi

  local available_mib=$((available_kib / 1024))
  local candidate=$((available_mib / 3))
  if [[ "$candidate" -lt 64 ]]; then
    candidate=64
  elif [[ "$candidate" -gt 512 ]]; then
    candidate=512
  fi
  printf '%s\n' "$candidate"
}

random_file_count() {
  if [[ -n "${NTFSACCESS_RANDOM_FILE_COUNT:-}" ]]; then
    if ! [[ "$NTFSACCESS_RANDOM_FILE_COUNT" =~ ^[1-9][0-9]*$ ]]; then
      fail "NTFSACCESS_RANDOM_FILE_COUNT must be a positive whole number"
    fi
    printf '%s\n' "$NTFSACCESS_RANDOM_FILE_COUNT"
    return 0
  fi
  printf '8\n'
}

small_file_count() {
  if [[ -n "${NTFSACCESS_SMALL_FILE_COUNT:-}" ]]; then
    if ! [[ "$NTFSACCESS_SMALL_FILE_COUNT" =~ ^[1-9][0-9]*$ ]]; then
      fail "NTFSACCESS_SMALL_FILE_COUNT must be a positive whole number"
    fi
    printf '%s\n' "$NTFSACCESS_SMALL_FILE_COUNT"
    return 0
  fi
  printf '1500\n'
}

random_file_size_mib() {
  if [[ -n "${NTFSACCESS_RANDOM_FILE_MIB:-}" ]]; then
    if ! [[ "$NTFSACCESS_RANDOM_FILE_MIB" =~ ^[1-9][0-9]*$ ]]; then
      fail "NTFSACCESS_RANDOM_FILE_MIB must be a positive whole number"
    fi
    printf '%s\n' "$NTFSACCESS_RANDOM_FILE_MIB"
    return 0
  fi
  printf '64\n'
}

cleanup() {
  local status=$?
  if [[ "$status" -ne 0 && -f "$SUMMARY" ]]; then
    log "FAILED_STEP=$CURRENT_STEP"
    /bin/cp "$SUMMARY" "$FINAL_SUMMARY" >/dev/null 2>&1 || true
    printf 'summary=%s\n' "$FINAL_SUMMARY" >&2
    KEEP_LOCAL_ROOT=1
  fi
  if [[ -n "$STRESS_DIR" && -d "$STRESS_DIR" ]]; then
    if ! run_with_timeout "$CLEANUP_TIMEOUT_SECONDS" /bin/rm -rf "$STRESS_DIR" >/dev/null 2>&1; then
      log "cleanup=deferred path=$STRESS_DIR reason=timeout-after-${CLEANUP_TIMEOUT_SECONDS}s"
    fi
  fi
  if [[ "$KEEP_LOCAL_ROOT" -eq 0 ]]; then
    /bin/rm -rf "$LOCAL_ROOT" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT

CURRENT_STEP="create local work directory"
mkdir -p "$LOCAL_ROOT"
: > "$SUMMARY"

require_tool() {
  local tool="$1"
  if [[ ! -x "$tool" ]] && ! /usr/bin/command -v "$tool" >/dev/null 2>&1; then
    fail "missing required tool: $tool"
  fi
}

require_tool "$NTFSACCESSCTL"
require_tool /usr/sbin/diskutil
require_tool /usr/bin/plutil
require_tool /usr/bin/shasum
require_tool /sbin/md5
require_tool /usr/bin/cmp
require_tool /usr/bin/diff
require_tool /usr/bin/rsync
require_tool /usr/sbin/mkfile
require_tool /usr/bin/jot

log "NTFS Access live full validation"
log "device=$DEVICE"
log "expectedName=$EXPECTED_NAME"
log "startedAt=$STAMP"

CURRENT_STEP="initial scan"
request_scan

VOLUMES="$("$NTFSACCESSCTL" list-volumes)"
log ""
log "ntfsaccessctl list-volumes:"
log "$VOLUMES"

if ! /usr/bin/printf '%s\n' "$VOLUMES" | /usr/bin/grep -q "^$DEVICE_ID[[:space:]]"; then
  fail "NTFS Access is not managing $DEVICE_ID"
fi

VOLUME_LINE="$(/usr/bin/printf '%s\n' "$VOLUMES" | /usr/bin/awk -F '\t' -v id="$DEVICE_ID" '$1 == id { print; exit }')"
MODE="$(/usr/bin/printf '%s\n' "$VOLUME_LINE" | /usr/bin/awk -F '\t' '{ print $2 }')"
MOUNT_POINT="$(/usr/bin/printf '%s\n' "$VOLUME_LINE" | /usr/bin/awk -F '\t' '{ print $3 }')"
REPORTED_NAME="$(/usr/bin/printf '%s\n' "$VOLUME_LINE" | /usr/bin/awk -F '\t' '{ print $4 }')"

[[ "$MODE" == "readWrite" ]] || fail "expected readWrite mode for $DEVICE_ID, got $MODE"
[[ -d "$MOUNT_POINT" ]] || fail "reported mount point does not exist: $MOUNT_POINT"
[[ "$REPORTED_NAME" == "$EXPECTED_NAME" ]] || fail "expected reported name $EXPECTED_NAME, got $REPORTED_NAME"
assert_mount_root_user_accessible "$MOUNT_POINT" "preflight"

INFO_PLIST="$LOCAL_ROOT/diskutil-info.plist"
capture_diskutil_info_plist "$INFO_PLIST" || fail "diskutil info -plist timed out or failed for $DEVICE"

DISKUTIL_NAME="$(/usr/libexec/PlistBuddy -c 'Print :VolumeName' "$INFO_PLIST" 2>/dev/null || true)"
DISKUTIL_MOUNT="$(/usr/libexec/PlistBuddy -c 'Print :MountPoint' "$INFO_PLIST" 2>/dev/null || true)"
DISKUTIL_WRITABLE="$(/usr/libexec/PlistBuddy -c 'Print :Writable' "$INFO_PLIST" 2>/dev/null || /usr/libexec/PlistBuddy -c 'Print :WritableVolume' "$INFO_PLIST" 2>/dev/null || true)"
FILESYSTEM_TYPE="$(/usr/libexec/PlistBuddy -c 'Print :FilesystemType' "$INFO_PLIST" 2>/dev/null || true)"

log ""
log "diskutil parsed state:"
log "volumeName=$DISKUTIL_NAME"
log "mountPoint=$DISKUTIL_MOUNT"
log "writable=$DISKUTIL_WRITABLE"
log "filesystemType=$FILESYSTEM_TYPE"

[[ "$DISKUTIL_NAME" == "$EXPECTED_NAME" ]] || fail "Disk Utility volume name mismatch: expected $EXPECTED_NAME, got $DISKUTIL_NAME"
[[ "$DISKUTIL_WRITABLE" == "true" || "$DISKUTIL_WRITABLE" == "1" ]] || fail "diskutil does not report the volume writable"

MOUNT_ENTRY="$(/sbin/mount | /usr/bin/grep -E "(^$DEVICE|$DEVICE_ID|$MOUNT_POINT)" | /usr/bin/head -n 1 || true)"
log ""
log "mount entry:"
log "$MOUNT_ENTRY"

[[ -n "$MOUNT_ENTRY" ]] || fail "mount entry not found"
if ! /usr/bin/printf '%s\n' "$MOUNT_ENTRY" | /usr/bin/grep -qi 'macfuse'; then
  fail "mount entry does not show macFUSE/ntfs-3g ownership"
fi
if /usr/bin/printf '%s\n' "$MOUNT_ENTRY" | /usr/bin/grep -qi 'read-only'; then
  fail "mount entry still says read-only"
fi

assert_single_ntfs3g_process "preflight"

STRESS_DIR="$MOUNT_POINT/NTFSAccess_full_validation_$STAMP"
ROUNDTRIP_DIR="$LOCAL_ROOT/roundtrip"
run_step "create stress directories" mkdir -p "$STRESS_DIR" "$ROUNDTRIP_DIR"

log ""
log "stressDir=$STRESS_DIR"

CURRENT_STEP="basic create write append"
printf 'NTFS Access validation marker %s\n' "$STAMP" > "$STRESS_DIR/basic.txt"
printf 'append line\n' >> "$STRESS_DIR/basic.txt"
/usr/bin/grep -q 'append line' "$STRESS_DIR/basic.txt" || fail "basic append/read failed"

run_step "create nested directories" mkdir -p "$STRESS_DIR/nested folder/child"
CURRENT_STEP="write spaces and unicode filename"
printf 'spaces and unicode\n' > "$STRESS_DIR/nested folder/child/file with spaces 中文 test.txt"
LONG_NAME="long-name-$(/usr/bin/jot -s '' -b a 120).txt"
CURRENT_STEP="write long filename"
printf 'long name\n' > "$STRESS_DIR/$LONG_NAME"

run_step "create local source tree" mkdir -p "$LOCAL_ROOT/source-tree/subdir"
printf 'source tree alpha\n' > "$LOCAL_ROOT/source-tree/alpha.txt"
printf 'source tree beta\n' > "$LOCAL_ROOT/source-tree/subdir/beta.txt"
run_step "rsync APFS to NTFS" /usr/bin/rsync -a "$LOCAL_ROOT/source-tree/" "$STRESS_DIR/copied-from-apfs/"
run_step "rsync NTFS to APFS" /usr/bin/rsync -a "$STRESS_DIR/copied-from-apfs/" "$ROUNDTRIP_DIR/"
CURRENT_STEP="compare APFS NTFS roundtrip ignoring AppleDouble metadata"
log "step=$CURRENT_STEP"
assert_tree_shape_ignoring_appledouble "apfs-ntfs-apfs-roundtrip" "$LOCAL_ROOT/source-tree" "$ROUNDTRIP_DIR"
assert_finder_metadata_copy

run_step "create many-small directory" mkdir -p "$STRESS_DIR/many-small"
SMALL_FILE_COUNT="$(small_file_count)"
log "smallFileCount=$SMALL_FILE_COUNT"
CURRENT_STEP="write $SMALL_FILE_COUNT small files"
SMALL_CREATE_START="$(now_epoch)"
for i in $(/usr/bin/jot "$SMALL_FILE_COUNT"); do
  printf 'small-file-%04d %s\n' "$i" "$STAMP" > "$STRESS_DIR/many-small/file-$(printf '%04d' "$i").txt"
done
SMALL_CREATE_END="$(now_epoch)"
SMALL_CREATE_SECONDS=$((SMALL_CREATE_END - SMALL_CREATE_START))
SMALL_CREATE_RATE=""
if [[ "$SMALL_CREATE_SECONDS" -gt 0 ]]; then
  SMALL_CREATE_RATE=" files_per_sec=$(/usr/bin/awk -v files="$SMALL_FILE_COUNT" -v seconds="$SMALL_CREATE_SECONDS" 'BEGIN { printf "%.2f", files / seconds }')"
fi
log "timing=many-small-create metric=files=$SMALL_FILE_COUNT start=$SMALL_CREATE_START end=$SMALL_CREATE_END seconds=$SMALL_CREATE_SECONDS status=0$SMALL_CREATE_RATE"
SMALL_COUNT="$(/usr/bin/find "$STRESS_DIR/many-small" -name '._*' -prune -o -type f -print | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
[[ "$SMALL_COUNT" == "$SMALL_FILE_COUNT" ]] || fail "expected $SMALL_FILE_COUNT small files, found $SMALL_COUNT"

RANDOM_FILE_COUNT="$(random_file_count)"
RANDOM_FILE_MIB="$(random_file_size_mib)"
log "randomFileCount=$RANDOM_FILE_COUNT"
log "randomFileMiB=$RANDOM_FILE_MIB"
run_step "create random test directories" mkdir -p "$LOCAL_ROOT/random-source" "$STRESS_DIR/random"
for i in $(/usr/bin/jot "$RANDOM_FILE_COUNT"); do
  src="$LOCAL_ROOT/random-source/random-$(printf '%02d' "$i").bin"
  dst="$STRESS_DIR/random/random-$(printf '%02d' "$i").bin"
  run_step "create random source $i" /usr/sbin/mkfile "${RANDOM_FILE_MIB}m" "$src"
  copy_data_file "copy random file $i" "$src" "$dst"
  run_step "compare random file $i" /usr/bin/cmp "$src" "$dst"
  log_integrity_pair "random-$(printf '%02d' "$i")" "$src" "$dst"
done

LARGE_MIB="$(large_file_size_mib)"
LARGE_SRC="$LOCAL_ROOT/large-${LARGE_MIB}m.bin"
LARGE_DST="$STRESS_DIR/large-${LARGE_MIB}m.bin"
LARGE_ROUNDTRIP="$ROUNDTRIP_DIR/large-${LARGE_MIB}m-roundtrip.bin"
log "largeFileMiB=$LARGE_MIB"
run_step "create ${LARGE_MIB}MiB source" /usr/sbin/mkfile "${LARGE_MIB}m" "$LARGE_SRC"
CURRENT_STEP="copy ${LARGE_MIB}MiB file"
log "step=$CURRENT_STEP"
time_step "large-copy-apfs-to-ntfs" "bytes=$((LARGE_MIB * 1048576))" /usr/bin/env COPYFILE_DISABLE=1 /bin/cp -X "$LARGE_SRC" "$LARGE_DST" >> "$SUMMARY" 2>&1 \
  || fail "$CURRENT_STEP failed: cp -X $LARGE_SRC $LARGE_DST"
run_step "compare ${LARGE_MIB}MiB file" /usr/bin/cmp "$LARGE_SRC" "$LARGE_DST"
log_integrity_pair "large-apfs-to-ntfs" "$LARGE_SRC" "$LARGE_DST"
CURRENT_STEP="copy ${LARGE_MIB}MiB file NTFS to APFS"
log "step=$CURRENT_STEP"
time_step "large-copy-ntfs-to-apfs" "bytes=$((LARGE_MIB * 1048576))" /usr/bin/env COPYFILE_DISABLE=1 /bin/cp -X "$LARGE_DST" "$LARGE_ROUNDTRIP" >> "$SUMMARY" 2>&1 \
  || fail "$CURRENT_STEP failed: cp -X $LARGE_DST $LARGE_ROUNDTRIP"
run_step "compare ${LARGE_MIB}MiB roundtrip file" /usr/bin/cmp "$LARGE_SRC" "$LARGE_ROUNDTRIP"
log_integrity_pair "large-apfs-ntfs-apfs-roundtrip" "$LARGE_SRC" "$LARGE_ROUNDTRIP"
LARGE_HASH_BEFORE="$(sha256_file "$LARGE_DST")"
LARGE_MD5_BEFORE="$(md5_file "$LARGE_DST")"
log "integrity=large-before-remount sha256=$LARGE_HASH_BEFORE md5=$LARGE_MD5_BEFORE"

run_step "create renamed-files directory" mkdir -p "$STRESS_DIR/renamed-files"
CURRENT_STEP="rename 50 files"
for i in $(/usr/bin/jot 50); do
  file="$STRESS_DIR/many-small/file-$(printf '%04d' "$i").txt"
  base="$(/usr/bin/basename "$file")"
  /bin/mv "$file" "$STRESS_DIR/renamed-files/renamed-$base"
done

run_step "create delete-me directory" mkdir -p "$STRESS_DIR/delete-me"
CURRENT_STEP="create delete batch"
DELETE_CREATE_START="$(now_epoch)"
for i in $(/usr/bin/jot 400); do
  printf 'delete %04d\n' "$i" > "$STRESS_DIR/delete-me/delete-$(printf '%04d' "$i").txt"
done
DELETE_CREATE_END="$(now_epoch)"
DELETE_CREATE_SECONDS=$((DELETE_CREATE_END - DELETE_CREATE_START))
DELETE_CREATE_RATE=""
if [[ "$DELETE_CREATE_SECONDS" -gt 0 ]]; then
  DELETE_CREATE_RATE=" files_per_sec=$(/usr/bin/awk -v files=400 -v seconds="$DELETE_CREATE_SECONDS" 'BEGIN { printf "%.2f", files / seconds }')"
fi
log "timing=delete-batch-create metric=files=400 start=$DELETE_CREATE_START end=$DELETE_CREATE_END seconds=$DELETE_CREATE_SECONDS status=0$DELETE_CREATE_RATE"
CURRENT_STEP="delete batch"
log "step=$CURRENT_STEP"
time_step "delete-batch-remove" "files=400" /bin/rm -rf "$STRESS_DIR/delete-me" >> "$SUMMARY" 2>&1 \
  || fail "$CURRENT_STEP failed: rm -rf $STRESS_DIR/delete-me"
[[ ! -e "$STRESS_DIR/delete-me" ]] || fail "delete-me directory survived deletion"

if /bin/ln -s basic.txt "$STRESS_DIR/basic-link" 2>/dev/null; then
  log "symlink=create-supported"
else
  log "symlink=create-not-supported"
fi

/usr/bin/stat -f 'basic.txt size=%z mode=%OLp modified=%Sm' "$STRESS_DIR/basic.txt" >> "$SUMMARY"
/bin/sync
log "durability=flush-evidence phase=pre-remount sync=ok sha256=$LARGE_HASH_BEFORE md5=$LARGE_MD5_BEFORE"

log ""
log "requesting unmount/remount"
REMOUNT_START="$(now_epoch)"
run_step "diskutil unmount with retries" unmount_device_with_retries
/bin/sleep 3
request_scan

POST_VOLUMES="$("$NTFSACCESSCTL" list-volumes)"
log ""
log "post-remount list-volumes:"
log "$POST_VOLUMES"
POST_LINE="$(/usr/bin/printf '%s\n' "$POST_VOLUMES" | /usr/bin/awk -F '\t' -v id="$DEVICE_ID" '$1 == id { print; exit }')"
POST_MODE="$(/usr/bin/printf '%s\n' "$POST_LINE" | /usr/bin/awk -F '\t' '{ print $2 }')"
POST_MOUNT="$(/usr/bin/printf '%s\n' "$POST_LINE" | /usr/bin/awk -F '\t' '{ print $3 }')"
POST_NAME="$(/usr/bin/printf '%s\n' "$POST_LINE" | /usr/bin/awk -F '\t' '{ print $4 }')"

[[ "$POST_MODE" == "readWrite" ]] || fail "post-remount expected readWrite mode, got $POST_MODE"
[[ "$POST_NAME" == "$EXPECTED_NAME" ]] || fail "post-remount expected name $EXPECTED_NAME, got $POST_NAME"
[[ -d "$POST_MOUNT" ]] || fail "post-remount mount point missing: $POST_MOUNT"
assert_mount_root_user_accessible "$POST_MOUNT" "post-remount"
assert_single_ntfs3g_process "post-remount"
REMOUNT_END="$(now_epoch)"
log "timing=unmount-remount metric=device=$DEVICE_ID start=$REMOUNT_START end=$REMOUNT_END seconds=$((REMOUNT_END - REMOUNT_START)) status=0"

STRESS_DIR="$POST_MOUNT/NTFSAccess_full_validation_$STAMP"
[[ -f "$STRESS_DIR/large-${LARGE_MIB}m.bin" ]] || fail "large file missing after remount"
LARGE_HASH_AFTER="$(sha256_file "$STRESS_DIR/large-${LARGE_MIB}m.bin")"
LARGE_MD5_AFTER="$(md5_file "$STRESS_DIR/large-${LARGE_MIB}m.bin")"
log "integrity=large-after-remount sha256=$LARGE_HASH_AFTER md5=$LARGE_MD5_AFTER"
[[ "$LARGE_HASH_BEFORE" == "$LARGE_HASH_AFTER" ]] || fail "large file checksum changed after remount"
[[ "$LARGE_MD5_BEFORE" == "$LARGE_MD5_AFTER" ]] || fail "large file MD5 changed after remount"
log "durability=flush-evidence phase=post-remount sync=ok remount=ok sha256=ok md5=ok"

printf 'post-remount write %s\n' "$STAMP" > "$STRESS_DIR/post-remount-marker.txt"
/usr/bin/grep -q 'post-remount write' "$STRESS_DIR/post-remount-marker.txt" || fail "post-remount write/read failed"
/bin/sync

MARKER="$POST_MOUNT/NTFSAccess_validation_passed_$STAMP.txt"
{
  printf 'NTFS Access full validation passed\n'
  printf 'timestamp=%s\n' "$STAMP"
  printf 'device=%s\n' "$DEVICE"
  printf 'volume=%s\n' "$EXPECTED_NAME"
  printf 'mountPoint=%s\n' "$POST_MOUNT"
} > "$MARKER"

/bin/rm -rf "$STRESS_DIR"
STRESS_DIR=""
/bin/sync

log ""
log "PASS"
log "marker=$MARKER"
log "summary=$SUMMARY"
KEEP_LOCAL_ROOT=1
