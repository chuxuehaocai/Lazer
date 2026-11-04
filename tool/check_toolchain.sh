#!/usr/bin/env bash
# Check that a local Linux/WSL checkout can run the same checks as CI.
#
# CI pins Flutter 3.47.0 stable and pubspec.lock requires Dart >= 3.13.0.
# Default mode only checks what `flutter pub get`, `flutter analyze` and
# `flutter test` need. --build additionally checks the Linux desktop build
# dependencies. The script only reports; it installs and changes nothing.
set -euo pipefail

readonly PINNED_FLUTTER="3.47.0"
readonly MIN_FLUTTER="3.47.0"
readonly MIN_DART="3.13.0"

script_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"

build_mode=0
ok_count=0
warn_count=0
fail_count=0

usage() {
  cat <<'EOF'
Usage: tool/check_toolchain.sh [--build]

Check the local Flutter/Dart toolchain against the versions pinned by CI.

  --build   also check the Linux desktop build toolchain (clang, CMake,
            Ninja, pkg-config, GTK 3, libmpv, liblzma); these are warnings
  --help    show this help

Default mode checks only what `flutter analyze` and `flutter test` need.
Missing or too-old hard requirements are reported as FAIL and make the script
exit 1. A Flutter newer than the CI pin is reported as WARN, not FAIL.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --build) build_mode=1 ;;
    --help|-h) usage; exit 0 ;;
    *)
      printf 'Unknown argument: %s\n\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

report() {
  printf '%-5s%s  %s\n' "$1" "$2" "$3"
  case "$1" in
    OK) ok_count=$((ok_count + 1)) ;;
    WARN) warn_count=$((warn_count + 1)) ;;
    FAIL) fail_count=$((fail_count + 1)) ;;
  esac
}

have() {
  command -v "$1" >/dev/null 2>&1
}

first_line() {
  { "$@" 2>/dev/null || true; } | sed -n '1p'
}

# Strip everything from the first non-digit so "13-0-1" or "13.0.0-1.2"
# still compares as a number.
digits() {
  local value="${1:-0}"
  value="${value%%[!0-9]*}"
  printf '%s' "${value:-0}"
}

# Zero-padded key for numeric comparison: 3.47.0 -> 30047000.
version_key() {
  local major=0 minor=0 patch=0 rest
  IFS=. read -r major minor patch rest <<<"${1#v}"
  printf '%d%03d%03d' "$(digits "$major")" "$(digits "$minor")" "$(digits "$patch")"
}

version_ge() {
  [ "$(version_key "$1")" -ge "$(version_key "$2")" ]
}

check_flutter() {
  local output version
  if ! have flutter; then
    report FAIL flutter "not found on PATH (export PATH=<sdk>/bin:\$PATH)"
    return
  fi
  output="$(flutter --version 2>&1)" || output=""
  version="$(printf '%s\n' "$output" | sed -n 's/^Flutter \([0-9][0-9.]*\).*/\1/p')"
  version="${version%%$'\n'*}"
  if [ -z "$version" ]; then
    report FAIL flutter "could not parse a version from flutter --version"
  elif ! version_ge "$version" "$MIN_FLUTTER"; then
    report FAIL flutter "$version (require >= $MIN_FLUTTER, CI pins $PINNED_FLUTTER)"
  elif [ "$version" = "$PINNED_FLUTTER" ]; then
    report OK flutter "$version (CI pin)"
  else
    report WARN flutter "$version (CI pins $PINNED_FLUTTER)"
  fi
}

check_dart() {
  local output version
  if ! have dart; then
    report FAIL dart "not found on PATH (export PATH=<sdk>/bin:\$PATH)"
    return
  fi
  output="$(dart --version 2>&1)" || output=""
  version="$(printf '%s\n' "$output" | sed -n 's/.*Dart SDK version: \([0-9][0-9.]*\).*/\1/p')"
  version="${version%%$'\n'*}"
  if [ -z "$version" ]; then
    report FAIL dart "could not parse a version from dart --version"
  elif ! version_ge "$version" "$MIN_DART"; then
    report FAIL dart "$version (require >= $MIN_DART)"
  else
    report OK dart "$version"
  fi
}

# Version of a Linux desktop build tool, empty when it cannot be read.
build_tool_version() {
  case "$1" in
    clang) first_line clang --version | sed -n 's/.*version \([0-9][^ ]*\).*/\1/p' ;;
    cmake) first_line cmake --version | sed -n 's/^cmake version \([0-9][^ ]*\).*/\1/p' ;;
    ninja) first_line ninja --version ;;
    pkg-config) first_line pkg-config --version ;;
    *) printf '' ;;
  esac
}

check_build_tool() {
  local tool="$1" version
  if ! have "$tool"; then
    report WARN "$tool" "not found (needed for --build)"
    return
  fi
  version="$(build_tool_version "$tool")"
  if [ -n "$version" ]; then
    report OK "$tool" "$version"
  else
    report OK "$tool" "$(command -v "$tool")"
  fi
}

check_pkg_component() {
  local module="$1" label="$2" version
  if ! have pkg-config; then
    report WARN "$label" "pkg-config not found (needed for --build)"
    return
  fi
  if ! pkg-config --exists "$module" 2>/dev/null; then
    report WARN "$label" "missing $module (needed for --build)"
    return
  fi
  version="$(pkg-config --modversion "$module" 2>/dev/null || true)"
  report OK "$label" "${version:-present}"
}

# Hard requirements for `flutter pub get`, `flutter analyze` and `flutter test`.
check_flutter
check_dart
for tool in git bash tar xz; do
  if have "$tool"; then
    report OK "$tool" "$(command -v "$tool")"
  else
    report FAIL "$tool" "not found on PATH"
  fi
done

# Warnings: a complete release tarball works without these, but fetching SDK
# artifacts or downloading a fresh SDK does not.
if have unzip; then
  report OK unzip "$(command -v unzip)"
else
  report WARN unzip "not found (Flutter needs it to unpack SDK artifacts)"
fi
if have curl; then
  report OK curl/wget "$(command -v curl)"
elif have wget; then
  report OK curl/wget "$(command -v wget)"
else
  report WARN curl/wget "not found (needed only for a fresh SDK download)"
fi

# Optional Linux desktop build toolchain, mirroring the CI apt package list.
if [ "$build_mode" -eq 1 ]; then
  for tool in clang cmake ninja pkg-config; do
    check_build_tool "$tool"
  done
  check_pkg_component 'gtk+-3.0' gtk3
  check_pkg_component mpv libmpv
  check_pkg_component liblzma liblzma
fi

# Report the checkout when the script lives inside a git work tree.
if have git && git -C "$repo_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  revision="$(git -C "$repo_root" rev-parse --short HEAD 2>/dev/null || true)"
  branch="$(git -C "$repo_root" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  report OK revision "${revision:-unknown}"
  if [ "$branch" = "nextgen" ]; then
    report OK branch "nextgen"
  else
    report OK branch "${branch:-detached HEAD} (not nextgen)"
  fi
fi

printf 'SUMMARY %d failed, %d warnings, %d ok\n' "$fail_count" "$warn_count" "$ok_count"

[ "$fail_count" -eq 0 ]
