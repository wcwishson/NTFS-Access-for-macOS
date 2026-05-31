#!/bin/bash
set -euo pipefail

usage() {
  cat <<'USAGE'
usage: live_ntfs_format_matrix_probe.sh [--all] [/dev/diskXsY [expectedName] ...]

Read-only NTFS format variant inventory probe. It records Disk Utility and
fstyp metadata for attached NTFS-like devices so the hardening ledger can track
which NTFS variants were actually tested.

This script does not mount, unmount, erase, repair, write, or call the NTFS
Access daemon. With no device arguments it auto-discovers likely NTFS devices
from `diskutil list`. When an expectedName follows a device argument, the probe
checks it against the Disk Utility volume name instead of treating it as another
device.
USAGE
}

STAMP="$(/bin/date +%Y%m%d-%H%M%S)"
LOCAL_ROOT="/tmp/ntfsaccess-format-matrix-$STAMP"
SUMMARY="$LOCAL_ROOT/summary.txt"
DEVICE_ARGS=()
EXPECTED_NAME_ARGS=()
AUTO_DISCOVER=0

fail() {
  printf 'FAIL: %s\n' "$*" | /usr/bin/tee -a "$SUMMARY" >&2
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

run_with_timeout_to_file() {
  local seconds="$1"
  local output_path="$2"
  shift 2
  local pid
  local waited=0

  "$@" > "$output_path" 2>> "$SUMMARY" &
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

normalize_device() {
  local raw="$1"
  raw="${raw#/dev/}"
  is_device_argument "$raw" || fail "not a disk device identifier: $1"
  printf '/dev/%s\n' "$raw"
}

is_device_argument() {
  local raw="$1"
  raw="${raw#/dev/}"
  [[ "$raw" =~ ^disk[0-9]+(s[0-9]+)?$ ]]
}

plist_value() {
  local plist="$1"
  local key="$2"
  /usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true
}

first_plist_value() {
  local plist="$1"
  shift
  local key
  local value

  for key in "$@"; do
    value="$(plist_value "$plist" "$key")"
    if [[ -n "$value" ]]; then
      printf '%s\n' "$value"
      return 0
    fi
  done

  printf 'unknown\n'
}

parent_whole_disk_for() {
  local plist="$1"
  local device_id="$2"
  local parent

  parent="$(plist_value "$plist" ParentWholeDisk)"
  if [[ -n "$parent" ]]; then
    printf '%s\n' "$parent"
    return 0
  fi

  printf '%s\n' "$device_id" | /usr/bin/sed -E 's/s[0-9]+$//'
}

partition_shape_for() {
  local plist="$1"
  local device_id="$2"
  local whole
  whole="$(first_plist_value "$plist" WholeDisk Whole)"

  if [[ "$whole" == "true" || "$whole" == "1" ]]; then
    printf 'partitionless-or-whole-disk\n'
  elif [[ "$device_id" =~ s[0-9]+$ ]]; then
    printf 'partition\n'
  else
    printf 'unknown\n'
  fi
}

variant_guess_for() {
  local partition_map="$1"
  local partition_shape="$2"
  local creator_hint="$3"
  local sector_size="$4"
  local total_size="$5"
  local pieces=()

  if [[ "$creator_hint" == *"ntfsaccess"* || "$creator_hint" == *"NTFS Access"* ]]; then
    pieces+=("ntfs-access-created-or-mounted")
  else
    pieces+=("creator-unknown")
  fi

  case "$partition_map" in
    *GUID*|*GPT*) pieces+=("gpt") ;;
    *FDisk*|*MBR*) pieces+=("mbr") ;;
    *) pieces+=("partition-map-unknown") ;;
  esac

  pieces+=("$partition_shape")

  if [[ "$sector_size" == "4096" ]]; then
    pieces+=("4kn-or-4k-logical")
  elif [[ "$sector_size" == "512" ]]; then
    pieces+=("512-byte-logical")
  else
    pieces+=("sector-unknown")
  fi

  if [[ "$total_size" =~ ^[0-9]+$ ]]; then
    if [[ "$total_size" -lt 8000000000 ]]; then
      pieces+=("small-under-8gb")
    elif [[ "$total_size" -gt 137438953472 ]]; then
      pieces+=("large-over-128gb")
    fi
  fi

  local IFS=,
  printf '%s\n' "${pieces[*]}"
}

capture_diskutil_info() {
  local device="$1"
  local output_path="$2"
  run_with_timeout_to_file 12 "$output_path" /usr/sbin/diskutil info -plist "$device"
}

capture_diskutil_list() {
  local device="$1"
  local output_path="$2"
  run_with_timeout_to_file 20 "$output_path" /usr/sbin/diskutil list "$device"
}

partition_map_from_list() {
  local list_file="$1"
  if /usr/bin/grep -Eq 'GUID_partition_scheme|GPT' "$list_file"; then
    printf 'GPT\n'
  elif /usr/bin/grep -Eq 'FDisk_partition_scheme|MBR' "$list_file"; then
    printf 'MBR\n'
  elif /usr/bin/grep -Eq 'Apple_partition_scheme' "$list_file"; then
    printf 'APM\n'
  else
    printf 'unknown\n'
  fi
}

fstyp_value_for() {
  local device="$1"
  local output_path="$2"
  if run_with_timeout_to_file 12 "$output_path" /sbin/fstyp "$device"; then
    local value
    value="$(/usr/bin/tr -d '\r\n' < "$output_path")"
    if [[ -n "$value" ]]; then
      printf '%s\n' "$value"
    else
      printf 'unknown\n'
    fi
  else
    printf 'unknown\n'
  fi
}

discover_devices() {
  local list_text="$LOCAL_ROOT/diskutil-list.txt"
  run_with_timeout_to_file 20 "$list_text" /usr/sbin/diskutil list \
    || fail "diskutil list failed during auto-discovery"

  /usr/bin/awk '
    /Windows_NTFS|Microsoft Basic Data|NTFS|ntfsaccess/ {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^disk[0-9]+(s[0-9]+)?$/) {
          print "/dev/" $i
        }
      }
    }
  ' "$list_text" | /usr/bin/sort -u
}

probe_device() {
  local device="$1"
  local expected_name="${2:-}"
  local device_id
  local info_plist
  local parent_id
  local list_text
  local fstyp_output
  local filesystem_personality
  local filesystem_type
  local content
  local volume_name
  local volume_uuid
  local media_uuid
  local disk_uuid
  local sector_size
  local allocation_block_size
  local cluster_size
  local total_size
  local internal
  local removable
  local ejectable
  local protocol_name
  local partition_shape
  local partition_map
  local creator_hint
  local fstyp_value
  local variant_guess
  local ledger_row

  device="$(normalize_device "$device")"
  device_id="$(device_id_for "$device")"
  info_plist="$LOCAL_ROOT/$device_id-info.plist"
  fstyp_output="$LOCAL_ROOT/$device_id-fstyp.txt"

  log "--- format-matrix device=$device ---"
  capture_diskutil_info "$device" "$info_plist" \
    || fail "diskutil info failed for $device"

  parent_id="$(parent_whole_disk_for "$info_plist" "$device_id")"
  list_text="$LOCAL_ROOT/$parent_id-list.txt"
  capture_diskutil_list "/dev/$parent_id" "$list_text" \
    || capture_diskutil_list "$device" "$list_text" \
    || fail "diskutil list failed for $device"

  fstyp_value="$(fstyp_value_for "$device" "$fstyp_output")"
  filesystem_personality="$(first_plist_value "$info_plist" FilesystemUserVisibleName FilesystemName)"
  filesystem_type="$(first_plist_value "$info_plist" FilesystemType TypeBundle)"
  content="$(first_plist_value "$info_plist" Content)"
  volume_name="$(first_plist_value "$info_plist" VolumeName MediaName)"
  volume_uuid="$(first_plist_value "$info_plist" VolumeUUID APFSVolumeUUID)"
  media_uuid="$(first_plist_value "$info_plist" MediaUUID)"
  disk_uuid="$(first_plist_value "$info_plist" DiskUUID)"
  sector_size="$(first_plist_value "$info_plist" DeviceBlockSize BlockSize)"
  allocation_block_size="$(first_plist_value "$info_plist" AllocationBlockSize AllocationBlockSizeBytes)"
  cluster_size="unknown"
  total_size="$(first_plist_value "$info_plist" TotalSize Size IOKitSize)"
  internal="$(first_plist_value "$info_plist" Internal OSInternal)"
  removable="$(first_plist_value "$info_plist" Removable)"
  ejectable="$(first_plist_value "$info_plist" Ejectable)"
  protocol_name="$(first_plist_value "$info_plist" BusProtocol Protocol)"
  partition_shape="$(partition_shape_for "$info_plist" "$device_id")"
  partition_map="$(partition_map_from_list "$list_text")"
  creator_hint="$filesystem_type $filesystem_personality $content $fstyp_value"
  variant_guess="$(variant_guess_for "$partition_map" "$partition_shape" "$creator_hint" "$sector_size" "$total_size")"

  log "format_matrix device=$device deviceIdentifier=$device_id parentWholeDisk=$parent_id"
  log "format_matrix volumeName=$volume_name filesystemPersonality=$filesystem_personality filesystemType=$filesystem_type content=$content fstyp=$fstyp_value"
  if [[ -n "$expected_name" ]]; then
    if [[ "$volume_name" != "$expected_name" ]]; then
      fail "expected volume name '$expected_name' for $device but Disk Utility reports '$volume_name'"
    fi
    log "format_matrix nameCheck=expectedName=$expected_name result=matched"
  fi
  log "format_matrix partitionMap=$partition_map partitionShape=$partition_shape sectorSize=$sector_size allocationBlockSize=$allocation_block_size clusterSize=$cluster_size totalSize=$total_size"
  log "format_matrix volumeUUID=$volume_uuid diskUUID=$disk_uuid mediaUUID=$media_uuid protocol=$protocol_name internal=$internal removable=$removable ejectable=$ejectable"
  log "format_matrix variantGuess=$variant_guess"
  log "format_matrix diskutilInfoPlist=$info_plist diskutilListText=$list_text fstypOutput=$fstyp_output"
  log "validator_command=live_ntfs_full_validation.sh $device $volume_name"
  log "validator_command=live_ntfs_metadata_package_matrix.sh $device $volume_name"
  log "validator_command=live_ntfs_filename_matrix.sh $device $volume_name"

  ledger_row="| $(/bin/date +%Y-%m-%d) | working tree | $device $volume_name | $variant_guess | format matrix probe | observed | $SUMMARY | read-only inventory: partitionMap=$partition_map sectorSize=$sector_size clusterSize=$cluster_size fstyp=$fstyp_value |"
  log "ledger_row=$ledger_row"
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --all)
      AUTO_DISCOVER=1
      shift
      ;;
    -*)
      usage >&2
      exit 64
      ;;
    *)
      if ! is_device_argument "$1"; then
        printf 'Error: expected a disk device before optional expectedName, got: %s\n' "$1" >&2
        usage >&2
        exit 64
      fi
      DEVICE_ARGS+=("$1")
      shift
      if [[ "$#" -gt 0 && "$1" != -* ]] && ! is_device_argument "$1"; then
        EXPECTED_NAME_ARGS+=("$1")
        shift
      else
        EXPECTED_NAME_ARGS+=("")
      fi
      ;;
  esac
done

if [[ "${#DEVICE_ARGS[@]}" -eq 0 ]]; then
  AUTO_DISCOVER=1
fi

/bin/mkdir -p "$LOCAL_ROOT"
require_tool /usr/sbin/diskutil
require_tool /usr/libexec/PlistBuddy
require_tool /sbin/fstyp

log "NTFS Access format matrix probe started=$STAMP mode=$([[ "$AUTO_DISCOVER" -eq 1 ]] && printf auto || printf explicit)"
log "readOnly=true writes=false mounts=false unmounts=false repairs=false formatting=false daemonActions=false"

if [[ "$AUTO_DISCOVER" -eq 1 && "${#DEVICE_ARGS[@]}" -eq 0 ]]; then
  while IFS= read -r discovered; do
    if [[ -n "$discovered" ]]; then
      DEVICE_ARGS+=("$discovered")
      EXPECTED_NAME_ARGS+=("")
    fi
  done < <(discover_devices)
fi

if [[ "${#DEVICE_ARGS[@]}" -eq 0 ]]; then
  log "NO_NTFS_CANDIDATES_FOUND"
  log "summary=$SUMMARY"
  exit 0
fi

for index in "${!DEVICE_ARGS[@]}"; do
  probe_device "${DEVICE_ARGS[$index]}" "${EXPECTED_NAME_ARGS[$index]:-}"
done

log "PASS NTFS Access format matrix probe"
log "summary=$SUMMARY"
