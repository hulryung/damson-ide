#!/usr/bin/env bash
# T86 workspace-switch latency benchmark.
#
# Reproduces the wave-24 measurement in a throwaway HOME: a headless `orchard serve`
# with three git repos, one Orchard worktree each, then times the calls a workspace
# switch actually pays — `worktree list` (all repos and one repo) and
# `terminal create --worktree id:<repoId>::<path>` — against the CLI round-trip
# baseline (`status`) and against raw `git` for the same facts.
#
# Every number is a median of N runs of the *whole* CLI invocation, which is how the
# coordinator measured: process spawn + socket connect + RPC + work.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORCHARD_BIN="${ORCHARD_BENCH_BIN:-$REPO_ROOT/.build/release/orchard}"
RUNS="${ORCHARD_BENCH_RUNS:-9}"
BENCH_ROOT="$(mktemp -d /tmp/orchard-bench.XXXXXX)"
BENCH_HOME="$BENCH_ROOT/home"
DATA_DIR="$BENCH_HOME/Library/Application Support/Orchard"
METADATA="$DATA_DIR/orchard-runtime.json"
SERVE_LOG="$BENCH_ROOT/serve.log"
SERVE_PID=""

fail() {
    echo "bench: FAIL: $*" >&2
    [[ -f "$SERVE_LOG" ]] && tail -60 "$SERVE_LOG" >&2
    exit 1
}

cleanup() {
    local status=$?
    if [[ -n "$SERVE_PID" ]] && kill -0 "$SERVE_PID" 2>/dev/null; then
        kill -INT "$SERVE_PID" 2>/dev/null || true
        for _ in {1..40}; do
            kill -0 "$SERVE_PID" 2>/dev/null || break
            sleep 0.1
        done
        kill -9 "$SERVE_PID" 2>/dev/null || true
        wait "$SERVE_PID" 2>/dev/null || true
    fi
    [[ $status -eq 0 ]] && rm -rf "$BENCH_ROOT"
    return 0
}
trap cleanup EXIT

orchard() { HOME="$BENCH_HOME" CFFIXED_USER_HOME="$BENCH_HOME" "$ORCHARD_BIN" "$@"; }

now_ns() { python3 -c 'import time;print(time.monotonic_ns())'; }

# Median wall-clock of RUNS invocations, in whole milliseconds.
median_ms() {
    local label=$1; shift
    local samples=() start end
    for _ in $(seq "$RUNS"); do
        start=$(now_ns)
        "$@" >/dev/null 2>&1 || fail "$label command failed: $*"
        end=$(now_ns)
        samples+=( $(( (end - start) / 1000000 )) )
    done
    printf '%s\n' "${samples[@]}" | sort -n | awk -v n="$RUNS" 'NR==int((n+1)/2){print}'
}

# `terminal create` leaves a live PTY behind. Each sample's pane is closed outside the
# timed region so a run does not finish holding N shells, and so the create rows measure
# one creation rather than one creation on top of everything the previous samples left
# running.
median_create_ms() {
    local label=$1; shift
    local samples=() start end handle out
    for _ in $(seq "$RUNS"); do
        start=$(now_ns)
        out=$("$@" 2>/dev/null) || fail "$label command failed: $*"
        end=$(now_ns)
        samples+=( $(( (end - start) / 1000000 )) )
        handle=$(OUT="$out" python3 -c '
import json, os
try:
    print(json.loads(os.environ["OUT"])["result"]["handle"])
except Exception:
    print("")
')
        [[ -n "$handle" ]] && orchard terminal close --terminal "$handle" --json >/dev/null 2>&1
    done
    printf '%s\n' "${samples[@]}" | sort -n | awk -v n="$RUNS" 'NR==int((n+1)/2){print}'
}

row() { printf '| %-46s | %6s ms |\n' "$1" "$2"; }

[[ -x "$ORCHARD_BIN" ]] || fail "missing $ORCHARD_BIN (swift build -c release)"
mkdir -p "$DATA_DIR"

for n in 1 2 3; do
    repo="$BENCH_ROOT/repo$n"
    mkdir -p "$repo"
    git -C "$repo" init -q -b main
    git -C "$repo" config user.email bench@example.invalid
    git -C "$repo" config user.name "Orchard Bench"
    printf 'repo %s\n' "$n" > "$repo/README.md"
    git -C "$repo" add README.md
    git -C "$repo" commit -q -m initial
done

# Launched directly rather than through the `orchard` helper: backgrounding a shell
# function makes `$!` the subshell, and killing that on the way out would leave the
# runtime orphaned and burning CPU for every later run on this machine.
HOME="$BENCH_HOME" CFFIXED_USER_HOME="$BENCH_HOME" \
    "$ORCHARD_BIN" serve --data-dir "$DATA_DIR" >"$SERVE_LOG" 2>&1 &
SERVE_PID=$!
for _ in {1..200}; do
    [[ -s "$METADATA" ]] && break
    kill -0 "$SERVE_PID" 2>/dev/null || fail "serve exited before publishing metadata"
    sleep 0.05
done
[[ -s "$METADATA" ]] || fail "serve metadata did not appear"

declare -a REPO_IDS
for n in 1 2 3; do
    repo="$BENCH_ROOT/repo$n"
    add_json=$(orchard repo add --path "$repo" --json 2>&1) || fail "repo add failed: $add_json"
    id=$(ADD_JSON="$add_json" python3 -c 'import json,os;print(json.loads(os.environ["ADD_JSON"])["result"]["id"])') \
        || fail "repo add receipt unreadable: $add_json"
    REPO_IDS+=( "$id" )
    orchard worktree create --repo "id:$id" --name "bench$n" --json >/dev/null \
        || fail "worktree create failed in repo$n"
done

# The selector the app hands to a pane materialization: id:<repoId>::<path>.
WT_JSON=$(orchard worktree list --json)
TARGET=$(WT_JSON="$WT_JSON" python3 -c '
import json, os
items = json.loads(os.environ["WT_JSON"])["result"]
items = items.get("worktrees", items) if isinstance(items, dict) else items
for item in items:
    if "bench" in item.get("path", ""):
        print(item["id"]); break
')
[[ -n "$TARGET" ]] || fail "could not find a bench worktree id"
TARGET_PATH=${TARGET#*::}

echo
echo "T86 switch-latency benchmark — median of $RUNS runs, 3 repos x 1 worktree"
echo
printf '| %-46s | %9s |\n' "Call" "Median"
printf '|%s|%s|\n' "$(printf -- '-%.0s' {1..48})" "$(printf -- '-%.0s' {1..11})"
row "orchard status (CLI round-trip baseline)"      "$(median_ms status orchard status --json)"
row "worktree list (all three repos)"               "$(median_ms wtlist orchard worktree list --json)"
row "worktree list --repo id:<repo1>"               "$(median_ms wtlist1 orchard worktree list --repo "id:${REPO_IDS[0]}" --json)"
row "terminal create --cwd <path>"                  "$(median_create_ms tcwd orchard terminal create --cwd "$TARGET_PATH" --json)"
row "terminal create --worktree id:<repo>::<path>"  "$(median_create_ms twt orchard terminal create --worktree "id:$TARGET" --json)"
row "git worktree list --porcelain (raw)"           "$(median_ms rawwt git -C "$BENCH_ROOT/repo1" worktree list --porcelain)"
row "git status --porcelain (raw)"                  "$(median_ms rawst git -C "$TARGET_PATH" status --porcelain)"
echo
