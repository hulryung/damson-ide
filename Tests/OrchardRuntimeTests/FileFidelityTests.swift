import XCTest
@testable import OrchardRuntime

/// T75: content that goes through `FileService` must come back out byte for byte.
///
/// Every fixture here is deliberately *not* `.utf8`. T72's audit found the same
/// decode-then-write defect in two places, and it shipped because the fixture set was
/// all-UTF-8 — a lossy decode round-trips perfectly when nothing lossy is in the file.
/// Binary, Latin-1, UTF-16, CRLF, and empty are the cases that actually prove fidelity.
final class FileFidelityTests: XCTestCase {
    private var tmp: URL!
    private let files = FileService()

    // MARK: Fixtures (bytes, never strings)

    /// Latin-1 "café déjà vu\n": 0xE9 and 0xE0 are legal Latin-1 and illegal UTF-8.
    private static let latin1 = Data([
        0x63, 0x61, 0x66, 0xE9, 0x20, 0x64, 0xE9, 0x6A, 0xE0, 0x20, 0x76, 0x75, 0x0A,
    ])
    /// A PNG-ish blob: NUL in the head, high bytes throughout.
    private static let binary = Data([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0xFF, 0xFE,
    ])
    /// UTF-16LE with a BOM — valid text in another encoding, invalid UTF-8, NUL-bearing.
    private static let utf16 = Data([0xFF, 0xFE, 0x68, 0x00, 0x69, 0x00])
    /// Windows line endings plus a final line with no terminator.
    private static let crlf = Data("one\r\ntwo\r\n\r\nfour".utf8)
    private static let empty = Data()
    /// Valid UTF-8 that a naive sniff could mistake for junk: BOM, emoji, lone CR.
    private static let trickyUTF8 = Data("\u{FEFF}héllo 🌳\rmid\n".utf8)

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orchard-fidelity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    @discardableResult
    private func put(_ data: Data, at name: String) throws -> URL {
        let url = tmp.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func bytes(at name: String) throws -> Data {
        try Data(contentsOf: tmp.appendingPathComponent(name))
    }

    // MARK: - preview never hands out a lossy decode

    func testPreviewRefusesLatin1RatherThanDecodingItLossily() throws {
        try put(Self.latin1, at: "notes.txt")
        let preview = try files.preview(root: tmp, relativePath: "notes.txt")

        XCTAssertTrue(preview.isBinary, "a file we cannot round-trip is not text")
        XCTAssertFalse(preview.isImage)
        XCTAssertEqual(preview.notTextReason, .notUTF8)
        XCTAssertEqual(preview.byteLength, Self.latin1.count)
        XCTAssertEqual(preview.content, "")
        XCTAssertFalse(preview.content.contains("\u{FFFD}"),
                       "the replacement character must never reach a caller as content")
    }

    func testPreviewMarksUTF16AndBinaryApart() throws {
        try put(Self.utf16, at: "wide.txt")
        try put(Self.binary, at: "blob.dat")

        // UTF-16LE text has NUL bytes, so git's own heuristic fires first — the file is
        // still refused, which is what matters; the reason is only for the pane's wording.
        let wide = try files.preview(root: tmp, relativePath: "wide.txt")
        XCTAssertTrue(wide.isBinary)
        XCTAssertEqual(wide.notTextReason, .nulBytes)

        let blob = try files.preview(root: tmp, relativePath: "blob.dat")
        XCTAssertTrue(blob.isBinary)
        XCTAssertEqual(blob.notTextReason, .nulBytes)
        XCTAssertEqual(blob.byteLength, Self.binary.count)
    }

    func testPreviewKeepsCRLFAndTrailingLineExactly() throws {
        try put(Self.crlf, at: "win.txt")
        let preview = try files.preview(root: tmp, relativePath: "win.txt")

        XCTAssertFalse(preview.isBinary)
        XCTAssertNil(preview.notTextReason)
        XCTAssertEqual(Data(preview.content.utf8), Self.crlf,
                       "CRLF must survive the decode: normalizing it rewrites every line")
        XCTAssertEqual(preview.byteLength, Self.crlf.count)
    }

    func testPreviewOfAnEmptyFileIsEmptyText() throws {
        try put(Self.empty, at: "blank.txt")
        let preview = try files.preview(root: tmp, relativePath: "blank.txt")

        XCTAssertFalse(preview.isBinary, "zero bytes is a text file with nothing in it")
        XCTAssertNil(preview.notTextReason)
        XCTAssertEqual(preview.content, "")
        XCTAssertEqual(preview.byteLength, 0)
    }

    func testPreviewKeepsBOMEmojiAndLoneCR() throws {
        try put(Self.trickyUTF8, at: "tricky.md")
        let preview = try files.preview(root: tmp, relativePath: "tricky.md")
        XCTAssertEqual(Data(preview.content.utf8), Self.trickyUTF8)
    }

    // MARK: - preview → write is byte-exact for everything it accepts

    func testTextRoundTripIsByteExact() throws {
        for (name, data) in [("win.txt", Self.crlf), ("blank.txt", Self.empty),
                             ("tricky.md", Self.trickyUTF8)] {
            try put(data, at: name)
            let preview = try files.preview(root: tmp, relativePath: name)
            try files.write(root: tmp, relativePath: name, contents: preview.content)
            XCTAssertEqual(try bytes(at: name), data, "\(name) changed on a read/write round trip")
        }
    }

    func testReadDataWriteDataRoundTripsBytesNoStringCanCarry() throws {
        for (name, data) in [("notes.txt", Self.latin1), ("blob.dat", Self.binary),
                             ("wide.txt", Self.utf16), ("blank.bin", Self.empty)] {
            try put(data, at: name)
            let read = try files.readData(root: tmp, relativePath: name)
            XCTAssertEqual(read, data)
            try files.write(root: tmp, relativePath: name, data: read)
            XCTAssertEqual(try bytes(at: name), data, "\(name) changed on a byte round trip")
        }
    }

    func testReadDataHonoursTheBudgetAndConfinement() throws {
        try put(Self.binary, at: "blob.dat")
        XCTAssertThrowsError(try files.readData(root: tmp, relativePath: "blob.dat", maxBytes: 4)) {
            XCTAssertEqual(($0 as? FileServiceError)?.code, "file_too_large")
        }
        XCTAssertThrowsError(try files.readData(root: tmp, relativePath: "../escape.bin")) {
            XCTAssertEqual(($0 as? FileServiceError)?.code, "path_escape")
        }
        XCTAssertThrowsError(try files.readData(root: tmp, relativePath: "gone.dat")) {
            XCTAssertEqual(($0 as? FileServiceError)?.code, "not_found")
        }
    }

    // MARK: - a text write never lands on bytes a text read could not have produced

    func testTextWriteRefusesToOverwriteNonUTF8AndLeavesTheFileAlone() throws {
        try put(Self.latin1, at: "notes.txt")
        XCTAssertThrowsError(
            try files.write(root: tmp, relativePath: "notes.txt", contents: "caf\u{FFFD} vu\n")
        ) { error in
            XCTAssertEqual((error as? FileServiceError)?.code, "not_utf8")
        }
        XCTAssertEqual(try bytes(at: "notes.txt"), Self.latin1,
                       "a refused save must not have touched a single byte")
    }

    func testTextWriteRefusesToOverwriteBinary() throws {
        try put(Self.binary, at: "blob.dat")
        XCTAssertThrowsError(try files.write(root: tmp, relativePath: "blob.dat", contents: "hi")) {
            XCTAssertEqual(($0 as? FileServiceError)?.code, "not_utf8")
        }
        XCTAssertEqual(try bytes(at: "blob.dat"), Self.binary)
    }

    func testTextWriteRefusesAFileLargerThanTheEditorCouldHaveLoaded() throws {
        let big = Data(repeating: UInt8(ascii: "a"), count: FileService.defaultTextBudget + 1)
        try put(big, at: "huge.txt")
        XCTAssertThrowsError(try files.write(root: tmp, relativePath: "huge.txt", contents: "tiny")) {
            XCTAssertEqual(($0 as? FileServiceError)?.code, "file_too_large")
        }
        XCTAssertEqual(try bytes(at: "huge.txt").count, big.count,
                       "an over-budget file must not be truncated to a buffer's worth")
    }

    func testTextWriteStillCreatesAndOverwritesOrdinaryText() throws {
        try put(Self.crlf, at: "win.txt")
        try files.write(root: tmp, relativePath: "win.txt", contents: "replaced\n")
        XCTAssertEqual(try bytes(at: "win.txt"), Data("replaced\n".utf8))

        try files.write(root: tmp, relativePath: "new.txt", contents: "")
        XCTAssertEqual(try bytes(at: "new.txt"), Data())

        try put(Self.empty, at: "blank.txt")
        try files.write(root: tmp, relativePath: "blank.txt", contents: "now has text\n")
        XCTAssertEqual(try bytes(at: "blank.txt"), Data("now has text\n".utf8))
    }

    func testByteWriteMayReplaceBinaryContent() throws {
        try put(Self.binary, at: "blob.dat")
        let info = try files.write(root: tmp, relativePath: "blob.dat", data: Self.latin1)
        XCTAssertEqual(info.size, Int64(Self.latin1.count))
        XCTAssertEqual(try bytes(at: "blob.dat"), Self.latin1)
    }

    func testByteWriteKeepsConfinementAndParentRules() throws {
        XCTAssertThrowsError(try files.write(root: tmp, relativePath: "../escape.bin",
                                             data: Self.binary)) {
            XCTAssertEqual(($0 as? FileServiceError)?.code, "path_escape")
        }
        XCTAssertThrowsError(try files.write(root: tmp, relativePath: "missing/new.bin",
                                             data: Self.binary)) {
            XCTAssertEqual(($0 as? FileServiceError)?.code, "not_found")
        }
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("dir"),
                                                withIntermediateDirectories: true)
        XCTAssertThrowsError(try files.write(root: tmp, relativePath: "dir", data: Self.binary)) {
            XCTAssertEqual(($0 as? FileServiceError)?.code, "not_a_file")
        }
    }

    // MARK: - what the editor is handed for each fixture

    func testEditorSurfacesRefuseToSaveEverythingButText() throws {
        try put(Self.latin1, at: "notes.txt")
        try put(Self.binary, at: "blob.dat")
        try put(Self.crlf, at: "win.txt")
        try put(Self.empty, at: "blank.txt")

        let latin = EditorDocument.surface(
            from: try files.preview(root: tmp, relativePath: "notes.txt"))
        XCTAssertEqual(latin, .notUTF8(byteLength: Self.latin1.count))
        XCTAssertEqual(EditorDocument.saveRefusal(for: latin)?.code, "not_utf8")

        let blob = EditorDocument.surface(
            from: try files.preview(root: tmp, relativePath: "blob.dat"))
        XCTAssertEqual(EditorDocument.saveRefusal(for: blob)?.code, "not_text")

        let win = EditorDocument.surface(from: try files.preview(root: tmp, relativePath: "win.txt"))
        XCTAssertEqual(win, .text(String(decoding: Self.crlf, as: UTF8.self)))
        XCTAssertNil(EditorDocument.saveRefusal(for: win), "ordinary CRLF text is savable")

        let blank = EditorDocument.surface(
            from: try files.preview(root: tmp, relativePath: "blank.txt"))
        XCTAssertEqual(blank, .text(""))
        XCTAssertNil(EditorDocument.saveRefusal(for: blank), "an empty file is savable")
    }

    // MARK: - the read-only search path still finds ASCII in non-UTF-8 files

    func testContentSearchStillMatchesInsideALatin1File() throws {
        try put(Self.latin1, at: "notes.txt")
        let result = try files.contentSearch(root: tmp, query: "vu")
        XCTAssertEqual(result.matches.map(\.path), ["notes.txt"],
                       "search is display-only and never writes, so it may still read this file")
    }
}
