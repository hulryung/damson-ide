import XCTest
@testable import OrchardRuntime

/// Direct FileService coverage: lazy tree, preview budgets, binary/image
/// detection, path confinement, name-filtered listing, and bounded search.
final class FileServiceTests: XCTestCase {
    private var tmp: URL!
    private let files = FileService()

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orchard-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func write(_ text: String, to name: String, in root: URL? = nil) throws {
        let base = root ?? tmp!
        let url = base.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func writeData(_ data: Data, to name: String) throws {
        let url = tmp.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url)
    }

    // MARK: - Tree

    func testReadDirIsLazySortedAndHidesDotfiles() throws {
        try write("a", to: "zeta.txt")
        try write("b", to: "alpha.txt")
        try write("c", to: "src/app.swift")
        try write("secret", to: ".hidden")
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("lib"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent(".config"),
                                                withIntermediateDirectories: true)

        let root = try files.readDir(root: tmp, showDotfiles: false)
        XCTAssertEqual(root.map(\.name), ["lib", "src", "alpha.txt", "zeta.txt"])
        XCTAssertTrue(root[0].isDirectory)
        XCTAssertTrue(root[1].isDirectory)
        XCTAssertFalse(root.contains { $0.name.hasPrefix(".") })

        // Lazy: nested listing is a separate call and does not leak into the parent.
        let src = try files.readDir(root: tmp, relativePath: "src")
        XCTAssertEqual(src.map(\.name), ["app.swift"])
        XCTAssertEqual(try files.readDir(root: tmp).map(\.name), root.map(\.name))

        let withDots = try files.readDir(root: tmp, showDotfiles: true)
        XCTAssertTrue(withDots.contains { $0.name == ".hidden" })
        XCTAssertTrue(withDots.contains { $0.name == ".config" && $0.isDirectory })
    }

    func testReadDirNumericNameOrder() throws {
        try write("x", to: "file2.txt")
        try write("x", to: "file10.txt")
        try write("x", to: "file1.txt")
        let names = try files.readDir(root: tmp).map(\.name)
        XCTAssertEqual(names, ["file1.txt", "file2.txt", "file10.txt"])
    }

    func testReadDirOfAFileIsNotADirectory() throws {
        try write("x", to: "only.txt")
        XCTAssertThrowsError(try files.readDir(root: tmp, relativePath: "only.txt")) { error in
            XCTAssertEqual((error as? FileServiceError)?.code, "not_a_directory")
        }
    }

    func testReadDirMissingPathIsNotFound() throws {
        XCTAssertThrowsError(try files.readDir(root: tmp, relativePath: "nope")) { error in
            XCTAssertEqual((error as? FileServiceError)?.code, "not_found")
        }
    }

    // MARK: - Preview budgets + binary/image

    func testPreviewTextAndBudget() throws {
        try write("hello orchard\n", to: "readme.txt")
        let preview = try files.preview(root: tmp, relativePath: "readme.txt")
        XCTAssertEqual(preview.content, "hello orchard\n")
        XCTAssertFalse(preview.isBinary)
        XCTAssertFalse(preview.isImage)
        XCTAssertEqual(preview.mimeType, "text/plain")
        XCTAssertEqual(preview.byteLength, 14)

        XCTAssertThrowsError(try files.preview(root: tmp, relativePath: "readme.txt", maxBytes: 4)) { error in
            XCTAssertEqual((error as? FileServiceError)?.code, "file_too_large")
        }
    }

    func testWriteOverwritesAndCreatesConfinedFiles() throws {
        try write("old\n", to: "notes.txt")
        let updated = try files.write(root: tmp, relativePath: "notes.txt", contents: "new\n")
        XCTAssertEqual(updated.size, 4)
        XCTAssertEqual(try String(contentsOf: tmp.appendingPathComponent("notes.txt"), encoding: .utf8), "new\n")

        let created = try files.write(root: tmp, relativePath: "fresh.txt", contents: "hi")
        XCTAssertEqual(created.size, 2)
        XCTAssertEqual(try files.preview(root: tmp, relativePath: "fresh.txt").content, "hi")

        XCTAssertThrowsError(try files.write(root: tmp, relativePath: "../escape.txt", contents: "x")) { error in
            XCTAssertEqual((error as? FileServiceError)?.code, "path_escape")
        }
        XCTAssertThrowsError(try files.write(root: tmp, relativePath: "notes.txt/nested", contents: "x")) { error in
            let code = (error as? FileServiceError)?.code
            XCTAssertTrue(code == "not_found" || code == "not_a_file" || code == "path_escape",
                          "expected confinement/existence error, got \(String(describing: code))")
        }
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("dir"),
                                                withIntermediateDirectories: true)
        XCTAssertThrowsError(try files.write(root: tmp, relativePath: "dir", contents: "x")) { error in
            XCTAssertEqual((error as? FileServiceError)?.code, "not_a_file")
        }
        XCTAssertThrowsError(try files.write(root: tmp, relativePath: "missing/new.txt", contents: "x")) { error in
            XCTAssertEqual((error as? FileServiceError)?.code, "not_found")
        }
    }

    func testPreviewDetectsBinaryByNUL() throws {
        try writeData(Data([0x68, 0x69, 0x00, 0x21]), to: "blob.bin")
        let preview = try files.preview(root: tmp, relativePath: "blob.bin")
        XCTAssertTrue(preview.isBinary)
        XCTAssertFalse(preview.isImage)
        XCTAssertEqual(preview.content, "")
        XCTAssertEqual(preview.byteLength, 4)
    }

    func testPreviewDetectsImageMIMEAndBase64() throws {
        // 1×1 PNG
        let png = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
        try writeData(png, to: "logo.png")
        let preview = try files.preview(root: tmp, relativePath: "logo.png")
        XCTAssertTrue(preview.isBinary)
        XCTAssertTrue(preview.isImage)
        XCTAssertEqual(preview.mimeType, "image/png")
        XCTAssertEqual(Data(base64Encoded: preview.content), png)
    }

    func testPreviewImageOverBudgetIsRejected() throws {
        let png = Data(repeating: 0x89, count: 64)
        try writeData(png, to: "big.jpg")
        XCTAssertThrowsError(try files.preview(root: tmp, relativePath: "big.jpg", maxBytes: 16)) { error in
            XCTAssertEqual((error as? FileServiceError)?.code, "file_too_large")
        }
    }

    func testStatReportsSizeAndDirectory() throws {
        try write("abcd", to: "n.txt")
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("d"),
                                                withIntermediateDirectories: true)
        let file = try files.stat(root: tmp, relativePath: "n.txt")
        XCTAssertEqual(file.size, 4)
        XCTAssertFalse(file.isDirectory)
        let dir = try files.stat(root: tmp, relativePath: "d")
        XCTAssertTrue(dir.isDirectory)
        let rootStat = try files.stat(root: tmp, relativePath: "")
        XCTAssertTrue(rootStat.isDirectory)
    }

    // MARK: - Path confinement

    func testRejectsDotDotAndAbsolutePaths() throws {
        try write("x", to: "inside.txt")
        let outside = tmp.deletingLastPathComponent().appendingPathComponent("secret.txt")
        try "nope".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }

        XCTAssertThrowsError(try files.preview(root: tmp, relativePath: "../secret.txt")) { error in
            XCTAssertEqual((error as? FileServiceError)?.code, "path_escape")
        }
        XCTAssertThrowsError(try files.preview(root: tmp, relativePath: "foo/../../secret.txt")) { error in
            XCTAssertEqual((error as? FileServiceError)?.code, "path_escape")
        }
        XCTAssertThrowsError(try files.preview(root: tmp, relativePath: "/etc/passwd")) { error in
            XCTAssertEqual((error as? FileServiceError)?.code, "path_escape")
        }
        XCTAssertThrowsError(try files.readDir(root: tmp, relativePath: "..")) { error in
            XCTAssertEqual((error as? FileServiceError)?.code, "path_escape")
        }
        XCTAssertThrowsError(try files.stat(root: tmp, relativePath: "foo/./bar")) { error in
            XCTAssertEqual((error as? FileServiceError)?.code, "path_escape")
        }
        // A path that is inside after standardize still has to be asked for relatively.
        XCTAssertNoThrow(try files.preview(root: tmp, relativePath: "inside.txt"))
    }

    func testRejectsSymlinkEscape() throws {
        let outsideDir = tmp.deletingLastPathComponent()
            .appendingPathComponent("orchard-files-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        let target = outsideDir.appendingPathComponent("leak.txt")
        try "leaked".write(to: target, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outsideDir) }

        let link = tmp.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outsideDir)

        XCTAssertThrowsError(try files.preview(root: tmp, relativePath: "escape/leak.txt")) { error in
            XCTAssertEqual((error as? FileServiceError)?.code, "path_escape")
        }
        // The symlink itself is listable as a non-directory entry.
        let listing = try files.readDir(root: tmp, showDotfiles: true)
        let row = listing.first { $0.name == "escape" }
        XCTAssertEqual(row?.isSymlink, true)
        XCTAssertEqual(row?.isDirectory, false)
    }

    func testRelativePathFromAbsoluteInsideRoot() throws {
        try write("x", to: "src/a.swift")
        let abs = tmp.appendingPathComponent("src/a.swift").path
        XCTAssertEqual(try files.relativePath(from: abs, root: tmp), "src/a.swift")
        XCTAssertThrowsError(try files.relativePath(from: "/etc/passwd", root: tmp)) { error in
            XCTAssertEqual((error as? FileServiceError)?.code, "path_escape")
        }
    }

    // MARK: - Search + name-filtered listing

    func testListFiltersByNameAndSkipsGit() throws {
        try write("x", to: "src/App.swift")
        try write("x", to: "src/Helper.swift")
        try write("x", to: "README.md")
        try write("x", to: ".git/objects/pack")
        try write("x", to: "src/.cache")

        let all = try files.list(root: tmp)
        XCTAssertEqual(all.files.sorted(), ["README.md", "src/App.swift", "src/Helper.swift"])
        XCTAssertFalse(all.truncated)

        let filtered = try files.list(root: tmp, query: "swift")
        XCTAssertEqual(filtered.files.sorted(), ["src/App.swift", "src/Helper.swift"])
        XCTAssertEqual(filtered.totalCount, 2)

        let capped = try files.list(root: tmp, limit: 1)
        XCTAssertEqual(capped.files.count, 1)
        XCTAssertEqual(capped.totalCount, 3)
        XCTAssertTrue(capped.truncated)
    }

    func testSearchRanksBasenameAndRespectsLimit() throws {
        try write("x", to: "src/App.swift")
        try write("x", to: "src/Helper.swift")
        try write("x", to: "docs/app-notes.md")
        try write("x", to: "AppTest.swift")

        let exact = try files.search(root: tmp, query: "App.swift")
        XCTAssertEqual(exact.files.first?.relativePath, "src/App.swift")
        XCTAssertEqual(exact.files.first?.basename, "App.swift")

        let hits = try files.search(root: tmp, query: "app")
        XCTAssertTrue(hits.files.contains { $0.relativePath == "src/App.swift" })
        XCTAssertTrue(hits.files.contains { $0.relativePath == "AppTest.swift" })
        XCTAssertTrue(hits.files.contains { $0.relativePath == "docs/app-notes.md" })
        XCTAssertFalse(hits.truncated)

        let limited = try files.search(root: tmp, query: "swift", limit: 1)
        XCTAssertEqual(limited.files.count, 1)
        XCTAssertEqual(limited.totalCount, 3)
        XCTAssertTrue(limited.truncated)

        XCTAssertThrowsError(try files.search(root: tmp, query: "  ")) { error in
            XCTAssertEqual((error as? FileServiceError)?.code, "invalid_argument")
        }
    }

    // MARK: - Full-text content search

    func testContentSearchFindsLineExcerptsCaseInsensitive() throws {
        try write("Hello Orchard\nsecond line\n", to: "src/app.swift")
        try write("nope\n", to: "README.md")
        let result = try files.contentSearch(root: tmp, query: "orchard")
        XCTAssertEqual(result.matches.count, 1)
        XCTAssertEqual(result.matches[0].path, "src/app.swift")
        XCTAssertEqual(result.matches[0].line, 1)
        XCTAssertEqual(result.matches[0].excerpt, "Hello Orchard")
        XCTAssertFalse(result.truncated)
        XCTAssertFalse(result.matches[0].path.contains(".."))
        XCTAssertFalse(result.matches[0].path.hasPrefix("/"))
    }

    func testContentSearchRespectsIncludeExcludeGlobs() throws {
        try write("needle in swift\n", to: "src/app.swift")
        try write("needle in notes\n", to: "docs/notes.md")
        try write("needle in bin-shaped\n", to: "src/skip.txt")

        let included = try files.contentSearch(
            root: tmp, query: "needle",
            options: FileContentSearchOptions(include: ["*.swift"]))
        XCTAssertEqual(included.matches.map(\.path), ["src/app.swift"])

        let nested = try files.contentSearch(
            root: tmp, query: "needle",
            options: FileContentSearchOptions(include: ["docs/*"]))
        XCTAssertEqual(nested.matches.map(\.path), ["docs/notes.md"])

        let excluded = try files.contentSearch(
            root: tmp, query: "needle",
            options: FileContentSearchOptions(exclude: ["*.txt"]))
        XCTAssertEqual(Set(excluded.matches.map(\.path)), ["src/app.swift", "docs/notes.md"])
    }

    func testContentSearchSkipsBinaryAndRespectsBudgets() throws {
        try write("visible secret\n", to: "plain.txt")
        try writeData(Data("secret".utf8) + Data([0x00, 0x01]), to: "blob.bin")
        // Image extension is skipped without a content read.
        try write("secret in a png\n", to: "logo.png")

        let skipped = try files.contentSearch(root: tmp, query: "secret")
        XCTAssertEqual(skipped.matches.map(\.path), ["plain.txt"])

        try write(String(repeating: "secret\n", count: 8), to: "many.txt")
        let perFile = try files.contentSearch(
            root: tmp, query: "secret",
            options: FileContentSearchOptions(perFileLimit: 2))
        XCTAssertEqual(perFile.matches.filter { $0.path == "many.txt" }.count, 2)
        XCTAssertTrue(perFile.truncated)

        let capped = try files.contentSearch(
            root: tmp, query: "secret",
            options: FileContentSearchOptions(limit: 1))
        XCTAssertEqual(capped.matches.count, 1)
        XCTAssertTrue(capped.truncated)

        try write(String(repeating: "x", count: 64) + "secret", to: "big.txt")
        let overFile = try files.contentSearch(
            root: tmp, query: "secret",
            options: FileContentSearchOptions(include: ["big.txt"], fileByteBudget: 16))
        XCTAssertTrue(overFile.matches.isEmpty)

        try write("secret-a\n", to: "a.txt")
        try write("secret-b\n", to: "b.txt")
        let overTotal = try files.contentSearch(
            root: tmp, query: "secret",
            options: FileContentSearchOptions(
                include: ["a.txt", "b.txt"],
                fileByteBudget: 100,
                totalByteBudget: 12))
        XCTAssertTrue(overTotal.truncated)
        XCTAssertLessThan(overTotal.matches.count, 2)
    }

    func testContentSearchConfinesAndSkipsSymlinkEscape() throws {
        try write("inside hit\n", to: "ok.txt")
        let outsideDir = tmp.deletingLastPathComponent()
            .appendingPathComponent("orchard-search-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        let leak = outsideDir.appendingPathComponent("leak.txt")
        try "inside hit\n".write(to: leak, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outsideDir) }
        try FileManager.default.createSymbolicLink(
            at: tmp.appendingPathComponent("escape"), withDestinationURL: outsideDir)

        let result = try files.contentSearch(root: tmp, query: "inside hit")
        XCTAssertEqual(result.matches.map(\.path), ["ok.txt"])
        XCTAssertFalse(result.matches.contains { $0.path.contains("..") })
        XCTAssertThrowsError(try files.contentSearch(root: tmp, query: "  ")) { error in
            XCTAssertEqual((error as? FileServiceError)?.code, "invalid_argument")
        }
    }

    func testFileGlobPatterns() throws {
        XCTAssertTrue(try FileGlob("*.swift").matches("App.swift"))
        XCTAssertTrue(try FileGlob("*.swift").matches("src/App.swift"))
        XCTAssertFalse(try FileGlob("*.swift").matches("App.swift.md"))
        XCTAssertTrue(try FileGlob("src/*.swift").matches("src/App.swift"))
        XCTAssertFalse(try FileGlob("src/*.swift").matches("src/nested/App.swift"))
        XCTAssertTrue(try FileGlob("src/**/*.swift").matches("src/nested/App.swift"))
        XCTAssertTrue(try FileGlob("**/notes.md").matches("docs/notes.md"))
        XCTAssertTrue(try FileGlob("foo/?at").matches("foo/cat"))
        XCTAssertFalse(try FileGlob("foo/?at").matches("foo/caat"))
        XCTAssertThrowsError(try FileGlob("  ")) { error in
            XCTAssertEqual((error as? FileServiceError)?.code, "invalid_argument")
        }
    }
}
