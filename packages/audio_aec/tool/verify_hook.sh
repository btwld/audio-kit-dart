#!/usr/bin/env bash
# Verify a local prebuilt with matching and mismatched SHA-256 pins.
set -euo pipefail
exec python3 "$(dirname "${BASH_SOURCE[0]}")/verify_hook.py" "$@"
