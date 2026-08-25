# T72 — conflict resolution is byte-exact (data-loss fix)

Fixes dogfood-6 finding 1 (`docs/reports/dogfood-6.md`, part 2.5) and tightens finding 13.
Wave 20. Owns `OrchardCore/Git/GitRunner.swift`, `OrchardCore/Git/GitConflicts.swift`,
`OrchardApp/Conflicts/ConflictReviewPane.swift` and their tests; nothing else was touched.

## What was wrong

`GitRunner.capture` decoded git's stdout with `String(decoding: outData, as: UTF8.self)`,
which is **lossy** — every byte that is not valid UTF-8 became U+FFFD. `GitConflictService`
read content through that string and wrote it back with `.utf8`, so both write paths
rewrote bytes nobody chose *and staged the result*:

- `take(.theirs)` on a 768-byte binary wrote 1792 bytes (`EF BF BD` per undecodable byte)
  and staged them. For a binary `document()` returns nil, so the pane offers no hunks and
  the Take buttons are the only route — the broken path was the only path.
- `resolve()` on a Latin-1 *text* file rewrote `caf<E9>` in a header line eight lines above
  the conflict, and staged that too.

T68's 25 tests all wrote and read their fixtures with `encoding: .utf8`, so none of them
could see it.

## The fix

**`GitRunner` grew a raw stdout path; the `String` API is unchanged.** `captureData`
launches the process and returns `DataOutput` (`stdout: Data`); `capture` is now a thin
UTF-8 decode over it, so every existing caller behaves exactly as before. New:
`runData(_:cwd:)`, `runData(in:_:)`, `queryData(in:_:)`.

**Whole-file take copies the chosen index stage byte for byte.** `stageContentsData` reads
`git show :N:path` as `Data`; `take` writes those bytes through a new `write(_ data:…)`
(atomic sibling + replace, as before). The staged blob id now equals git's own blob id for
that side — the test asserts `:0:path == feature:path`, which no re-encoding can fake.

**Per-hunk resolution refuses instead of corrupting.** Hunks need lines, and a non-UTF-8
file has no lossless line form. `readDocument` decodes *strictly* (`String(data:encoding:)`,
plus git's NUL heuristic) and throws a typed `GitConflictError.notUTF8`; `resolve` calls it
and therefore writes nothing. `document()` keeps its optional shape for callers that only
want "are there hunks".

**Typed errors** (`GitConflictError`, same `code`/`message`/`displayText` shape as
`GitSourceControlError`): `not_utf8`, `unreadable`, `markers_remain`, `write_failed`.

**The marker refusal is now a byte scan.** `GitConflictDocument.containsMarkers(_ data:)`
looks for `<<<<<<<` / `>>>>>>>` at line starts in raw bytes — markers are ASCII, so asking
the question no longer requires corrupting the file to ask it.

**A blob is content *plus* a mode.** `take` reads the chosen stage's mode from
`git ls-files --stage`, keeps the executable bit (an atomic replace creates a new file and
inherits nothing), and recreates a `120000` stage as a symlink rather than writing the
target path into a regular file. Only the exec bits are forced; the rest of the file's
permissions (or the umask's, for a new file) are left alone.

**Pane** (`ConflictReviewPane`): a non-UTF-8 file gets a standing notice above the panes —
"…take one whole side instead" — instead of an empty hunk list with no explanation. Stage
panes render `GitConflictStageContent`, so a binary side shows
`(not UTF-8 text — 768 bytes; nothing safe to show)` rather than U+FFFD soup, and a side
that does not exist keeps its own wording. Per dogfood-6 finding 13, the fall-through
button for such a file is now "Stage File As-Is" with truthful help ("…which is git's
'ours' copy until you take a side"), because the marker refusal it used to advertise can
never fire on a file with no markers.

## Tests

`Tests/OrchardCoreTests/GitConflictTests.swift`: the git-backed cases now share a
`GitConflictRepoCase` base (scratch repo, byte-level helpers), plus 16 new tests —
13 in `GitConflictByteFidelityTests`, 3 in `GitRunnerDataTests`. Every one compares bytes.

- **Binary** (768 bytes of `00 FF FE 80 C3 28`, the dogfood-6 fixture): no hunks + typed
  `not_utf8`; `take` ours/theirs is byte-identical and stages git's own blob; the file is
  still 768 bytes ("the old code wrote 1792 bytes here"); no `EF BF BD` anywhere;
  `resolve` throws and writes nothing.
- **Latin-1**: `resolve` refuses and the file is byte-for-byte unchanged; `take` keeps the
  `0xE9` header byte; staging refuses on markers via the byte scan, then accepts a
  hand-resolution whose staged blob equals `git hash-object` of the bytes on disk.
- **Valid UTF-8 stays resolvable**: emoji, a combining accent and a CRLF line ending
  survive a real `resolve` byte-for-byte.
- **Mode**: exec bit carried from the chosen stage (index ends at `100755`); symlink
  conflict resolves to a symlink at `120000`.
- **`GitRunner`**: `queryData` is byte-exact where `query` is lossy (asserted side by side),
  `runData` throws on a nonzero exit, and `captureData`/`capture` agree on status/stderr.

`swift build` clean; `swift test` 1122 tests, 0 failures, 2 skipped (was 1106).

Not verifiable here: the pane is SwiftUI and the app was neither launched nor quit, so the
notice, the placeholder and the relabelled button are unverified on screen — that belongs
to T74's visual pass.

## Audit — other places that write content read through a `String`

| Where | Verdict |
| --- | --- |
| `GitConflictService` (take/resolve/stage/write) | **Was the bug.** Fixed above. |
| `FileService.preview` → `FileService.write` (`OrchardRuntime/Files`), used by the editor (`EditorDocumentController.swift:39,61`) | **Same defect, different owner.** `preview` decodes with `String(decoding:as:UTF8.self)` and only calls a file binary when it holds a NUL, so a Latin-1 file opens as text with U+FFFD in it; `write` re-encodes `Data(contents.utf8)`. Opening such a file in the editor and saving corrupts every non-UTF-8 byte, whether or not the user edited that line. Outside T72's ownership — filed here for a follow-up (the shape of the fix is the same: strict decode, refuse or read-only). |
| `WorktreeManager.ensureExcluded` (`.git/info/exclude`) | **Adjacent risk.** The read is strict (`String(contentsOf:encoding:.utf8)`) but falls back to `""` on failure and then overwrites — a non-UTF-8 exclude file would be truncated to just the appended pattern. Not the git-stdout path; not owned by T72. |
| `GitService.diff` / `countLines` | Safe: lossy decode is display-only (a diff shown to a human); nothing is written back. |
| `GitSourceControl` / SourceControl panel | Safe: it stages, unstages and commits through git and never rewrites file content — no content round-trip exists there. |
| `HookInstaller`, `SetupRunner`, `OrchardTrampoline`, `BrowserService`, `OrchardDataStore`, `KeeperRestoration` | Safe: each writes content it generated itself, or JSON it round-trips as `Data` through `Codable`. |
| `LiveOrchestrationStore` receipt encoding | Safe: `String(decoding:)` over `JSONEncoder` output, which is always valid UTF-8. |

## Note for T73 (conflict verbs on the CLI)

No signature was removed, so `GitConflictService` still compiles for callers written
against the old shape. Worth adopting: `readDocument` (typed refusal instead of a bare
nil), `GitConflictError.code` for typed exits, `stageContent` to tell "binary side" from
"no such side", and `stageContentsData` for any `--output` that writes bytes.
`stageContents` (String) is now strict — it returns nil for a non-UTF-8 stage rather than
handing back U+FFFD.
