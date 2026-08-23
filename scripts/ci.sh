#!/usr/bin/env bash
# ci.sh — the exact merge gate this project uses.
#
#   swift package clean
#   swift build
#   swift test
#   swift build -c release
#
# Fails fast at the first section. Usage: ./scripts/ci.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

section() {
    echo
    echo "============================================================"
    echo "==> $1"
    echo "============================================================"
}

section "swift package clean"
swift package clean

section "swift build"
swift build

section "swift test"
swift test

section "swift build -c release"
swift build -c release

echo
echo "==> ci.sh: all sections passed"
