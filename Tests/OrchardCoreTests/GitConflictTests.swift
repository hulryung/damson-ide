import XCTest
@testable import OrchardCore

/// Marker parsing and resolution are pure text transforms, so they are tested without a
/// repo — the cases that matter (diff3, several hunks, a half-edited file) are awkward to
/// produce with real merges and trivial to write down.
final class GitConflictDocumentTests: XCTestCase {
    private let twoWay = """
    header
    <<<<<<< HEAD
    ours one
    ours two
    =======
    theirs one
    >>>>>>> feature
    footer

    """

    func testParsesOneHunkWithLabelsAndRange() {
        let doc = GitConflictDocument.parse(twoWay)
        XCTAssertEqual(doc.hunkCount, 1)
        let hunk = try! XCTUnwrap(doc.hunks.first)
        XCTAssertEqual(hunk.oursLabel, "HEAD")
        XCTAssertEqual(hunk.theirsLabel, "feature")
        XCTAssertNil(hunk.baseLabel)
        XCTAssertNil(hunk.base)
        XCTAssertEqual(hunk.ours, ["ours one", "ours two"])
        XCTAssertEqual(hunk.theirs, ["theirs one"])
        XCTAssertEqual(hunk.range, 1..<7)
        XCTAssertEqual(hunk.startLine, 2)
        XCTAssertTrue(doc.hasTrailingNewline)
    }

    func testResolvesEachSideAndPreservesSurroundingText() {
        let doc = GitConflictDocument.parse(twoWay)
        XCTAssertEqual(doc.resolvedText(choices: [0: .ours]),
                       "header\nours one\nours two\nfooter\n")
        XCTAssertEqual(doc.resolvedText(choices: [0: .theirs]),
                       "header\ntheirs one\nfooter\n")
        XCTAssertEqual(doc.resolvedText(choices: [0: .both]),
                       "header\nours one\nours two\ntheirs one\nfooter\n")
    }

    /// The whole point of a per-hunk choice: deciding one hunk must not touch the others.
    func testUndecidedHunksKeepTheirMarkersVerbatim() {
        let text = """
        a
        <<<<<<< HEAD
        one-ours
        =======
        one-theirs
        >>>>>>> other
        b
        <<<<<<< HEAD
        two-ours
        =======
        two-theirs
        >>>>>>> other
        c

        """
        let doc = GitConflictDocument.parse(text)
        XCTAssertEqual(doc.hunkCount, 2)

        let partial = doc.resolvedText(choices: [0: .theirs])
        XCTAssertEqual(partial, """
        a
        one-theirs
        b
        <<<<<<< HEAD
        two-ours
        =======
        two-theirs
        >>>>>>> other
        c

        """)
        XCTAssertEqual(doc.unresolvedHunks(choices: [0: .theirs]).map(\.index), [1])
        XCTAssertFalse(doc.isFullyResolved(choices: [0: .theirs]))
        XCTAssertTrue(doc.isFullyResolved(choices: [0: .theirs, 1: .ours]))
        XCTAssertTrue(GitConflictDocument.containsMarkers(partial))
        XCTAssertFalse(GitConflictDocument.containsMarkers(
            doc.resolvedText(choices: [0: .theirs, 1: .ours])))
    }

    func testDiff3StyleCarriesBaseSection() {
        let text = """
        <<<<<<< HEAD
        ours
        ||||||| merged common ancestors
        base
        =======
        theirs
        >>>>>>> topic

        """
        let hunk = try! XCTUnwrap(GitConflictDocument.parse(text).hunks.first)
        XCTAssertEqual(hunk.base, ["base"])
        XCTAssertEqual(hunk.baseLabel, "merged common ancestors")
        XCTAssertEqual(hunk.ours, ["ours"])
        XCTAssertEqual(hunk.theirs, ["theirs"])
    }

    /// A file the user half-edited has no closing marker. Rewriting a region whose end we
    /// never found would eat the rest of the file, so it is reported as no hunk at all.
    func testUnterminatedRegionIsNotAHunkAndTextIsUntouched() {
        let text = "a\n<<<<<<< HEAD\nours\n=======\ntheirs\n"
        let doc = GitConflictDocument.parse(text)
        XCTAssertEqual(doc.hunkCount, 0)
        XCTAssertFalse(doc.hasConflictMarkers)
        XCTAssertEqual(doc.resolvedText(choices: [0: .ours]), text)
        // Still recognisably conflicted, so staging stays refused.
        XCTAssertTrue(GitConflictDocument.containsMarkers(text))
    }

    func testFileWithoutTrailingNewlineStaysThatWay() {
        let doc = GitConflictDocument.parse("<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> t")
        XCTAssertFalse(doc.hasTrailingNewline)
        XCTAssertEqual(doc.resolvedText(choices: [0: .ours]), "ours")
    }

    func testEmptySideResolvesToDeletion() {
        let text = "keep\n<<<<<<< HEAD\n=======\nadded\n>>>>>>> t\ntail\n"
        let doc = GitConflictDocument.parse(text)
        XCTAssertEqual(doc.hunks.first?.ours, [])
        XCTAssertEqual(doc.resolvedText(choices: [0: .ours]), "keep\ntail\n")
    }
}

/// Porcelain decoding, including the rename-record trap: an `R` entry carries a second
/// NUL-terminated field, and missing it shifts every later record.
final class GitConflictPorcelainTests: XCTestCase {
    func testDecodesOnlyUnmergedEntries() {
        let out = "UU src/a.swift\0 M other.txt\0?? new.txt\0AA both.txt\0"
        let files = GitConflictService.parsePorcelain(out)
        XCTAssertEqual(files.map(\.path), ["both.txt", "src/a.swift"])
        XCTAssertEqual(files.map(\.kind), [.bothAdded, .bothModified])
    }

    func testRenameOriginFieldDoesNotShiftLaterRecords() {
        let out = "R  new name.txt\0old name.txt\0UD gone.txt\0DU mine.txt\0"
        let files = GitConflictService.parsePorcelain(out)
        XCTAssertEqual(files.map(\.path), ["gone.txt", "mine.txt"])
        XCTAssertEqual(files.map(\.kind), [.deletedByThem, .deletedByUs])
    }

    func testPathsWithSpacesSurvive() {
        let files = GitConflictService.parsePorcelain("UU a folder/with space.txt\0")
        XCTAssertEqual(files.first?.path, "a folder/with space.txt")
        XCTAssertEqual(files.first?.fileName, "with space.txt")
        XCTAssertEqual(files.first?.directory, "a folder")
    }

    /// Which panes a kind can even fill, and what "keep ours" means when ours is a delete.
    func testKindStagesAndActionWording() {
        XCTAssertEqual(GitConflictKind.bothModified.stages, [.base, .ours, .theirs])
        XCTAssertEqual(GitConflictKind.bothAdded.stages, [.ours, .theirs])
        XCTAssertFalse(GitConflictKind.bothAdded.has(.base))
        XCTAssertTrue(GitConflictKind.bothModified.hasInlineMarkers)
        XCTAssertFalse(GitConflictKind.deletedByThem.hasInlineMarkers)
        XCTAssertEqual(GitConflictKind.deletedByThem.actionLabel(for: .ours), "Keep ours")
        XCTAssertEqual(GitConflictKind.deletedByThem.actionLabel(for: .theirs),
                       "Keep theirs (delete file)")
    }

    /// A rebase replays your commits onto the upstream, so ours/theirs swap meaning.
    func testRebaseRelabelsSides() {
        XCTAssertEqual(GitConflictOperation.merge.oursLabel, "Ours (current)")
        XCTAssertEqual(GitConflictOperation.rebase.oursLabel, "Ours (upstream)")
        XCTAssertEqual(GitConflictOperation.rebase.theirsLabel, "Theirs (replayed commit)")
    }

    func testSummaryHeadlineAndNextStep() {
        let stuck = GitConflictSummary(operation: .merge,
                                       files: [GitConflictedFile(path: "a", kind: .bothModified)])
        XCTAssertEqual(stuck.headline, "Merge in progress — 1 conflicted file")
        XCTAssertNil(stuck.nextStepHint)
        XCTAssertTrue(stuck.isActive)

        let cleared = GitConflictSummary(operation: .rebase, files: [])
        XCTAssertEqual(cleared.headline, "Rebase in progress — all conflicts resolved")
        XCTAssertEqual(cleared.nextStepHint,
                       "Run `git rebase --continue` in a terminal to finish.")
        XCTAssertTrue(cleared.isActive)

        XCTAssertFalse(GitConflictSummary.none.isActive)
        XCTAssertEqual(GitConflictSummary.none.headline, "No conflicts")
    }
}

/// Shared scaffolding for the git-backed cases: a scratch repo per test, and the handful
/// of helpers that build conflicts in it. Byte-level helpers are here too, because the
/// lesson of dogfood-6 is that a fixture written with `encoding: .utf8` cannot catch a bug
/// about bytes that are not UTF-8.
class GitConflictRepoCase: XCTestCase {
    var tmp: URL!
    let service = GitConflictService()

    override func setUpWithError() throws {
        try XCTSkipIf(!FileManager.default.isExecutableFile(atPath: "/usr/bin/git"), "git unavailable")
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orchard-conflict-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    @discardableResult
    func git(_ args: [String], cwd: URL) throws -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = args
        proc.currentDirectoryURL = cwd
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_EDITOR"] = "true"
        proc.environment = env
        try proc.run()
        proc.waitUntilExit()
        return proc.terminationStatus
    }

    func write(_ text: String, to name: String, in repo: URL) throws {
        let url = repo.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func read(_ name: String, in repo: URL) -> String? {
        try? String(contentsOf: repo.appendingPathComponent(name), encoding: .utf8)
    }

    /// Byte-exact counterparts. Every fixture that matters below is written and compared
    /// through these: `String` cannot represent the content under test.
    func writeBytes(_ data: Data, to name: String, in repo: URL) throws {
        let url = repo.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url)
    }

    func readBytes(_ name: String, in repo: URL) -> Data? {
        try? Data(contentsOf: repo.appendingPathComponent(name))
    }

    /// The object id git has for a path at a ref (`feature:blob.bin`) or an index stage
    /// (`:0:blob.bin`) — the only check that proves a *staged* copy is byte-identical.
    func objectID(_ spec: String, in repo: URL) -> String? {
        GitRunner.shared.line(in: repo, ["rev-parse", spec])
    }

    func fileMode(_ name: String, in repo: URL) -> Int? {
        let attrs = try? FileManager.default.attributesOfItem(
            atPath: repo.appendingPathComponent(name).path)
        return (attrs?[.posixPermissions] as? NSNumber)?.intValue
    }

    /// A repo on `main` with `file.txt`, plus a `feature` branch that changed the same
    /// middle line differently. Merging feature into main conflicts on exactly one hunk.
    func makeConflictedRepo(name: String = "repo",
                            file: String = "file.txt") throws -> URL {
        let repo = tmp.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        XCTAssertEqual(try git(["init", "-q", "-b", "main"], cwd: repo), 0)
        try git(["config", "user.email", "test@orchard.app"], cwd: repo)
        try git(["config", "user.name", "Test"], cwd: repo)
        try write("top\nmiddle\nbottom\n", to: file, in: repo)
        try git(["add", "."], cwd: repo)
        try git(["commit", "-q", "-m", "init"], cwd: repo)

        try git(["checkout", "-q", "-b", "feature"], cwd: repo)
        try write("top\nfeature line\nbottom\n", to: file, in: repo)
        try git(["commit", "-qam", "feature edit"], cwd: repo)

        try git(["checkout", "-q", "main"], cwd: repo)
        try write("top\nmain line\nbottom\n", to: file, in: repo)
        try git(["commit", "-qam", "main edit"], cwd: repo)

        // Expected to fail — that failure is the fixture.
        XCTAssertNotEqual(try git(["merge", "feature"], cwd: repo), 0)
        return repo
    }

    func porcelain(_ repo: URL) -> String {
        GitRunner.shared.query(in: repo, ["status", "--porcelain"]) ?? ""
    }

    /// An empty repo with identity configured, ready for a fixture to diverge.
    func makeRepo(_ name: String) throws -> URL {
        let repo = tmp.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        XCTAssertEqual(try git(["init", "-q", "-b", "main"], cwd: repo), 0)
        try git(["config", "user.email", "test@orchard.app"], cwd: repo)
        try git(["config", "user.name", "Test"], cwd: repo)
        return repo
    }
}

/// The git half, against real conflicted repos the test creates. Detection and staging are
/// entirely about git's actual behaviour, so a mocked runner would prove nothing.
final class GitConflictServiceTests: GitConflictRepoCase {
    // MARK: -

    func testDetectsMergeAndListsUnmergedFile() throws {
        let repo = try makeConflictedRepo()
        let summary = service.summary(worktree: repo)

        XCTAssertEqual(summary.operation, .merge)
        XCTAssertEqual(summary.files.map(\.path), ["file.txt"])
        XCTAssertEqual(summary.files.first?.kind, .bothModified)
        XCTAssertTrue(summary.isActive)
        XCTAssertEqual(summary.headline, "Merge in progress — 1 conflicted file")
    }

    func testStageContentsGiveBaseOursTheirs() throws {
        let repo = try makeConflictedRepo()
        XCTAssertEqual(service.stageContents(worktree: repo, path: "file.txt", stage: .base),
                       "top\nmiddle\nbottom\n")
        XCTAssertEqual(service.stageContents(worktree: repo, path: "file.txt", stage: .ours),
                       "top\nmain line\nbottom\n")
        XCTAssertEqual(service.stageContents(worktree: repo, path: "file.txt", stage: .theirs),
                       "top\nfeature line\nbottom\n")
    }

    func testWorkingFileParsesIntoOneHunk() throws {
        let repo = try makeConflictedRepo()
        let doc = try XCTUnwrap(service.document(worktree: repo, path: "file.txt"))
        XCTAssertEqual(doc.hunkCount, 1)
        XCTAssertEqual(doc.hunks.first?.ours, ["main line"])
        XCTAssertEqual(doc.hunks.first?.theirs, ["feature line"])
    }

    /// The headline behaviour: a fully-decided file is written *and* staged, and git stops
    /// calling it unmerged.
    func testResolvingEveryHunkWritesAndStagesTheFile() throws {
        let repo = try makeConflictedRepo()
        let result = try service.resolve(worktree: repo, path: "file.txt", choices: [0: .theirs])

        XCTAssertEqual(result.remainingHunks, 0)
        XCTAssertTrue(result.staged)
        XCTAssertEqual(read("file.txt", in: repo), "top\nfeature line\nbottom\n")
        XCTAssertTrue(service.conflictedFiles(worktree: repo).isEmpty)
        XCTAssertTrue(porcelain(repo).hasPrefix("M "), "expected a staged modification, got: \(porcelain(repo))")
        // The merge itself is still in progress — this tab resolves files, it does not commit.
        XCTAssertEqual(service.operation(worktree: repo), .merge)
        XCTAssertEqual(service.summary(worktree: repo).nextStepHint,
                       "Run `git commit` in a terminal to finish the merge.")
    }

    /// A partial pass saves progress but must not tell git the conflict is over.
    func testPartialResolutionWritesWithoutStaging() throws {
        let repo = tmp.appendingPathComponent("multi")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"], cwd: repo)
        try git(["config", "user.email", "t@o.app"], cwd: repo)
        try git(["config", "user.name", "T"], cwd: repo)
        // Six untouched lines between the two edits: git coalesces conflicts that sit
        // closer together than that into a single region, which would make this a
        // one-hunk fixture and quietly stop testing partial resolution.
        try write("a\nx\nb\nc\nd\ne\nf\ng\ny\nz\n", to: "f.txt", in: repo)
        try git(["add", "."], cwd: repo)
        try git(["commit", "-q", "-m", "init"], cwd: repo)
        try git(["checkout", "-q", "-b", "feature"], cwd: repo)
        try write("a\nX-them\nb\nc\nd\ne\nf\ng\nY-them\nz\n", to: "f.txt", in: repo)
        try git(["commit", "-qam", "them"], cwd: repo)
        try git(["checkout", "-q", "main"], cwd: repo)
        try write("a\nX-us\nb\nc\nd\ne\nf\ng\nY-us\nz\n", to: "f.txt", in: repo)
        try git(["commit", "-qam", "us"], cwd: repo)
        XCTAssertNotEqual(try git(["merge", "feature"], cwd: repo), 0)

        let doc = try XCTUnwrap(service.document(worktree: repo, path: "f.txt"))
        XCTAssertEqual(doc.hunkCount, 2)

        let partial = try service.resolve(worktree: repo, path: "f.txt", choices: [0: .ours])
        XCTAssertEqual(partial.remainingHunks, 1)
        XCTAssertFalse(partial.staged)
        XCTAssertTrue(read("f.txt", in: repo)?.contains("X-us") ?? false)
        XCTAssertTrue(read("f.txt", in: repo)?.contains("<<<<<<<") ?? false)
        XCTAssertEqual(service.conflictedFiles(worktree: repo).map(\.path), ["f.txt"])

        // Finishing the second hunk against the already-rewritten file stages it.
        let done = try service.resolve(worktree: repo, path: "f.txt", choices: [0: .theirs])
        XCTAssertEqual(done.remainingHunks, 0)
        XCTAssertTrue(done.staged)
        XCTAssertEqual(read("f.txt", in: repo), "a\nX-us\nb\nc\nd\ne\nf\ng\nY-them\nz\n")
        XCTAssertTrue(service.conflictedFiles(worktree: repo).isEmpty)
    }

    func testStagingRefusesWhileMarkersRemain() throws {
        let repo = try makeConflictedRepo()
        XCTAssertThrowsError(try service.stage(worktree: repo, path: "file.txt")) { error in
            XCTAssertTrue("\(error)".contains("conflict markers"), "got: \(error)")
        }
        XCTAssertEqual(service.conflictedFiles(worktree: repo).count, 1)

        // Hand-resolved in an editor, then staged explicitly.
        try write("top\nby hand\nbottom\n", to: "file.txt", in: repo)
        try service.stage(worktree: repo, path: "file.txt")
        XCTAssertTrue(service.conflictedFiles(worktree: repo).isEmpty)
    }

    func testTakeWholeSideStagesThatSide() throws {
        let repo = try makeConflictedRepo()
        try service.take(.ours, worktree: repo, path: "file.txt")
        XCTAssertEqual(read("file.txt", in: repo), "top\nmain line\nbottom\n")
        XCTAssertTrue(service.conflictedFiles(worktree: repo).isEmpty)
    }

    /// A delete/modify conflict has no hunks: choosing the deleting side must remove the
    /// file and stage the removal, not leave the other side's content on disk.
    func testDeleteModifyConflictResolvesToADeletion() throws {
        let repo = tmp.appendingPathComponent("del")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"], cwd: repo)
        try git(["config", "user.email", "t@o.app"], cwd: repo)
        try git(["config", "user.name", "T"], cwd: repo)
        try write("content\n", to: "doomed.txt", in: repo)
        try git(["add", "."], cwd: repo)
        try git(["commit", "-q", "-m", "init"], cwd: repo)
        try git(["checkout", "-q", "-b", "feature"], cwd: repo)
        try git(["rm", "-q", "doomed.txt"], cwd: repo)
        try git(["commit", "-qm", "drop it"], cwd: repo)
        try git(["checkout", "-q", "main"], cwd: repo)
        try write("content changed\n", to: "doomed.txt", in: repo)
        try git(["commit", "-qam", "keep and edit"], cwd: repo)
        XCTAssertNotEqual(try git(["merge", "feature"], cwd: repo), 0)

        let file = try XCTUnwrap(service.conflictedFiles(worktree: repo).first)
        XCTAssertEqual(file.kind, .deletedByThem)
        XCTAssertFalse(file.kind.hasInlineMarkers)
        XCTAssertNil(service.stageContents(worktree: repo, path: "doomed.txt", stage: .theirs))
        XCTAssertEqual(file.kind.actionLabel(for: .theirs), "Keep theirs (delete file)")

        try service.take(.theirs, worktree: repo, path: "doomed.txt")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: repo.appendingPathComponent("doomed.txt").path))
        XCTAssertTrue(service.conflictedFiles(worktree: repo).isEmpty)
    }

    func testDetectsRebaseRatherThanMerge() throws {
        let repo = try makeConflictedRepo(name: "rebase-repo")
        try git(["merge", "--abort"], cwd: repo)
        XCTAssertEqual(service.operation(worktree: repo), .none)

        XCTAssertNotEqual(try git(["rebase", "feature"], cwd: repo), 0)
        XCTAssertEqual(service.operation(worktree: repo), .rebase)
        XCTAssertEqual(service.summary(worktree: repo).operation.oursLabel, "Ours (upstream)")
        XCTAssertEqual(service.conflictedFiles(worktree: repo).map(\.path), ["file.txt"])
        try git(["rebase", "--abort"], cwd: repo)
    }

    /// A worktree has its own git dir under `.git/worktrees/<name>`, so detection has to
    /// resolve it per worktree instead of looking for `<path>/.git/MERGE_HEAD`.
    func testDetectsConflictInsideALinkedWorktree() throws {
        let repo = try makeConflictedRepo(name: "wt-origin")
        try git(["merge", "--abort"], cwd: repo)
        let wt = tmp.appendingPathComponent("linked")
        try git(["worktree", "add", "-q", "-b", "wt-branch", wt.path, "main"], cwd: repo)
        XCTAssertEqual(service.operation(worktree: wt), .none)

        XCTAssertNotEqual(try git(["merge", "feature"], cwd: wt), 0)
        XCTAssertEqual(service.operation(worktree: wt), .merge)
        XCTAssertEqual(service.conflictedFiles(worktree: wt).map(\.path), ["file.txt"])
        XCTAssertEqual(service.operation(worktree: repo), .none, "the origin repo is not mid-merge")
    }

    func testPathWithSpacesResolvesEndToEnd() throws {
        let repo = try makeConflictedRepo(name: "spacey", file: "a folder/with space.txt")
        let file = try XCTUnwrap(service.conflictedFiles(worktree: repo).first)
        XCTAssertEqual(file.path, "a folder/with space.txt")
        XCTAssertNotNil(service.stageContents(worktree: repo, path: file.path, stage: .base))

        try service.resolve(worktree: repo, path: file.path, choices: [0: .both])
        XCTAssertEqual(read(file.path, in: repo), "top\nmain line\nfeature line\nbottom\n")
        XCTAssertTrue(service.conflictedFiles(worktree: repo).isEmpty)
    }

    func testCleanRepoReportsNoConflicts() throws {
        let repo = try makeConflictedRepo(name: "clean")
        try git(["merge", "--abort"], cwd: repo)
        let summary = service.summary(worktree: repo)
        XCTAssertEqual(summary.operation, .none)
        XCTAssertTrue(summary.isEmpty)
        XCTAssertFalse(summary.isActive)
    }
}

/// The fixtures T68 did not have.
///
/// T68 shipped 25 passing tests and a data-loss bug, because every one of those fixtures
/// was written and read with `encoding: .utf8` — so nothing ever asked what happens to a
/// byte that is not UTF-8. dogfood-6 answered it live: `take(.theirs)` on a 768-byte blob
/// wrote 1792 bytes of U+FFFD and staged them, and `resolve()` rewrote a Latin-1 header
/// line nobody had touched. Every case below compares *bytes*.
final class GitConflictByteFidelityTests: GitConflictRepoCase {

    // MARK: Fixtures

    /// 768 bytes that no UTF-8 decoder can round-trip: a NUL, two bytes that are never
    /// legal UTF-8 (0xFF, 0xFE), a lone continuation byte (0x80), and a truncated two-byte
    /// sequence (0xC3 0x28). `salt` is the one byte the two sides disagree about.
    private func binaryPattern(_ salt: UInt8) -> Data {
        var data = Data()
        for _ in 0..<128 { data.append(contentsOf: [0x00, 0xFF, 0xFE, 0x80, 0xC3, 0x28] as [UInt8]) }
        data[100] = salt
        return data
    }

    /// `header caf<E9> latin1` — ordinary text in Latin-1, with the conflict eight lines
    /// below the byte that matters. Nothing in the review touches the header; the old code
    /// rewrote it anyway.
    private func latin1(middle: String) -> Data {
        var data = Data("header caf".utf8)
        data.append(0xE9)
        data.append(Data(" latin1\n".utf8))
        data.append(Data("alpha\nbeta\ngamma\ndelta\nepsilon\nzeta\neta\n\(middle)\ntail\n".utf8))
        return data
    }

    private func makeBinaryConflictRepo() throws -> URL {
        try makeConflictOverBytes(name: "bin", file: "blob.bin",
                                  base: binaryPattern(0x01),
                                  ours: binaryPattern(0x02),
                                  theirs: binaryPattern(0x03))
    }

    private func makeLatin1ConflictRepo() throws -> URL {
        try makeConflictOverBytes(name: "latin", file: "latin1.txt",
                                  base: latin1(middle: "middle"),
                                  ours: latin1(middle: "main line"),
                                  theirs: latin1(middle: "feature line"))
    }

    /// Three byte blobs, two branches, one failed merge.
    private func makeConflictOverBytes(name: String, file: String,
                                       base: Data, ours: Data, theirs: Data) throws -> URL {
        let repo = try makeRepo(name)
        try writeBytes(base, to: file, in: repo)
        try git(["add", "."], cwd: repo)
        try git(["commit", "-q", "-m", "init"], cwd: repo)
        try git(["checkout", "-q", "-b", "feature"], cwd: repo)
        try writeBytes(theirs, to: file, in: repo)
        try git(["commit", "-qam", "feature edit"], cwd: repo)
        try git(["checkout", "-q", "main"], cwd: repo)
        try writeBytes(ours, to: file, in: repo)
        try git(["commit", "-qam", "main edit"], cwd: repo)
        XCTAssertNotEqual(try git(["merge", "feature"], cwd: repo), 0, "the failed merge is the fixture")
        return repo
    }

    /// The replacement-character sequence a lossy decode leaves behind.
    private func containsReplacementChar(_ data: Data) -> Bool {
        data.range(of: Data([0xEF, 0xBF, 0xBD])) != nil
    }

    // MARK: Binary

    func testBinaryConflictHasNoHunksAndSaysWhy() throws {
        let repo = try makeBinaryConflictRepo()
        XCTAssertEqual(service.conflictedFiles(worktree: repo).map(\.kind), [.bothModified])

        XCTAssertNil(service.document(worktree: repo, path: "blob.bin"))
        XCTAssertThrowsError(try service.readDocument(worktree: repo, path: "blob.bin")) { error in
            XCTAssertEqual(error as? GitConflictError, .notUTF8("blob.bin"))
            XCTAssertEqual((error as? GitConflictError)?.code, "not_utf8")
        }

        // Stage reads: exact bytes for the writer, a typed "not text" for the reader, and
        // never a lossy string.
        XCTAssertEqual(service.stageContentsData(worktree: repo, path: "blob.bin", stage: .theirs),
                       binaryPattern(0x03))
        XCTAssertEqual(service.stageContentsData(worktree: repo, path: "blob.bin", stage: .ours),
                       binaryPattern(0x02))
        XCTAssertEqual(service.stageContentsData(worktree: repo, path: "blob.bin", stage: .base),
                       binaryPattern(0x01))
        XCTAssertNil(service.stageContents(worktree: repo, path: "blob.bin", stage: .theirs))
        XCTAssertEqual(service.stageContent(worktree: repo, path: "blob.bin", stage: .theirs),
                       .notText(byteCount: 768))
        XCTAssertEqual(service.stageContent(worktree: repo, path: "blob.bin", stage: .theirs)?
                        .placeholder,
                       "(not UTF-8 text — 768 bytes; nothing safe to show)")
    }

    /// dogfood-6's headline case: for a binary the Take buttons are the pane's only route,
    /// so the only route has to be byte-exact — 768 bytes in, 768 identical bytes out, and
    /// the *staged* copy is git's own theirs blob, not a re-encoding of it.
    func testTakeOnABinaryCopiesTheChosenStageByteForByte() throws {
        let repo = try makeBinaryConflictRepo()
        try service.take(.theirs, worktree: repo, path: "blob.bin")

        let onDisk = try XCTUnwrap(readBytes("blob.bin", in: repo))
        XCTAssertEqual(onDisk.count, 768, "the old code wrote 1792 bytes here")
        XCTAssertEqual(onDisk, binaryPattern(0x03))
        XCTAssertFalse(containsReplacementChar(onDisk), "U+FFFD means the bytes went through a String")

        XCTAssertEqual(objectID(":0:blob.bin", in: repo), objectID("feature:blob.bin", in: repo),
                       "the staged blob must be theirs, not a re-encoding of theirs")
        XCTAssertTrue(service.conflictedFiles(worktree: repo).isEmpty)
        XCTAssertTrue(porcelain(repo).hasPrefix("M "), "got: \(porcelain(repo))")
    }

    func testTakeOursOnABinaryIsAlsoExact() throws {
        let repo = try makeBinaryConflictRepo()
        try service.take(.ours, worktree: repo, path: "blob.bin")
        XCTAssertEqual(readBytes("blob.bin", in: repo), binaryPattern(0x02))
        XCTAssertEqual(objectID(":0:blob.bin", in: repo), objectID("main:blob.bin", in: repo))
    }

    /// Refusing is the fix: there is no honest per-hunk answer for bytes that cannot be
    /// lines, so nothing is written and the file stays unmerged.
    func testResolveRefusesOnABinaryAndWritesNothing() throws {
        let repo = try makeBinaryConflictRepo()
        let before = try XCTUnwrap(readBytes("blob.bin", in: repo))

        XCTAssertThrowsError(try service.resolve(worktree: repo, path: "blob.bin",
                                                 choices: [0: .theirs])) { error in
            XCTAssertEqual(error as? GitConflictError, .notUTF8("blob.bin"))
        }
        XCTAssertEqual(readBytes("blob.bin", in: repo), before, "a refusal must not write")
        XCTAssertEqual(service.conflictedFiles(worktree: repo).map(\.path), ["blob.bin"],
                       "and must not stage")
    }

    // MARK: Latin-1 — text, just not UTF-8

    /// The case that proves this is not only about binaries: a normal source file with one
    /// Latin-1 byte in a header line the reviewer never opens.
    func testLatin1FileIsRefusedAndItsUntouchedHeaderSurvives() throws {
        let repo = try makeLatin1ConflictRepo()
        let before = try XCTUnwrap(readBytes("latin1.txt", in: repo))
        XCTAssertTrue(before.contains(0xE9), "fixture must carry the Latin-1 byte")
        XCTAssertTrue(GitConflictDocument.containsMarkers(before),
                      "git wrote real markers into this one — it is text to git")

        XCTAssertNil(service.document(worktree: repo, path: "latin1.txt"))
        XCTAssertThrowsError(try service.readDocument(worktree: repo, path: "latin1.txt")) { error in
            XCTAssertEqual(error as? GitConflictError, .notUTF8("latin1.txt"))
        }
        XCTAssertThrowsError(try service.resolve(worktree: repo, path: "latin1.txt",
                                                 choices: [0: .theirs]))

        let after = try XCTUnwrap(readBytes("latin1.txt", in: repo))
        XCTAssertEqual(after, before, "the old code rewrote caf<E9> as caf<EF BF BD> here")
        XCTAssertFalse(containsReplacementChar(after))
        XCTAssertEqual(service.conflictedFiles(worktree: repo).map(\.path), ["latin1.txt"])
    }

    func testTakeOnALatin1FileKeepsEveryByteOfTheChosenSide() throws {
        let repo = try makeLatin1ConflictRepo()
        try service.take(.theirs, worktree: repo, path: "latin1.txt")

        let onDisk = try XCTUnwrap(readBytes("latin1.txt", in: repo))
        XCTAssertEqual(onDisk, latin1(middle: "feature line"))
        XCTAssertTrue(onDisk.contains(0xE9))
        XCTAssertFalse(containsReplacementChar(onDisk))
        XCTAssertEqual(objectID(":0:latin1.txt", in: repo), objectID("feature:latin1.txt", in: repo))
        XCTAssertTrue(service.conflictedFiles(worktree: repo).isEmpty)
    }

    /// The marker refusal has to work on bytes too, or the only way to ask "are there still
    /// markers in this Latin-1 file" is to corrupt it first.
    func testStagingALatin1FileRefusesOnMarkersThenAcceptsAHandResolution() throws {
        let repo = try makeLatin1ConflictRepo()
        XCTAssertThrowsError(try service.stage(worktree: repo, path: "latin1.txt")) { error in
            XCTAssertEqual(error as? GitConflictError, .markersRemain("latin1.txt"))
            XCTAssertTrue("\(error)".contains("conflict markers"), "got: \(error)")
        }
        XCTAssertEqual(service.conflictedFiles(worktree: repo).count, 1)

        // Resolved by hand in an editor that understands Latin-1, then staged from here.
        let byHand = latin1(middle: "by hand")
        try writeBytes(byHand, to: "latin1.txt", in: repo)
        try service.stage(worktree: repo, path: "latin1.txt")
        XCTAssertTrue(service.conflictedFiles(worktree: repo).isEmpty)
        XCTAssertEqual(readBytes("latin1.txt", in: repo), byHand)
        XCTAssertEqual(objectID(":0:latin1.txt", in: repo),
                       GitRunner.shared.line(in: repo, ["hash-object", "--", "latin1.txt"]),
                       "the staged blob is the bytes on disk")
    }

    func testMarkerScanOnRawBytes() {
        var latin = Data("caf".utf8); latin.append(0xE9)
        latin.append(Data("\n<<<<<<< HEAD\nx\n=======\ny\n>>>>>>> feature\n".utf8))
        XCTAssertTrue(GitConflictDocument.containsMarkers(latin))
        XCTAssertFalse(GitConflictDocument.containsMarkers(latin1(middle: "no markers here")))
        // A marker that is not at the start of a line is not a marker.
        XCTAssertFalse(GitConflictDocument.containsMarkers(Data("a <<<<<<< b\n".utf8)))
        XCTAssertFalse(GitConflictDocument.containsMarkers(Data()))
        // Unterminated regions still count, which is what keeps a half-edit unstageable.
        XCTAssertTrue(GitConflictDocument.containsMarkers(Data("x\n<<<<<<< HEAD".utf8)))
    }

    // MARK: UTF-8 that is merely awkward

    /// Valid UTF-8 *is* resolved — and the parts outside the hunk come back byte-identical,
    /// including a multi-byte emoji, a combining accent, and a CRLF line ending.
    func testResolvingValidUTF8IsByteExactOutsideTheHunk() throws {
        func file(_ middle: String) -> Data {
            Data("héllo ☕\r\nalpha\nbeta\ngamma\ndelta\nepsilon\nzeta\n\(middle)\ntail 🚀\n".utf8)
        }
        let repo = try makeConflictOverBytes(name: "utf8", file: "u.txt",
                                             base: file("middle"),
                                             ours: file("main line"),
                                             theirs: file("feature line"))
        let doc = try service.readDocument(worktree: repo, path: "u.txt")
        XCTAssertEqual(doc.hunkCount, 1)

        let result = try service.resolve(worktree: repo, path: "u.txt", choices: [0: .theirs])
        XCTAssertTrue(result.staged)
        XCTAssertEqual(readBytes("u.txt", in: repo), file("feature line"))
        XCTAssertEqual(objectID(":0:u.txt", in: repo), objectID("feature:u.txt", in: repo))
    }

    /// A file with NUL bytes that happens to be valid UTF-8 is still not something to pick
    /// hunks in — git's own heuristic, kept, and now typed instead of silent.
    func testNULBytesAreNotTextEvenWhenTheyDecode() {
        let withNUL = Data("ok\n".utf8) + Data([0x00]) + Data("more\n".utf8)
        XCTAssertNotNil(String(data: withNUL, encoding: .utf8), "these bytes do decode")
        XCTAssertNil(GitConflictService.text(of: withNUL), "but they are not text to review")
        XCTAssertNotNil(GitConflictService.text(of: Data("plain\n".utf8)))
    }

    // MARK: Mode

    /// A blob is content *plus* a mode. Taking theirs on a file they made executable has to
    /// bring the bit along, or the resolution stages a mode change nobody chose.
    func testTakeCarriesTheChosenStagesFileMode() throws {
        let repo = try makeRepo("modes")
        try write("#!/bin/sh\necho base\n", to: "run.sh", in: repo)
        try git(["add", "."], cwd: repo)
        try git(["commit", "-q", "-m", "init"], cwd: repo)
        try git(["checkout", "-q", "-b", "feature"], cwd: repo)
        try write("#!/bin/sh\necho theirs\n", to: "run.sh", in: repo)
        // chmod on disk, then a plain `add`: `commit -a` re-reads the working-tree mode, so
        // an `update-index --chmod` alone would be undone before it was ever committed.
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o755))],
                                              ofItemAtPath: repo.appendingPathComponent("run.sh").path)
        try git(["add", "run.sh"], cwd: repo)
        try git(["commit", "-qm", "theirs + exec bit"], cwd: repo)
        try git(["checkout", "-q", "main"], cwd: repo)
        try write("#!/bin/sh\necho ours\n", to: "run.sh", in: repo)
        try git(["commit", "-qam", "ours"], cwd: repo)
        XCTAssertNotEqual(try git(["merge", "feature"], cwd: repo), 0)

        XCTAssertEqual(service.indexMode(worktree: repo, path: "run.sh", stage: .ours), "100644")
        XCTAssertEqual(service.indexMode(worktree: repo, path: "run.sh", stage: .theirs), "100755")

        try service.take(.theirs, worktree: repo, path: "run.sh")
        XCTAssertEqual(read("run.sh", in: repo), "#!/bin/sh\necho theirs\n")
        XCTAssertEqual((fileMode("run.sh", in: repo) ?? 0) & 0o111, 0o111, "lost the executable bit")
        XCTAssertEqual(service.indexMode(worktree: repo, path: "run.sh", stage: .base), nil,
                       "resolved: no unmerged stages left")
        XCTAssertEqual(GitRunner.shared.query(in: repo, ["ls-files", "--stage", "--", "run.sh"])?
                        .prefix(6), "100755")
    }

    /// A symlink blob's content is its target path. Writing those bytes as a regular file
    /// would stage a type change; the resolution has to stay a symlink.
    func testTakeOnASymlinkConflictKeepsItASymlink() throws {
        let repo = try makeRepo("links")
        try write("anchor\n", to: "anchor.txt", in: repo)
        try git(["add", "."], cwd: repo)
        try git(["commit", "-q", "-m", "init"], cwd: repo)
        try git(["checkout", "-q", "-b", "feature"], cwd: repo)
        try FileManager.default.createSymbolicLink(
            atPath: repo.appendingPathComponent("link").path, withDestinationPath: "theirs-target")
        try git(["add", "link"], cwd: repo)
        try git(["commit", "-qm", "their link"], cwd: repo)
        try git(["checkout", "-q", "main"], cwd: repo)
        try FileManager.default.createSymbolicLink(
            atPath: repo.appendingPathComponent("link").path, withDestinationPath: "ours-target")
        try git(["add", "link"], cwd: repo)
        try git(["commit", "-qm", "our link"], cwd: repo)
        XCTAssertNotEqual(try git(["merge", "feature"], cwd: repo), 0)
        XCTAssertEqual(service.indexMode(worktree: repo, path: "link", stage: .theirs), "120000")

        try service.take(.theirs, worktree: repo, path: "link")
        let destination = try FileManager.default.destinationOfSymbolicLink(
            atPath: repo.appendingPathComponent("link").path)
        XCTAssertEqual(destination, "theirs-target")
        XCTAssertEqual(GitRunner.shared.query(in: repo, ["ls-files", "--stage", "--", "link"])?
                        .prefix(6), "120000")
        XCTAssertTrue(service.conflictedFiles(worktree: repo).isEmpty)
    }

    // MARK: Typed errors

    func testRefusalCodesAndText() {
        XCTAssertEqual(GitConflictError.notUTF8("a.bin").code, "not_utf8")
        XCTAssertEqual(GitConflictError.markersRemain("a.txt").code, "markers_remain")
        XCTAssertEqual(GitConflictError.unreadable("a.txt").code, "unreadable")
        XCTAssertEqual(GitConflictError.writeFailed("a.txt", "disk full").code, "write_failed")
        XCTAssertEqual(GitConflictError.writeFailed("a.txt", "disk full").displayText,
                       "write_failed — cannot write a.txt: disk full")
        XCTAssertTrue(GitConflictError.notUTF8("a.bin").message.contains("Take one whole side"),
                      "the refusal has to name the route that still works")
    }
}

/// `GitRunner`'s two stdout shapes. The `String` one stays exactly as it was — every
/// existing caller reads git's own prose through it — and the `Data` one exists for the
/// single job that prose cannot do: carrying file content back to disk.
final class GitRunnerDataTests: GitConflictRepoCase {
    func testRawStdoutIsByteExactWhereTheStringPathIsLossy() throws {
        let repo = try makeRepo("raw")
        var blob = Data("head ".utf8)
        blob.append(contentsOf: [0xFF, 0xFE, 0x80, 0x00] as [UInt8])
        blob.append(Data(" tail\n".utf8))
        try writeBytes(blob, to: "b.bin", in: repo)
        try git(["add", "."], cwd: repo)
        try git(["commit", "-q", "-m", "init"], cwd: repo)

        let raw = try XCTUnwrap(GitRunner.shared.queryData(in: repo, ["show", "HEAD:b.bin"]))
        XCTAssertEqual(raw, blob)

        // Unchanged, and unusable for content: the four odd bytes become replacement chars.
        let text = try XCTUnwrap(GitRunner.shared.query(in: repo, ["show", "HEAD:b.bin"]))
        XCTAssertNotEqual(Data(text.utf8), blob)
        XCTAssertGreaterThan(Data(text.utf8).count, blob.count)
        XCTAssertTrue(text.contains("\u{FFFD}"))
    }

    func testRunDataThrowsOnANonzeroExitAndCarriesStderr() throws {
        let repo = try makeRepo("raw-fail")
        XCTAssertThrowsError(try GitRunner.shared.runData(in: repo, ["show", "HEAD:nope"])) { error in
            XCTAssertTrue("\(error)".contains("failed"), "got: \(error)")
        }
        XCTAssertNil(GitRunner.shared.queryData(in: repo, ["show", "HEAD:nope"]))
    }

    func testCaptureDataAndCaptureAgreeOnStatusAndStderr() throws {
        let repo = try makeRepo("raw-status")
        let raw = try GitRunner.shared.captureData(["-C", repo.path, "status", "--porcelain"])
        let string = try GitRunner.shared.capture(["-C", repo.path, "status", "--porcelain"])
        XCTAssertEqual(raw.status, 0)
        XCTAssertEqual(raw.status, string.status)
        XCTAssertEqual(String(decoding: raw.stdout, as: UTF8.self), string.stdout)
        XCTAssertEqual(raw.stderr, string.stderr)
    }
}
