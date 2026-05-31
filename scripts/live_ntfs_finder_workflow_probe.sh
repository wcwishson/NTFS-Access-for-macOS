#!/bin/bash
set -euo pipefail

DEVICE="${1:-}"
EXPECTED_NAME="${2:-}"
NTFSACCESSCTL="${NTFSACCESSCTL:-/usr/local/bin/ntfsaccessctl}"
STAMP="$(/bin/date +%Y%m%d-%H%M%S)"
LOCAL_ROOT="/tmp/ntfsaccess-finder-workflow-probe-$STAMP"
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

refresh_mount_state() {
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
  assert_mount_root_user_accessible "$MOUNT_POINT" "refresh"
  /sbin/mount | /usr/bin/grep -F "$MOUNT_POINT" >> "$SUMMARY" \
    || fail "mount table does not contain $MOUNT_POINT"

  export VOLUMES LINE MODE MOUNT_POINT NAME
}

assert_async_mount() {
  local mount_line="$1"
  log "mountLine=$mount_line"
  [[ "$mount_line" == *"asynchronous"* ]] \
    || fail "expected asynchronous macFUSE mount after performance fix"
  [[ "$mount_line" != *" synchronous"* ]] \
    || fail "mount is still synchronous"
}

copy_path() {
  local source="$1"
  local destination="$2"
  [[ -e "$source" ]] || fail "source does not exist: $source"
  log "copySource=$source"
  log "copyDestination=$destination"
  source_bytes="$(/usr/bin/du -sk "$source" | /usr/bin/awk '{ print $1 * 1024 }')"
  time_step "finder-copy" "bytes=$source_bytes source=$source" run_with_timeout 180 /bin/cp -R "$source" "$destination" >> "$SUMMARY" 2>&1 \
    || fail "copy failed or timed out: $source"
  [[ -e "$destination" ]] || fail "copy destination missing: $destination"
}

trash_and_remove() {
  local target="$1"
  local trash_root="$MOUNT_POINT/.Trashes/$(/usr/bin/id -u)"
  local trashed="$trash_root/$(/usr/bin/basename "$target").$STAMP"
  /bin/mkdir -p "$trash_root"
  log "trashTarget=$target"
  time_step "finder-trash-move" "target=$target" run_with_timeout 60 /bin/mv "$target" "$trashed" >> "$SUMMARY" 2>&1 \
    || fail "moving item to trash path failed or timed out: $target"
  [[ -e "$trashed" ]] || fail "trashed item missing: $trashed"
  time_step "finder-trash-delete" "target=$target" run_with_timeout 60 /bin/rm -rf "$trashed" >> "$SUMMARY" 2>&1 \
    || fail "removing trashed item failed or timed out: $trashed"
  [[ ! -e "$trashed" ]] || fail "trashed item survived removal: $trashed"
}

if [[ -z "$DEVICE" || -z "$EXPECTED_NAME" ]]; then
  echo "usage: live_ntfs_finder_workflow_probe.sh /dev/diskXsY EXPECTED_VOLUME_NAME" >&2
  exit 64
fi

if [[ "$EUID" -eq 0 ]]; then
  echo "live_ntfs_finder_workflow_probe.sh must run as the logged-in user, not root" >&2
  exit 64
fi

require_tool "$NTFSACCESSCTL"
require_tool /bin/cp
require_tool /bin/mv
require_tool /bin/rm
require_tool /usr/bin/find

/bin/mkdir -p "$LOCAL_ROOT"
: > "$SUMMARY"

DEVICE_ID="$(device_id_for "$DEVICE")"
log "NTFS Access Finder workflow probe"
log "device=$DEVICE"
log "expectedName=$EXPECTED_NAME"
log "downloads=$DOWNLOADS_DIR"
log "startedAt=$STAMP"

refresh_mount_state
MOUNT_LINE="$(/sbin/mount | /usr/bin/grep -F "$MOUNT_POINT" || true)"
assert_async_mount "$MOUNT_LINE"

DEST_ROOT="$MOUNT_POINT/NTFSAccess_finder_workflow_probe_$STAMP"
/bin/mkdir -p "$DEST_ROOT"

PDF_DIR="$DEST_ROOT/pdf-copy"
/bin/mkdir -p "$PDF_DIR"
PDF_COUNT=0
while IFS= read -r -d '' pdf_path; do
  copy_path "$pdf_path" "$PDF_DIR/$(/usr/bin/basename "$pdf_path")"
  PDF_COUNT=$((PDF_COUNT + 1))
  if [[ "$PDF_COUNT" -ge 3 ]]; then
    break
  fi
done < <(/usr/bin/find "$DOWNLOADS_DIR" -maxdepth 1 -type f \( -iname '*.pdf' -o -iname '*.PDF' \) -print0)
[[ "$PDF_COUNT" -gt 0 ]] || fail "no PDF files found in $DOWNLOADS_DIR for Finder-style PDF copy probe"

if [[ -d "$DOWNLOADS_DIR/Telegram" ]]; then
  copy_path "$DOWNLOADS_DIR/Telegram" "$DEST_ROOT/Telegram"
  trash_and_remove "$DEST_ROOT/Telegram"
fi

trash_and_remove "$PDF_DIR"
refresh_mount_state

log "PASS"
log "destination=$DEST_ROOT"
log "summary=$SUMMARY"
