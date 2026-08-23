#!/usr/bin/env bash
# run-dev.sh — build Orchard and launch it for local dogfooding.
#
# Orchard self-materializes a .app bundle (OrchardTrampoline) at
# ~/Library/Caches/orchard/Orchard.app on first run and re-execs into it, so it
# gets its own Dock icon / bundle identity (app.damson.orchard) without a full
# packaging pipeline. Set ORCHARD_NO_TRAMPOLINE=1 to run the bare binary instead
# (useful when driving it headless via orchard-cli).
#
# Usage: ./scripts/run-dev.sh          # release build, launched via trampoline
#        ORCHARD_NO_TRAMPOLINE=1 ./scripts/run-dev.sh   # bare binary, no bundle
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

HASH="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
echo "==> Orchard dev build @ $HASH"

# Kill a previous dev instance (its own bundle id, distinct from Damson.app).
pkill -f "orchard/Orchard.app/Contents/MacOS/Orchard" 2>/dev/null || true
pkill -f ".build/.*/release/OrchardApp" 2>/dev/null || true

swift build -c release --product OrchardApp
echo "==> launching Orchard"
exec "$REPO_ROOT/.build/release/OrchardApp"
