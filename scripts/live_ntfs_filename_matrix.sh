#!/bin/bash
set -euo pipefail

DEVICE="${1:-}"
EXPECTED_NAME="${2:-}"
NTFSACCESSCTL="${NTFSACCESSCTL:-/usr/local/bin/ntfsaccessctl}"
STAMP="$(/bin/date +%Y%m%d-%H%M%S)"
LOCAL_ROOT="/tmp/ntfsaccess-filename-matrix-$STAMP"
SUMMARY="$LOCAL_ROOT/summary.txt"
DEST_ROOT=""

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

device_id_for() {
  printf '%s\n' "${1##*/}"
}

utf8_name() {
  /usr/bin/perl -CS -Mutf8 -e 'print eval shift' "$1"
}

sha256_file() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{ print $1 }'
}

md5_file() {
  /sbin/md5 -q "$1"
}

now_epoch() {
  /bin/date +%s
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
  run_with_timeout 120 "$NTFSACCESSCTL" scan-now --wait || true
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
  assert_mount_root_user_accessible "$MOUNT_POINT" "filename-matrix"
}

assert_integrity() {
  local label="$1"
  local source="$2"
  local destination="$3"
  local source_sha
  local destination_sha
  local source_md5
  local destination_md5

  /usr/bin/cmp "$source" "$destination" >/dev/null || fail "$label byte comparison failed"
  source_sha="$(sha256_file "$source")"
  destination_sha="$(sha256_file "$destination")"
  source_md5="$(md5_file "$source")"
  destination_md5="$(md5_file "$destination")"
  log "integrity=$label source_sha256=$source_sha destination_sha256=$destination_sha source_md5=$source_md5 destination_md5=$destination_md5"
  [[ "$source_sha" == "$destination_sha" ]] || fail "$label SHA-256 mismatch"
  [[ "$source_md5" == "$destination_md5" ]] || fail "$label MD5 mismatch"
}

pass_expected_file() {
  local label="$1"
  local name="$2"
  local local_file="$LOCAL_ROOT/pass-source/$label"
  local ntfs_file="$DEST_ROOT/pass/$name"
  local roundtrip_file="$LOCAL_ROOT/roundtrip/$label"

  /bin/mkdir -p "$(/usr/bin/dirname "$local_file")" "$DEST_ROOT/pass" "$LOCAL_ROOT/roundtrip"
  printf 'filename-pass label=%s stamp=%s\n' "$label" "$STAMP" > "$local_file"
  run_with_timeout 90 /bin/cp -X "$local_file" "$ntfs_file" \
    || fail "pass-expected copy to NTFS failed for $label: $name"
  [[ -f "$ntfs_file" ]] || fail "pass-expected destination missing for $label: $name"
  assert_integrity "filename-pass-to-ntfs-$label" "$local_file" "$ntfs_file"
  run_with_timeout 90 /bin/cp -X "$ntfs_file" "$roundtrip_file" \
    || fail "pass-expected copy back to APFS failed for $label: $name"
  assert_integrity "filename-pass-roundtrip-$label" "$local_file" "$roundtrip_file"
  log "filename_case label=$label expectation=pass result=accepted name=$name"
}

pass_expected_deep_path() {
  local label="deep-path"
  local base="$DEST_ROOT/pass"
  local path="$base"
  local i
  local local_file="$LOCAL_ROOT/pass-source/$label"
  local roundtrip_file="$LOCAL_ROOT/roundtrip/$label"

  for i in $(/usr/bin/jot 20); do
    path="$path/level-$(printf '%02d' "$i")-safe-name"
  done
  /bin/mkdir -p "$path"
  printf 'filename-pass label=%s stamp=%s\n' "$label" "$STAMP" > "$local_file"
  run_with_timeout 90 /bin/cp -X "$local_file" "$path/payload.txt" \
    || fail "deep path copy to NTFS failed"
  assert_integrity "filename-pass-to-ntfs-$label" "$local_file" "$path/payload.txt"
  run_with_timeout 90 /bin/cp -X "$path/payload.txt" "$roundtrip_file" \
    || fail "deep path copy back failed"
  assert_integrity "filename-pass-roundtrip-$label" "$local_file" "$roundtrip_file"
  log "filename_case label=$label expectation=pass result=accepted path=$path/payload.txt"
}

observe_name_case() {
  local label="$1"
  local name="$2"
  local path="$DEST_ROOT/observed/$name"
  local renamed="$DEST_ROOT/observed/${label}-renamed-$STAMP.txt"

  /bin/mkdir -p "$DEST_ROOT/observed"
  if printf 'observed label=%s stamp=%s\n' "$label" "$STAMP" > "$path" 2>> "$SUMMARY"; then
    /usr/bin/grep -q "$STAMP" "$path" || fail "observed accepted name could not be read back: $label"
    log "filename_case label=$label expectation=fail-or-normalize result=accepted name=$name sha256=$(sha256_file "$path") md5=$(md5_file "$path")"
    if /bin/mv "$path" "$renamed" >> "$SUMMARY" 2>&1; then
      /bin/rm -f "$renamed"
    else
      /bin/rm -f "$path" || true
      fail "observed accepted name could not be renamed: $label"
    fi
  else
    log "filename_case label=$label expectation=fail-or-normalize result=rejected name=$name"
  fi
}

observe_normalization_collision() {
  local dir="$DEST_ROOT/observed/normalization-collision"
  local nfc
  local nfd
  local count

  nfc="$(utf8_name '"Caf\x{E9}.txt"')"
  nfd="$(utf8_name '"Cafe\x{301}.txt"')"
  /bin/mkdir -p "$dir"
  printf 'nfc %s\n' "$STAMP" > "$dir/$nfc" 2>> "$SUMMARY" || {
    log "filename_case label=normalization-collision expectation=fail-or-normalize result=nfc-rejected"
    return 0
  }
  if printf 'nfd %s\n' "$STAMP" > "$dir/$nfd" 2>> "$SUMMARY"; then
    count="$(/usr/bin/find "$dir" -maxdepth 1 -type f | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
    log "filename_case label=normalization-collision expectation=fail-or-normalize result=accepted count=$count nfc=$nfc nfd=$nfd"
  else
    log "filename_case label=normalization-collision expectation=fail-or-normalize result=nfd-rejected nfc=$nfc nfd=$nfd"
  fi
}

trash_and_remove() {
  local target="$1"
  local trash_root="$MOUNT_POINT/.Trashes/$(/usr/bin/id -u)"
  local trashed="$trash_root/$(/usr/bin/basename "$target").$STAMP"
  local start
  local end

  /bin/mkdir -p "$trash_root"
  start="$(now_epoch)"
  run_with_timeout 90 /bin/mv "$target" "$trashed" || fail "moving filename matrix to trash failed"
  [[ -e "$trashed" ]] || fail "filename matrix trash target missing"
  run_with_timeout 90 /bin/rm -rf "$trashed" || fail "removing filename matrix trash target failed"
  [[ ! -e "$trashed" ]] || fail "filename matrix trash target survived removal"
  end="$(now_epoch)"
  log "timing=filename-matrix-trash-delete metric=filename-fixtures start=$start end=$end seconds=$((end - start)) status=0"
}

cleanup() {
  local status=$?
  if [[ -n "$DEST_ROOT" && -d "$DEST_ROOT" ]]; then
    if [[ "$status" -eq 0 ]]; then
      /bin/rm -rf "$DEST_ROOT" >/dev/null 2>&1 || true
    fi
  fi
}

trap cleanup EXIT

if [[ -z "$DEVICE" || -z "$EXPECTED_NAME" ]]; then
  echo "usage: live_ntfs_filename_matrix.sh /dev/diskXsY EXPECTED_VOLUME_NAME" >&2
  exit 64
fi

if [[ "$EUID" -eq 0 ]]; then
  echo "live_ntfs_filename_matrix.sh must run as the logged-in user, not root" >&2
  exit 64
fi

/bin/mkdir -p "$LOCAL_ROOT/pass-source" "$LOCAL_ROOT/roundtrip"
: > "$SUMMARY"

require_tool "$NTFSACCESSCTL"
require_tool /usr/bin/perl
require_tool /bin/cp
require_tool /bin/mv
require_tool /usr/bin/cmp
require_tool /usr/bin/shasum
require_tool /sbin/md5

DEVICE_ID="$(device_id_for "$DEVICE")"
log "NTFS Access filename matrix"
log "device=$DEVICE"
log "expectedName=$EXPECTED_NAME"
log "startedAt=$STAMP"

refresh_mount_state

DEST_ROOT="$MOUNT_POINT/NTFSAccess_filename_matrix_$STAMP"
/bin/mkdir -p "$DEST_ROOT/pass" "$DEST_ROOT/observed"

pass_expected_file "spaces" "file with spaces.txt"
pass_expected_file "cjk" "$(utf8_name '"\x{4E2D}\x{6587} file.txt"')"
pass_expected_file "emoji" "$(utf8_name '"emoji \x{1F600}.txt"')"
pass_expected_file "nfc" "$(utf8_name '"Caf\x{E9}-nfc.txt"')"
pass_expected_file "nfd" "$(utf8_name '"Cafe\x{301}-nfd.txt"')"
pass_expected_file "case-upper" "Case.txt"
pass_expected_file "case-lower" "case.txt"
pass_expected_file "long-200" "$(/usr/bin/perl -e 'print "a" x 200, ".txt"')"
pass_expected_deep_path

observe_name_case "trailing-space" "trailing-space .txt"
observe_name_case "trailing-dot" "trailing-dot."
observe_name_case "colon" "colon:name.txt"
observe_name_case "star" "star*name.txt"
observe_name_case "question" "question?name.txt"
observe_name_case "less-than" "less<name.txt"
observe_name_case "greater-than" "greater>name.txt"
observe_name_case "pipe" "pipe|name.txt"
observe_normalization_collision

trash_and_remove "$DEST_ROOT"
DEST_ROOT=""
refresh_mount_state

log "PASS"
log "summary=$SUMMARY"
