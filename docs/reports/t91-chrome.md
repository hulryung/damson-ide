# T91 — bringing the left sidebar and the tab strip closer to Orca

**Reference read:** `~/dev/orca`, read-only, 2026-08-27. Findings written up
separately in [`docs/research/orca-chrome.md`](../research/orca-chrome.md) —
that document is the evidence, this one is the argument.

**Changed:** `DesignTokens.swift`, `SidebarView.swift`, the tab-strip half of
`WorkbenchView.swift`, `StatusStyles.swift`.
**Not touched:** the right sidebar, `Checks/**`, `Hosts/**`, `Automations`,
anything under `OrchardRuntime`.

`swift build` clean; `swift test` 1325 tests, 4 skipped, 0 failures.

---

## What Orca is actually doing

Three rules explain nearly all of it, and none of them is about rounding.

**1. Selection is neutral.** Orca never tints a selected row or an active tab
with its accent colour. Selected card, active tab, and the group-by toggle all
use the same primitive: a low-alpha wash of the *foreground* colour, with a
brighter neutral edge doing the actual signalling. The accent appears in that
column for exactly one thing — a drag-insertion bar — and Orca overrides even
that with a hard-coded blue because the theme accent was "too subtle".

**2. Hover changes fill only.** Nothing borders, lifts, or rounds on hover. Tabs
go further: hover changes *text colour* and nothing else.

**3. The list has no dividers.** None between cards, none under headers, none
between groups. The rhythm is padding. The only hairlines in the left column are
the sidebar's own right edge and the borders separating one tab cell from the
next.

And one typographic surprise: **Orca's group headers are 13px semibold at full
foreground — the same size as the card titles beneath them.** There is no 11px
uppercase caption anywhere in that sidebar. Weight does the hierarchy work.

---

## What we adopted

### Selection, everywhere in scope

`Tokens.selectionFill` (10% label) + `Tokens.selectionEdge` (55% label) replace
`Tokens.rowSelected`'s `accentColor.opacity(0.18)` in the workspace list, and
`Tokens.tabActiveFill` (6% label) does the same for the active tab.

This is the change our cards needed most. An Orchard card carries a coloured
status glyph, a coloured git count, an orange unread dot and a host chip whose
colour means reachability. Four independent colour signals sitting in a blue
field is four signals arguing with a fifth that means nothing. Neutral gets out
of their way.

The marker itself: a **2pt bar on the edge facing what the selection owns** —
the bottom of an active tab (exactly Orca's device), the leading edge of a
selected row. See "Departures" below for why the row gets a bar and not Orca's
outline.

The filter bar's archive and group-by toggles moved to the same grammar: "on" is
the neutral wash, not an accent-coloured glyph. That is three fewer accent uses
in a column where the accent should mean *an agent is doing something*.

### Section headers as titles

`Tokens.fontSection` (13pt semibold) at full `Tokens.text`, in a fixed 28pt row,
10pt left gutter, 8pt right, 16pt icon lane, 4pt of air above each group. Both
`RepoHeader` and `StatusGroupHeader` route through one `sectionHeaderChrome()`
modifier so they cannot drift apart.

Previously these were 11pt semibold at `textSecondary` — a caption. In a list
where every card also shows a branch, a host and a diffstat, the repo name was
the smallest, faintest text on screen while being the only thing telling you
which repo the next eight cards belong to.

### The tab strip is a rail of cells

The old `TabChip` was a rounded, bordered chip floating in a strip with 8pt of
horizontal padding and 2pt gaps. That is the "pill sitting on top of a list that
has none" shape the user called out on the left, appearing again in the middle.

Now: a fixed 32pt strip, tabs filling it edge to edge and top to bottom, zero
rounding, separated by single 1px hairlines. The last tab drops its own divider
and the strip closes the run, so the end of the row is one hairline rather than
two stacked into a heavy edge — Orca hit and fixed exactly this and left a
comment about the "heavier L-corner".

Active tab: the neutral 6% lift plus the 2pt bottom bar. Inactive: hover moves
the title to full foreground and touches nothing else.

Two fixes that came along with the geometry: the tab title now truncates instead
of stretching the strip, and the select button fills the cell — a 32pt-tall tab
whose only hit area was its 17pt of text was a miss waiting to happen.

The `+` moved from the far right to immediately after the last tab, where Orca
puts it. It adds to that run; it belongs next to its end.

### Density

Nav header pinned to 32pt with an 8pt gutter (Orca's `h-8 px-2`). Card list
spacing 2 → 0, so a run of cards reads as one list rather than a stack of tiles;
each row's own padding is the whole rhythm. Status glyph 9pt → 11pt inside its
unchanged 14pt lane — the lane width is load-bearing (the meta row indents by 20
to sit under the title), so the glyph grew and the frame did not.

---

## Departures, and why

**Cards stay full-bleed. No 4pt inset, no 8pt radius.**
Orca's cards are inset tiles. Copying that would have been the single most
recognisable "looks like Orca" move available, and it is the one thing here I
deliberately did not do. The only direct feedback we have is that the left list
reads *too rounded*; adding an 8pt radius where there is currently none answers
that with more of what was complained about. A full-bleed row is also the macOS
source-list idiom, it is flatter than Orca, and it costs nothing that matters —
the tile shape was carrying Orca's selection outline, and we replaced that job
with the edge bar. If the user turns out to want the tile, it is a small change
to `WorkspaceRowSurface` and the card's padding, not a rework.

**Tabs keep intrinsic widths. No fixed 180pt.**
Orca pins every tab to 180pt (220pt above 1280px) with an 88pt floor, and has a
scrolling strip with overflow arrows to absorb the consequences. We have no
scrolling strip, and `Tokens.paneMinWidth` is 240 — three fixed-width tabs would
overflow a legal pane and clip with no way to reach the hidden ones. The
*reason* Orca pins them (a live title update resizing every tab) is real and
worth revisiting, but the fix is a scrolling strip first, then fixed widths.
Truncating titles at their intrinsic width is the honest interim.

**No top hairline on tabs.**
Orca borders the top of every tab, which completes the cell grid against the
window titlebar its strip sits under. Ours sits under a `.unifiedCompact`
titlebar or another split, and a hairline that runs across the tabs but stops at
the `+` would read as a rendering artefact rather than structure. The full-height
fill, the dividers and the bottom bar already deliver the cell reading.

**Read card titles are not dimmed.**
Orca dims *read* titles rather than brightening unread ones, which is a large
part of why its list reads calm. Our cards already run a branch, a host chip, a
ports chip and a diffstat at secondary and tertiary, so dimming the titles too
would leave nothing at full contrast. Worth trying only alongside a pass that
quietens the meta row first.

**`Tokens.rowSelected` still exists and is still accent-tinted.**
Nine views outside this task's scope use it — Automations, Chat, Conflicts,
FileExplorer, JumpPalette, OpenRemoteSheet, Orchestration, the right sidebar,
Vault. Retuning the token would have changed all nine without touching a file,
including one T88 is actively editing. The new tokens sit alongside it. Migrating
the rest is a clean follow-up for a wave where nobody else is in those files, and
until then the app has two selection idioms — the sidebar and tab strip on the
neutral one, everything else on the accent one.

**`Tokens.fontPill` stays 10pt semibold.**
Orca's equivalent badges are 10px *medium*. Fourteen files use `fontPill`;
a weight change there is a whole-app pass, not a chrome pass.

---

## Follow-ups, in the order I would take them

1. Migrate the remaining nine `Tokens.rowSelected` call sites to
   `selectionFill`/`selectionEdge` so the app has one selection idiom.
2. Give the tab strip horizontal scrolling with overflow affordances; then adopt
   Orca's fixed tab widths, which are a genuine improvement once nothing clips.
3. Decide the inset-tile question with the user in front of the running app —
   it is the one open judgement call here, and it is cheap either way.
