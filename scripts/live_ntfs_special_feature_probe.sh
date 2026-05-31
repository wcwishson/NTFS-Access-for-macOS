#!/bin/bash
set -euo pipefail

usage() {
  cat <<'USAGE'
usage: live_ntfs_special_feature_probe.sh <mount-point-or-fixture-root> [fixture-root-name]

Read/copy-out probe for pre-prepared Windows NTFS feature fixtures.
The default fixture root is NTFSAccessSpecialFixtures under the supplied mount
point. The script copies readable primary streams to /tmp, hashes bytes with
SHA-256 and MD5, and records unsupported/missing features explicitly.

Expected fixture entries:
  sparse-file.bin
  compressed-file.bin
  encrypted-efs-file.bin
  alternate-data-stream.txt
  junction
  symlink
  mount-point
  reparse-point
  cloud-placeholder

This script does not write to the NTFS volume, mount/unmount devices, repair
NTFS, format disks, or call the NTFS Access daemon.
USAGE
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

[[ "$#" -ge 1 && "$#" -le 2 ]] || { usage >&2; exit 64; }

INPUT_ROOT="$1"
FIXTURE_ROOT_NAME="${2:-NTFSAccessSpecialFixtures}"
STAMP="$(/bin/date +%Y%m%d-%H%M%S)"
LOCAL_ROOT="/tmp/ntfsaccess-special-feature-probe-$STAMP"
SUMMARY="$LOCAL_ROOT/summary.txt"
COPY_ROOT="$LOCAL_ROOT/copied-primary-streams"

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

sha256_file() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{ print $1 }'
}

md5_file() {
  /sbin/md5 -q "$1"
}

classify_path() {
  local path="$1"
  if [[ -L "$path" ]]; then
    printf 'symlink\n'
  elif [[ -f "$path" ]]; then
    printf 'file\n'
  elif [[ -d "$path" ]]; then
    printf 'directory\n'
  elif [[ -e "$path" ]]; then
    printf 'other\n'
  else
    printf 'missing\n'
  fi
}

record_metadata() {
  local label="$1"
  local path="$2"
  /bin/ls -ldeO@ "$path" >> "$SUMMARY" 2>&1 || true
  /usr/bin/stat -f "feature_metadata label=$label mode=%Sp type=%HT size=%z inode=%i flags=%Sf path=%N" "$path" >> "$SUMMARY" 2>&1 || true
  /usr/bin/xattr -l "$path" >> "$SUMMARY" 2>&1 || true
}

copy_primary_stream() {
  local label="$1"
  local source="$2"
  local destination="$COPY_ROOT/$label"
  local source_sha
  local destination_sha
  local source_md5
  local destination_md5

  /bin/mkdir -p "$COPY_ROOT"
  if ! run_with_timeout 120 /bin/cp -X "$source" "$destination"; then
    log "special_feature label=$label status=unsupported reason=primary-stream-copy-failed path=$source"
    return 0
  fi

  if ! /usr/bin/cmp "$source" "$destination" >/dev/null 2>> "$SUMMARY"; then
    log "special_feature label=$label status=failed reason=byte-compare-mismatch path=$source copy=$destination"
    return 1
  fi

  source_sha="$(sha256_file "$source")"
  destination_sha="$(sha256_file "$destination")"
  source_md5="$(md5_file "$source")"
  destination_md5="$(md5_file "$destination")"
  log "special_feature label=$label status=primary-stream-copied sha256=$source_sha copy_sha256=$destination_sha md5=$source_md5 copy_md5=$destination_md5 copy=$destination"
  [[ "$source_sha" == "$destination_sha" ]] || fail "$label SHA-256 mismatch after copy-out"
  [[ "$source_md5" == "$destination_md5" ]] || fail "$label MD5 mismatch after copy-out"
}

probe_feature() {
  local label="$1"
  local relative_path="$2"
  local expectation="$3"
  local path="$FIXTURE_ROOT/$relative_path"
  local kind
  local link_target

  kind="$(classify_path "$path")"
  log "special_feature label=$label expectation=$expectation path=$path kind=$kind"

  if [[ "$kind" == "missing" ]]; then
    log "special_feature label=$label status=missing expected=pre-prepared-windows-fixture"
    return 0
  fi

  record_metadata "$label" "$path"

  case "$kind" in
    file)
      copy_primary_stream "$label" "$path"
      ;;
    symlink)
      link_target="$(/usr/bin/readlink "$path" 2>/dev/null || true)"
      log "special_feature label=$label status=observed-symlink target=$link_target"
      if [[ -r "$path" && ! -d "$path" ]]; then
        copy_primary_stream "$label" "$path"
      else
        log "special_feature label=$label status=unsupported reason=symlink-target-not-readable-as-file"
      fi
      ;;
    directory)
      log "special_feature label=$label status=observed-directory reason=copying-recursive-reparse-targets-is-not-required-by-this-probe"
      ;;
    *)
      log "special_feature label=$label status=unsupported reason=unsupported-macos-node-kind kind=$kind"
      ;;
  esac
}

if [[ "$INPUT_ROOT" == "/Volumes/"* || -d "$INPUT_ROOT/$FIXTURE_ROOT_NAME" ]]; then
  if [[ -d "$INPUT_ROOT/$FIXTURE_ROOT_NAME" ]]; then
    FIXTURE_ROOT="$INPUT_ROOT/$FIXTURE_ROOT_NAME"
  else
    FIXTURE_ROOT="$INPUT_ROOT"
  fi
else
  FIXTURE_ROOT="$INPUT_ROOT"
fi

/bin/mkdir -p "$LOCAL_ROOT" "$COPY_ROOT"
: > "$SUMMARY"

require_tool /usr/bin/shasum
require_tool /sbin/md5
require_tool /usr/bin/cmp
require_tool /usr/bin/stat
require_tool /usr/bin/xattr

[[ -d "$FIXTURE_ROOT" ]] || fail "fixture root not found: $FIXTURE_ROOT"

log "NTFS Access special feature probe started=$STAMP fixtureRoot=$FIXTURE_ROOT"
log "readOnly=true writesToNTFS=false mounts=false unmounts=false repairs=false formatting=false daemonActions=false"
log "expectation=sparse-file byte-preservation-required"
log "expectation=compressed-file byte-preservation-required"
log "expectation=encrypted-efs-file read-only-or-unsupported-acceptable-must-not-crash"
log "expectation=alternate-data-stream primary-stream-byte-preservation-required metadata-preservation-if-exposed"
log "expectation=junction unsupported-acceptable-must-not-crash"
log "expectation=symlink read-or-unsupported-acceptable-must-not-crash"
log "expectation=mount-point unsupported-acceptable-must-not-crash"
log "expectation=reparse-point unsupported-acceptable-must-not-crash"
log "expectation=cloud-placeholder read-only-or-unsupported-acceptable-must-not-crash"

probe_feature "sparse-file" "sparse-file.bin" "byte-preservation-required"
probe_feature "compressed-file" "compressed-file.bin" "byte-preservation-required"
probe_feature "encrypted-efs-file" "encrypted-efs-file.bin" "read-only-or-unsupported-acceptable-must-not-crash"
probe_feature "alternate-data-stream" "alternate-data-stream.txt" "primary-stream-byte-preservation-required"
probe_feature "junction" "junction" "unsupported-acceptable-must-not-crash"
probe_feature "symlink" "symlink" "read-or-unsupported-acceptable-must-not-crash"
probe_feature "mount-point" "mount-point" "unsupported-acceptable-must-not-crash"
probe_feature "reparse-point" "reparse-point" "unsupported-acceptable-must-not-crash"
probe_feature "cloud-placeholder" "cloud-placeholder" "read-only-or-unsupported-acceptable-must-not-crash"

log "PASS NTFS Access special feature probe"
log "summary=$SUMMARY"
