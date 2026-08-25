# Capture fidelity upstream of the cleaner (T54)

Status: **shipped** — wave 14. Orchard-side fix; no damson change, no pin bump.

Follows `docs/design/terminal-capture-fidelity.md` (T52), which proved the cleaner
faithful and localized the damage upstream. This document answers the question T52
left open: *where*, between the damson grid and the `worker-read` page, do a wide paste
lose its spaces and a repaint lose its letters — and fixes it.

Evidence: `Tests/OrchardTerminalsTests/Fixtures/claude-code-tui-capture-t50.txt`
(referenced below by line number). Repro: `Tests/OrchardTerminalsTests/
UpstreamCaptureFidelityTests.swift`. Unit contract: `TerminalCaptureCollectorTests`.

## 1. The pipeline, as it was

```
PTY bytes
  └─ DamsonSession.handlePTYData            (one chunk = one burst, all synchronous)
       ├─ outputBytes.send(chunk)
       ├─ VTParser.feed(chunk)
       │    ├─ printable bytes  → didEmitText   → grid.putChar(each)   + outputEvents(.text)
       │    ├─ C0 controls      → didExecute    → grid.lineFeed/CR/…   + outputEvents(.execute)
       │    ├─ CSI              → didEmitCSI    → handleCSI (cursor, erase, modes…) + outputEvents(.csi)
       │    └─ OSC              → didEmitOSC    → title/cwd/…          + outputEvents(.osc)
       └─ gridChanged.send()
DamsonTerminalSession.outputEvents        .text → .text, .execute → .control, .osc → .osc, .csi → nil
TerminalRecord.attach                     .text → buffer.appendText, .control → buffer.appendControl
TerminalStreamBuffer                      lines broken only by CR / LF
TerminalService.read(screen: false)       buffer.page(cursor:limit:)
WorkerVerbs (release)                     runtime.readTerminal(handle, nil, 2000) → rawLines / cleaner → lines
```

So the archive is the tail of the stream buffer, and the stream buffer is the parser's
text events with every CSI thrown away at the seam. The grid — the one structure that
actually holds the frame — is never consulted for the stream. That is the whole
finding; the rest of this section says why it produces exactly the T50 shapes.

## 2. Root cause

### 2.1 What was checked and ruled out

- **damson's parser dropping characters or spaces.** No. `VTParser.groundByte`
  accumulates every printable and UTF-8 continuation byte; `flushText` emits the longest
  valid UTF-8 prefix and holds the remainder for the next chunk; nothing filters spaces.
  `DamsonSession.vtParser(didEmitText:)` puts every character in the grid *and* sends
  the same string on `outputEvents`. The text events are a faithful record of the bytes
  the program sent.
- **A snapshot racing a repaint.** No. The archive is read from the stream buffer, not
  the grid, and the buffer is fed synchronously on the main thread inside
  `handlePTYData`. There is no timing component in the loss; the same bytes always
  produce the same archive.
- **Grid row → string trimming/joining.** Not on this path — `gridSnapshot()` only
  serves `--screen` and readiness. It did have its own, smaller infidelity (§4.3), fixed
  alongside.

### 2.2 The mechanism

Claude Code (v2.1.239 in the fixture) renders the way Ink and every cell-diffing TUI
renderer does: it keeps the last frame it drew, positions the cursor, and rewrites
**only the cells whose character changed**, inside a DECSET 2026 synchronized-output
frame. The text events for such a frame are therefore *cell writes*, not lines:

1. **Collapsed spacing** (fixture 1–15, 25–127: the whole preamble paste). On a screen
   that is blank where the new text has spaces, a space cell already holds a space, so
   it is stepped over with cursor motion and never sent as a character. `Tips for
   getting started` arrives as the events `Tips`, `for`, `getting`, `started` with
   CSI CUF/CHA between them; drop the CSIs and append the text and you have
   `Tipsforgettingstarted` (line 2).

2. **Torn repaints** (fixture 16, 19, 23, 140–430). When a row is painted over
   *different* text, every cell that differs is sent — including spaces, which now
   overwrite old ink — and every cell that happens to match is not. So the letters
   that go missing are exactly the ones that coincided with what was underneath:
   `paste again to expand` painted where two of its letters already stood becomes
   `paste gain to expad` (line 19); the status bar repainted over an older status bar
   keeps its spaces but loses `i`, `o` (line 16, `damson-de/dogfod-`); a spinner tick
   sends only the glyph and the digits that changed — `✢63`, `✳88`, `ought for 1s)`,
   `↓ 25 tokens ·tnking wihxhigheffort)` (lines 158–160, 165).

   The fixture carries the signature of this: the same row appears both spaced-with-
   letters-missing (line 16) and collapsed-but-complete (line 132). Its spelling in the
   archive depended on what was on the screen before it, which only a diff renderer
   explains.

3. **Row fragments joining** (fixture 23, 158). Cursor positioning does not break a
   stream line — only CR and LF do — so the fragments of one repaint, and sometimes of
   neighbouring rows, concatenate into a single archive line.

None of this is a damson defect. The parser emits what the program wrote; the program
wrote a diff. The faithful record of a paint is the frame, and damson keeps it — in the
grid, and in scrollback for rows that leave the screen.

## 3. Reproduction

`UpstreamCaptureFidelityTests` runs the real engine — `DamsonSession` (VT parser +
grid) on a process-free `SessionIOBackend` — behind the production seam
(`DamsonTerminalSession` → `TerminalService` → `TerminalRecord` → `read`), and drives
it with a `CellDiffRenderer` that does what §2.2 describes: CHA to each run of changed
cells, CRLF between rows, the frame wrapped in `?2026h … ?2026l`. Each test keeps a
second stream buffer fed the pre-T54 way (text events only) next to the fixed one:

| Painted | Pre-T54 stream (text events) | T54 stream (frame capture) |
|---|---|---|
| `│ Tips for getting started   │` on a clean screen | `│Tipsforgettingstarted│` | `│ Tips for getting started   │` |
| `paste again to expand` two columns left of where it was | `paste agin to expand` | `paste again to expand` |
| `✶ Improvising… (5s · ↓ 195 tokens · thought for 1s)` over the previous tick | `✶595` | the whole row |
| a frame cut across two PTY reads | (torn) | nothing until the frame closes, then whole rows |
| twelve rows through an eight-row screen in one frame | — | all twelve, from scrollback + screen |
| `$ swift test` … printed with SGR | unchanged | byte-identical to pre-T54 |

The unit suite (`TerminalCaptureCollectorTests`) pins the same contract on the scripted
session, plus scrolling alignment, blank-row structure, print-then-paint, alt screen,
sync frames, exit flush, and respawn.

## 4. The fix

### 4.1 The seam carries the classification

`TerminalOutputEvent` gains `.csi(TerminalControlSequence)`; `DamsonTerminalSession`
forwards every CSI instead of dropping it. `TerminalControlSequence.isPaint` is the one
question the capture layer asks: does this sequence place, erase, scroll, or switch what
is on the grid? Cursor motion, ED/EL/ECH, ICH/DCH/IL/DL, SU/SD, DECSTBM, SCOSC/SCORC,
and the alt-screen / synchronized-output private modes say *paint*. SGR, cursor
visibility and shape, bracketed paste, mouse/focus modes, and reports do not — a shell
colouring its output is still printing.

`TerminalGridSnapshot` gains `firstRowIndex` — the absolute line number of row 0
(damson's `scrollbackPushCount`, the identity its prompt marks already rely on) — and
`TerminalSession` gains `scrolledOffLines(fromAbsoluteRow:)`, reading damson's
scrollback as text. Both are defaulted, so every existing conformance compiles unchanged.

### 4.2 `TerminalCaptureCollector`

Per burst (`outputBytes` → events → `gridChanged`, the engine's own framing):

- **Print** (no paint CSI): the burst's text/control tokens are appended to the stream
  exactly as before — every pre-T54 read test passes untouched — and the grid is
  recorded as the new *baseline* without emitting anything.
- **Paint** (a paint CSI seen): the burst's text events are discarded — they are cell
  writes — and the frame is captured from the grid: every row whose text differs from
  the baseline at the same absolute row is appended, top to bottom, rows that scrolled
  off since the last capture first (from scrollback, so a frame larger than the screen
  is not truncated). Rows that merely scrolled up are not re-emitted; blank rows are
  never emitted alone, but one blank line keeps two emitted rows apart that had only
  blanks between them.
- **Synchronized output**: a paint that ends with `inSyncOutputMode` still set is held
  and captured when a later burst ends with the frame closed. This is what keeps a
  torn repaint out: a frame split across PTY reads is captured once, whole.
- **Exit / close / respawn**: `TerminalRecord.flushPendingCapture()` captures a frame
  that will never close; respawn resets baselines (a new grid counts from 0) and keeps
  the stream.
- The primary and alt screens keep separate baselines (damson resets the push count on
  alt entry and restores it on exit), so leaving a pager adds nothing to the stream.

The baseline-after-print rule is what makes the everyday shell right: `ls` prints,
zsh repaints its prompt with `\r\e[K` — only the prompt row is new to the stream.

### 4.3 Row → string

`DamsonTerminalSession.gridSnapshot()` mapped every cell's `char`, including the
continuation cell a wide glyph leaves after itself, so `--screen` showed `한 글` for
`한글` and a phantom space after every emoji. `rowText` now skips continuation and
wide-spacer cells. Frame capture and `--screen` share it.

### 4.4 What did not change

The stream buffer's paging and cursor contract; `--screen`; the cleaner and its
fixtures; the receipt wire (T55 owns the `respacedLines` addition); damson.

## 5. Consequences for readers

A `terminal_tail` archive of an agent TUI now holds rows as they were shown. A status
bar still contributes a row whenever its token count changes (those are the cleaner's
digit-masked `duplicateLines`). Spinner/progress ticks no longer stack one-per-frame:
T58 coalesces them in the stream ring so a thinking phase occupies one retained line,
updated in place. The cleaner's "never rewrite" rule stands; it simply has far less
to hide, and `spinnerLines` on a post-T58 capture counts the thinking *phases*, not
every 10 fps glyph.

`worker-read --raw` remains the untouched capture. It is now worth reading.

## 6. Follow-ups

- **Ring capacity under a fast spinner — done in T58.** Measurement, uncoalesced: a
  10 fps spinner row fills the 10_000-line ring in 1_000 s (~16.7 min) and fills a
  `terminal_tail` archive of the newest 2_000 lines (WorkerVerbs at release) in 200 s
  (~3.3 min), evicting the transcript behind it. A larger ring or a byte budget only
  delays that. Bound chosen: collector-aware retention *inside the buffer* (no
  collector change). `appendCapturedRow` overwrites the most recent spinner/progress
  tick at the tail (walking back through blanks only, window of 8) so a sustained
  spinner occupies one slot and cannot evict recent real output. Printed CR-stacked
  fragments still stack. Cursors do not shift — the replace is in place at the
  existing absolute index. Tests: `TerminalStreamBufferTests` (`testSustainedSpinnerDoesNotEvictRecentRealOutput`
  and neighbours).
- **A post-T54 live fixture.** The three pinned captures are pre-T54; the next dogfood
  cycle should pin a fourth so the cleaner is measured against the new shape and the
  archive-readability row in the dogfood report can be closed on evidence.
- **Full-clear TUIs.** A program that clears and repaints everything (alt-screen
  editors on resize) re-emits rows that moved; matching by row content across a move
  would trim that at the cost of another guess. Left as is: repeats are honest.
