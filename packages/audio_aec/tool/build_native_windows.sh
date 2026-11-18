#!/usr/bin/env bash
# Windows entry point for the shared Meson build. Invoke from Git Bash with
# the x64 Visual Studio developer environment loaded.
set -euo pipefail
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) ;;
  *) echo "Run this script under Git Bash on Windows." >&2; exit 1 ;;
esac
exec "$(dirname "${BASH_SOURCE[0]}")/build_native.sh" "$@"
