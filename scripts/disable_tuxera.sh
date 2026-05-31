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

move_if_exists() {
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

bootout_user_agent() {
  local uid=""
  uid="$(console_uid || true)"
  if [[ -n "$uid" ]]; then
    /bin/launchctl bootout "gui/$uid" "$TUXERA_AGENT_PLIST" >/dev/null 2>&1 || true
    /bin/launchctl disable "gui/$uid/com.tuxera.ntfs.agent" >/dev/null 2>&1 || true
  fi
}

mkdir -p "$BACKUP_ROOT"

if [[ -e "$TUXERA_AGENT_PLIST" ]]; then
  bootout_user_agent
  move_if_exists "$TUXERA_AGENT_PLIST" "$DISABLED_AGENT_PLIST"
fi

if [[ -d "$TUXERA_FS_BUNDLE" ]]; then
  move_if_exists "$TUXERA_FS_BUNDLE" "$DISABLED_FS_BUNDLE"
fi

move_if_exists "/Library/Application Support/Tuxera NTFS" "$BACKUP_ROOT/Library/Application Support/Tuxera NTFS"
move_if_exists "/Library/StartupItems/TuxeraNTFSUnmountHelper" "$BACKUP_ROOT/Library/StartupItems/TuxeraNTFSUnmountHelper"
move_if_exists "/Library/PreferencePanes/Tuxera NTFS.prefPane" "$BACKUP_ROOT/Library/PreferencePanes/Tuxera NTFS.prefPane"
move_if_exists "/Library/Preferences/com.tuxera.NTFS.plist" "$BACKUP_ROOT/Library/Preferences/com.tuxera.NTFS.plist"
move_if_exists "/Applications/Tuxera Disk Manager.app" "$BACKUP_ROOT/Applications/Tuxera Disk Manager.app"

cat <<EOF
Tuxera NTFS has been disabled for clean-slate testing.

Disabled items:
  $DISABLED_FS_BUNDLE
  $DISABLED_AGENT_PLIST
  $BACKUP_ROOT/Library/Application Support/Tuxera NTFS
  $BACKUP_ROOT/Library/StartupItems/TuxeraNTFSUnmountHelper
  $BACKUP_ROOT/Library/PreferencePanes/Tuxera NTFS.prefPane
  $BACKUP_ROOT/Library/Preferences/com.tuxera.NTFS.plist
  $BACKUP_ROOT/Applications/Tuxera Disk Manager.app

Next steps:
  1. Unplug the NTFS drive.
  2. Reinstall the latest NTFS Access package if needed:
       sudo "$ROOT_DIR/scripts/verify_install.sh" --install
  3. Plug the NTFS drive back in.
  4. Check:
       /usr/local/bin/ntfsaccessctl status
       /usr/local/bin/ntfsaccessctl list-volumes
       diskutil listFilesystems | grep -E 'NTFS Access|Tuxera'

Restore later with:
  sudo "$ROOT_DIR/scripts/restore_tuxera.sh"
EOF
