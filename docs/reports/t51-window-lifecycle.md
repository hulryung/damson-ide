# T51 — Runtime survives window close

Closing the main workbench no longer terminates Orchard. The in-process runtime
and every supervised worker stay up; Dock reopen / a windowless activation
restores the same workbench. Cmd-Q / Orchard ▸ Quit is still the only full
termination path (T23 keeper handoff, `shutdownAll`, metadata removal).

This change was not exercised against a live Orchard.app in this worktree —
the task forbids launching or quitting the running app. The checks below need
a human visual pass on a build that includes this commit.

## What is covered by unit tests

`WindowLifecycle` (OrchardCore) is the decision table the AppKit callbacks
consult:

- A runtime-hosting app does **not** quit when the last window closes; a
  non-host still does (Cocoa default).
- Dock / Finder reopen always order-fronts the workbench, even if an
  auxiliary window is already visible.
- Cmd-Tab restores the workbench only when **no** Orchard window is visible
  (a focused Settings / Vault / Orchestration / Dashboard / Automations
  window is not stolen). Window ▸ Show Orchard and the Dock menu item always
  front the workbench.
- The Dock / Orchard menu indication is **alive** only when this process has
  a listening control-plane socket. A constructed-but-unbound host reads
  "Runtime not listening"; a missing host reads "Runtime unavailable". The
  title includes the live `runtimeId` when alive so it cannot be a stale
  "we're still here" badge.

## Human visual pass

Use a build of this commit (not the currently running Orchard). Do **not**
Cmd-Q the live dogfood app to "test" this.

1. **Close the main window, runtime stays.** With at least one repo open and
   `orchard status --json` succeeding, close the Orchard workbench (red
   traffic-light or ⌘W on that window). The Dock icon must remain. A second
   `orchard status --json` must still return `ok: true` with the **same**
   `runtimeId` and a living pid. `~/Library/Application Support/Orchard/orchard-runtime.json`
   must still exist. Supervised terminals / workers must not SIGHUP.
2. **Dock reopen restores the workbench.** Click the Dock icon. The same
   workbench must come back (same project / card / split layout — state lives
   on `AppStore`, not in a new empty window).
3. **Windowless activation.** Close the workbench and every auxiliary window,
   then Cmd-Tab to Orchard. The workbench must reappear.
4. **Auxiliary windows are unchanged.** Open Settings, Dashboard,
   Orchestration, Automations, Vault. Close each independently. Each must
   hide without quitting. Closing the last auxiliary window while the
   workbench is already closed must **not** quit (same as 1). Dock click
   while Settings is open must re-front the workbench without closing
   Settings.
5. **Runtime indication without the workbench.** After step 1, open the
   Dock menu and the Orchard application menu. Both must show
   `Runtime alive · rt_…` matching `status --json`. The row is not an
   action. If the socket ever failed to bind, the title must be
   `Runtime not listening`, not a false "alive".
6. **Cmd-Q is still T23.** With live panes, Orchard ▸ Quit (or ⌘Q). Confirm
   `orchard-runtime.json` is removed, the process exits, and a subsequent
   relaunch adopts surviving PTYs (keeper generation consumed; no SIGHUP
   of children that were handed off). This is the existing T23 path —
   `applicationWillTerminate` is unchanged except for a comment that
   window-close must not reach it.

## Not in this task

- Status-bar / in-window runtime badge (the requirement is reachable
  *without* the main window: Dock menu + app menu).
- Changing auxiliary-window close behavior beyond "do not quit the app".
- OrchardTerminals, OrchardRuntime, or the CLI.
