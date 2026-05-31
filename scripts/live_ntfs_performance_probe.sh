#!/bin/bash
set -euo pipefail

if [[ "$(id -u)" == "0" ]]; then
  echo "live_ntfs_performance_probe.sh must run as the logged-in user, not root" >&2
  exit 1
fi

usage() {
  cat <<'USAGE'
Usage:
  live_ntfs_performance_probe.sh /Volumes/NAME
  live_ntfs_performance_probe.sh /dev/diskXsY ExpectedVolumeName

Environment:
  NTFSACCESS_PERF_MAX_MIB       Maximum sequential test size in MiB (default: 128)
  NTFSACCESS_PERF_MIN_FREE_MIB  Free-space reserve to keep untouched (default: 256)
  NTFSACCESS_PERF_TIMEOUT       Per-operation timeout in seconds (default: 120)
  NTFSACCESS_SMALL_FILE_COUNT   Small-file count (default: 200)
USAGE
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage >&2
  exit 2
fi

DEVICE_ARG="${1:-}"
EXPECTED_NAME="${2:-}"
STAMP="$(/bin/date +%Y%m%d-%H%M%S)"
WORK_ROOT="/tmp/ntfsaccess-performance-probe-$STAMP"
LOCAL_ROOT="$WORK_ROOT/local"
SUMMARY="$WORK_ROOT/summary.txt"
MAX_MIB="${NTFSACCESS_PERF_MAX_MIB:-128}"
MIN_FREE_MIB="${NTFSACCESS_PERF_MIN_FREE_MIB:-256}"
TIMEOUT_SECONDS="${NTFSACCESS_PERF_TIMEOUT:-120}"
SMALL_FILE_COUNT="${NTFSACCESS_SMALL_FILE_COUNT:-200}"
RANDOM_CHUNK_COUNT="${NTFSACCESS_PERF_RANDOM_CHUNKS:-64}"
RANDOM_CHUNK_KIB="${NTFSACCESS_PERF_RANDOM_CHUNK_KIB:-64}"
NTFSACCESSCTL="${NTFSACCESSCTL:-/usr/local/bin/ntfsaccessctl}"
DEVICE_ID=""

mkdir -p "$LOCAL_ROOT"

log() {
  printf '%s\n' "$*" | tee -a "$SUMMARY"
}

fail() {
  log "FAIL: $*"
  exit 1
}

run_with_timeout() {
  local seconds="$1"
  shift
  local tmp_status="$WORK_ROOT/status.$$"
  local command_status=0
  rm -f "$tmp_status"
  "$@" &
  local pid=$!
  (
    sleep "$seconds"
    if kill -0 "$pid" 2>/dev/null; then
      echo "timeout after ${seconds}s" >"$tmp_status"
      kill -TERM "$pid" 2>/dev/null || true
      sleep 1
      kill -KILL "$pid" 2>/dev/null || true
    fi
  ) &
  local watcher=$!
  set +e
  wait "$pid"
  command_status=$?
  set -e
  kill "$watcher" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true
  if [[ -s "$tmp_status" ]]; then
    local message
    message="$(cat "$tmp_status")"
    rm -f "$tmp_status"
    fail "$message: $*"
  fi
  rm -f "$tmp_status"
  return "$command_status"
}

elapsed_ms() {
  local start="$1"
  local end
  end="$(/bin/date +%s)"
  echo $(( (end - start) * 1000 ))
}

sha256_file() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{ print $1 }'
}

md5_file() {
  /sbin/md5 -q "$1"
}

device_from_volume() {
  local volume="$1"
  local plist device_node
  plist="$(/usr/sbin/diskutil info -plist "$volume" 2>/dev/null || true)"
  device_node="$(/usr/bin/printf '%s' "$plist" | /usr/bin/plutil -extract DeviceNode raw -o - - 2>/dev/null || true)"
  if [[ "$device_node" == /dev/disk* ]]; then
    /usr/bin/basename "$device_node"
    return 0
  fi
  return 1
}

volume_from_device() {
  local device="$1"
  local name="$2"
  if [[ -n "$name" && -d "/Volumes/$name" ]]; then
    echo "/Volumes/$name"
    return 0
  fi

  local plist mount_point
  plist="$(/usr/sbin/diskutil info -plist "$device" 2>/dev/null || true)"
  mount_point="$(printf '%s' "$plist" | /usr/bin/plutil -extract MountPoint raw -o - - 2>/dev/null || true)"
  if [[ -n "$mount_point" && "$mount_point" != "(null)" && -d "$mount_point" ]]; then
    echo "$mount_point"
    return 0
  fi
  return 1
}

if [[ "$DEVICE_ARG" == /dev/disk* ]]; then
  DEVICE_ID="${DEVICE_ARG##*/}"
  VOLUME_PATH="$(volume_from_device "$DEVICE_ARG" "$EXPECTED_NAME")" || fail "Could not resolve mounted volume for $DEVICE_ARG"
else
  VOLUME_PATH="$DEVICE_ARG"
  DEVICE_ID="$(device_from_volume "$VOLUME_PATH" || true)"
fi

[[ -d "$VOLUME_PATH" ]] || fail "Volume path does not exist: $VOLUME_PATH"
[[ -w "$VOLUME_PATH" ]] || fail "Volume path is not writable by the logged-in user: $VOLUME_PATH"

available_kib="$(/bin/df -Pk "$VOLUME_PATH" | /usr/bin/awk 'NR == 2 { print $4 }')"
available_mib=$(( available_kib / 1024 ))
cap_mib="$MAX_MIB"
spare_mib=$(( available_mib - MIN_FREE_MIB ))
if [[ "$spare_mib" -lt 8 ]]; then
  fail "Not enough free space for probe while keeping ${MIN_FREE_MIB}MiB reserve: available=${available_mib}MiB"
fi
if [[ "$spare_mib" -lt "$cap_mib" ]]; then
  cap_mib="$spare_mib"
fi
if [[ "$cap_mib" -lt 8 ]]; then
  cap_mib=8
fi

TEST_ROOT="$VOLUME_PATH/.ntfsaccess-performance-probe-$STAMP"
mkdir -p "$TEST_ROOT"
trap 'rm -rf "$TEST_ROOT" "$LOCAL_ROOT" 2>/dev/null || true' EXIT

log "summary=$SUMMARY"
log "volume=$VOLUME_PATH"
log "available_mib=$available_mib"
log "cap_mib=$cap_mib"
log "small_file_count=$SMALL_FILE_COUNT"
log "random_chunk_count=$RANDOM_CHUNK_COUNT"
log "random_chunk_kib=$RANDOM_CHUNK_KIB"
log "device_id=${DEVICE_ID:-unresolved}"

SOURCE_FILE="$LOCAL_ROOT/source-${cap_mib}m.bin"
NTFS_FILE="$TEST_ROOT/source-${cap_mib}m.bin"
ROUNDTRIP_FILE="$LOCAL_ROOT/roundtrip-${cap_mib}m.bin"

start="$(/bin/date +%s)"
run_with_timeout "$TIMEOUT_SECONDS" /usr/sbin/mkfile "${cap_mib}m" "$SOURCE_FILE"
log "local_source_create_ms=$(elapsed_ms "$start")"

source_sha256="$(sha256_file "$SOURCE_FILE")"
source_md5="$(md5_file "$SOURCE_FILE")"
log "source_sha256=$source_sha256"
log "source_md5=$source_md5"

start="$(/bin/date +%s)"
run_with_timeout "$TIMEOUT_SECONDS" /bin/cp "$SOURCE_FILE" "$NTFS_FILE"
/bin/sync
write_ms="$(elapsed_ms "$start")"
/usr/bin/cmp "$SOURCE_FILE" "$NTFS_FILE"
ntfs_sha256="$(sha256_file "$NTFS_FILE")"
ntfs_md5="$(md5_file "$NTFS_FILE")"
log "sequential_write_ms=$write_ms"
write_divisor="$write_ms"
if [[ "$write_divisor" -le 0 ]]; then
  write_divisor=1
fi
log "sequential_write_mib_per_s=$(( cap_mib * 1000 / write_divisor ))"
log "ntfs_sha256=$ntfs_sha256"
log "ntfs_md5=$ntfs_md5"
[[ "$source_sha256" == "$ntfs_sha256" ]] || fail "SHA-256 mismatch after write"
[[ "$source_md5" == "$ntfs_md5" ]] || fail "MD5 mismatch after write"

start="$(/bin/date +%s)"
run_with_timeout "$TIMEOUT_SECONDS" /bin/cp "$NTFS_FILE" "$ROUNDTRIP_FILE"
read_ms="$(elapsed_ms "$start")"
/usr/bin/cmp "$SOURCE_FILE" "$ROUNDTRIP_FILE"
log "sequential_read_ms=$read_ms"
read_divisor="$read_ms"
if [[ "$read_divisor" -le 0 ]]; then
  read_divisor=1
fi
log "sequential_read_mib_per_s=$(( cap_mib * 1000 / read_divisor ))"

RANDOM_ROOT="$TEST_ROOT/random-ish-chunks"
mkdir -p "$RANDOM_ROOT"
start="$(/bin/date +%s)"
for i in $(/usr/bin/seq 1 "$RANDOM_CHUNK_COUNT"); do
  chunk="$RANDOM_ROOT/chunk-$(/usr/bin/printf '%04d' "$i").bin"
  /usr/bin/perl -e '
    my ($index, $stamp, $bytes) = @ARGV;
    my $seed = sprintf("ntfsaccess-random-ish-chunk %04d %s\n", $index, $stamp);
    print substr($seed x (int($bytes / length($seed)) + 1), 0, $bytes);
  ' "$i" "$STAMP" "$(( RANDOM_CHUNK_KIB * 1024 ))" > "$chunk"
done
/bin/sync
random_write_ms="$(elapsed_ms "$start")"
random_hash="$(/usr/bin/find "$RANDOM_ROOT" -type f -print0 | /usr/bin/sort -z | /usr/bin/xargs -0 /usr/bin/shasum -a 256 | /usr/bin/shasum -a 256 | /usr/bin/awk '{ print $1 }')"
log "random_chunk_write_ms=$random_write_ms"
log "random_chunk_tree_sha256=$random_hash"

CHUNK_ROOT="$TEST_ROOT/small-chunks"
mkdir -p "$CHUNK_ROOT"
start="$(/bin/date +%s)"
for i in $(/usr/bin/seq 1 "$SMALL_FILE_COUNT"); do
  /usr/bin/printf 'ntfsaccess-small-file-%04d-%s\n' "$i" "$STAMP" >"$CHUNK_ROOT/file-$i.txt"
done
/bin/sync
small_create_ms="$(elapsed_ms "$start")"
log "small_file_create_ms=$small_create_ms"
log "small_file_create_count=$SMALL_FILE_COUNT"
small_create_divisor="$small_create_ms"
if [[ "$small_create_divisor" -le 0 ]]; then
  small_create_divisor=1
fi
log "small_file_create_files_per_s=$(( SMALL_FILE_COUNT * 1000 / small_create_divisor ))"

start="$(/bin/date +%s)"
run_with_timeout "$TIMEOUT_SECONDS" /bin/rm -rf "$CHUNK_ROOT"
/bin/sync
small_delete_ms="$(elapsed_ms "$start")"
log "small_file_delete_ms=$small_delete_ms"
small_delete_divisor="$small_delete_ms"
if [[ "$small_delete_divisor" -le 0 ]]; then
  small_delete_divisor=1
fi
log "small_file_delete_files_per_s=$(( SMALL_FILE_COUNT * 1000 / small_delete_divisor ))"

FOLDER_SRC="$LOCAL_ROOT/finder-style-folder"
FOLDER_DST="$TEST_ROOT/finder-style-folder"
mkdir -p "$FOLDER_SRC/sub"
/usr/bin/printf 'hello pdf-like payload\n' >"$FOLDER_SRC/report.pdf"
/usr/bin/printf 'image-like payload\n' >"$FOLDER_SRC/sub/photo.jpg"
/usr/bin/xattr -w com.apple.metadata:kMDItemWhereFroms "ntfsaccess-performance-probe" "$FOLDER_SRC/report.pdf" 2>/dev/null || true
start="$(/bin/date +%s)"
run_with_timeout "$TIMEOUT_SECONDS" /bin/cp -R "$FOLDER_SRC" "$FOLDER_DST"
/bin/sync
folder_copy_ms="$(elapsed_ms "$start")"
[[ -f "$FOLDER_DST/report.pdf" && -f "$FOLDER_DST/sub/photo.jpg" ]] || fail "Folder copy did not preserve expected files"
log "folder_copy_ms=$folder_copy_ms"

start="$(/bin/date +%s)"
/bin/sync
sync_ms="$(elapsed_ms "$start")"
log "sync_ms=$sync_ms"

if [[ -x "$NTFSACCESSCTL" ]]; then
  start="$(/bin/date +%s)"
  if run_with_timeout "$TIMEOUT_SECONDS" "$NTFSACCESSCTL" scan-now --wait >>"$SUMMARY" 2>&1; then
    log "daemon_scan_ms=$(elapsed_ms "$start")"
  else
    log "daemon_scan_status=skipped_or_failed path=$NTFSACCESSCTL"
  fi
else
  log "daemon_scan_status=skipped reason=ntfsaccessctl-not-found path=$NTFSACCESSCTL"
fi

if [[ -n "$DEVICE_ID" ]]; then
  start="$(/bin/date +%s)"
  if run_with_timeout "$TIMEOUT_SECONDS" /usr/sbin/diskutil unmount force "/dev/$DEVICE_ID"; then
    unmount_ms="$(elapsed_ms "$start")"
    log "forced_unmount_ms=$unmount_ms"

    start="$(/bin/date +%s)"
    run_with_timeout "$TIMEOUT_SECONDS" /usr/sbin/diskutil mount "/dev/$DEVICE_ID" || fail "remount failed for /dev/$DEVICE_ID"
    remount_ms="$(elapsed_ms "$start")"
    log "remount_ms=$remount_ms"

    VOLUME_PATH="$(volume_from_device "/dev/$DEVICE_ID" "$EXPECTED_NAME")" || fail "could not resolve mount point after remount for /dev/$DEVICE_ID"
    TEST_ROOT="$VOLUME_PATH/.ntfsaccess-performance-probe-$STAMP"
    NTFS_FILE="$TEST_ROOT/source-${cap_mib}m.bin"
    [[ -f "$NTFS_FILE" ]] || fail "post-remount test file missing: $NTFS_FILE"
    post_remount_sha256="$(sha256_file "$NTFS_FILE")"
    post_remount_md5="$(md5_file "$NTFS_FILE")"
    log "post_remount_sha256=$post_remount_sha256"
    log "post_remount_md5=$post_remount_md5"
    [[ "$source_sha256" == "$post_remount_sha256" ]] || fail "post-remount SHA-256 mismatch"
    [[ "$source_md5" == "$post_remount_md5" ]] || fail "post-remount MD5 mismatch"
  else
    log "forced_unmount_status=skipped_or_failed device=/dev/$DEVICE_ID"
  fi
else
  log "remount_status=skipped reason=device-identifier-unresolved"
fi

log "result=pass"
log "summary_path=$SUMMARY"
