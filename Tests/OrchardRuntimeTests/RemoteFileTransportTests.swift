import XCTest
@testable import OrchardRuntime

/// T85: the far-side helper (perl) plus protocol parse. Runs perl locally against
/// a temp tree so the transport is pinned without ssh; the handler suite scripts
/// the ssh seam on top of the same protocol.
final class RemoteFileTransportTests: XCTestCase {
    private var tmp: URL!

    /// Latin-1 "café déjà vu\n" — legal Latin-1, illegal UTF-8.
    private static let latin1 = Data([
        0x63, 0x61, 0x66, 0xE9, 0x20, 0x64, 0xE9, 0x6A, 0xE0, 0x20, 0x76, 0x75, 0x0A,
    ])
    private static let binary = Data([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0xFF, 0xFE,
    ])
    private static let trickyUTF8 = Data("\u{FEFF}héllo 🌳\rmid\n".utf8)

    override func setUpWithError() throws {
        try XCTSkipIf(!FileManager.default.isExecutableFile(atPath: "/usr/bin/perl"),
                      "perl unavailable")
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orchard-remote-file-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try Data("hello\n".utf8).write(to: tmp.appendingPathComponent("README.md"))
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("src"),
                                                withIntermediateDirectories: true)
        try Data("fn main() { println!(\"hello\"); }\n".utf8)
            .write(to: tmp.appendingPathComponent("src/app.swift"))
        try Data("secret".utf8).write(to: tmp.appendingPathComponent(".env"))
        try Self.latin1.write(to: tmp.appendingPathComponent("notes.txt"))
        try Self.binary.write(to: tmp.appendingPathComponent("blob.dat"))
        try Self.trickyUTF8.write(to: tmp.appendingPathComponent("tricky.md"))
    }

    override func tearDownWithError() throws {
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
    }

    func testReadDirOmitsDotfilesUnlessAsked() throws {
        let listing = try parse(run(op: "read-dir", rel: "", extra: ["ORCHARD_FILE_DOTS": "0"]))
        XCTAssertTrue(listing.ok, listing.message)
        let names = listing.entries
        XCTAssertEqual(names.sorted(), ["README.md", "blob.dat", "notes.txt", "src", "tricky.md"])
        XCTAssertFalse(names.contains(".env"))
        XCTAssertTrue(listing.entry("src")?.isDirectory == true)
        XCTAssertTrue(listing.entry("README.md")?.isDirectory == false)

        let dotted = try parse(run(op: "read-dir", rel: "", extra: ["ORCHARD_FILE_DOTS": "1"]))
        XCTAssertTrue(dotted.entries.contains(".env"))
    }

    func testReadReturnsLatin1BytesAndNeverAReplacementCharacter() throws {
        let parsed = try parse(run(op: "read", rel: "notes.txt", extra: [
            "ORCHARD_FILE_MAX": "524288",
        ]))
        XCTAssertTrue(parsed.ok, parsed.message)
        let data = try XCTUnwrap(parsed.body)
        XCTAssertEqual(data, Self.latin1)
        let preview = try FileService().preview(data: data, relativePath: "notes.txt")
        XCTAssertEqual(preview.notTextReason, .notUTF8)
        XCTAssertEqual(preview.content, "")
        XCTAssertFalse(preview.content.contains("\u{FFFD}"))
        XCTAssertEqual(preview.byteLength, Self.latin1.count)
    }

    func testReadOfUTF8RoundTripsIncludingBOM() throws {
        let parsed = try parse(run(op: "read", rel: "tricky.md", extra: [
            "ORCHARD_FILE_MAX": "524288",
        ]))
        let data = try XCTUnwrap(parsed.body)
        XCTAssertEqual(data, Self.trickyUTF8)
        let preview = try FileService().preview(data: data, relativePath: "tricky.md")
        XCTAssertNil(preview.notTextReason)
        XCTAssertEqual(Data(preview.content.utf8), Self.trickyUTF8)
    }

    func testReadOfNULHeadIsNulBytesNotUTF8() throws {
        let parsed = try parse(run(op: "read", rel: "blob.dat", extra: [
            "ORCHARD_FILE_MAX": "524288",
        ]))
        let data = try XCTUnwrap(parsed.body)
        XCTAssertEqual(data, Self.binary)
        let preview = try FileService().preview(data: data, relativePath: "blob.dat")
        XCTAssertEqual(preview.notTextReason, .nulBytes)
        XCTAssertEqual(preview.content, "")
    }

    func testReadDirRejectsDotDotBeforeTheFarSideWalks() throws {
        XCTAssertThrowsError(try RemoteFilePath.requireSafe("../secret")) { error in
            XCTAssertEqual((error as? FileServiceError)?.code, "path_escape")
        }
        let parsed = try parse(run(op: "read-dir", rel: "../secret"))
        XCTAssertFalse(parsed.ok)
        XCTAssertEqual(parsed.code, "path_escape")
    }

    func testReadOfADirectoryIsNotAFile() throws {
        let parsed = try parse(run(op: "read", rel: "src", extra: ["ORCHARD_FILE_MAX": "100"]))
        XCTAssertFalse(parsed.ok)
        XCTAssertEqual(parsed.code, "not_a_file")
    }

    func testStatOfADirectory() throws {
        let parsed = try parse(run(op: "stat", rel: "src"))
        XCTAssertTrue(parsed.ok, parsed.message)
        XCTAssertEqual(parsed.stat?.isDirectory, true)
        XCTAssertEqual(parsed.stat?.isSymlink, false)
    }

    func testListAndContentSearch() throws {
        let listed = try parse(run(op: "list", rel: "", extra: [
            "ORCHARD_FILE_DOTS": "0",
            "ORCHARD_FILE_LIMIT": "2000",
            "ORCHARD_FILE_QUERY": "md",
        ]))
        XCTAssertTrue(listed.ok, listed.message)
        XCTAssertEqual(listed.listPaths.sorted(), ["README.md", "tricky.md"])

        let swiftGlob = try FileGlob("*.swift")
        let searched = try parse(run(op: "search", rel: "", extra: [
            "ORCHARD_FILE_QUERY": "hello",
            "ORCHARD_FILE_DOTS": "0",
            "ORCHARD_FILE_CASE": "0",
            "ORCHARD_FILE_LIMIT": "200",
            "ORCHARD_FILE_PERFILE": "20",
            "ORCHARD_FILE_FILEBUDGET": "524288",
            "ORCHARD_FILE_TOTALBUDGET": "8388608",
            "ORCHARD_FILE_EXCERPT": "200",
            "ORCHARD_FILE_INCLUDE_RE": swiftGlob.regexPattern,
        ]))
        XCTAssertTrue(searched.ok, searched.message)
        XCTAssertEqual(searched.hits.count, 1)
        XCTAssertEqual(searched.hits.first?.path, "src/app.swift")
        XCTAssertEqual(searched.hits.first?.line, 1)
        XCTAssertTrue(searched.hits.first?.excerpt.contains("hello") ?? false)
    }

    func testSearchFindsASCIIInsideLatin1() throws {
        let searched = try parse(run(op: "search", rel: "", extra: [
            "ORCHARD_FILE_QUERY": "caf",
            "ORCHARD_FILE_DOTS": "0",
            "ORCHARD_FILE_CASE": "0",
            "ORCHARD_FILE_LIMIT": "200",
            "ORCHARD_FILE_PERFILE": "20",
            "ORCHARD_FILE_FILEBUDGET": "524288",
            "ORCHARD_FILE_TOTALBUDGET": "8388608",
            "ORCHARD_FILE_EXCERPT": "200",
        ]))
        XCTAssertTrue(searched.ok, searched.message)
        XCTAssertTrue(searched.hits.contains { $0.path == "notes.txt" },
                      String(describing: searched.hits))
    }

    func testSymlinkEscapeIsPathEscape() throws {
        let outside = tmp.deletingLastPathComponent()
            .appendingPathComponent("orchard-remote-file-outside-\(UUID().uuidString)")
        try Data("leaked\n".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let link = tmp.appendingPathComponent("escape.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        let parsed = try parse(run(op: "read", rel: "escape.txt", extra: [
            "ORCHARD_FILE_MAX": "524288",
        ]))
        XCTAssertFalse(parsed.ok)
        XCTAssertEqual(parsed.code, "path_escape")
        XCTAssertNil(parsed.body)
    }

    func testProtocolParseRejectsALossyHeader() {
        XCTAssertNil(RemoteFileTransport.Parsed(stdout: "not a protocol\n"))
        let err = RemoteFileTransport.Parsed(stdout: "ORCHARD-FILE/1\nerr\nnot_found\nno such file: x\n")
        XCTAssertEqual(err?.ok, false)
        XCTAssertEqual(err?.code, "not_found")
    }

    // MARK: - helpers

    private func run(op: String, rel: String, extra: [String: String] = [:]) throws -> String {
        var env = ProcessInfo.processInfo.environment
        env["ORCHARD_FILE_OP"] = op
        env["ORCHARD_FILE_ROOT"] = tmp.path
        env["ORCHARD_FILE_REL"] = rel
        extra.forEach { env[$0] = $1 }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", RemoteFileTransport.perlSource]
        process.environment = env
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, "perl stderr: \(stderr)\nstdout: \(stdout)")
        return stdout
    }

    private func parse(_ stdout: String) throws -> RemoteFileTransport.Parsed {
        try XCTUnwrap(RemoteFileTransport.Parsed(stdout: stdout), "no protocol header in:\n\(stdout)")
    }
}

private extension RemoteFileTransport.Parsed {
    var entries: [String] {
        records.compactMap {
            if case .entry(_, let name) = $0 { return name }
            return nil
        }
    }

    func entry(_ name: String) -> FileDirEntry? {
        for record in records {
            if case .entry(let kind, let n) = record, n == name {
                return FileDirEntry(name: n, isDirectory: kind == "d", isSymlink: kind == "l")
            }
        }
        return nil
    }

    var listPaths: [String] {
        records.compactMap {
            if case .list(let path) = $0 { return path }
            return nil
        }
    }

    struct Hit { var path: String; var line: Int; var excerpt: String }
    var hits: [Hit] {
        records.compactMap {
            if case .hit(let path, let line, let excerpt) = $0 {
                return Hit(path: path, line: line, excerpt: excerpt)
            }
            return nil
        }
    }
}
