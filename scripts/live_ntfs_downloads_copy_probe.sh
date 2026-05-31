#!/bin/bash
set -euo pipefail

DEVICE="${1:-}"
EXPECTED_NAME="${2:-}"
shift 2 || true

NTFSACCESSCTL="${NTFSACCESSCTL:-/usr/local/bin/ntfsaccessctl}"
STAMP="$(/bin/date +%Y%m%d-%H%M%S)"
LOCAL_ROOT="/tmp/ntfsaccess-downloads-copy-probe-$STAMP"
SUMMARY="$LOCAL_ROOT/summary.txt"
DOWNLOADS_DIR="${DOWNLOADS_DIR:-$HOME/Downloads}"

fail() {
  printf 'FAIL: %s\n' "$*" | /usr/bin/tee -a "$SUMMARY"
  printf 'summary=%s\n' "$SUMMARY" >&2
  exit 1
}

log() {
  printf '%s\n' "$*" | /usr/bin/tee -a "$SUMMARY"
}

require_tool() {
  local tool="$1"
  if [[ ! -x "$tool" ]] && ! /usr/bin/command -v "$tool" >/dev/null 2>&1; then
    fail "missing required tool: $tool"
  fi
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

device_id_for() {
  printf '%s\n' "${1##*/}"
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

copy_size_bytes() {
  /usr/bin/du -sk "$1" | /usr/bin/awk '{ print $1 * 1024 }'
}

regular_file_count() {
  /usr/bin/find "$1" -type f ! -name '._*' | /usr/bin/wc -l | /usr/bin/tr -d '[:space:]'
}

remove_appledouble_sidecars() {
  local target="$1"
  /usr/bin/find "$target" -name '._*' -delete
}

copy_and_compare_folder() {
  local source="$1"
  local destination="$DEST_ROOT/$(/usr/bin/basename "$source")"
  local expected="$COMPARE_ROOT/expected/$(/usr/bin/basename "$source")"
  local actual="$COMPARE_ROOT/actual/$(/usr/bin/basename "$source")"
  local source_bytes
  local destination_bytes
  local source_files
  local destination_files

  [[ -d "$source" ]] || fail "Downloads source folder does not exist: $source"

  log ""
  log "copySource=$source"
  log "copyDestination=$destination"
  /bin/cp -R "$source" "$destination" >> "$SUMMARY" 2>&1 \
    || fail "Downloads folder copy failed: $source"

  source_bytes="$(copy_size_bytes "$source")"
  destination_bytes="$(copy_size_bytes "$destination")"
  source_files="$(regular_file_count "$source")"
  destination_files="$(regular_file_count "$destination")"
  log "sourceBytes=$source_bytes"
  log "destinationBytes=$destination_bytes"
  log "sourceRegularFileCount=$source_files"
  log "destinationRegularFileCount=$destination_files"

  [[ "$source_files" == "$destination_files" ]] \
    || fail "Downloads folder copy changed regular file count for $source"
  [[ "$destination_bytes" -ge "$source_bytes" ]] \
    || fail "Downloads folder copy destination is smaller than source for $source"

  /usr/bin/ditto --noextattr --norsrc "$source" "$expected" >> "$SUMMARY" 2>&1 \
    || fail "could not normalize source for comparison: $source"
  /usr/bin/ditto --noextattr --norsrc "$destination" "$actual" >> "$SUMMARY" 2>&1 \
    || fail "could not normalize destination for comparison: $destination"
  remove_appledouble_sidecars "$actual" >> "$SUMMARY" 2>&1 \
    || fail "could not normalize AppleDouble sidecars for comparison: $destination"
  /usr/bin/diff -qr "$expected" "$actual" >> "$SUMMARY" 2>&1 \
    || fail "Downloads folder copy content differs after normalization: $source"
}

if [[ -z "$DEVICE" || -z "$EXPECTED_NAME" ]]; then
  echo "usage: live_ntfs_downloads_copy_probe.sh /dev/diskXsY EXPECTED_VOLUME_NAME [DownloadsFolderName ...]" >&2
  exit 64
fi

if [[ "$EUID" -eq 0 ]]; then
  echo "live_ntfs_downloads_copy_probe.sh must run as the logged-in user, not root" >&2
  exit 64
fi

require_tool "$NTFSACCESSCTL"
require_tool /bin/cp
require_tool /usr/bin/ditto
require_tool /usr/bin/diff

/bin/mkdir -p "$LOCAL_ROOT"
: > "$SUMMARY"

DEVICE_ID="$(device_id_for "$DEVICE")"
log "NTFS Access Downloads folder copy probe"
log "device=$DEVICE"
log "expectedName=$EXPECTED_NAME"
log "downloads=$DOWNLOADS_DIR"
log "startedAt=$STAMP"

run_with_timeout 120 "$NTFSACCESSCTL" scan-now --wait >> "$SUMMARY" 2>&1 || true
VOLUMES="$("$NTFSACCESSCTL" list-volumes)"
log "$VOLUMES"
LINE="$(/usr/bin/printf '%s\n' "$VOLUMES" | /usr/bin/awk -F '\t' -v id="$DEVICE_ID" '$1 == id { print; exit }')"
[[ -n "$LINE" ]] || fail "NTFS Access is not managing $DEVICE_ID"

MODE="$(/usr/bin/printf '%s\n' "$LINE" | /usr/bin/awk -F '\t' '{ print $2 }')"
MOUNT_POINT="$(/usr/bin/printf '%s\n' "$LINE" | /usr/bin/awk -F '\t' '{ print $3 }')"
NAME="$(/usr/bin/printf '%s\n' "$LINE" | /usr/bin/awk -F '\t' '{ print $4 }')"

[[ "$MODE" == "readWrite" ]] || fail "expected readWrite mode for $DEVICE_ID, got $MODE"
[[ "$NAME" == "$EXPECTED_NAME" ]] || fail "expected reported name $EXPECTED_NAME, got $NAME"
[[ -d "$MOUNT_POINT" ]] || fail "mount point does not exist: $MOUNT_POINT"
assert_mount_root_user_accessible "$MOUNT_POINT" "downloads-copy"

DEST_ROOT="$MOUNT_POINT/NTFSAccess_downloads_copy_probe_$STAMP"
COMPARE_ROOT="$LOCAL_ROOT/compare"
/bin/mkdir -p "$DEST_ROOT" "$COMPARE_ROOT/expected" "$COMPARE_ROOT/actual"

if [[ "$#" -eq 0 ]]; then
  set -- Reference Telegram
fi

for folder_name in "$@"; do
  copy_and_compare_folder "$DOWNLOADS_DIR/$folder_name"
done

log ""
log "PASS"
log "destination=$DEST_ROOT"
log "summary=$SUMMARY"
