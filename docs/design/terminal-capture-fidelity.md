# Terminal capture fidelity (the archive cleaner's contract)

Status: **shipped** — T35 (wave 8) built the chrome stripper; T38 (wave 9) taught it the
Swift-debug dump; **T52 (wave 13)** made it faithful and removed the passes that were
rewriting text.

Sources followed: `docs/reports/dogfood-1.md` finding 4, `docs/reports/dogfood-2.md`,
`docs/reports/dogfood-3.md` (archive readability row); the live archives in
`worker_terminal_archives`, now pinned as fixtures under
`Tests/OrchardTerminalsTests/Fixtures/`.

## 1. The rule

**Cleaning drops chrome. It never rewrites text.**

Every line `TerminalCaptureCleaner` emits is one captured line with its chrome taken
off — the same characters in the same order, with the same word boundaries. There is
exactly one text rewrite, and it is not a guess: if the capture contains another line
holding *exactly* the same characters but painted with more of its spaces, the
better-spaced paint is shown (`spacingIndex`, counted as `Report.respacedLines`).
Character equality is the proof: the spaces being restored are ones the terminal
really painted, on the same run of text, in the same session.

Anything weaker is banned, because anything weaker is a guess about where the missing
spaces went:

- splicing a well-spaced fragment of one line into the middle of another,
- splitting `camelCase` or letter/digit runs in a collapsed line,
- breaking before a `--flag`.

A guess that lands is unremarkable. A guess that misses is an archive that reads
smoothly and says the wrong thing — and the reader has no way to tell the two apart.
Dogfood cycle 3 found the misses in the Vault: `term_f 91112 a 8-b 4 ac-…` for a
terminal handle, `dogfood-t 50-20260825` for a worktree path, `Git Hub`,
`Claude Codev 2.1.239`, `its Task ID,Dispatch ID`.

The cost of the rule is that a capture which lost its spaces stays hard to read. That
is the honest outcome, and it is the one the plan asks for: prefer raw pass-through
over unfaithful cleaning.

## 2. What the cleaner is *not* responsible for

Dogfood-3 quoted `Tipsforgettingstarted`, `WelcomebackDaekeun!`,
`coorinatoronlythroughtheCLIcommandsbelow.Donotuse`, `paste gain to expad` and
`handleis` as damage the reader was showing. Reading the T50 archive's `rawLines` out
of the store settles where that damage comes from: **all of it is in the capture.**

```
raw  19| paste gain to expad
raw  21|   Your coordinator's terminalhandleis:cli
raw  23| You talk tohe coorinatoronlythroughtheCLIcommandsbelow.Donotuse
```

Two different upstream losses are stacked here:

1. **Collapsed spacing.** A full-screen TUI paints text into cells; a cell holding a
   space is often never emitted as a space character, so a wide paste reaches
   `TerminalStreamBuffer` already concatenated. Most of the T50 capture is like this.
2. **Torn paints.** A frame captured mid-repaint drops characters outright —
   "paste again to expand" arrives as `paste gain to expad`, "coordinator" as
   `coorinator`, "damson-ide" as `damson-de`. The *same session* also painted
   `pasteagaintoexpand` correctly a few frames later, which is why both spellings
   appear in the archive.

No cleaner can restore what the capture never carried. Fixing this belongs upstream —
in how a TUI frame is captured — not in a text pass that would have to invent the
missing letters. The cleaner's obligation is to not add to the damage, and to be
measured on it.

**T54 (wave 14) found and fixed the upstream loss** — see
`docs/design/capture-fidelity-upstream.md`. Both losses were one mechanism: the stream
was assembled from the parser's *text events* with every cursor-motion sequence
dropped, and a cell-diffing renderer's text events are cell writes, not lines. A paint
is now captured from the rendered frame. The three fixtures above are pre-T54 captures
and stay as they are: they are what the cleaner is measured against, and the cleaner's
contract is unchanged.

## 3. What the cleaner still does

Line-granularity drops, each counted in `Report` so the reader can see the size of what
was removed:

| Reason | What it drops |
|---|---|
| `separatorLines` | Lines that are only box rules or ASCII rules. |
| `spinnerLines` | Spinner-only frames, progress readouts (`Levitating… (11s · ↓ 490 tokens)`), lines with no letters, and torn fragments of ≤4 characters that still carry the spinner's frame counter (`tg5`). Real short output — `ok`, `PASS`, `done` — survives. |
| `duplicateLines` | A line already emitted inside a 40-line window; for chrome lines also a digit-masked or tail match, which is how a status bar whose only change is `$0.14` → `$0.17` stops being printed hundreds of times. |
| `blankLines` | Blank runs squeezed to one, leading and trailing blanks removed. |
| `debugDumpLines` | `OrchardProtocol.JSONValue` debug dumps (dogfood-2's `orchard send` without `--json`). |

Character-granularity edits are limited to chrome: escape sequences and orphaned
sequence bodies, C0 controls, NBSP → space, ZWSP removed, leading/trailing frame
borders trimmed, interior cell walls turned into spaces (never removed — removing them
would join the cells they separated). An escape that sat between two printable
fragments becomes a space for the same reason: the two fragments were painted
separately.

`worker-read --raw` still serves the untouched capture, and always should. The change
in T52 is that the cleaned face is evidence too.

## 4. How this is enforced

`Tests/OrchardTerminalsTests/TerminalCaptureFidelityTests.swift` runs the cleaner over
all three live captures (T34, T38, T50) and asserts, with its own definition of chrome
and its own tokenizer so it audits rather than echoes the implementation:

- **Every emitted line is one raw line without its chrome.** For each cleaned line
  there must be a captured line with the same characters *and* the same word
  boundaries. A join loses a boundary, a drop or an invented split changes the token
  list — one assertion covers both halves of "no word-joins and no character loss".
- **Substantive raw lines survive.** A captured line of three words and twenty-four
  letters that is not a repaint frame or a debug dump has to reach the reader.

`TerminalCaptureCleanerTests` keeps the per-pass unit tests and a headline test per
capture. Two cycle-2-era expectations were **corrected** in T52: the assertions that
`orchardsend` and `OrcharddogfoodT38completed` must disappear from the readable face.
Neither line has an equally-lettered paint anywhere in that capture — only lines that
contain them, or that they contain — so the only way to satisfy them was the splicing
pass that dogfood-3 caught mangling live archives. They are replaced by tests that the
lines pass through as captured.
