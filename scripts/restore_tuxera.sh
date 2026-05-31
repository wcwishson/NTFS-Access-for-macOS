#!/bin/bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run this script with sudo." >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BACKUP_ROOT="/Library/Application Support/NTFSAccess/disabled/tuxera"
FILESYSTEMS_DIR="/Library/Filesystems"
LAUNCH_AGENTS_DIR="/Library/LaunchAgents"
TUXERA_FS_BUNDLE="$FILESYSTEMS_DIR/tuxera_ntfs.fs"
TUXERA_AGENT_PLIST="$LAUNCH_AGENTS_DIR/com.tuxera.ntfs.agent.plist"
DISABLED_FS_BUNDLE="$BACKUP_ROOT/tuxera_ntfs.fs"
DISABLED_AGENT_PLIST="$BACKUP_ROOT/com.tuxera.ntfs.agent.plist"

restore_if_exists() {
  local source_path="$1"
  local destination_path="$2"

  if [[ ! -e "$source_path" ]]; then
    return 0
  fi

  mkdir -p "$(dirname "$destination_path")"
  /bin/mv "$source_path" "$destination_path"
}

console_uid() {
  local uid
  uid="$(/usr/bin/stat -f '%u' /dev/console 2>/dev/null || true)"
  if [[ -n "$uid" && "$uid" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$uid"
    return 0
  fi
  return 1
}

bootstrap_user_agent() {
  local uid=""
  uid="$(console_uid || true)"
  if [[ -n "$uid" && -e "$TUXERA_AGENT_PLIST" ]]; then
    /bin/launchctl enable "gui/$uid/com.tuxera.ntfs.agent" >/dev/null 2>&1 || true
    /bin/launchctl bootstrap "gui/$uid" "$TUXERA_AGENT_PLIST" >/dev/null 2>&1 || true
  fi
}

if [[ -d "$DISABLED_FS_BUNDLE" ]]; then
  restore_if_exists "$DISABLED_FS_BUNDLE" "$TUXERA_FS_BUNDLE"
fi

if [[ -e "$DISABLED_AGENT_PLIST" ]]; then
  restore_if_exists "$DISABLED_AGENT_PLIST" "$TUXERA_AGENT_PLIST"
  bootstrap_user_agent
fi

restore_if_exists "$BACKUP_ROOT/Library/Application Support/Tuxera NTFS" "/Library/Application Support/Tuxera NTFS"
restore_if_exists "$BACKUP_ROOT/Library/StartupItems/TuxeraNTFSUnmountHelper" "/Library/StartupItems/TuxeraNTFSUnmountHelper"
restore_if_exists "$BACKUP_ROOT/Library/PreferencePanes/Tuxera NTFS.prefPane" "/Library/PreferencePanes/Tuxera NTFS.prefPane"
restore_if_exists "$BACKUP_ROOT/Library/Preferences/com.tuxera.NTFS.plist" "/Library/Preferences/com.tuxera.NTFS.plist"
restore_if_exists "$BACKUP_ROOT/Applications/Tuxera Disk Manager.app" "/Applications/Tuxera Disk Manager.app"

cat <<EOF
Tuxera NTFS has been restored.

Restored items:
  $TUXERA_FS_BUNDLE
  $TUXERA_AGENT_PLIST
  /Library/Application Support/Tuxera NTFS
  /Library/StartupItems/TuxeraNTFSUnmountHelper
  /Library/PreferencePanes/Tuxera NTFS.prefPane
  /Library/Preferences/com.tuxera.NTFS.plist
  /Applications/Tuxera Disk Manager.app

If you want to verify:
  diskutil listFilesystems | grep -E 'NTFS Access|Tuxera'

Repo:
  $ROOT_DIR
EOF
