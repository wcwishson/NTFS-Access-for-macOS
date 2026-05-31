#!/bin/bash
set -euo pipefail

DEFAULT_PREFIX="/Library/NTFSAccess/toolchain"
DEFAULT_REF="d3ace19838ce37cfde55294e76841e6d2f393f9e"
DEFAULT_URL_BASE="https://codeload.github.com/tuxera/ntfs-3g/tar.gz"

PREFIX="${NTFSACCESS_TOOLCHAIN_ROOT:-$DEFAULT_PREFIX}"
SOURCE_REF="$DEFAULT_REF"
INSTALL_BUILD_DEPS=0
KEEP_BUILD_DIR=0
BUILD_DIR=""
DOWNLOAD_URL=""

usage() {
  cat <<EOF
usage: ./scripts/bootstrap_ntfs_toolchain.sh [--prefix <path>] [--ref <git-ref>] [--install-build-deps] [--keep-build-dir]

Builds and installs the managed NTFS Access toolchain from the upstream ntfs-3g source.

Defaults:
  prefix: $DEFAULT_PREFIX
  ref:    $DEFAULT_REF

Notes:
  - macFUSE is still required separately for runtime mounting.
  - The default prefix requires root. Run this script with sudo unless you override --prefix.
  - --install-build-deps uses Homebrew to install: autoconf automake libtool pkgconf libgcrypt
  - Homebrew must not run as root. On macOS, use:
      1. ./scripts/bootstrap_ntfs_toolchain.sh --install-build-deps
      2. sudo ./scripts/bootstrap_ntfs_toolchain.sh
EOF
}

cleanup() {
  if [[ "$KEEP_BUILD_DIR" -eq 0 && -n "$BUILD_DIR" ]]; then
    rm -rf "$BUILD_DIR"
  fi
}

trap cleanup EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)
      PREFIX="$2"
      shift 2
      continue
      ;;
    --ref)
      SOURCE_REF="$2"
      shift 2
      continue
      ;;
    --install-build-deps)
      INSTALL_BUILD_DEPS=1
      shift
      continue
      ;;
    --keep-build-dir)
      KEEP_BUILD_DIR=1
      shift
      continue
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
done

DOWNLOAD_URL="$DEFAULT_URL_BASE/$SOURCE_REF"

find_brew() {
  local candidates=(
    "$(command -v brew 2>/dev/null || true)"
    "/opt/homebrew/bin/brew"
    "/usr/local/bin/brew"
  )
  local candidate=""
  for candidate in "${candidates[@]}"; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

prepend_brew_path() {
  local brew_path="$1"
  local brew_prefix
  brew_prefix="$("$brew_path" --prefix)"
  export PATH="$brew_prefix/bin:$brew_prefix/sbin:$PATH"
}

prepend_env_path() {
  local variable_name="$1"
  local path_entry="$2"
  local current_value="${!variable_name:-}"
  if [[ ! -d "$path_entry" ]]; then
    return 0
  fi
  case ":$current_value:" in
    *":$path_entry:"*)
      return 0
      ;;
  esac
  if [[ -n "$current_value" ]]; then
    export "$variable_name=$path_entry:$current_value"
  else
    export "$variable_name=$path_entry"
  fi
}

prepend_flag() {
  local variable_name="$1"
  local flag_value="$2"
  local current_value="${!variable_name:-}"
  case " $current_value " in
    *" $flag_value "*)
      return 0
      ;;
  esac
  if [[ -n "$current_value" ]]; then
    export "$variable_name=$flag_value $current_value"
  else
    export "$variable_name=$flag_value"
  fi
}

require_command() {
  local command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required command: $command_name" >&2
    exit 1
  fi
}

find_existing_ancestor() {
  local probe_path="$1"
  while [[ ! -e "$probe_path" && "$probe_path" != "/" ]]; do
    probe_path="$(dirname "$probe_path")"
  done
  printf '%s\n' "$probe_path"
}

can_prepare_path() {
  local target_path="$1"
  local existing_ancestor
  existing_ancestor="$(find_existing_ancestor "$target_path")"
  [[ -w "$existing_ancestor" ]]
}

print_dependency_install_next_steps() {
  cat <<EOF
Homebrew build dependencies are installed.

The target prefix still requires root:
  $PREFIX

Continue with:
  sudo ./scripts/bootstrap_ntfs_toolchain.sh
EOF
}

ensure_writable_prefix() {
  local prefix_parent
  prefix_parent="$(dirname "$PREFIX")"

  if [[ ! -e "$prefix_parent" ]]; then
    if ! can_prepare_path "$prefix_parent"; then
      if [[ "$INSTALL_BUILD_DEPS" -eq 1 && "$EUID" -ne 0 ]]; then
        print_dependency_install_next_steps
        exit 0
      fi
      echo "Prefix parent is not writable: $prefix_parent" >&2
      echo "Rerun with sudo or choose a writable --prefix." >&2
      exit 1
    fi
    mkdir -p "$prefix_parent"
  fi

  if [[ ! -w "$prefix_parent" ]]; then
    if [[ "$INSTALL_BUILD_DEPS" -eq 1 && "$EUID" -ne 0 ]]; then
      print_dependency_install_next_steps
      exit 0
    fi
    echo "Prefix parent is not writable: $prefix_parent" >&2
    echo "Rerun with sudo or choose a writable --prefix." >&2
    exit 1
  fi

  if [[ -e "$PREFIX" && ! -w "$PREFIX" ]]; then
    if [[ "$INSTALL_BUILD_DEPS" -eq 1 && "$EUID" -ne 0 ]]; then
      print_dependency_install_next_steps
      exit 0
    fi
    echo "Prefix is not writable: $PREFIX" >&2
    echo "Rerun with sudo or choose a writable --prefix." >&2
    exit 1
  fi
}

ensure_build_deps() {
  local missing=()
  local brew_path=""

  if ! command -v autoreconf >/dev/null 2>&1; then
    missing+=("autoconf")
    missing+=("automake")
  fi

  if ! command -v libtoolize >/dev/null 2>&1 && ! command -v glibtoolize >/dev/null 2>&1; then
    missing+=("libtool")
  fi

  if ! command -v pkg-config >/dev/null 2>&1; then
    missing+=("pkgconf")
  fi

  if ! command -v libgcrypt-config >/dev/null 2>&1 && ! pkg-config --exists libgcrypt >/dev/null 2>&1; then
    missing+=("libgcrypt")
  fi

  if [[ "${#missing[@]}" -eq 0 ]]; then
    return 0
  fi

  if [[ "$INSTALL_BUILD_DEPS" -ne 1 ]]; then
    echo "Missing build dependencies: ${missing[*]}" >&2
    echo "Install them manually, or rerun with --install-build-deps." >&2
    echo "On macOS, do not combine --install-build-deps with sudo." >&2
    exit 1
  fi

  if [[ "$EUID" -eq 0 ]]; then
    echo "Homebrew build dependencies cannot be installed as root." >&2
    echo "Run these two commands instead:" >&2
    echo "  ./scripts/bootstrap_ntfs_toolchain.sh --install-build-deps" >&2
    echo "  sudo ./scripts/bootstrap_ntfs_toolchain.sh" >&2
    exit 1
  fi

  brew_path="$(find_brew || true)"
  if [[ -z "$brew_path" ]]; then
    echo "Homebrew not found; cannot auto-install build dependencies." >&2
    exit 1
  fi

  prepend_brew_path "$brew_path"
  "$brew_path" install autoconf automake libtool pkgconf libgcrypt
}

configure_brew_environment() {
  local brew_path=""
  local brew_prefix=""
  local formula=""
  local formula_prefix=""
  local aclocal_flags=()
  local aclocal_paths=()

  brew_path="$(find_brew || true)"
  if [[ -z "$brew_path" ]]; then
    return 0
  fi

  prepend_brew_path "$brew_path"
  brew_prefix="$("$brew_path" --prefix)"
  prepend_env_path PKG_CONFIG_PATH "$brew_prefix/lib/pkgconfig"
  prepend_env_path PKG_CONFIG_PATH "$brew_prefix/share/pkgconfig"
  prepend_env_path ACLOCAL_PATH "$brew_prefix/share/aclocal"

  for formula in libgcrypt libgpg-error; do
    formula_prefix="$("$brew_path" --prefix "$formula" 2>/dev/null || true)"
    if [[ -z "$formula_prefix" ]]; then
      continue
    fi
    prepend_env_path PATH "$formula_prefix/bin"
    prepend_env_path PATH "$formula_prefix/sbin"
    prepend_env_path PKG_CONFIG_PATH "$formula_prefix/lib/pkgconfig"
    prepend_env_path PKG_CONFIG_PATH "$formula_prefix/share/pkgconfig"
    prepend_env_path ACLOCAL_PATH "$formula_prefix/share/aclocal"
    prepend_flag CPPFLAGS "-I$formula_prefix/include"
    prepend_flag LDFLAGS "-L$formula_prefix/lib"
    if [[ "$formula" == "libgcrypt" && -x "$formula_prefix/bin/libgcrypt-config" ]]; then
      export LIBGCRYPT_CONFIG="$formula_prefix/bin/libgcrypt-config"
    fi
  done

  IFS=':' read -r -a aclocal_paths <<<"${ACLOCAL_PATH:-}"
  for formula_prefix in "${aclocal_paths[@]}"; do
    if [[ -d "$formula_prefix" ]]; then
      aclocal_flags+=("-I" "$formula_prefix")
    fi
  done
  if [[ "${#aclocal_flags[@]}" -gt 0 ]]; then
    export ACLOCAL_FLAGS="${aclocal_flags[*]}"
  fi
}

prepare_environment() {
  local brew_path=""
  brew_path="$(find_brew || true)"
  if [[ -n "$brew_path" ]]; then
    prepend_brew_path "$brew_path"
  fi

  require_command curl
  require_command tar
  require_command make
  require_command xcode-select

  if ! xcode-select -p >/dev/null 2>&1; then
    echo "Xcode Command Line Tools are required." >&2
    exit 1
  fi

  ensure_build_deps
  configure_brew_environment

  if command -v glibtoolize >/dev/null 2>&1 && ! command -v libtoolize >/dev/null 2>&1; then
    export LIBTOOLIZE="glibtoolize"
  fi

  require_command autoreconf
  require_command pkg-config
}

download_source() {
  BUILD_DIR="$(mktemp -d /tmp/ntfsaccess-toolchain.XXXXXX)"
  local archive_path="$BUILD_DIR/ntfs-3g.tar.gz"
  curl -L --fail --show-error "$DOWNLOAD_URL" -o "$archive_path"
  tar -xzf "$archive_path" -C "$BUILD_DIR"
}

build_source() {
  local source_dir
  source_dir="$(find "$BUILD_DIR" -maxdepth 1 -type d -name 'ntfs-3g-*' | head -n 1)"
  if [[ -z "$source_dir" ]]; then
    echo "Unable to locate unpacked ntfs-3g source tree in $BUILD_DIR" >&2
    exit 1
  fi

  cd "$source_dir"
  ./autogen.sh
  ./configure \
    --prefix="$PREFIX" \
    --exec-prefix="$PREFIX" \
    --enable-extras \
    --disable-static

  local jobs
  jobs="$(/usr/sbin/sysctl -n hw.ncpu 2>/dev/null || echo 4)"
  make -j"$jobs"
  make install
}

verify_installation() {
  local required=(
    "$PREFIX/bin/ntfs-3g"
    "$PREFIX/bin/ntfs-3g.probe"
    "$PREFIX/sbin/mkntfs"
    "$PREFIX/bin/ntfsfix"
  )
  local path=""
  for path in "${required[@]}"; do
    if [[ ! -x "$path" ]]; then
      echo "Expected installed tool missing: $path" >&2
      exit 1
    fi
  done
}

print_summary() {
  cat <<EOF
Managed NTFS toolchain installed.

Prefix:
  $PREFIX

Installed tools:
  $PREFIX/bin/ntfs-3g
  $PREFIX/bin/ntfs-3g.probe
  $PREFIX/bin/ntfsfix
  $PREFIX/sbin/mkntfs
  $PREFIX/sbin/ntfslabel

Next steps:
  1. Install macFUSE if it is not already installed:
       brew install --cask macfuse
  2. Re-run the readiness check:
       ./scripts/verify_install.sh --host-readiness
  3. Run a real host install without --uninstall-after if you want Disk Utility/Finder testing to remain installed:
       sudo ./scripts/verify_install.sh --install
EOF
}

prepare_environment
ensure_writable_prefix
download_source
build_source
verify_installation
print_summary
