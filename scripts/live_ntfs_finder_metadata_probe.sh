#!/bin/bash
set -euo pipefail

DEVICE="${1:-}"
EXPECTED_NAME="${2:-}"
NTFSACCESSCTL="${NTFSACCESSCTL:-/usr/local/bin/ntfsaccessctl}"
STAMP="$(/bin/date +%Y%m%d-%H%M%S)"
LOCAL_ROOT="/tmp/ntfsaccess-finder-metadata-probe-$STAMP"
SUMMARY="$LOCAL_ROOT/summary.txt"

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

if [[ -z "$DEVICE" || -z "$EXPECTED_NAME" ]]; then
  echo "usage: live_ntfs_finder_metadata_probe.sh /dev/diskXsY EXPECTED_VOLUME_NAME" >&2
  exit 64
fi

if [[ "$EUID" -eq 0 ]]; then
  echo "live_ntfs_finder_metadata_probe.sh must run as the logged-in user, not root" >&2
  exit 64
fi

require_tool "$NTFSACCESSCTL"
require_tool /usr/bin/xattr
require_tool /bin/cp

/bin/mkdir -p "$LOCAL_ROOT"
: > "$SUMMARY"

DEVICE_ID="$(device_id_for "$DEVICE")"
log "NTFS Access Finder-style metadata copy probe"
log "device=$DEVICE"
log "expectedName=$EXPECTED_NAME"
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
assert_mount_root_user_accessible "$MOUNT_POINT" "metadata-probe"

SOURCE_DIR="$LOCAL_ROOT/Downloads-style source"
DEST_DIR="$MOUNT_POINT/NTFSAccess_finder_metadata_probe_$STAMP"
SOURCE_FILE="$SOURCE_DIR/plain.txt"
DEST_FILE="$DEST_DIR/plain.txt"
FINDER_INFO_HEX="4649445200000000000000000000000000000000000000000000000000000000"

/bin/mkdir -p "$SOURCE_DIR/nested"
printf 'Finder metadata probe %s\n' "$STAMP" > "$SOURCE_FILE"
printf 'nested Finder metadata probe %s\n' "$STAMP" > "$SOURCE_DIR/nested/file.txt"
/usr/bin/xattr -w com.apple.quarantine "0081;00000000;NTFSAccess;finder-metadata-probe" "$SOURCE_FILE" >> "$SUMMARY" 2>&1 \
  || fail "could not prepare quarantine xattr"
/usr/bin/xattr -wx com.apple.FinderInfo "$FINDER_INFO_HEX" "$SOURCE_FILE" >> "$SUMMARY" 2>&1 \
  || fail "could not prepare FinderInfo xattr"

log "copying with normal /bin/cp -R so Apple metadata is preserved"
if ! /bin/cp -R "$SOURCE_DIR" "$DEST_DIR" >> "$SUMMARY" 2>&1; then
  fail "Finder-style metadata copy failed"
fi

/usr/bin/grep -q "$STAMP" "$DEST_FILE" || fail "copied file content missing"
/usr/bin/xattr -p com.apple.quarantine "$DEST_FILE" >> "$SUMMARY" 2>&1 \
  || fail "copied file is missing quarantine xattr"
/usr/bin/xattr -p com.apple.FinderInfo "$DEST_FILE" >> "$SUMMARY" 2>&1 \
  || fail "copied file is missing FinderInfo xattr"

SOURCE_FINDER_INFO="$(/usr/bin/xattr -px com.apple.FinderInfo "$SOURCE_FILE" | /usr/bin/tr -d '[:space:]')"
DEST_FINDER_INFO="$(/usr/bin/xattr -px com.apple.FinderInfo "$DEST_FILE" | /usr/bin/tr -d '[:space:]')"
[[ "$SOURCE_FINDER_INFO" == "$DEST_FINDER_INFO" ]] \
  || fail "copied file changed FinderInfo xattr"

log "PASS"
log "destination=$DEST_DIR"
log "summary=$SUMMARY"
