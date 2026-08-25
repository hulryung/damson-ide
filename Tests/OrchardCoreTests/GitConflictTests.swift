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

/// The git half, against real conflicted repos the test creates. Detection and staging are
/// entirely about git's actual behaviour, so a mocked runner would prove nothing.
final class GitConflictServiceTests: XCTestCase {
    private var tmp: URL!
    private let service = GitConflictService()

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
    private func git(_ args: [String], cwd: URL) throws -> Int32 {
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

    private func write(_ text: String, to name: String, in repo: URL) throws {
        let url = repo.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ name: String, in repo: URL) -> String? {
        try? String(contentsOf: repo.appendingPathComponent(name), encoding: .utf8)
    }

    /// A repo on `main` with `file.txt`, plus a `feature` branch that changed the same
    /// middle line differently. Merging feature into main conflicts on exactly one hunk.
    private func makeConflictedRepo(name: String = "repo",
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

    private func porcelain(_ repo: URL) -> String {
        GitRunner.shared.query(in: repo, ["status", "--porcelain"]) ?? ""
    }

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
