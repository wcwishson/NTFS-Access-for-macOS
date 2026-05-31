#!/bin/bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run this script with sudo." >&2
  exit 1
fi

if [[ $# -lt 1 ]]; then
  echo "usage: sudo ./scripts/diagnose_ntfs_mount.sh <device>" >&2
  echo "example: sudo ./scripts/diagnose_ntfs_mount.sh /dev/disk4s2" >&2
  exit 64
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE_INPUT="$1"

resolve_tool() {
  local binary="$1"
  local candidate=""

  for candidate in \
    "/Library/NTFSAccess/toolchain/bin/$binary" \
    "/Library/NTFSAccess/toolchain/sbin/$binary" \
    "/opt/homebrew/bin/$binary" \
    "/usr/local/bin/$binary"; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  if candidate="$(command -v "$binary" 2>/dev/null)"; then
    printf '%s\n' "$candidate"
    return 0
  fi

  return 1
}

normalize_device() {
  local value="$1"
  if [[ "$value" == /dev/* ]]; then
    printf '%s\n' "$value"
  else
    printf '/dev/%s\n' "$value"
  fi
}

console_ids() {
  local uid gid
  uid="$(/usr/bin/stat -f '%u' /dev/console 2>/dev/null || echo 0)"
  gid="$(/usr/bin/stat -f '%g' /dev/console 2>/dev/null || echo 0)"
  printf '%s %s\n' "$uid" "$gid"
}

run_attempt() {
  local label="$1"
  shift

  echo
  echo "== $label =="
  echo "+ $*"
  set +e
  "$@"
  local status=$?
  set -e
  echo "[exit $status]"
}

DEVICE="$(normalize_device "$DEVICE_INPUT")"
RAW_DEVICE="$DEVICE"
if [[ "$DEVICE" == /dev/disk* ]]; then
  RAW_DEVICE="/dev/rdisk${DEVICE#/dev/disk}"
fi

NTFS3G="$(resolve_tool ntfs-3g)"
PROBE="$(resolve_tool ntfs-3g.probe)"
read -r CONSOLE_UID CONSOLE_GID < <(console_ids)
MOUNT_POINT="/Volumes/NTFSAccessDiag-$(basename "$DEVICE")"

cleanup() {
  /sbin/umount "$MOUNT_POINT" >/dev/null 2>&1 || true
  /usr/sbin/diskutil unmount force "$DEVICE" >/dev/null 2>&1 || true
  /bin/rmdir "$MOUNT_POINT" >/dev/null 2>&1 || true
}

trap cleanup EXIT

/bin/mkdir -p "$MOUNT_POINT"

echo "Repo: $ROOT_DIR"
echo "Device: $DEVICE"
echo "Raw device: $RAW_DEVICE"
echo "ntfs-3g: $NTFS3G"
echo "ntfs-3g.probe: $PROBE"
echo "Console uid/gid: $CONSOLE_UID/$CONSOLE_GID"
echo "Mount point: $MOUNT_POINT"

run_attempt "diskutil info (before)" /usr/sbin/diskutil info "$DEVICE"
run_attempt "force unmount" /usr/sbin/diskutil unmount force "$DEVICE"
run_attempt "diskutil info (after unmount)" /usr/sbin/diskutil info "$DEVICE"

run_attempt "probe block readwrite" "$PROBE" --readwrite "$DEVICE"
run_attempt "probe raw readwrite" "$PROBE" --readwrite "$RAW_DEVICE"
run_attempt "probe block readonly" "$PROBE" --readonly "$DEVICE"
run_attempt "probe raw readonly" "$PROBE" --readonly "$RAW_DEVICE"

run_attempt "mount raw readonly minimal" \
  "$NTFS3G" "$RAW_DEVICE" "$MOUNT_POINT" \
  -o "ro,uid=$CONSOLE_UID,gid=$CONSOLE_GID,umask=022"
run_attempt "mount block readonly minimal" \
  "$NTFS3G" "$DEVICE" "$MOUNT_POINT" \
  -o "ro,uid=$CONSOLE_UID,gid=$CONSOLE_GID,umask=022"
run_attempt "mount raw readwrite minimal" \
  "$NTFS3G" "$RAW_DEVICE" "$MOUNT_POINT" \
  -o "uid=$CONSOLE_UID,gid=$CONSOLE_GID,umask=022"
run_attempt "mount block readwrite minimal" \
  "$NTFS3G" "$DEVICE" "$MOUNT_POINT" \
  -o "uid=$CONSOLE_UID,gid=$CONSOLE_GID,umask=022"

run_attempt "mount output check" /sbin/mount
run_attempt "diskutil info (final)" /usr/sbin/diskutil info "$DEVICE"
