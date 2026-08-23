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
}
