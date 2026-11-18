#!/usr/bin/env bash
#
# Adapted from Control Center's `scripts/natives/build_aec.sh` (and the helpers
# it sources from `scripts/natives/lib/natives_common.sh`).
# Copyright (c) 2026 Samuel Alev. Licensed under the MIT License. See NOTICE.
#
# Adaptation notes:
#   - Self-contained: the original sources a shared `natives_common.sh` used by
#     five native builds; audio_aec has exactly one, so the three helpers it
#     actually needs (log/die, pinned clone, ad-hoc sign) are inlined.
#   - Install destination is the package-local, GITIGNORED `.native/` directory
#     instead of the app-support root. This package is a library, not an app: it
#     has no bundle to install into, and the loader (lib/src/bindings.dart)
#     resolves an explicit path or $AUDIO_AEC_LIBRARY rather than a data dir.
#   - The upstream repository and pinned revision are unchanged, so the produced
#     ABI matches the shim in native/aec_ffi.cc symbol-for-symbol.
#
# Builds libaec_ffi — a thin C ABI (native/aec_ffi.cc) over WebRTC's AEC3
# AudioProcessing module — from webrtc-audio-processing at a pinned revision.
# No WebRTC source is vendored into this repository; it is fetched here.
#
# abseil is statically linked from the meson wrap (NOT a system/Homebrew shared
# abseil) so the result is self-contained and relocatable.
#
# Requirements: git, Meson, Ninja and a C++17 toolchain. Windows builds run
# under Git Bash with the x64 developer environment set up by the workflow.
# Usage: tool/build_native.sh [DEST_DIR]
set -euo pipefail

PKG_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SHIM="$PKG_ROOT/native/aec_ffi.cc"
DEST="${1:-$PKG_ROOT/.native}"

# Resolved from this script's absolute package root.
# shellcheck disable=SC1091
source "$PKG_ROOT/tool/native_release.env"
WAP_REPO="${WAP_REPO:-$AUDIO_AEC_WAP_REPO}"
WAP_REF="${WAP_REF:-$AUDIO_AEC_WAP_REF}"

log()  { printf '==> %s\n' "$*"; }
warn() { printf '!! %s\n' "$*" >&2; }
die()  { printf 'Error: %s\n' "$*" >&2; exit 1; }

require_cmd() { # cmd hint
  command -v "$1" >/dev/null 2>&1 || die "$1 not found. $2"
}

# Shallow-clone a single pinned commit; falls back to a full fetch + checkout if
# the server rejects a shallow SHA fetch.
git_clone_pinned() { # repo ref dest
  git init -q "$3"
  git -C "$3" remote add origin "$1"
  if git -C "$3" fetch -q --depth 1 origin "$2" 2>/dev/null; then
    git -C "$3" -c advice.detachedHead=false checkout -q FETCH_HEAD
  else
    git -C "$3" fetch -q origin
    git -C "$3" -c advice.detachedHead=false checkout -q "$2"
  fi
}

case "$(uname -s)" in
  Darwin)
    NATIVE_OS=Darwin
    LIB=libaec_ffi.dylib
    # New Xcode SDKs otherwise stamp the host SDK version into the dylib (for
    # example macOS 26), making a locally built code asset unloadable on the
    # app's supported macOS 12/13 machines. Consumers may raise this baseline,
    # but the package default must match its declared deployment contract.
    MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-12.0}"
    export MACOSX_DEPLOYMENT_TARGET
    ;;
  Linux) NATIVE_OS=Linux; LIB=libaec_ffi.so ;;
  MINGW*|MSYS*|CYGWIN*) NATIVE_OS=Windows; LIB=aec_ffi.dll ;;
  *) die "Unsupported native build host: $(uname -s)" ;;
esac

for cmd in git meson ninja; do require_cmd "$cmd" "Install $cmd and rerun."; done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

log "Cloning $WAP_REPO @ $WAP_REF"
git_clone_pinned "$WAP_REPO" "$WAP_REF" "$WORK/wap"
SRC="$WORK/wap"

# Make archive metadata and compiler path records stable across checkout paths.
# The pinned source commit supplies a stable epoch unless a release builder
# deliberately overrides it.
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git -C "$SRC" show -s --format=%ct HEAD)}"
export SOURCE_DATE_EPOCH ZERO_AR_DATE=1

# Build the shim as a Meson target so the upstream dependency graph supplies
# architecture flags, static archives in link order, and system libraries.
cp "$SHIM" "$SRC/aec_ffi.cc"
cat "$PKG_ROOT/native/shim.meson" >> "$SRC/meson.build"
options=(--buildtype=release --default-library=static --force-fallback-for=abseil-cpp)
if [ "$NATIVE_OS" = Windows ]; then
  export CC=cl CXX=cl
  options+=(-Db_vscrt=mt)
fi
meson setup "$SRC/build" "$SRC" "${options[@]}"
meson compile -C "$SRC/build" aec_ffi

mkdir -p "$DEST"
cp "$SRC/build/$LIB" "$DEST/$LIB"
if [ "$NATIVE_OS" = Darwin ]; then
  build_metadata="$(xcrun vtool -show-build "$DEST/$LIB")"
  minimum="$(awk '$1 == "minos" { print $2 }' <<<"$build_metadata")"
  [ "$minimum" = "$MACOSX_DEPLOYMENT_TARGET" ] ||
    die "Expected macOS $MACOSX_DEPLOYMENT_TARGET, built for $minimum"
  codesign --force --sign - --timestamp=none "$DEST/$LIB"
  codesign --verify "$DEST/$LIB"
fi
log "Built $DEST/$LIB"
