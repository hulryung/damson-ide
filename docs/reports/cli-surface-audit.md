# T77 — CLI surface audit against inventory §7

Wave 21. Owns `Sources/orchard/**`, `OrchardProtocol/CommandSpec.swift` + guides,
worktree/project handlers in `OrchardRuntime/Workspaces/**`, WorkerVerbs' read
path for `hasOlder`, matching tests. Does not touch Files/**,
WorktreeManager.swift, Conflicts/**, or Automations.

Inventory: `docs/research/orca-inventory.md` §7. Known going in: `worktree`
lacked first-class `show|current|create|set|rm|ps`; there was no `project`
group; `worker-read` had no `hasOlder` (dogfood-5 finding 11, dogfood-6
finding 12). Skills, artifacts, and computer are out of scope.

## Inventory §7 vs orchard

| Inventory group | Orchard today | This task |
|---|---|---|
| `open` | no CLI verb | left — see below |
| `serve` | `orchard serve` | already present |
| `status` | `orchard status` | already present |
| `repo list\|add\|show\|set-base-ref` | `repo list\|add\|show\|remove`; `--base-ref` on add only | `set-base-ref` left — see below |
| `project …` | missing | **closed**: `list\|show\|current` |
| `worktree list\|show\|current\|create\|set\|rm\|ps` | RPC + CLI routing existed; spec/help/human face treated them as one bag of flags | **closed**: first-class subverbs, flags, guide, human faces, tests |
| `file …` | `open\|diff\|open-changed\|search` | already present (Files/** out of ownership) |
| `automations …` | full group including `once` / `due` / `fire-due` | already present (Automations out of ownership) |
| `artifacts share\|update\|unshare\|list\|delete` | none | **out of scope** |
| `skills …` | none (`guide get` is the in-binary guide surface) | **out of scope** |
| `computer …` | none | **out of scope** |
| `agent-context` | `orchard agent-context --json` | already present |

`terminal`, `browser`, `host`, orchestration verbs, `conflicts`, and
`workspace-ports` are extra relative to §7 and were not in this task.

## Gaps closed

### 1. `worktree` subverbs are first-class

RPC already had `worktree-list|show|current|create|set|rm`; `worktree-ps` already
lived on `PortCommandHandler`. Dogfood cycles used `list` / `create` / `show` /
`rm`. What was missing was the agent-facing contract:

- CommandSpec usage is now `orchard worktree list|show|current|create|set|rm|ps [options]`,
  with one example per subverb. Summary no longer reads as list+ps only.
- `--agent` (enumerated), `--prompt`, and `--run-hooks` are advertised so
  `worktree create --agent claude` is not rejected as an unknown flag (the
  handler already accepted them).
- CLI validates the known subverb set and maps `remove`/`delete` → `rm`.
- `create` infers `--repo` from the enclosing worktree when omitted (Orca's
  default), typed `invalid_argument` otherwise.
- Human faces for `show`/`current`/`set`/`create` instead of the JSON fallback.
- `orchard guide get worktree`.

### 2. `project` group

A project is a registered repo — the same grouping the sidebar uses.

- `project list` — id, display name, path, host, kind, base ref, worktree count.
- `project show --project <selector>` — that record plus its worktrees.
  `--repo` is an alias of `--project`.
- `project current` — cwd → enclosing project's repo.
- Handler in `OrchardRuntime/Workspaces/ProjectCommandHandler.swift`, registered
  next to the worktree handler. CommandSpec, guide, human faces, tests.

Host-setup verbs are deliberately not implemented (see below).

### 3. `worker-read.hasOlder`

Dogfood-5/6: a live `--limit` default of 200 on 231 lines returned
`truncated: false`; older lines were only discoverable by comparing
`oldestCursor` with `latestCursor − returnedLineCount`.

The receipt now carries `hasOlder` (and live `startCursor`, matching the
archive shape):

- `hasOlder` is true when lines exist *before this window* that the caller can
  still request (`startCursor > oldestCursor`; archive oldest is 0).
- `truncated` stays "the requested cursor was below the retained ring" — those
  older lines are gone.
- Transcript reads (the whole document) set `hasOlder: false`; byte-cap
  truncation stays on `truncated`.
- CommandSpec notes, orchestration guide, and worker-read tests name the field.

## Gaps deliberately left

- **`open`**: launching the app is a user/trampoline action; this task forbids
  launching or quitting Orchard, and an agent-facing `open` would fight that.
- **`repo set-base-ref`**: inventory §7 names it; orchard takes `--base-ref` on
  `repo add` only. Changing a repo's default base after add would live in
  `RepoRegistryHandler` (`Server/**`), outside this task's ownership.
- **`project setups|setup-clone|setup-create|setup-update|setup-delete|setup-existing-folder`**:
  Orca's independent project-host-setup metadata / multi-host federation.
  Orchard registers a checkout with `repo add` (including `--host ssh:<name>`).
- **`worktree create --project / --host / --project-host-setup / --activate / --linear-issue`**:
  Orca extras that need the host-setup model or Linear. `--repo` and cwd
  inference cover placement; Linear links stay `--issue`.
- **`worktree create --setup run|skip|inherit`**: the handler's setup switch is
  boolean `--run-hooks`; the full policy lives on `worker-start --setup`.
- **Skills, artifacts, computer**: out of scope for T77 — not invented.
- **`guide get` remaining Orca skill topics** (orca-cli, linear, …): orchard
  ships orchestration, conflicts, worktree, and project.

## Tests

- `WorkspaceHandlerTests`: create infers repo from cwd; missing repo+cwd is
  typed `invalid_argument`. Existing list/show/current/set/rm coverage kept.
- `ProjectHandlerTests`: list/show/current, `unknown_repo`, missing selector,
  `not_in_worktree`.
- `WorkerVerbTests`: live `--limit 3` of 10 lines → `hasOlder: true`; `--cursor 0`
  → false; archived full window false, paged window true; transcript false.
- `CLIFormattingTests` / `DispatchErgonomicsTests` / `PreambleTests`: CommandSpec,
  human faces, guides, `hasOlder` notes.

`swift build && swift test` must pass on this change. The app was not launched
or quit.
