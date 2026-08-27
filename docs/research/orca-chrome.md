# How Orca builds its left sidebar and its tab strip

Read from `~/dev/orca` (read-only reference) on 2026-08-27. Orca is an
Electron/React app; the numbers below are Tailwind utilities and CSS custom
properties resolved to pixels. Every claim cites the file it came from so a
later reader can re-check it rather than trust this summary.

Tailwind → px, for the classes quoted below: `0.5`=2, `1`=4, `1.25`=5,
`1.5`=6, `2`=8, `2.5`=10, `4`=16, `5`=20, `6`=24, `7`=28, `8`=32.
`rounded-sm`=2, `rounded`=4, `rounded-md`=6, `rounded-lg`=8.

---

## 1. The one rule that explains most of it

**Selection and activation are neutral. Colour is never spent on "this row is
picked".**

Orca's selected workspace card, its active tab, and its group-by segmented
control all use the same primitive: a low-alpha wash of the *foreground*
colour, plus a brighter neutral *edge* that does the actual signalling.

| surface | fill | edge |
|---|---|---|
| selected card, dark (`main.css:1222`) | `color-mix(foreground 10%, transparent)` | `color-mix(foreground 18%, border)` 1px, all round |
| selected card, light (`main.css:1216`) | `color-mix(foreground 8%, transparent)` | `color-mix(border 40%, transparent)` |
| active tab (`drop-indicator.ts:33`) | `color-mix(foreground 6%, card)` | 2px bottom bar at `color-mix(foreground 60%, card)` |
| group-by toggle (`SidebarGroupByToggle.tsx:31`) | `bg-foreground/10` | — (adds `font-semibold`) |

The accent colour appears in the sidebar for exactly two things: a drag-insertion
bar (`drop-indicator.ts:7` — and even there Orca overrides the theme accent with
a hard-coded `blue-500` because "the theme's accent color is too subtle for a
drag-and-drop insertion cue"), and status-carrying glyphs. Never for selection.

The second rule, almost as load-bearing: **hover changes fill only.** No border
appears, no radius changes, nothing lifts. `worktree-sidebar-card-hover:hover`
(`main.css:1205`) sets `background` and nothing else. Tabs go further — hover
changes *text colour only*, no fill at all (`drop-indicator.ts:36`).

Third rule: **the list has no dividers.** Between cards, between a header and
its cards, between groups — nothing. The only 1px lines in the left column are
the sidebar's own right edge (`main.css:161`) and the borders that separate one
tab cell from the next. Vertical rhythm is carried by padding, not rules.

---

## 2. Left sidebar

### Panel

`main.css:159` — `background: var(--sidebar)`, `border-right: 1px solid
var(--sidebar-border)`. Dark `--sidebar` is `#171717` on a `#0a0a0a` canvas;
the workspace list inside it sits on `--worktree-sidebar` `#2a2a2a`. Orca
*lifts* the sidebar above the canvas rather than sinking it, which is the
opposite of the macOS convention. `--sidebar-border` is `rgb(255 255 255 /
0.07)` — deliberately matched to `--border` so "the left sidebar's divider
lines aren't brighter than the rest of the UI in dark mode".

### Header row (`SidebarHeader.tsx:24`)

`h-8` (32) · `px-2` · `gap-2` · `mt-2`. Title is `text-xs font-semibold
text-muted-foreground/80` — 12px semibold, muted, no uppercase, no tracking.
Trailing icon buttons are `size-3.5` (14) glyphs.

### Group-by control (`SidebarGroupByToggle.tsx:22`)

A `ToggleGroup variant="outline" size="sm"`, `h-6` (24) full width, items
`h-6 grow basis-0 px-1 text-[10px]`. Selected item: `bg-foreground/10
font-semibold text-foreground`. It is an outlined strip of flat cells, not a
capsule with a floating knob.

### Group / section headers (`worktree-list/rows/SectionHeader.tsx:216`)

```
h-7  pr-2  gap-1.5   paddingLeft: 10 (+10 per nesting level)
```

- **28px tall.** No background of its own, no border, no rule beneath it.
  Background appears only when the header is pinned by sticky scrolling, and
  then it is just `bg-worktree-sidebar` so rows don't show through.
- Icon: a `size-4` (16) box containing a `size-3`–`size-3.5` (12–14) glyph,
  `rounded-[4px]` when it is a repo icon.
- **Label: `text-[13px] font-semibold leading-none`.** This is the single
  biggest typographic surprise. Orca's group headers are the *same size as the
  card titles below them* and sit at full foreground — they are titles, not
  captions. There is no 11px uppercase caption anywhere in this sidebar.
- Right side: a collapse chevron in a `size-5` (20) `rounded-md` hover-tinted
  hit box, plus `…`/`+` actions, all revealed on row hover
  (`ProjectHeaderActions`).
- Spacing above a group: `pt-1` (4), dropped when the header is pinned.

### Host headers — the one boxed header (`HostSectionHeader.tsx:110`)

Wrapped in `px-2 pt-1`; the header itself is `h-8` (32) `rounded-md` (6) with
a real `border` and `bg-worktree-sidebar-accent/70`, `px-2 gap-2`. Label is
`text-[12px] font-semibold leading-none` — *smaller* than the group header
below it. The comment says why: "outlined card + server glyph marks hosts as
machines, not mere groups." This is the exception that proves the rule: a box
is reserved for a tier that is categorically different, not used for ordinary
grouping.

Its count badge: `h-4` (16) `rounded-full` bordered, `text-[9px] font-medium
leading-none`, inner `px-1.5 min-w-4`.

### Workspace cards (`worktree-card-surface.tsx:114`)

```
ml-1  pr-1.5  rounded-lg          title-only: py-2
                                  with meta:  pt-1.25 pb-1.5
border border-transparent         (resting; the border slot is always reserved)
```

- The card is **inset 4px from the sidebar's left edge** and rounded 8px, so it
  reads as a tile in a channel, not as a full-bleed row.
- Resting state carries a *transparent* 1px border, so selecting a card colours
  an existing border rather than adding one — no 1px layout shift.
- Selected adds the wash + edge from §1 and a `0 1px 2px foreground 3%` shadow.
- Multi-select is a separate, dimmer treatment (`ring-1` at 30–35% of
  `--worktree-sidebar-ring`), so "current" and "also selected" stay distinct.
- Cards are contiguous — no gap between them. Their own vertical padding is the
  whole rhythm.

### Card contents

- **Title**: `text-[13px] leading-5` (`worktree-card-header.tsx:178`). Weight
  carries unread; read titles are *dimmed* rather than unread being brightened.
- **Meta badges** (`primary`, `sparse`, `rename failed`): `h-[16px] px-1.5
  text-[10px] font-medium rounded leading-none` — 16px tall, **4px radius**,
  outlined with a 20%-alpha border over a 5–6%-alpha fill.
- **Repo identity chip**: `size-4` (16) square, `rounded-[4px]`, 1px border,
  containing a `size-3` glyph.
- **Nested agent rows** are quieter than the card that holds them:
  hover `color-mix(accent 18%, transparent)` vs the card's 40%; the focused
  agent pane gets `color-mix(accent 70%, transparent)` and is explicitly "a
  borderless fill" (`main.css:1250`).

### Indentation (`worktree-list/rows/indentation.ts`)

`SIDEBAR_TREE_INDENT = 18` per tree level. Group headers start at 10 and step
by 10 per nesting level — headers indent at a *smaller* step than the rows
under them, so deep nesting doesn't march the titles off the right edge.

---

## 3. Centre tab strip

### The strip (`tab-group/TabGroupPanel.tsx:212`)

```
h-[32px]  shrink-0  border-b border-border  bg-card
```

**32px, and that is the whole strip.** No horizontal padding, no vertical
padding, no gap between tabs. Tabs fill the strip edge to edge and top to
bottom. The strip container itself adds `border-r border-border/70` at its
trailing edge, with a comment explaining that a leading `border-l` was removed
because it "would render a heavier L-corner than the first tab's own
`border-l`" (`tab-bar-surface.tsx:159`).

### Tabs (`SortableTab.tsx:227`, `drop-indicator.ts`)

```
relative flex items-center h-full px-1.5 text-xs cursor-pointer select-none
border-t border-border                     (always)
border-r border-border                     (only when a tab follows)
w-[180px] min-w-[88px] min-[1280px]:w-[220px]
```

- **Zero radius.** There is no `rounded-*` anywhere on a tab root. Tabs are
  *cells in a strip*, separated by 1px hairlines — not chips floating on a bar.
  The top border bridges the strip's top edge; the right border is the divider;
  the last tab omits it so the strip's own `border-r` finishes the run.
- 6px horizontal padding, 12px text, full strip height.
- **Fixed width**, not content-derived: "the strip shrink-wraps its tabs, so a
  content-derived width lets one live title update resize every tab; a definite
  width pins them and flex-shrink still narrows to the floor"
  (`tab-width-rules.ts:1`).
- **Active**: `bg-[color-mix(foreground 6%, card)] text-foreground`, plus a
  **2px bar on the bottom edge**, `inset-x-0`, at `color-mix(foreground 60%,
  card)`, `z-10`. The comment calls it a bar "bridging the tab into the panel
  it owns", and notes the wash alone was not a crisp enough marker. Horizontal
  inset is exactly 0 — a negative inset on the last tab changed the strip's
  scrollWidth and jittered every tab by 1px.
- **Inactive**: `bg-card text-muted-foreground`; hover raises text to
  `text-foreground` and changes *nothing else*.
- Close button: `w-4 h-4` (16) `rounded-sm` (2), `text-transparent` until the
  tab is hovered, then `text-muted-foreground`, then a `hover:bg-muted` fill.
- Colour dot: `size-2` (8) `rounded-full`. Pin glyph: `size-3` (12).
- Unread activity is a full-tab `bg-amber-500/10` wash rendered as a real
  child, layered *under* the active indicator so an active unread tab still
  reads as selected.

### Around the strip (`tab-bar-surface.tsx`)

- Overflow arrows: `h-6 w-5` ghost buttons, `mx-0.5 my-auto`, `size-3.5`
  chevrons, `disabled:opacity-35`.
- The `+`: **outside** the strip, `ml-2 h-7 w-7` (28) `rounded-md` (6),
  `hover:bg-accent/50`, `size-3.5` glyph. It is the only rounded thing in the
  tab row, and it is a button, not a tab.

---

## 4. Density and type, condensed

| element | Orca |
|---|---|
| sidebar header row | 32 tall, 8 side pad, 12px semibold muted |
| group / section header | 28 tall, 10 left pad, **13px semibold** full-colour |
| host header (boxed) | 32 tall, 6 radius, 12px semibold |
| workspace card | 4 left inset, 8 radius, 5/6 or 8 vertical pad |
| card title | 13px, 20 leading |
| card badge | 16 tall, 4 radius, 10px medium, 6 side pad |
| count badge | 16 tall, pill, 9px medium |
| tree indent | 18 per level (headers: 10) |
| tab strip | 32 tall, no padding |
| tab | full height, **0 radius**, 6 side pad, 12px |
| tab close / dot | 16 box / 8 dot |
| new-tab button | 28 square, 6 radius |

Type scale in the whole left column and tab strip is just **9 / 10 / 12 / 13**.
There is no 11, and nothing above 13. Weight does the hierarchy work, not size.
