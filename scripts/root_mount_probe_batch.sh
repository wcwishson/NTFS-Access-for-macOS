#!/bin/bash
set -u

DEVICE="${1:-/dev/disk12s1}"
RAW_DEVICE="${DEVICE/\/dev\/disk/\/dev\/rdisk}"
MOUNT_ROOT="/Volumes/NTFSAccessRootProbe"
HELPER="/Library/Filesystems/ntfsaccess.fs/Contents/Resources/mount_ntfsaccess"
NTFS3G="/Library/NTFSAccess/toolchain/bin/ntfs-3g"
LOAD_MACFUSE="/Library/Filesystems/macfuse.fs/Contents/Resources/load_macfuse"

run() {
  echo
  echo "== $* =="
  "$@" 2>&1
  echo "[exit $?]"
}

echo "Device: $DEVICE"
echo "Raw device: $RAW_DEVICE"
echo "Mount root: $MOUNT_ROOT"

run /usr/sbin/diskutil list external physical
run /usr/sbin/diskutil info "$DEVICE"
run /usr/sbin/diskutil unmountDisk "${DEVICE%s*}"

run /bin/ls -l "$DEVICE" "$RAW_DEVICE"
run /bin/dd if="$DEVICE" of=/dev/null bs=512 count=1
run /bin/dd if="$RAW_DEVICE" of=/dev/null bs=512 count=1

if [[ -x "$LOAD_MACFUSE" ]]; then
  run "$LOAD_MACFUSE"
fi
run /usr/sbin/kextstat

/bin/mkdir -p "$MOUNT_ROOT"
run /sbin/umount "$MOUNT_ROOT"
run /bin/rmdir "$MOUNT_ROOT"
/bin/mkdir -p "$MOUNT_ROOT"

if [[ -x "$HELPER" ]]; then
  run "$HELPER" "$DEVICE" "$MOUNT_ROOT" removable writable nosuid nodev
fi

run /sbin/mount
if /sbin/mount | /usr/bin/grep -Fq "$MOUNT_ROOT"; then
  echo "Mounted through helper at $MOUNT_ROOT"
  exit 0
fi

run "$NTFS3G" "$DEVICE" "$MOUNT_ROOT" -o allow_other,defer_permissions
run /sbin/mount
if /sbin/mount | /usr/bin/grep -Fq "$MOUNT_ROOT"; then
  echo "Mounted through ntfs-3g block device at $MOUNT_ROOT"
  exit 0
fi

run "$NTFS3G" "$RAW_DEVICE" "$MOUNT_ROOT" -o allow_other,defer_permissions
run /sbin/mount
if /sbin/mount | /usr/bin/grep -Fq "$MOUNT_ROOT"; then
  echo "Mounted through ntfs-3g raw device at $MOUNT_ROOT"
  exit 0
fi

echo "No root mount path succeeded."
exit 1
