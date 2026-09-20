#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
saved=$(mktemp -d "${TMPDIR:-/tmp}/trusted-router-mutations.XXXXXX")
restore() {
  python3 scripts/mutation-check.py --restore "$saved"
  rm -rf "$saved"
}
trap restore EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
python3 scripts/mutation-check.py --saved "$saved" "$@"
