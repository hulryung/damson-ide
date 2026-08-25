# T62 — Window frame persistence

The main workbench and the auxiliary windows (Settings, Dashboard,
Orchestration, Automations, Vault) now remember their frames across relaunch
via AppKit `setFrameUsingName` / `setFrameAutosaveName`. First launch still
uses the compile-time default size and centers; a later launch restores the
saved frame instead of re-centering on top of it. That is the dogfood-4
reason keeper-adopted panes commonly first painted into a smaller window
than the user had left.

This change was not exercised against a live Orchard.app in this worktree —
the task forbids launching or quitting the running app. The checks below need
a human visual pass on a build that includes this commit.

## What is covered by unit tests

`WindowFrameAutosave` (OrchardCore) is the decision table the AppKit creation
sites consult:

- Every role has a unique, stable autosave name (`OrchardMainWindow`,
  `OrchardSettingsWindow`, `OrchardDashboardWindow`,
  `OrchardOrchestrationWindow`, `OrchardAutomationsWindow`,
  `OrchardVaultWindow`). Renaming one forgets that window's frame.
- Default content sizes match the pre-T62 creation sites (main 1180×760,
  dashboard 960×520, orchestration/automations 1040×620, vault 1080×640).
  Settings has no compile-time size; its origin still autosaves.
- Center only when no saved frame was applied. Centering after a successful
  restore is what made relaunch forget the user's frame.
- T51 close→reopen reuses the retained `NSWindow` (`isReleasedWhenClosed =
  false`): `reopenStrategy` is `orderFrontExisting` when the window already
  exists, `createAndRestore` only on first creation this process. Reopen
  does not re-apply the default size or re-center.

AppKit's actual UserDefaults write/restore is not unit-tested (needs a
window server and would pollute the test runner's defaults).

## Human visual pass

Use a build of this commit (not the currently running Orchard). Do **not**
Cmd-Q the live dogfood app to "test" this.

1. **Relaunch restores the workbench frame.** Resize and move the Orchard
   workbench away from the first-launch default. Quit (⌘Q) and relaunch.
   The workbench must come back at the same origin and size, not 1180×760
   centered. Keeper-adopted panes should therefore first paint into the
   size the user left, not the compile-time default (pairs with T59).
2. **T51 close→reopen keeps the in-memory frame.** With the workbench
   already at a non-default size, close it (runtime stays). Dock click /
   Window ▸ Show Orchard must bring back the **same** frame — not a
   re-centered default. AppKit is not creating a new window here.
3. **Auxiliary windows persist independently.** Open Settings, Dashboard,
   Orchestration, Automations, Vault. Move (and, where resizable, resize)
   each. Close each, reopen from the menu: same frame in-process. Quit and
   relaunch, reopen each: same frames from autosave. Closing one must not
   change another's frame.
4. **First-launch fallback.** On a machine / defaults domain with no saved
   frames (or after clearing `NSWindow Frame Orchard*Window`), each window
   must still open at its default size, centered, and then start autosaving.
5. **Off-screen / display change.** Unplug a display that held a window.
   The next restore should stay on a visible screen (AppKit's default
   `setFrameUsingName` constraint). Not a blocker if the window is merely
   snapped to the remaining display.

## Not in this task

- Making Settings resizable (it was titled+closable only; position still
  persists).
- AppKit secure restorable state / reopening which windows were visible
  at quit. Only frames of windows the app itself creates are persisted.
- OrchardRuntime, OrchardTerminals, or AutomationEditorSheet.swift.
- Launching or quitting the live dogfood app.
