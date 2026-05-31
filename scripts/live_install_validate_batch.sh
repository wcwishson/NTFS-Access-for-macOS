#!/bin/bash
set -euo pipefail

PKG_PATH="${1:?usage: live_install_validate_batch.sh <pkg-path> <repo-root> [device] [volume-name]}"
REPO_ROOT="${2:?usage: live_install_validate_batch.sh <pkg-path> <repo-root> [device] [volume-name]}"
DEVICE="${3:-/dev/disk12s1}"
EXPECTED_NAME="${4:-NTFS_STRESS}"
DEVICE_ID="${DEVICE##*/}"
CONSOLE_USER="$(/usr/bin/stat -f '%Su' /dev/console)"
CONSOLE_UID="$(/usr/bin/stat -f '%u' /dev/console)"
VALIDATOR_SOURCE="$REPO_ROOT/scripts/live_ntfs_full_validation.sh"
VALIDATOR="/tmp/ntfsaccess-live_ntfs_full_validation.sh"

echo "NTFS Access live install+validate batch"
echo "pkg=$PKG_PATH"
echo "repo=$REPO_ROOT"
echo "device=$DEVICE"
echo "expectedName=$EXPECTED_NAME"
echo "consoleUser=$CONSOLE_USER"

stop_stale_ntfs3g_for_device() {
  local pid
  local waited

  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    echo "Stopping stale ntfs-3g process $pid for $DEVICE_ID"
    /bin/kill -TERM "$pid" >/dev/null 2>&1 || true
  done < <(/usr/bin/pgrep -f "ntfs-3g .*${DEVICE_ID}" 2>/dev/null || true)

  for waited in 1 2 3 4 5; do
    if ! /usr/bin/pgrep -f "ntfs-3g .*${DEVICE_ID}" >/dev/null 2>&1; then
      return 0
    fi
    /bin/sleep 1
  done

  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    echo "Force-killing stale ntfs-3g process $pid for $DEVICE_ID"
    /bin/kill -KILL "$pid" >/dev/null 2>&1 || true
  done < <(/usr/bin/pgrep -f "ntfs-3g .*${DEVICE_ID}" 2>/dev/null || true)

  /bin/sleep 1
  if /usr/bin/pgrep -f "ntfs-3g .*${DEVICE_ID}" >/dev/null 2>&1; then
    echo "Stale ntfs-3g process survived cleanup for $DEVICE_ID" >&2
    return 1
  fi
}

stop_existing_menu_app() {
  local menu_binary="/Applications/NTFS Access.app/Contents/MacOS/NTFSMenuApp"
  local pid=""

  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    echo "Stopping existing NTFSMenuApp process $pid"
    /bin/kill "$pid" >/dev/null 2>&1 || true
  done < <(/usr/bin/pgrep -f "$menu_binary" 2>/dev/null || true)
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
      echo "timeout after ${seconds}s: $*" >&2
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
  local output_file="$2"
  shift 2
  local pid
  local waited=0

  "$@" >"$output_file" 2>&1 &
  pid=$!

  while /bin/kill -0 "$pid" >/dev/null 2>&1; do
    if [[ "$waited" -ge "$seconds" ]]; then
      echo "timeout after ${seconds}s: $*" >&2
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

print_diskutil_info() {
  local label="$1"
  local temp_output="/tmp/ntfsaccess-${DEVICE_ID}-${label//[^A-Za-z0-9_.-]/_}-diskutil-info.txt"

  if run_with_timeout_to_file 12 "$temp_output" /usr/sbin/diskutil info "$DEVICE"; then
    /bin/cat "$temp_output"
  else
    echo "diskutil info timed out for $DEVICE during $label"
    /bin/cat "$temp_output" 2>/dev/null || true
  fi
  /bin/rm -f "$temp_output"
}

if [[ ! -f "$PKG_PATH" ]]; then
  echo "Package not found: $PKG_PATH" >&2
  exit 66
fi
if [[ ! -x "$VALIDATOR_SOURCE" ]]; then
  echo "Validator not executable: $VALIDATOR_SOURCE" >&2
  exit 66
fi

/bin/cp "$VALIDATOR_SOURCE" "$VALIDATOR"
/bin/chmod 755 "$VALIDATOR"

echo "--- preflight cleanup for $DEVICE_ID ---"
run_with_timeout 20 /usr/sbin/diskutil unmount force "$DEVICE" >/dev/null 2>&1 || true
stop_stale_ntfs3g_for_device
/bin/rm -rf "/Volumes/NTFSAccess-$DEVICE_ID" >/dev/null 2>&1 || true

echo "--- installing package ---"
/usr/sbin/installer -pkg "$PKG_PATH" -target /

echo "--- restarting daemon and menu app ---"
stop_existing_menu_app
run_with_timeout 20 /bin/launchctl kickstart -k system/com.ntfsaccess.mountd >/dev/null 2>&1 || true
run_with_timeout 20 /bin/launchctl kickstart -k "gui/$CONSOLE_UID/com.ntfsaccess.menu" >/dev/null 2>&1 || true

echo "--- requesting scans ---"
for _ in 1 2 3; do
  /usr/local/bin/ntfsaccessctl scan-now >/dev/null 2>&1 || true
  /bin/sleep 6
done

echo "--- status before validation ---"
/usr/local/bin/ntfsaccessctl status || true
/usr/local/bin/ntfsaccessctl list-volumes || true
print_diskutil_info "before-validation" || true
/sbin/mount | /usr/bin/grep -Ei "$DEVICE_ID|ntfs|fuse|macfuse|$EXPECTED_NAME|NTFSAccess" || true
/bin/ps aux | /usr/bin/grep -E 'ntfs-3g|mountd|NTFS Access|NTFSMenuApp' | /usr/bin/grep -v grep || true

if ! /usr/local/bin/ntfsaccessctl list-volumes 2>/dev/null | /usr/bin/grep -Eq "^$DEVICE_ID[[:space:]]+readWrite[[:space:]]"; then
  echo "NTFS Access is not reporting $DEVICE_ID as readWrite; refusing to run destructive validation" >&2
  exit 75
fi

echo "--- running destructive validation as $CONSOLE_USER ---"
/usr/bin/sudo -u "$CONSOLE_USER" "$VALIDATOR" "$DEVICE" "$EXPECTED_NAME"

echo "--- status after validation ---"
/usr/local/bin/ntfsaccessctl status || true
/usr/local/bin/ntfsaccessctl list-volumes || true
print_diskutil_info "after-validation" || true
/sbin/mount | /usr/bin/grep -Ei "$DEVICE_ID|ntfs|fuse|macfuse|$EXPECTED_NAME|NTFSAccess" || true
/bin/ps aux | /usr/bin/grep -E 'ntfs-3g|mountd|NTFS Access|NTFSMenuApp' | /usr/bin/grep -v grep || true
