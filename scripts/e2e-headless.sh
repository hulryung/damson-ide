#!/usr/bin/env bash
# Headless, process-boundary orchestration smoke test. The harness follows the
# documented scripted-shell path: it reads the worker's injected capability, then
# answers for that otherwise non-agent shell using its bound terminal identity.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORCHARD_BIN="${ORCHARD_E2E_BIN:-$REPO_ROOT/.build/release/orchard}"
E2E_ROOT="$(mktemp -d /tmp/orchard-e2e.XXXXXX)"
E2E_HOME="$E2E_ROOT/home"
DATA_DIR="$E2E_HOME/Library/Application Support/Orchard"
SOURCE_REPO="$E2E_ROOT/repo"
SERVE_LOG="$E2E_ROOT/serve.log"
METADATA="$DATA_DIR/orchard-runtime.json"
SERVE_PID=""
SOCKET_PATH=""

fail() {
    echo "e2e-headless: FAIL: $*" >&2
    if [[ -f "$SERVE_LOG" ]]; then tail -100 "$SERVE_LOG" >&2; fi
    exit 1
}

cleanup() {
    local status=$?
    if [[ -n "$SERVE_PID" ]] && kill -0 "$SERVE_PID" 2>/dev/null; then
        kill -INT "$SERVE_PID" 2>/dev/null || true
        wait "$SERVE_PID" 2>/dev/null || true
    fi
    if [[ $status -eq 0 ]]; then rm -rf "$E2E_ROOT"; fi
}
trap cleanup EXIT

receipt() {
    local label=$1
    shift
    local output
    if ! output=$(HOME="$E2E_HOME" CFFIXED_USER_HOME="$E2E_HOME" "$ORCHARD_BIN" "$@" 2>&1); then
        echo "e2e-headless: $label receipt:" >&2
        echo "$output" >&2
        fail "$label command failed"
    fi
    if ! RECEIPT="$output" python3 - "$label" <<'PY'
import json, os, sys
label = sys.argv[1]
try:
    value = json.loads(os.environ["RECEIPT"])
except Exception as error:
    raise SystemExit(f"{label}: invalid JSON: {error}\n{os.environ['RECEIPT']}")
if value.get("ok") is not True:
    raise SystemExit(f"{label}: receipt was not ok\n{json.dumps(value, indent=2)}")
PY
    then
        echo "$output" >&2
        fail "$label receipt assertion failed"
    fi
    printf '%s' "$output"
}

field() {
    RECEIPT="$1" python3 - "$2" <<'PY'
import json, os, sys
value = json.loads(os.environ["RECEIPT"])
for part in sys.argv[1].split('.'):
    value = value[int(part)] if isinstance(value, list) else value[part]
if isinstance(value, bool): print(str(value).lower())
elif isinstance(value, (dict, list)): print(json.dumps(value, separators=(',', ':')))
else: print(value)
PY
}

find_key() {
    RECEIPT="$1" python3 - "$2" <<'PY'
import json, os, sys
needle = sys.argv[1]
def find(value):
    if isinstance(value, dict):
        if needle in value: return value[needle]
        for child in value.values():
            found = find(child)
            if found is not None: return found
    elif isinstance(value, list):
        for child in value:
            found = find(child)
            if found is not None: return found
    return None
found = find(json.loads(os.environ["RECEIPT"]))
if found is None: raise SystemExit(f"missing key: {needle}")
print(json.dumps(found, separators=(',', ':')) if isinstance(found, (dict, list)) else found)
PY
}

assert_eq() {
    [[ "$1" == "$2" ]] || fail "$3 (expected '$2', got '$1')"
}

# Headless PTYs have no pane repaint. A raw write gives the generic shell
# readiness detector the same quiescent output a visible prompt would.
# `$1` is a file of already-poked handles so fireDue can poll without
# re-injecting into a pane that is already idle.
poke_shell_terminals() {
    local seen_file=${1:-}
    local terminals_json handle
    terminals_json=$(receipt terminal-list terminal list --json)
    while IFS= read -r handle; do
        [[ -z "$handle" ]] && continue
        if [[ -n "$seen_file" ]] && grep -qx "$handle" "$seen_file" 2>/dev/null; then
            continue
        fi
        # T60: an automation shell that already ran its command line and exited
        # refuses input — that is the fix working, not a harness failure.
        HOME="$E2E_HOME" CFFIXED_USER_HOME="$E2E_HOME" "$ORCHARD_BIN" terminal send \
            --terminal "$handle" --text "printf 'orchard-e2e-shell-ready\\n'" --enter --json \
            >/dev/null 2>&1 || true
        if [[ -n "$seen_file" ]]; then
            printf '%s\n' "$handle" >> "$seen_file"
        fi
    done < <(RECEIPT="$terminals_json" python3 - <<'PY'
import json, os
r=json.loads(os.environ['RECEIPT'])['result']
items=r.get('terminals', r if isinstance(r, list) else [])
for item in items:
    handle=item.get('handle')
    if handle:
        print(handle)
PY
)
}

[[ -x "$ORCHARD_BIN" ]] || fail "missing executable $ORCHARD_BIN (run swift build -c release)"
mkdir -p "$DATA_DIR" "$SOURCE_REPO"
# A headless PTY has no rendered pane to repaint its first prompt. Emit one stable
# line during shell startup so the generic readiness detector observes quiescence.
printf 'printf "\\033]9999;idle\\007"\nprint -r -- "orchard-e2e-shell-ready"\n' > "$E2E_HOME/.zshrc"
git -C "$SOURCE_REPO" init -q -b main
git -C "$SOURCE_REPO" config user.email orchard-e2e@example.invalid
git -C "$SOURCE_REPO" config user.name "Orchard E2E"
printf 'headless e2e\n' > "$SOURCE_REPO/README.md"
git -C "$SOURCE_REPO" add README.md
git -C "$SOURCE_REPO" commit -q -m initial

HOME="$E2E_HOME" CFFIXED_USER_HOME="$E2E_HOME" "$ORCHARD_BIN" serve --data-dir "$DATA_DIR" >"$SERVE_LOG" 2>&1 &
SERVE_PID=$!
for _ in {1..200}; do
    [[ -s "$METADATA" ]] && break
    kill -0 "$SERVE_PID" 2>/dev/null || fail "serve exited before publishing metadata"
    sleep 0.05
done
[[ -s "$METADATA" ]] || fail "serve metadata did not appear"
SOCKET_PATH=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["socketPath"])' "$METADATA")
[[ -S "$SOCKET_PATH" ]] || fail "metadata socket is not live: $SOCKET_PATH"

status_json=$(receipt status status --json)
assert_eq "$(field "$status_json" result.mode)" headless "status mode"
assert_eq "$(field "$status_json" result.status)" ready "status readiness"

repo_json=$(receipt repo-add repo add --path "$SOURCE_REPO" --json)
repo_id=$(field "$repo_json" result.id)
[[ "$repo_id" == *-* ]] || fail "unexpected repo id: $repo_id"

run_json=$(receipt run-create run-create --objective "Headless E2E orchestration cycle" --json)
run_id=$(find_key "$run_json" runId)
task_json=$(receipt task-create task-create --run "$run_id" --task-title "Shell worker self-report" \
    --spec "The headless E2E harness will submit worker_done through this shell PTY." --json)
task_id=$(find_key "$task_json" taskId)

start_receipt="$E2E_ROOT/worker-start.json"
HOME="$E2E_HOME" CFFIXED_USER_HOME="$E2E_HOME" "$ORCHARD_BIN" worker-start \
    --task "$task_id" --repo "$repo_id" --name "headless-e2e-worker" \
    --agent shell --base-branch main --setup skip --timeout-ms 30000 --json \
    >"$start_receipt" 2>&1 &
start_pid=$!
worker_handle=""
for _ in {1..200}; do
    terminals_json=$(receipt terminal-list terminal list --json)
    worker_handle=$(RECEIPT="$terminals_json" python3 - <<'PY'
import json, os
r=json.loads(os.environ['RECEIPT'])['result']
items=r.get('terminals', r if isinstance(r, list) else [])
print(items[0]['handle'] if items else '')
PY
)
    [[ -n "$worker_handle" ]] && break
    kill -0 "$start_pid" 2>/dev/null || break
    sleep 0.05
done
[[ -n "$worker_handle" ]] || fail "worker-start did not create a discoverable shell terminal"
# Headless mode has no pane repaint. A raw PTY write gives the generic shell
# readiness detector the same quiescent output evidence a visible prompt provides.
receipt shell-readiness terminal send --terminal "$worker_handle" \
    --text "printf 'orchard-e2e-shell-ready\\n'" --enter --json >/dev/null
if ! wait "$start_pid"; then
    echo "e2e-headless: worker-start receipt:" >&2
    cat "$start_receipt" >&2
    fail "worker-start command failed"
fi
start_json=$(python3 -c 'import json,sys; value=json.load(open(sys.argv[1])); assert value.get("ok") is True, json.dumps(value,indent=2); print(json.dumps(value))' "$start_receipt") \
    || fail "worker-start receipt assertion failed"
assert_eq "$(field "$start_json" result.state)" ready "worker-start state"
assert_eq "$(field "$start_json" result.stage)" input_accepted "worker-start stage"
dispatch_id=$(field "$start_json" result.dispatchId)
started_handle=$(RECEIPT="$start_json" python3 - <<'PY'
import json, os
r=json.loads(os.environ['RECEIPT'])['result']
print(next(x['id'] for x in r['effects'] if x.get('kind') == 'terminal'))
PY
)
assert_eq "$started_handle" "$worker_handle" "worker terminal identity"
worktree_id=$(RECEIPT="$start_json" python3 - <<'PY'
import json, os
r=json.loads(os.environ['RECEIPT'])['result']
print(next(x['id'] for x in r['effects'] if x.get('kind') == 'worktree'))
PY
)

read_live=$(receipt worker-read-live worker-read --dispatch "$dispatch_id" --source terminal --cursor 0 --limit 1000 --json)
capability=$(RECEIPT="$read_live" python3 - <<'PY'
import json, os, re
value=json.loads(os.environ['RECEIPT'])
text='\n'.join(value['result']['lines'])
match=re.search(r'--dispatch-capability (dcap_[A-Za-z0-9_-]+)', text)
if not match: raise SystemExit('dispatch capability absent from worker preamble')
print(match.group(1))
PY
)

done_json=$(receipt scripted-worker-done send --from "$worker_handle" \
    --dispatch-capability "$capability" --type worker_done --subject headless-e2e \
    --body "Harness-reported completion for the bound non-agent shell." \
    --task-id "$task_id" --dispatch-id "$dispatch_id" --outcome succeeded --json)
assert_eq "$(field "$done_json" result.lifecycle.status)" settled "worker_done settlement"

check_json=$(receipt check-wait check --run "$run_id" --wait --types worker_done,escalation,question --timeout-ms 30000 --json)
assert_eq "$(find_key "$check_json" type)" worker_done "check delivery type"
delivery_id=$(find_key "$check_json" deliveryId)

release_json=$(receipt worker-release worker-release --dispatch "$dispatch_id" --json)
assert_eq "$(field "$release_json" result.state)" released "worker release state"
archive_json=$(receipt worker-read-archive worker-read --dispatch "$dispatch_id" --source terminal --limit 1000 --json)
assert_eq "$(field "$archive_json" result.archived)" true "worker archive presence"
RECEIPT="$archive_json" python3 - <<'PY' || fail "worker archive lacks its injected lifecycle preamble"
import json, os
r=json.loads(os.environ['RECEIPT'])['result']
assert any('worker_done' in line for line in r['lines'])
PY

receipt check-ack check --run "$run_id" --ack "$delivery_id" --json >/dev/null
rm_json=$(receipt worktree-rm worktree rm --worktree "$worktree_id" --force --json)
assert_eq "$(field "$rm_json" result.removed)" true "worktree removal"

# T56/T60: create a `once` automation due in the current UTC minute, with a shell
# provider whose prompt is a real command, then drive due/fireDue (not
# automations-run) and require:
#   - a fired history row naming the worktree, terminal, and dispatch (T56 + T60);
#   - the dispatch settles on the shell's own exit — the submitted command line
#     runs the prompt, reports worker_done with the exit status, and exits
#     (dogfood-4 findings 3 and 5; nothing is left as an unsubmitted paste);
#   - worker-release archives the exited pane (closed_exited_terminal);
#   - the once automation disabled itself and no path fires it again (finding 4);
#   - a paused cron automation is never due (create --disabled, then remove).
auto_json=$(receipt automations-create automations create \
    --name "e2e-fire-once" \
    --trigger once \
    --time now \
    --provider shell \
    --prompt "printf 'orchard-e2e-%s\\n' \"\$((6*7))\"" \
    --repo "$repo_id" \
    --json)
auto_id=$(field "$auto_json" result.id)
[[ "$auto_id" == auto_* ]] || fail "unexpected automation id: $auto_id"
assert_eq "$(field "$auto_json" result.trigger)" once "automation trigger"
assert_eq "$(field "$auto_json" result.enabled)" true "automation starts enabled"

due_json=$(receipt automations-due automations due --json)
due_count=$(RECEIPT="$due_json" python3 - <<'PY'
import json, os
print(len(json.loads(os.environ["RECEIPT"])["result"].get("due") or []))
PY
)
runs_before=$(receipt automations-runs-before automations runs --id "$auto_id" --json)
already_fired=$(RECEIPT="$runs_before" python3 - <<'PY'
import json, os
runs=json.loads(os.environ["RECEIPT"])["result"].get("runs") or []
print("true" if any(r.get("outcome") == "fired" and r.get("worktreeId") and r.get("terminalId") for r in runs) else "false")
PY
)
if [[ "$due_count" == "0" && "$already_fired" != "true" ]]; then
    fail "automation $auto_id was not due immediately and has no fired run yet"
fi

if [[ "$already_fired" != "true" ]]; then
    fire_receipt="$E2E_ROOT/automation-fire-due.json"
    poked_handles="$E2E_ROOT/poked-handles"
    : >"$poked_handles"
    HOME="$E2E_HOME" CFFIXED_USER_HOME="$E2E_HOME" "$ORCHARD_BIN" automations fire-due --json \
        >"$fire_receipt" 2>&1 &
    fire_pid=$!
    for _ in {1..400}; do
        poke_shell_terminals "$poked_handles"
        kill -0 "$fire_pid" 2>/dev/null || break
        sleep 0.05
    done
    if ! wait "$fire_pid"; then
        echo "e2e-headless: automations fire-due receipt:" >&2
        cat "$fire_receipt" >&2
        fail "automations fire-due command failed"
    fi
    fire_json=$(python3 -c 'import json,sys; value=json.load(open(sys.argv[1])); assert value.get("ok") is True, json.dumps(value,indent=2); print(json.dumps(value))' "$fire_receipt") \
        || fail "automations fire-due receipt assertion failed"
    RECEIPT="$fire_json" python3 - <<'PY' || fail "automations fire-due did not persist a fired run with worktree/terminal/dispatch"
import json, os
runs=json.loads(os.environ["RECEIPT"])["result"].get("runs") or []
assert any(r.get("outcome") == "fired" and r.get("worktreeId") and r.get("terminalId") and r.get("dispatchId") for r in runs), json.dumps(runs, indent=2)
PY
fi

runs_json=$(receipt automations-runs automations runs --id "$auto_id" --json)
auto_run_fields=$(RECEIPT="$runs_json" python3 - <<'PY'
import json, os, sys
runs=json.loads(os.environ["RECEIPT"])["result"].get("runs") or []
for run in runs:
    if run.get("outcome") == "fired" and run.get("worktreeId") and run.get("terminalId"):
        print(run["worktreeId"], run["terminalId"], run.get("dispatchId") or "", run.get("orchestrationRunId") or "")
        sys.exit(0)
raise SystemExit("run history has no fired row with worktreeId and terminalId")
PY
)
read -r auto_worktree auto_terminal auto_dispatch auto_orun <<<"$auto_run_fields"
[[ -n "$auto_worktree" ]] || fail "automation run history missing worktree id"
[[ "$auto_dispatch" == ctx_* ]] || fail "automation run history missing dispatch id (got '$auto_dispatch')"
[[ "$auto_orun" == run_* ]] || fail "automation run history missing orchestration run id (got '$auto_orun')"
[[ "$(RECEIPT="$runs_json" python3 -c 'import json,os; print(len(json.loads(os.environ["RECEIPT"])["result"]["runs"]))')" == "1" ]] \
    || fail "the once automation must have exactly one run row"

# T60: the shell worker settles on its own exit. Its submitted command line ran
# the prompt, sent worker_done with the exit status, and exited; the dispatch is
# therefore `succeeded` without anyone else touching it.
auto_state=""
for _ in {1..400}; do
    auto_show=$(receipt automation-worker-show worker-show --dispatch "$auto_dispatch" --json)
    auto_state=$(field "$auto_show" result.worker.state)
    case "$auto_state" in succeeded|failed|stopped|abandoned) break ;; esac
    sleep 0.05
done
assert_eq "$auto_state" succeeded "automation shell worker settled on exit"
assert_eq "$(field "$auto_show" result.dispatch.status)" completed "automation dispatch completed"
auto_done=$(receipt automation-check check --run "$auto_orun" --types worker_done --json)
assert_eq "$(find_key "$auto_done" type)" worker_done "automation worker_done delivered to its run"
auto_outcome=$(RECEIPT="$auto_done" python3 - <<'PY'
import json, os
def find(value, needle):
    if isinstance(value, dict):
        if needle in value: return value[needle]
        for child in value.values():
            found = find(child, needle)
            if found is not None: return found
    elif isinstance(value, list):
        for child in value:
            found = find(child, needle)
            if found is not None: return found
    return None
value = json.loads(os.environ["RECEIPT"])
payload = find(value, "payload")
if isinstance(payload, str):
    try: payload = json.loads(payload)
    except Exception: payload = {}
print((payload or {}).get("outcome") or find(value, "outcome") or "")
PY
)
assert_eq "$auto_outcome" succeeded "automation worker_done outcome"
auto_exit=$(receipt automation-terminal-wait terminal wait --terminal "$auto_terminal" --for exit --timeout-ms 10000 --json)
assert_eq "$(field "$auto_exit" result.satisfied)" true "automation shell exited after worker_done"

# Release must not strand the exited pane: archive first, then close it.
auto_release=$(receipt automation-worker-release worker-release --dispatch "$auto_dispatch" --json)
assert_eq "$(field "$auto_release" result.state)" released "automation worker release state"
assert_eq "$(field "$auto_release" result.processAction)" closed_exited_terminal "automation worker release closed the exited pane"
auto_archive=$(receipt automation-worker-read worker-read --dispatch "$auto_dispatch" --source terminal --limit 2000 --json)
assert_eq "$(field "$auto_archive" result.archived)" true "automation worker archive presence"
RECEIPT="$auto_archive" python3 - <<'PY' || fail "automation archive lacks the prompt's own output (the command did not execute)"
import json, os
r=json.loads(os.environ['RECEIPT'])['result']
lines=[line.strip() for line in r['lines']]
assert 'orchard-e2e-42' in lines, lines[-40:]
PY

# T60 (finding 4): once → auto-disabled; nothing fires it a second time.
auto_show_json=$(receipt automations-show automations show "$auto_id" --json)
assert_eq "$(field "$auto_show_json" result.enabled)" false "once automation auto-disabled after firing"
refire_json=$(receipt automations-fire-due-again automations fire-due --json)
[[ "$(RECEIPT="$refire_json" python3 -c 'import json,os; print(len(json.loads(os.environ["RECEIPT"])["result"].get("runs") or []))')" == "0" ]] \
    || fail "a consumed once automation fired again"
cron_json=$(receipt automations-create-paused automations create \
    --name "e2e-cron-paused" --trigger five-field-cron --time '* * * * *' \
    --provider shell --prompt "true" --repo "$repo_id" --disabled --json)
cron_id=$(field "$cron_json" result.id)
assert_eq "$(field "$cron_json" result.enabled)" false "paused cron automation created disabled"
due_after=$(receipt automations-due-after automations due --json)
[[ "$(RECEIPT="$due_after" python3 -c 'import json,os; print(len(json.loads(os.environ["RECEIPT"])["result"].get("due") or []))')" == "0" ]] \
    || fail "a consumed once automation or a paused cron automation was listed as due"
rm_cron=$(receipt automations-remove-paused automations remove "$cron_id" --json)
assert_eq "$(field "$rm_cron" result.removed)" true "paused cron automation removal"

rm_auto=$(receipt automation-worktree-rm worktree rm --worktree "$auto_worktree" --force --json)
assert_eq "$(field "$rm_auto" result.removed)" true "automation worktree removal"

kill -INT "$SERVE_PID"
if ! wait "$SERVE_PID"; then fail "serve did not exit cleanly after SIGINT"; fi
SERVE_PID=""
[[ ! -e "$METADATA" ]] || fail "runtime metadata remained after shutdown"
[[ ! -e "$SOCKET_PATH" ]] || fail "runtime socket remained after shutdown"
rm -rf "$E2E_ROOT"
[[ ! -e "$E2E_ROOT" ]] || fail "temporary directory was not removable"
trap - EXIT
echo "e2e-headless: PASS (repo → run/task → shell worker_done → archive/release → worktree rm → automations once due/fireDue → shell worker settled on exit → release/archive → auto-disabled → clean SIGINT)"
