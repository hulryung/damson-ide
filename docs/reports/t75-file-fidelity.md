# T75 — file content fidelity outside the conflict path

Wave 21. Closes the follow-on the T72 audit recorded
(`docs/reports/t72-byte-exact-conflicts.md`): the decode-then-write defect T72 fixed for
conflict resolution was still live in the editor path, plus a truncation risk in
`WorktreeManager.ensureExcluded`.

Owns `OrchardRuntime/Files/**`, `OrchardCore/Worktrees/WorktreeManager.swift`, the editor
save path in `Sources/OrchardApp/Editor/**`, and their tests. `GitConflicts.swift`,
`GitRunner.swift`, `GitSourceControl.swift`, and Automations were not touched.

## What was wrong

**1. Open a Latin-1 file, save it, lose it.** `FileService.preview` decoded with
`String(decoding: data, as: UTF8.self)` — lossy, so every byte that is not valid UTF-8
became U+FFFD — and `FileService.write` wrote that same String back with `.utf8`. The
editor pane loads through `preview` and saves through `write`, so ⌘S on a Latin-1 file
replaced `caf<E9>` with `caf<EF BF BD>` for every undecodable byte in the file, including
lines nobody scrolled to. Three bytes written where one stood, across the whole file, with
no error and no prompt.

**2. ⌘S on a file the editor could not represent was a silent no-op.**
`EditorDocumentController.save()` began `guard let state else { return false }`. Binary,
over-budget, and missing files have no `state`, so the keystroke did nothing at all and
said nothing — indistinguishable from a save that worked.

**3. `ensureExcluded` truncated the file it meant to append to.** It read
`.git/info/exclude` with `String(contentsOf:encoding:.utf8)`, fell back to `""` on *any*
failure, and wrote that plus one line. An exclude file holding a single non-UTF-8 byte —
one accented character in a comment — was replaced by a one-line file, deleting every
other rule in it. An unreadable-but-replaceable file went the same way: an atomic write
needs the *directory* to be writable, not the file to be readable, so "read failed" fell
straight through to "overwrite".

**4. `ensureExcluded` also wrote where git does not read.** It resolved the target with
`rev-parse --git-dir`, which in a linked worktree is `.git/worktrees/<name>` — and git
reads `info/exclude` from the *common* directory. `AgentSupervisor` calls it on worktree
paths, so `.claude/settings.local.json` kept showing up in every agent's `git status`
while a rule for it sat in a file git never consults. Verified before and after; the
remote mirror in `RemoteHookConfig` already did this correctly with `--git-path`.

## The fix

**One definition of "text", and it is a round trip.** `FileService.text(of:)` decodes and
then re-encodes and demands the bytes match. Neither obvious decoder is sufficient alone:
`String(decoding:as:)` substitutes U+FFFD and reports success, while
`String(data:encoding:.utf8)` is strict about that but **eats a leading byte-order mark** —
a BOM'd UTF-8 file comes back three bytes shorter than it went in. Testing the round trip
tests the property callers actually need instead of a proxy for it. Git's NUL-in-the-head
heuristic still runs first.

**`preview` never hands out a String it cannot put back.** A file that fails that check
returns `content: ""` plus a typed `notTextReason` (`nul_bytes` / `not_utf8`), the same
shape binary files already used. U+FFFD cannot reach a caller as content any more.

**Reads and writes come in byte-exact pairs.** New `readData(root:relativePath:maxBytes:)`
and `write(root:relativePath:data:)` move bytes and decode nothing.
`write(root:relativePath:contents:)` keeps its signature and grows one refusal: the file
already on disk must itself be UTF-8 text within the editor's budget, because a String
that came from a decode may only replace bytes that decode. Typed:
`not_utf8`, `unreadable`, `file_too_large`, on top of the existing confinement errors.

**The editor refuses out loud.** `EditorDocument.SaveRefusal` (`not_utf8`, `not_text`,
`file_too_large`, `not_loaded`) carries a stable code and a sentence saying why; `save()`
checks the surface first and puts `code — message` in the pane's error banner. A new
`Surface.notUTF8(byteLength:)` separates "this is a PNG" from "this looks like text and
isn't", and the pane says so. A `truncated` preview now maps to `.tooLarge` rather than
becoming an editable buffer — saving a prefix writes it over the whole file.

**Dirty tracking is byte-level.** `State.isDirty` and `isOwnWrite` compared Strings, and
Swift compares Strings by *canonical equivalence*: a precomposed `é` and its decomposed
form are `==` while their UTF-8 differs. Normalizing a file's accents used to read as a
clean document and get dropped at save time. Both now go through
`EditorDocument.bytesEqual`, as does the controller's `diskChanged` check.

**`ensureExcluded` works in bytes and reports what it did.** It resolves the target with
`--git-path info/exclude`, follows a symlinked exclude file to its target, reads the
existing bytes, refuses (`.unreadable`) rather than writing when it cannot read them,
matches existing rules byte-for-byte (CR-tolerant, so a CRLF file is understood), appends a
missing final newline instead of joining two rules onto one line, and returns a typed
`ExcludeOutcome` — `appended`, `alreadyPresent`, `notARepo`, `invalidPattern`,
`unreadable`, `writeFailed`. Patterns carrying a line break are rejected: that check is
byte-level too, because `String.contains("\n")` is *false* for `"a\r\nb"` (CRLF is one
grapheme cluster) and such a pattern would otherwise smuggle two rules into the file.

## Tests

30 new tests (1143 → 1173). Every fixture in `FileFidelityTests` is deliberately not `.utf8` —
the T72 lesson is that a lossy decode round-trips perfectly when nothing lossy is in the
file, which is exactly why an all-`.utf8` fixture set proved nothing and the bug shipped.

- `Tests/OrchardRuntimeTests/FileFidelityTests.swift` (16) — fixtures written as raw
  `Data`: Latin-1 (`caf<E9> d<E9>j<E0> vu`), a PNG-ish binary with a NUL head, UTF-16LE
  with a BOM, CRLF with an unterminated final line, an empty file, and valid-but-tricky
  UTF-8 (BOM + emoji + lone CR). Preview refusal and reason per fixture; byte-exact
  `preview → write` and `readData → write(data:)` round trips asserted against the
  original bytes; text-write refusals proven to leave the file *unchanged byte for byte*;
  budget and confinement on the new byte paths; content search still matching ASCII inside
  a Latin-1 file (it is read-only and never writes).
- `Tests/OrchardRuntimeTests/EditorDocumentTests.swift` (+6) — `notUTF8` vs binary
  surfaces, truncated preview never becoming editable, a refusal for every non-text
  surface with its code, and the canonical-equivalence dirty-tracking trap
  (precomposed vs decomposed `é`, and a CRLF→LF rewrite staying dirty).
- `Tests/OrchardCoreTests/WorktreeManagerTests.swift` (+8) — append preserving prior
  rules, idempotence, a non-UTF-8 exclude file matched and appended to without losing a
  byte, a mode-000 file refused rather than overwritten, missing-final-newline, CRLF
  rules, invalid patterns, not-a-repo, and a linked worktree where the assertion is
  `git status` in the worktree actually ignoring the file.

`swift build` clean; `swift test` 1173 tests, 0 failures — with the caveat below,
which is pre-existing and unrelated to this diff.

### The intermittent failure, named — for T76

Six full-suite runs were made here. Five were clean. One (`run3` of a three-run stability
loop) failed a single test:

```
FileWatcherTests.testEventCallbackBudgetAvoidsUnusedPathMaterialization
```

Run **in isolation, 40 times**, it failed **3 times** (`swift test --filter
'FileWatcherTests/testEventCallbackBudgetAvoidsUnusedPathMaterialization'`, 37 pass / 3
fail). So it is not an isolation bug between suites and not a product race — it is the
test itself.

The mechanism is in the assertion: the test is a wall-clock microbenchmark that times two
in-process loops over local arrays (`legacyBytes` summing 10,000 UTF-8 lengths ×20, versus
a flag scan ×20) and asserts `XCTAssertLessThan(after, before)`. No filesystem, no
`FileWatcher`, no product code — nothing but two `ContinuousClock` deltas. Any scheduling
slice, thermal step, or competing core that lands in the second loop flips the comparison.
The margin it relies on is real (~14× on a quiet machine) but it is asserted as a strict
inequality with no slack and no repetition, so it is a coin that comes up tails a few
percent of the time.

An earlier run here — the first full run after a `swift build` — reported
`3 failures (1 unexpected)` with the assertion lines outside the captured tail, so those
could not be named; this one was captured.

Not fixed here, deliberately: T76 owns the flaky hunt and `FileWatcherTests.swift` is the
file its fix would land in, so editing it from this task would collide. Suggested shape
for whoever takes it: assert a ratio with headroom (`after < before / 4`) rather than a
bare `<`, take the best of N repetitions, or drop the timing assertion entirely and keep
only the two correctness assertions — the *behaviour* under test (not materializing paths
for flags nobody reads) is already pinned by `XCTAssertEqual(rootChanges, 0)`.

## Handed on, not fixed here

- **`GitConflicts.text(of:)` strips a UTF-8 BOM.** T72 replaced the lossy decode with
  `String(data:encoding:.utf8)`, which is strict about invalid bytes but silently drops a
  leading BOM (measured: 5 bytes in, 2 bytes out for `"\u{FEFF}hi"`). `resolve()` writes
  that string back, so resolving a conflict in a BOM'd UTF-8 file loses three bytes at the
  top. Same class of defect, smaller blast radius; `GitConflicts.swift` is out of this
  task's scope. The fix is the round-trip check now in `FileService.text(of:)`.
- **`FileService.contentSearch` still decodes leniently**, deliberately. Search never
  writes, so the cost of a lossy decode there is a mojibake excerpt rather than a rewritten
  file, and refusing Latin-1 files outright would hide ASCII matches that are really in
  them. Marked in the source as display-only, with a test pinning the behavior.
- **`RemoteHookConfig.ensureExcluded`** (out of scope, `OrchardRuntime/Hosts/`) already
  appends with `grep -qxF … || printf … >>` against `--git-path info/exclude`, so it has
  neither defect. It is now the local implementation's model rather than its divergent
  twin.
