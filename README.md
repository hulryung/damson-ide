# Orchard

**A native macOS cockpit for running CLI coding agents side by side — each in its own git worktree.**

Orchard drives multiple agents (Claude Code today; more engines planned) in
parallel, each isolated in its own `git worktree`, and tracks them in one place:
a sidebar of workspaces and agents, a grid or tabbed view of their live
terminals, a task queue, and turn-completion detection so you can see at a glance
which agent is working, waiting on you, or done.

It's the orchestration counterpart to [Damson](https://github.com/hulryung/damson),
the GPU terminal it reuses — Orchard renders each agent's PTY with Damson's own
Metal terminal engine (`DamsonTerminal`) rather than reimplementing one.

> Same product space as [Orca](https://github.com/stablyai/orca), but native
> Swift/AppKit, macOS-only, and built on Damson's terminal engine.

## Status

Early. The core loop works: spawn an agent in a fresh worktree, drive its PTY,
detect when its turn completes, queue and schedule tasks across a concurrency
limit, and steer it from the UI or the `orchard-cli` control socket.

## Build & run

Requires macOS 13+ and a Swift 5.9+ toolchain.

```sh
swift build                 # resolves the Damson engine dependency + builds
./scripts/run-dev.sh        # build Orchard (release) and launch it
swift test                  # DamsonOrchestrator unit tests
```

Orchard self-bundles into `~/Library/Caches/orchard/Orchard.app` on first launch
(its own Dock identity, `app.damson.orchard`). `ORCHARD_NO_TRAMPOLINE=1` runs the
bare binary — handy for driving it headless via `orchard-cli`.

## Architecture

| Target | Role |
|---|---|
| `DamsonOrchestrator` | Engine library: agent sessions, worktree manager, task queue, readiness/turn detection, engine adapters (Claude Code, generic shell). Depends on `DamsonTerminal` + `DamsonControl`. |
| `Orchard` | SwiftUI app: workspace sidebar, agent grid/tabs, session sheets, control-socket dispatch. |
| `OrchardControl` + `orchard-cli` | Unix-socket control plane so scripts (or an agent) can drive a running Orchard instance. |

The terminal engine (`DamsonTerminal`) and IPC wire format (`DamsonControl`) come
from the [damson](https://github.com/hulryung/damson) repo as versioned SwiftPM
library products — pinned in `Package.swift` so damson's daily development can't
break Orchard's build.

## License

MIT — see [LICENSE](LICENSE).
