#!/bin/bash
set -euo pipefail

umask 077

STAGE_ROOT="/Users/Shared/NTFSAccessLiveBatch"
SUPPORT_ROOT="/Library/Application Support/NTFSAccess"
INSTALLED_LIVE_ROOT="$SUPPORT_ROOT/live-tests"
REQUEST_ROOT="$STAGE_ROOT/requests"
DEFAULT_CONFIG="$REQUEST_ROOT/live-job.conf"
CONFIG_PATH="${1:-$DEFAULT_CONFIG}"
TRIGGER_PATH="$REQUEST_ROOT/live-job.trigger"
RUN_ID="$(/bin/date +%Y%m%d-%H%M%S)"
LOG_ROOT="$STAGE_ROOT/logs"
LATEST_LOG="$LOG_ROOT/latest.log"
LOCK_DIR="$STAGE_ROOT/.live-job.lock"
LOCK_PID="$LOCK_DIR/pid"
LOG_PATH=""

log() {
  printf '%s\n' "$*" | /usr/bin/tee -a "$LOG_PATH"
}

fail() {
  if [[ -n "${LOG_PATH:-}" ]]; then
    log "ERROR: $*"
  else
    printf 'ERROR: %s\n' "$*" >&2
  fi
  exit 1
}

prepare_root_directory() {
  local path="$1"
  local label="$2"
  local mode="$3"
  local owner
  local file_type

  [[ ! -L "$path" ]] || fail "$label must not be a symlink: $path"
  /bin/mkdir -p "$path" || fail "Unable to create $label: $path"
  [[ -d "$path" ]] || fail "$label is not a directory: $path"
  [[ ! -L "$path" ]] || fail "$label must not be a symlink: $path"
  /usr/sbin/chown root:wheel "$path" 2>/dev/null || true
  /bin/chmod "$mode" "$path" 2>/dev/null || fail "Unable to chmod $label to $mode: $path"

  owner="$(/usr/bin/stat -f '%u' "$path" 2>/dev/null || true)"
  file_type="$(/usr/bin/stat -f '%HT' "$path" 2>/dev/null || true)"
  [[ "$file_type" == "Directory" ]] || fail "$label must be a directory, got $file_type: $path"
  [[ "$owner" == "0" ]] || fail "$label owner uid $owner is not root: $path"
}

prepare_live_job_paths() {
  prepare_root_directory "$STAGE_ROOT" "Stage root" 755
  prepare_root_directory "$REQUEST_ROOT" "Request directory" 1777
  prepare_root_directory "$LOG_ROOT" "Log directory" 755

  LOG_PATH="$(/usr/bin/mktemp "$LOG_ROOT/live-job-$RUN_ID.XXXXXX")" || fail "Unable to create exclusive live-job log in $LOG_ROOT"
  /bin/chmod 600 "$LOG_PATH" 2>/dev/null || true
  [[ ! -L "$LOG_PATH" ]] || fail "Log path must not be a symlink: $LOG_PATH"

  /bin/rm -f "$LATEST_LOG"
  /bin/ln -s "$LOG_PATH" "$LATEST_LOG"
  /bin/chmod -h 700 "$LATEST_LOG" 2>/dev/null || true
}

take_lock() {
  if /bin/mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s\n' "$$" > "$LOCK_PID"
    trap 'rm -rf "$LOCK_DIR"' EXIT
    return 0
  fi

  local existing_pid=""
  if [[ -f "$LOCK_PID" ]]; then
    existing_pid="$(/bin/cat "$LOCK_PID" 2>/dev/null || true)"
  fi

  if [[ "$existing_pid" =~ ^[0-9]+$ ]] && /bin/kill -0 "$existing_pid" >/dev/null 2>&1; then
    fail "Another live job is already running as pid $existing_pid"
  fi

  log "Removing stale live job lock"
  /bin/rm -rf "$LOCK_DIR"
  if ! /bin/mkdir "$LOCK_DIR" 2>/dev/null; then
    fail "Unable to acquire live job lock: $LOCK_DIR"
  fi
  printf '%s\n' "$$" > "$LOCK_PID"
  trap 'rm -rf "$LOCK_DIR"' EXIT
}

validate_regular_file_for_root_read() {
  local path="$1"
  local label="$2"
  local owner
  local mode
  local file_type

  [[ -e "$path" ]] || fail "$label not found: $path"
  [[ ! -L "$path" ]] || fail "$label must not be a symlink: $path"
  [[ -f "$path" ]] || fail "$label must be a regular file: $path"

  owner="$(/usr/bin/stat -f '%u' "$path" 2>/dev/null || true)"
  mode="$(/usr/bin/stat -f '%Lp' "$path" 2>/dev/null || true)"
  file_type="$(/usr/bin/stat -f '%HT' "$path" 2>/dev/null || true)"
  [[ "$file_type" == "Regular File" ]] || fail "$label must be a plain file, got $file_type: $path"
  [[ "$owner" =~ ^[0-9]+$ ]] || fail "Unable to read $label owner: $path"
  [[ "$mode" =~ ^[0-7]+$ ]] || fail "Unable to read $label mode: $path"
  if (( owner == 0 )); then
    :
  else
    # Accept files staged by the signed-in user, but not arbitrary system/service users.
    local console_uid
    console_uid="$(/usr/bin/stat -f '%u' /dev/console 2>/dev/null || true)"
    [[ "$owner" == "$console_uid" ]] || fail "$label owner uid $owner is not root or console uid $console_uid"
  fi
  (( (8#$mode & 0002) == 0 )) || fail "$label must not be world-writable: $path mode=$mode"
}

validate_executable_for_root_run() {
  local path="$1"
  local label="$2"
  local owner
  local mode
  local file_type

  [[ -e "$path" ]] || fail "$label not found: $path"
  [[ ! -L "$path" ]] || fail "$label must not be a symlink: $path"
  [[ -f "$path" ]] || fail "$label must be a regular file: $path"
  [[ -x "$path" ]] || fail "$label must be executable: $path"

  owner="$(/usr/bin/stat -f '%u' "$path" 2>/dev/null || true)"
  mode="$(/usr/bin/stat -f '%Lp' "$path" 2>/dev/null || true)"
  file_type="$(/usr/bin/stat -f '%HT' "$path" 2>/dev/null || true)"
  [[ "$file_type" == "Regular File" ]] || fail "$label must be a plain file, got $file_type: $path"
  [[ "$owner" == "0" ]] || fail "$label owner uid $owner is not root: $path"
  [[ "$mode" =~ ^[0-7]+$ ]] || fail "Unable to read $label mode: $path"
  (( (8#$mode & 0022) == 0 )) || fail "$label must not be group/world-writable: $path mode=$mode"
}

require_live_job_trigger_if_needed() {
  if [[ "${NTFSACCESS_REQUIRE_LIVEJOB_TRIGGER:-0}" != "1" ]]; then
    return 0
  fi

  if [[ ! -e "$TRIGGER_PATH" ]]; then
    log "No live-job trigger found; ignoring launchd wake."
    exit 0
  fi

  validate_regular_file_for_root_read "$TRIGGER_PATH" "Trigger"
  /bin/rm -f "$TRIGGER_PATH" || fail "Unable to consume live job trigger: $TRIGGER_PATH"
  log "Consumed live-job trigger: $TRIGGER_PATH"
}

config_value() {
  local key="$1"
  local value
  value="$(
    /usr/bin/awk -F= -v key="$key" '
      $0 ~ /^[[:space:]]*($|#)/ { next }
      {
        left=$1
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", left)
        if (left == key) {
          sub(/^[^=]*=/, "", $0)
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
          print $0
          exit
        }
      }
    ' "$CONFIG_PATH" 2>/dev/null || true
  )"
  printf '%s\n' "$value"
}

positive_integer_or_default() {
  local key="$1"
  local fallback="$2"
  local value
  value="$(config_value "$key")"
  if [[ -z "$value" ]]; then
    printf '%s\n' "$fallback"
    return 0
  fi
  if ! [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
    fail "Invalid $key=$value. Use a positive whole number."
  fi
  printf '%s\n' "$value"
}

bool_or_default() {
  local key="$1"
  local fallback="$2"
  local value
  value="$(config_value "$key")"
  if [[ -z "$value" ]]; then
    printf '%s\n' "$fallback"
    return 0
  fi
  case "$value" in
    0|1)
      printf '%s\n' "$value"
      ;;
    true|TRUE|yes|YES)
      printf '1\n'
      ;;
    false|FALSE|no|NO)
      printf '0\n'
      ;;
    *)
      fail "Invalid $key=$value. Use 1/0, true/false, or yes/no."
      ;;
  esac
}

if [[ "$EUID" -ne 0 ]]; then
  fail "live_job_runner.sh must run as root. Use one admin authorization for this runner, then let it run the whole batch."
fi

prepare_live_job_paths
take_lock
require_live_job_trigger_if_needed

validate_regular_file_for_root_read "$CONFIG_PATH" "Config"

FORCE_SKIP_INSTALL="${NTFSACCESS_FORCE_SKIP_INSTALL:-0}"
RUN_SCRIPT="$INSTALLED_LIVE_ROOT/scripts/run_live_multi_device_admin_batch.sh"
if [[ ! -x "$RUN_SCRIPT" ]]; then
  fail "Installed live-test script missing or not executable: $RUN_SCRIPT"
fi
validate_executable_for_root_run "$RUN_SCRIPT" "Live run script"

SKIP_INSTALL="$(bool_or_default SKIP_INSTALL 1)"
if [[ "$FORCE_SKIP_INSTALL" == "1" ]]; then
  SKIP_INSTALL=1
fi
REMOUNT_CYCLES="$(positive_integer_or_default NTFSACCESS_REMOUNT_CYCLES 12)"
SOAK_CYCLES="$(positive_integer_or_default NTFSACCESS_SOAK_CYCLES 40)"
MULTI_CYCLES="$(positive_integer_or_default NTFSACCESS_MULTI_CYCLES 12)"
LARGE_FILE_MIB="$(positive_integer_or_default NTFSACCESS_LARGE_FILE_MIB 64)"
RANDOM_FILE_COUNT="$(positive_integer_or_default NTFSACCESS_RANDOM_FILE_COUNT 4)"
RANDOM_FILE_MIB="$(positive_integer_or_default NTFSACCESS_RANDOM_FILE_MIB 16)"
MULTI_SOURCE_MIB="$(positive_integer_or_default NTFSACCESS_MULTI_SOURCE_MIB 32)"

log "NTFS Access prompt-safe live job"
log "config=$CONFIG_PATH"
log "stageRoot=$STAGE_ROOT"
log "runScript=$RUN_SCRIPT"
log "log=$LOG_PATH"
log "skipInstall=$SKIP_INSTALL"
log "remountCycles=$REMOUNT_CYCLES"
log "soakCycles=$SOAK_CYCLES"
log "multiCycles=$MULTI_CYCLES"
log "largeFileMiB=$LARGE_FILE_MIB"
log "randomFileCount=$RANDOM_FILE_COUNT"
log "randomFileMiB=$RANDOM_FILE_MIB"
log "multiSourceMiB=$MULTI_SOURCE_MIB"

if [[ -x /usr/local/bin/ntfsaccessctl ]]; then
  log ""
  log "--- preflight-live ---"
  /usr/local/bin/ntfsaccessctl preflight-live >> "$LOG_PATH" 2>&1 || true
fi

export NTFSACCESS_REMOUNT_CYCLES="$REMOUNT_CYCLES"
export NTFSACCESS_SOAK_CYCLES="$SOAK_CYCLES"
export NTFSACCESS_MULTI_CYCLES="$MULTI_CYCLES"
export NTFSACCESS_LARGE_FILE_MIB="$LARGE_FILE_MIB"
export NTFSACCESS_RANDOM_FILE_COUNT="$RANDOM_FILE_COUNT"
export NTFSACCESS_RANDOM_FILE_MIB="$RANDOM_FILE_MIB"
export NTFSACCESS_MULTI_SOURCE_MIB="$MULTI_SOURCE_MIB"
export NTFSACCESS_STAGE_ROOT="$STAGE_ROOT"
export NTFSACCESS_PKG_PATH="$STAGE_ROOT/dist/NTFSAccess-installer.pkg"

log ""
log "--- starting staged multi-device batch ---"
if [[ "$SKIP_INSTALL" -eq 1 ]]; then
  /bin/bash "$RUN_SCRIPT" --skip-install >> "$LOG_PATH" 2>&1
else
  /bin/bash "$RUN_SCRIPT" >> "$LOG_PATH" 2>&1
fi

log ""
log "DONE"
log "log=$LOG_PATH"
