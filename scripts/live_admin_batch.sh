#!/bin/bash
set -euo pipefail

PKG_PATH="${1:?usage: live_admin_batch.sh <pkg-path> [device]}"
DEVICE="${2:-/dev/disk12s1}"

/usr/sbin/installer -pkg "$PKG_PATH" -target /
/bin/sleep 2
/bin/launchctl kickstart -k system/com.ntfsaccess.mountd || true
/bin/sleep 2
/usr/local/bin/ntfsaccessctl scan-now || true
/bin/sleep 5

echo "--- diskutil info $DEVICE ---"
/usr/sbin/diskutil info "$DEVICE" || true
echo "--- ntfsaccessctl status ---"
/usr/local/bin/ntfsaccessctl status || true
echo "--- ntfsaccessctl list-volumes ---"
/usr/local/bin/ntfsaccessctl list-volumes || true
echo "--- mount entries ---"
/sbin/mount | /usr/bin/grep -Ei 'disk12|ntfs|fuse|macfuse|NTFS_STRESS|NTFSAccess' || true
