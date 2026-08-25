# T59 — Keeper-adopted pane fit

**Symptom (wave 7 → 15):** after a clean quit + relaunch, a keeper-adopted pane
shows its first row clipped at the top until a manual resize. T31 (wave 8)
re-evaluated the SwiftUI alignment on `gridChanged` and the pane it screenshotted
looked right, but the symptom kept recurring.

This report records what the code path actually does for an adopted pane versus a
fresh spawn, what changed, what the tests pin, and what still needs eyes on a
relaunched app. It was produced headlessly — the app was not launched or quit.

## Where the fit lives

`Sources/OrchardApp/TerminalPaneHost.swift` (T30):

* `TerminalFitSurface.sizeThatFits` snaps the surface to whole cells; leftover
  pixels stay on the SwiftUI parent.
* `TerminalFitHost` top-aligns short content / bottom-aligns overflow from
  `contentRows` vs the snapped viewport rows.

Inside the snapped surface, Damson draws every row at
`inset + row·cellH − scrollY` (`MetalTerminalBackend`), so with a whole-cell
viewport a clipped first row can only come from Damson's **scroll position**
(`scrollY`), not from the geometry SwiftUI hands it. That scroll position is
decided by the surface itself in two places:

* `DamsonSurfaceView.layout()` → `reportSizeIfChanged()` (cell metrics from the
  render font, `session.resize` if the grid or PTY size is stale) and then a
  follow re-pin (`scrollViewportToBottom` / `scrollViewportToAltTop`).
* `renderNow()` → `alignScroll(to: followTargetY())`, keyed on `grid.version`
  — a render whose grid version already matched the last one returns early
  without touching the scroll.

Both are conditional: the cursor-visible policy leaves an already-visible cursor
alone, and the render dedupe skips a grid that did not change.

## What differs for an adopted pane

Fresh spawn (`AppStore.damsonSession(for:)`): the session is created **inside
the view update**, at a live pane's geometry or the spawn default. Its surface is
framed while the grid is still empty; the first `layout()` sizes the PTY; the
prompt then paints into a grid that already matches the viewport. Every scroll
decision is made with real cell metrics against real content.

Keeper adoption (`KeeperRestart.completeBoot`, before any window exists):

1. `DamsonTerminalSession(adopted:…, initialCols: pane.cols, initialRows: pane.rows)`
   — the grid is the *recorded* geometry (correct: the replay was painted for it).
2. `PTYHost.spawn` for an adopted host delivers the replay (mode preamble +
   bytes buffered while the app was down) on the **next main-queue turn**.
3. The main window is created, the surface is built, framed, and laid out.
4. The first `layout()` resizes the grid to the live fit (reflow / trim-pad,
   plus Damson's adoption jiggle: two well-separated SIGWINCHes 300 ms apart).
5. The child repaints on SIGWINCH — the first real paint for this surface.

Steps 2 and 5 are asynchronous relative to 3. Depending on runloop order, the
surface can render replayed content **before it has a frame** (placeholder cell
metrics `1×1`, zero viewport — `followTargetY` then parks a small non-row-aligned
`scrollY`), or the repaint can land against a surface whose `layout()` already
ran and will not run again because its frame did not change. T31's re-fit only
re-evaluated the SwiftUI alignment; it never re-ran the surface's own pass, and
the surface's later renders only re-pin when the cursor leaves the viewport.
The T51 window re-open (a new surface over a live session with content) has the
same shape.

## Change

`TerminalPaneFit.AttachFit` (OrchardTerminals) replaces T31's `AdoptionFit`
latch — which the host never actually wired. It fires **once per surface**, the
moment both facts hold: the surface has a real frame, and the grid holds painted
content. Whichever arrives last triggers it; a resize's own contentless
`gridChanged` (Damson notifies on every `resize`, changed or not — pinned by
`testAdoptedShellAtTheSameGeometryStillWaitsForTheRepaint`) never counts.

`AttachFitDriver` (the surface's SwiftUI coordinator) feeds the latch from
`NSView.frameDidChangeNotification` and `session.gridChanged`, seeds it with what
is already true at attach (an adopted session may already hold content), and on
fire runs — one turn later, after the notifying pass has unwound —

```
view.needsLayout = true
view.layoutSubtreeIfNeeded()   // reportSizeIfChanged + follow re-pin, real metrics, final frame
view.repaintNow()              // render that ignores the grid-version dedupe
```

That is the fresh-spawn attach sequence (layout, then first paint) replayed for
a pane whose paint came first. It runs for every session, so adopted and fresh
panes take the same path by construction; for a fresh pane it is one extra
layout + draw at the prompt paint.

`TerminalPaneFit.contentRows(in:)` / `hasContent(_:)` moved into OrchardTerminals
(`TerminalPaneFit+Grid.swift`) so the decision inputs are testable without the
app target. `KeeperRestart` is unchanged in behaviour; it now documents why the
recorded geometry is the right spawn size and where the reconciliation happens.

Files: `Sources/OrchardApp/TerminalPaneHost.swift`, `Sources/OrchardApp/KeeperRestart.swift`,
`Sources/OrchardTerminals/TerminalPaneFit.swift`, `Sources/OrchardTerminals/TerminalPaneFit+Grid.swift`,
`Tests/OrchardTerminalsTests/TerminalPaneFitTests.swift`,
`Tests/OrchardTerminalsTests/KeeperAdoptedFitTests.swift`.

## Tests

`TerminalPaneFitTests` — the latch as a pure state machine: fresh order (frame,
contentless resize churn, first paint → fires), adoption order (content, zero
frame, real frame → fires), churn before the first paint never spends it, exactly
once per surface.

`KeeperAdoptedFitTests` — a real `DamsonSession` over a fake IO backend that
plays `PTYHost.adopt` + `spawn` (replay on the next main-queue turn):

* Shell held at its prompt, recorded 200×60, fitted to 120×34: the preamble
  replays on the next turn and paints nothing; the attach resize reaches the
  child at 120×34, **pushes no blank rows into scrollback**, and its own
  `gridChanged` carries no paint; the prompt repaint is the first paint, content
  rows = 2, decision = top-aligned, row 0 at y = 0, surface height a whole
  number of cells.
* Same record and window: the no-op resize still notifies; the latch still waits
  for the repaint.
* TUI shape (sync-output frames, cursor-addressed 60-row paint, foreground job):
  content lands unframed → latch waits; the fit shrink keeps all 60 rows as
  scrollback + viewport (`hasUsedSyncOutput` stays armed, so Damson's follow is
  the grid-top anchor); decision = bottom-aligned with the leftover above the
  surface, whole cells only.

`swift build && swift test` pass.

## Human visual pass (after relaunch)

What the tests cannot reach is Damson's scroll position inside the surface. On
the next quit/relaunch cycle of the real app, with `orchard.keepSessionsOnRestart`
on, check each of these **before touching the window**:

1. **Adopted shell pane, same window size as at quit.** The prompt's first line
   sits fully visible at the top with the theme padding above it; no row is cut.
   (This is the case T31 screenshotted; it must still hold.)
2. **Adopted shell pane, window smaller than at quit** (resize the window larger
   before quitting, or clear the saved size). Same expectation; additionally the
   pane must not show a blank gap with the prompt pushed to the bottom.
3. **Adopted Claude Code pane** (a worker running, or Claude idle at its input
   box). The frame is fully visible and top-anchored; the input box and status
   line are at the bottom of the frame, not clipped; the top row of the frame is
   not cut. The two adoption SIGWINCHes will repaint it once or twice within
   ~300 ms — that is expected.
4. **Only then resize the window.** Nothing should jump: a resize must not be
   what makes the first row appear.
5. **T51 re-open**: close the workbench window (runtime stays alive), reopen from
   the Dock. Same checks on the same panes — this path attaches a fresh surface
   to a session that already has content and takes the same re-fit.

If any of 1–3 still shows a clipped first row, capture it with
`DAMSON_RESIZE_LOG=1` in the app's environment and note whether the pane was a
shell or a TUI, and whether the window size changed across the relaunch — the
remaining suspects are all inside `DamsonSurfaceView`'s follow policy (a
Damson-side change; see "Where the fit lives").

## Not done / out of reach here

* No live quit/relaunch verification: the app is the user's and was not launched.
* Nothing changed on the Damson side; the fix uses only `needsLayout`,
  `layoutSubtreeIfNeeded()` and `repaintNow()`. If the visual pass still fails,
  the next lever is Damson exposing an explicit "re-pin follow" entry point
  (`alignScroll` to `followTargetY`) that the host can call unconditionally.
* Window frame persistence is T62 (`docs/reports/t62-window-frames.md`): the
  workbench and auxiliary windows now restore via `setFrameAutosaveName`, so
  case 2 above is no longer the default relaunch path.
