#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
STAGE_ROOT="${NTFSACCESS_STAGE_ROOT:-/Users/Shared/NTFSAccessLiveBatch}"
PKG_PATH="${NTFSACCESS_PKG_PATH:-$REPO_ROOT/dist/NTFSAccess-installer.pkg}"
PREFLIGHT_ROOT="/tmp/ntfsaccess-live-multi-preflight"
PREFLIGHT_LOG="$PREFLIGHT_ROOT/latest.log"
DRY_RUN=0
SKIP_INSTALL=0

for argument in "$@"; do
  case "$argument" in
    --dry-run)
      DRY_RUN=1
      ;;
    --skip-install)
      SKIP_INSTALL=1
      ;;
  esac
done

mkdir -p "$PREFLIGHT_ROOT"
: > "$PREFLIGHT_LOG"

log() {
  printf '%s\n' "$*" | /usr/bin/tee -a "$PREFLIGHT_LOG"
}

plist_value() {
  local key="$1"
  local file="$2"
  /usr/libexec/PlistBuddy -c "Print :$key" "$file" 2>/dev/null || true
}

name_for_device() {
  local device="$1"
  local plist="$2"
  /usr/sbin/diskutil info -plist "$device" > "$plist" 2>>"$PREFLIGHT_LOG" || return 1
  local volume_name media_name
  volume_name="$(plist_value VolumeName "$plist")"
  media_name="$(plist_value MediaName "$plist")"
  if [[ -n "$volume_name" ]]; then
    printf '%s\n' "$volume_name"
  elif [[ -n "$media_name" ]]; then
    printf '%s\n' "$media_name"
  else
    printf '%s\n' "$(basename "$device")"
  fi
}

is_ntfs_personality() {
  local personality="$1"
  local bundle="$2"
  local normalized
  normalized="$(/usr/bin/printf '%s %s\n' "$personality" "$bundle" | /usr/bin/tr '[:upper:]' '[:lower:]')"
  [[ "$normalized" == *"ntfs access"* || "$normalized" == *"windows nt filesystem"* || "$normalized" == *" ntfs"* || "$normalized" == "ntfs "* || "$normalized" == "ntfs" ]]
}

fstyp_for_device() {
  local device="$1"
  /sbin/fstyp "$device" 2>/dev/null || true
}

diskutil_list_for_device() {
  local device="$1"
  /usr/sbin/diskutil list "$device" 2>/dev/null || true
}

is_ntfs_candidate() {
  local personality="$1"
  local bundle="$2"
  local fstyp="$3"
  local list_output="$4"
  local normalized

  if is_ntfs_personality "$personality" "$bundle"; then
    return 0
  fi

  normalized="$(/usr/bin/printf '%s %s\n%s\n' "$fstyp" "$personality $bundle" "$list_output" | /usr/bin/tr '[:upper:]' '[:lower:]')"
  [[ "$normalized" == *"ntfs"* || "$normalized" == *"windows_ntfs"* || "$normalized" == *"microsoft basic data"* ]]
}

cd "$REPO_ROOT"

log "NTFS Access live multi-device preflight"
log "repo=$REPO_ROOT"
log "pkg=$PKG_PATH"
log "preflightLog=$PREFLIGHT_LOG"
log "skipInstall=$SKIP_INSTALL"

if [[ "$SKIP_INSTALL" -eq 0 && ! -f "$PKG_PATH" ]]; then
  log "Package not found. Build it first with: ./scripts/package_pkg.sh"
  exit 66
fi

external_devices=()
while IFS= read -r device; do
  external_devices+=("$device")
done < <(/usr/sbin/diskutil list external physical | /usr/bin/awk '/Windows_NTFS|Microsoft Basic Data/ { print "/dev/" $NF }')
targets=()
for device in "${external_devices[@]}"; do
  [[ -e "$device" ]] || continue
  plist="$(/usr/bin/mktemp "$PREFLIGHT_ROOT/device.XXXXXX")"
  name="$(name_for_device "$device" "$plist" || true)"
  personality="$(plist_value FilesystemName "$plist")"
  bundle="$(plist_value FilesystemUserVisibleName "$plist")"
  mounted="$(plist_value Mounted "$plist")"
  readonly="$(plist_value VolumeReadOnly "$plist")"
  fstyp_value="$(fstyp_for_device "$device")"
  list_output="$(diskutil_list_for_device "$device")"
  log "candidate=$device name=$name filesystem=$personality userVisible=$bundle fstyp=$fstyp_value mounted=$mounted readOnly=$readonly"

  if is_ntfs_candidate "$personality" "$bundle" "$fstyp_value" "$list_output"; then
    targets+=("$device:$name")
  else
    log "skip=$device reason=not-live-ntfs-filesystem"
    if [[ -n "$list_output" ]]; then
      /usr/bin/printf '%s\n' "$list_output" >> "$PREFLIGHT_LOG"
    fi
  fi
done

if [[ "${#targets[@]}" -eq 0 ]]; then
  log "No live external NTFS filesystem targets found. Current external disks:"
  /usr/sbin/diskutil list external physical >> "$PREFLIGHT_LOG" 2>&1 || true
  exit 75
fi

log "targets=${targets[*]}"
if [[ "$DRY_RUN" -eq 1 ]]; then
  log "dry-run complete; admin batch not started"
  exit 0
fi

log "starting admin batch"

if [[ "$SKIP_INSTALL" -eq 1 ]]; then
  /bin/bash "$REPO_ROOT/scripts/live_multi_device_admin_batch.sh" \
    --skip-install \
    "$PKG_PATH" \
    "$REPO_ROOT" \
    "${targets[@]}"
else
  /bin/bash "$REPO_ROOT/scripts/live_multi_device_admin_batch.sh" \
    "$PKG_PATH" \
    "$REPO_ROOT" \
    "${targets[@]}"
fi
