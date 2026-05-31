#!/bin/bash
set -euo pipefail

DEVICE="${1:-}"
EXPECTED_NAME="${2:-}"
NTFSACCESSCTL="${NTFSACCESSCTL:-/usr/local/bin/ntfsaccessctl}"
STAMP="$(/bin/date +%Y%m%d-%H%M%S)"
LOCAL_ROOT="/tmp/ntfsaccess-metadata-package-matrix-$STAMP"
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
  assert_mount_root_user_accessible "$MOUNT_POINT" "metadata-package"
  /sbin/mount | /usr/bin/grep -F "$MOUNT_POINT" >> "$SUMMARY" \
    || fail "mount table does not contain $MOUNT_POINT"
}

create_fixture_tree() {
  local root="$1"
  local app="$root/Sample.app"
  local bundle="$root/Sample.bundle"
  local pkg="$root/Sample.pkg"
  local metadata_dir="$root/metadata"

  /bin/mkdir -p "$root" "$app/Contents/MacOS" "$app/Contents/Resources" "$bundle/Contents" "$pkg/Contents" "$metadata_dir"

  printf 'plain text %s\n' "$STAMP" > "$root/plain.txt"
  printf '%%PDF-1.4\n%% NTFS Access fixture %s\n' "$STAMP" > "$root/document.pdf"
  printf '\xff\xd8\xff\xe0NTFSACCESS%s\xff\xd9\n' "$STAMP" > "$root/image.jpg"
  printf 'zip payload %s\n' "$STAMP" > "$root/zip-source.txt"
  (cd "$root" && /usr/bin/zip -qr "$root/archive.zip" zip-source.txt) >> "$SUMMARY" 2>&1

  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.ntfsaccess.fixture</string></dict></plist>
PLIST
  printf '#!/bin/sh\nprintf fixture\\n\n' > "$app/Contents/MacOS/stub"
  /bin/chmod 755 "$app/Contents/MacOS/stub"
  printf 'app resource %s\n' "$STAMP" > "$app/Contents/Resources/data.txt"
  printf 'bundle data %s\n' "$STAMP" > "$bundle/Contents/data.txt"
  printf 'pkg payload %s\n' "$STAMP" > "$pkg/Contents/payload.txt"

  printf 'quarantine %s\n' "$STAMP" > "$metadata_dir/quarantine.txt"
  printf 'finder info %s\n' "$STAMP" > "$metadata_dir/finder-info.txt"
  printf 'custom xattr %s\n' "$STAMP" > "$metadata_dir/custom.txt"

  /usr/bin/xattr -w com.apple.quarantine "0081;00000000;NTFSAccess;metadata-package-matrix" "$metadata_dir/quarantine.txt"
  /usr/bin/xattr -wx com.apple.FinderInfo "4649445200000000000000000000000000000000000000000000000000000000" "$metadata_dir/finder-info.txt"
  /usr/bin/xattr -w com.ntfsaccess.test "metadata-package-$STAMP" "$metadata_dir/custom.txt"
}

hex_xattr() {
  local attr="$1"
  local path="$2"
  /usr/bin/xattr -px "$attr" "$path" 2>/dev/null | /usr/bin/tr -d '[:space:]' || true
}

assert_xattr_hex_equal() {
  local attr="$1"
  local source="$2"
  local destination="$3"
  local source_hex
  local destination_hex

  source_hex="$(hex_xattr "$attr" "$source")"
  destination_hex="$(hex_xattr "$attr" "$destination")"
  [[ -n "$source_hex" ]] || fail "source missing xattr $attr: $source"
  [[ -n "$destination_hex" ]] || fail "destination missing xattr $attr: $destination"
  log "xattr=$attr source=$source destination=$destination source_hex=$source_hex destination_hex=$destination_hex"
  [[ "$source_hex" == "$destination_hex" ]] || fail "xattr mismatch for $attr: $destination"
}

assert_quarantine_xattr_present() {
  local source="$1"
  local destination="$2"
  local source_value
  local destination_value

  source_value="$(/usr/bin/xattr -p com.apple.quarantine "$source" 2>/dev/null || true)"
  destination_value="$(/usr/bin/xattr -p com.apple.quarantine "$destination" 2>/dev/null || true)"
  [[ -n "$source_value" ]] || fail "source missing quarantine xattr: $source"
  [[ -n "$destination_value" ]] || fail "destination missing quarantine xattr: $destination"
  log "xattr=com.apple.quarantine source=$source destination=$destination source_value=$source_value destination_value=$destination_value"
  [[ "$destination_value" == *"metadata-package-matrix"* ]] \
    || fail "destination quarantine xattr lost metadata-package marker: $destination"
}

assert_file_integrity() {
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
}

assert_tree_roundtrip() {
  local label="$1"
  local expected="$2"
  local actual="$3"

  assert_tree_shape_ignoring_appledouble "$label" "$expected" "$actual"
  assert_file_integrity "$label-plain" "$expected/plain.txt" "$actual/plain.txt"
  assert_file_integrity "$label-pdf" "$expected/document.pdf" "$actual/document.pdf"
  assert_file_integrity "$label-jpg" "$expected/image.jpg" "$actual/image.jpg"
  assert_file_integrity "$label-zip" "$expected/archive.zip" "$actual/archive.zip"
  assert_file_integrity "$label-app-resource" "$expected/Sample.app/Contents/Resources/data.txt" "$actual/Sample.app/Contents/Resources/data.txt"
  assert_file_integrity "$label-bundle" "$expected/Sample.bundle/Contents/data.txt" "$actual/Sample.bundle/Contents/data.txt"
  assert_file_integrity "$label-pkg" "$expected/Sample.pkg/Contents/payload.txt" "$actual/Sample.pkg/Contents/payload.txt"
}

assert_metadata_preserved() {
  local label="$1"
  local expected="$2"
  local actual="$3"

  assert_quarantine_xattr_present "$expected/metadata/quarantine.txt" "$actual/metadata/quarantine.txt"
  assert_xattr_hex_equal com.apple.FinderInfo "$expected/metadata/finder-info.txt" "$actual/metadata/finder-info.txt"
  assert_xattr_hex_equal com.ntfsaccess.test "$expected/metadata/custom.txt" "$actual/metadata/custom.txt"
  APPLEDOUBLE_COUNT="$(/usr/bin/find "$actual" -name '._*' -print | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
  log "appledouble_count label=$label count=$APPLEDOUBLE_COUNT"
}

create_resource_fork_fixture() {
  local source="$1"

  printf 'resource fork base data %s\n' "$STAMP" > "$source"
  printf 'resource fork payload %s\n' "$STAMP" > "$source/..namedfork/rsrc"
  /usr/bin/xattr -px com.apple.ResourceFork "$source" >/dev/null 2>&1 \
    || fail "local APFS source could not prepare com.apple.ResourceFork fixture"
}

observe_resource_fork_copy() {
  local label="$1"
  local command_name="$2"
  local source="$3"
  local destination="$4"
  shift 4
  local status
  local appledouble_count
  local destination_resource_hex

  set +e
  run_with_timeout 120 "$@"
  status=$?
  set -e

  log "resource_fork_probe=$label command=$command_name status=$status"
  if [[ "$status" -eq 124 ]]; then
    fail "resource fork $command_name probe timed out"
  fi

  if [[ -e "$destination" ]]; then
    assert_file_integrity "resource-fork-$label-primary-data" "$source" "$destination"
    appledouble_count="$(/usr/bin/find "$(/usr/bin/dirname "$destination")" -maxdepth 1 -name '._*' -print | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
    log "resource_fork_probe=$label appledouble_count=$appledouble_count"
  elif [[ "$status" -eq 0 ]]; then
    fail "resource fork $command_name reported success but destination is missing: $destination"
  else
    log "resource_fork_probe=$label destination_missing=1"
  fi

  destination_resource_hex="$(hex_xattr com.apple.ResourceFork "$destination")"
  if [[ "$status" -eq 0 && -n "$destination_resource_hex" ]]; then
    assert_xattr_hex_equal com.apple.ResourceFork "$source" "$destination"
    log "resource_fork_probe=$label result=preserved"
    return 0
  fi

  log "resource_fork_probe=$label result=unsupported_known_limitation"
  log "resource_fork_limitation=macFUSE/ntfs-3g currently rejects com.apple.ResourceFork writes used by cp -R and ditto --rsrc; primary data and ordinary xattrs remain mandatory"
}

observe_direct_resource_fork_write() {
  local destination="$1"
  local namedfork_status
  local xattr_status

  printf 'direct resource fork base %s\n' "$STAMP" > "$destination"
  set +e
  printf 'direct namedfork payload %s\n' "$STAMP" > "$destination/..namedfork/rsrc" 2>> "$SUMMARY"
  namedfork_status=$?
  /usr/bin/xattr -w com.apple.ResourceFork "direct resource xattr $STAMP" "$destination" >> "$SUMMARY" 2>&1
  xattr_status=$?
  set -e

  log "resource_fork_direct_write namedfork_status=$namedfork_status xattr_status=$xattr_status"
  if [[ "$namedfork_status" -eq 0 ]]; then
    log "resource_fork_direct_write namedfork=accepted"
  fi
  if [[ "$xattr_status" -ne 0 ]]; then
    log "resource_fork_direct_write xattr=unsupported_known_limitation"
  fi
}

observe_resource_fork_limitations() {
  local source="$LOCAL_ROOT/resource-fork-source.txt"
  local cp_destination="$DEST_ROOT/resource-fork-cp.txt"
  local ditto_destination="$DEST_ROOT/resource-fork-ditto.txt"
  local direct_destination="$DEST_ROOT/resource-fork-direct.txt"

  create_resource_fork_fixture "$source"

  log "copy APFS -> NTFS resource fork using /bin/cp -R"
  observe_resource_fork_copy "cp-apfs-to-ntfs" "cp -R" "$source" "$cp_destination" \
    /bin/cp -R "$source" "$cp_destination"

  log "copy APFS -> NTFS resource fork using ditto --rsrc"
  observe_resource_fork_copy "ditto-apfs-to-ntfs" "ditto --rsrc" "$source" "$ditto_destination" \
    /usr/bin/ditto --rsrc "$source" "$ditto_destination"

  observe_direct_resource_fork_write "$direct_destination"
}

trash_and_remove() {
  local target="$1"
  local trash_root="$MOUNT_POINT/.Trashes/$(/usr/bin/id -u)"
  local trashed="$trash_root/$(/usr/bin/basename "$target").$STAMP"
  local start
  local end

  /bin/mkdir -p "$trash_root"
  start="$(now_epoch)"
  run_with_timeout 90 /bin/mv "$target" "$trashed" || fail "moving metadata/package matrix to trash failed"
  [[ -e "$trashed" ]] || fail "metadata/package matrix trash target missing"
  run_with_timeout 90 /bin/rm -rf "$trashed" || fail "removing metadata/package matrix trash target failed"
  [[ ! -e "$trashed" ]] || fail "metadata/package matrix trash target survived removal"
  end="$(now_epoch)"
  log "timing=metadata-package-trash-delete metric=package-fixtures start=$start end=$end seconds=$((end - start)) status=0"
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
  echo "usage: live_ntfs_metadata_package_matrix.sh /dev/diskXsY EXPECTED_VOLUME_NAME" >&2
  exit 64
fi

if [[ "$EUID" -eq 0 ]]; then
  echo "live_ntfs_metadata_package_matrix.sh must run as the logged-in user, not root" >&2
  exit 64
fi

/bin/mkdir -p "$LOCAL_ROOT"
: > "$SUMMARY"

require_tool "$NTFSACCESSCTL"
require_tool /usr/bin/xattr
require_tool /bin/cp
require_tool /usr/bin/ditto
require_tool /usr/bin/diff
require_tool /usr/bin/cmp
require_tool /usr/bin/shasum
require_tool /sbin/md5
require_tool /usr/bin/zip

DEVICE_ID="$(device_id_for "$DEVICE")"
log "NTFS Access metadata/package matrix"
log "device=$DEVICE"
log "expectedName=$EXPECTED_NAME"
log "startedAt=$STAMP"

refresh_mount_state

SOURCE_ROOT="$LOCAL_ROOT/source-fixtures"
ROUNDTRIP_CP="$LOCAL_ROOT/roundtrip-cp"
ROUNDTRIP_DITTO="$LOCAL_ROOT/roundtrip-ditto"
DEST_ROOT="$MOUNT_POINT/NTFSAccess_metadata_package_matrix_$STAMP"
NTFS_CP_ROOT="$DEST_ROOT/cp/source-fixtures"
NTFS_DITTO_ROOT="$DEST_ROOT/ditto/source-fixtures"

create_fixture_tree "$SOURCE_ROOT"
/bin/mkdir -p "$DEST_ROOT/cp" "$DEST_ROOT/ditto"

log "copy APFS -> NTFS using /bin/cp -R"
run_with_timeout 240 /bin/cp -R "$SOURCE_ROOT" "$NTFS_CP_ROOT" \
  || fail "cp -R APFS to NTFS failed"
assert_tree_roundtrip "cp-apfs-to-ntfs" "$SOURCE_ROOT" "$NTFS_CP_ROOT"
assert_metadata_preserved "cp-apfs-to-ntfs" "$SOURCE_ROOT" "$NTFS_CP_ROOT"

log "copy NTFS -> APFS using /bin/cp -R"
run_with_timeout 240 /bin/cp -R "$NTFS_CP_ROOT" "$ROUNDTRIP_CP" \
  || fail "cp -R NTFS to APFS failed"
assert_tree_roundtrip "cp-ntfs-to-apfs" "$SOURCE_ROOT" "$ROUNDTRIP_CP"
assert_metadata_preserved "cp-ntfs-to-apfs" "$SOURCE_ROOT" "$ROUNDTRIP_CP"

log "copy APFS -> NTFS using ditto --rsrc"
run_with_timeout 240 /usr/bin/ditto --rsrc "$SOURCE_ROOT" "$NTFS_DITTO_ROOT" \
  || fail "ditto --rsrc APFS to NTFS failed"
assert_tree_roundtrip "ditto-apfs-to-ntfs" "$SOURCE_ROOT" "$NTFS_DITTO_ROOT"
assert_metadata_preserved "ditto-apfs-to-ntfs" "$SOURCE_ROOT" "$NTFS_DITTO_ROOT"

log "copy NTFS -> APFS using ditto --rsrc"
run_with_timeout 240 /usr/bin/ditto --rsrc "$NTFS_DITTO_ROOT" "$ROUNDTRIP_DITTO" \
  || fail "ditto --rsrc NTFS to APFS failed"
assert_tree_roundtrip "ditto-ntfs-to-apfs" "$SOURCE_ROOT" "$ROUNDTRIP_DITTO"
assert_metadata_preserved "ditto-ntfs-to-apfs" "$SOURCE_ROOT" "$ROUNDTRIP_DITTO"

observe_resource_fork_limitations

trash_and_remove "$DEST_ROOT"
DEST_ROOT=""
refresh_mount_state

log "PASS"
log "summary=$SUMMARY"
