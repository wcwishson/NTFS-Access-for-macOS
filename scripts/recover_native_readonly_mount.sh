#!/bin/bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: recover_native_readonly_mount.sh /dev/diskXsY" >&2
  exit 64
fi

DEVICE="$1"
BUNDLE="/Library/Filesystems/ntfsaccess.fs"
DISABLED="/Library/Filesystems/ntfsaccess.fs.disabled-for-native-recovery"
DAEMON_PLIST="/Library/LaunchDaemons/com.ntfsaccess.mountd.plist"

if [[ "$EUID" -ne 0 ]]; then
  echo "This recovery must run as root because it temporarily moves a filesystem bundle under /Library." >&2
  exit 77
fi

restore() {
  if [[ -e "$DISABLED" && ! -e "$BUNDLE" ]]; then
    mv "$DISABLED" "$BUNDLE"
  fi

  /usr/sbin/diskutil listFilesystems >/dev/null 2>&1 || true
  if [[ -f "$DAEMON_PLIST" ]]; then
    /bin/launchctl bootstrap system "$DAEMON_PLIST" >/dev/null 2>&1 || true
    /bin/launchctl kickstart -k system/com.ntfsaccess.mountd >/dev/null 2>&1 || true
  fi
}

trap restore EXIT

echo "Stopping NTFS Access mount daemon..."
if [[ -f "$DAEMON_PLIST" ]]; then
  /bin/launchctl bootout system "$DAEMON_PLIST" >/dev/null 2>&1 || true
fi

echo "Temporarily moving NTFS Access filesystem bundle aside..."
if [[ -e "$DISABLED" ]]; then
  echo "Refusing to delete existing disabled bundle path: $DISABLED" >&2
  echo "Restore or inspect that path before retrying native read-only recovery." >&2
  exit 78
fi
if [[ -e "$BUNDLE" ]]; then
  mv "$BUNDLE" "$DISABLED"
fi

/usr/sbin/diskutil listFilesystems >/dev/null 2>&1 || true

echo "Requesting native macOS read-only NTFS mount for $DEVICE..."
/usr/sbin/diskutil unmount "$DEVICE" >/dev/null 2>&1 || true
/bin/sleep 1
/usr/sbin/diskutil mount readOnly "$DEVICE"
/bin/sleep 2

echo
echo "Recovered mount state:"
/usr/sbin/diskutil info "$DEVICE"
echo
/sbin/mount | /usr/bin/grep -Ei "$(basename "$DEVICE")|ntfs" || true
