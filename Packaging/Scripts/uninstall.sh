#!/bin/bash
set -euo pipefail

TARGET_ROOT="${NTFSACCESS_TARGET_ROOT:-/}"
if [ -z "$TARGET_ROOT" ]; then
  TARGET_ROOT="/"
fi

target_path() {
  local path="$1"
  if [ "$TARGET_ROOT" = "/" ]; then
    printf '%s\n' "$path"
  else
    printf '%s%s\n' "${TARGET_ROOT%/}" "$path"
  fi
}

DAEMON_PLIST="$(target_path "/Library/LaunchDaemons/com.ntfsaccess.mountd.plist")"
LIVEJOB_PLIST="$(target_path "/Library/LaunchDaemons/com.ntfsaccess.livejob.plist")"
AGENT_PLIST="$(target_path "/Library/LaunchAgents/com.ntfsaccess.menu.plist")"
APP_PATH="$(target_path "/Applications/NTFS Access.app")"
APP_SUPPORT="$(target_path "/Library/Application Support/NTFSAccess")"
FILESYSTEM_BUNDLE="$(target_path "/Library/Filesystems/ntfsaccess.fs")"
TOOLCHAIN_ROOT="$(target_path "/Library/NTFSAccess")"
NEWFS_PATH="$(target_path "/usr/local/bin/newfs_ntfsaccess")"
CLI_PATH="$(target_path "/usr/local/bin/ntfsaccessctl")"

if [ "$TARGET_ROOT" = "/" ]; then
  launchctl bootout system "$DAEMON_PLIST" >/dev/null 2>&1 || true
  launchctl bootout system "$LIVEJOB_PLIST" >/dev/null 2>&1 || true
fi
rm -f "$DAEMON_PLIST"
rm -f "$LIVEJOB_PLIST"

if [ "$TARGET_ROOT" = "/" ]; then
  console_uid="$(stat -f '%u' /dev/console 2>/dev/null || echo '')"
  if [ -n "$console_uid" ] && [ "$console_uid" != "0" ]; then
    launchctl bootout "gui/$console_uid" "$AGENT_PLIST" >/dev/null 2>&1 || true
  fi
fi
rm -f "$AGENT_PLIST"

rm -rf "$APP_PATH"
rm -rf "$APP_SUPPORT"
rm -rf "$FILESYSTEM_BUNDLE"
rm -rf "$TOOLCHAIN_ROOT"
rm -f "$NEWFS_PATH"
rm -f "$CLI_PATH"

echo "NTFS Access uninstalled from $TARGET_ROOT"
