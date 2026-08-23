import XCTest
@testable import OrchardRuntime

/// Dirty tracking and external-change resolution — the UI-free half of T28.
final class EditorDocumentTests: XCTestCase {
    func testSurfaceClassifiesPreviewKinds() {
        let text = FilePreview(content: "hello\n", isBinary: false, isImage: false,
                               mimeType: "text/plain", byteLength: 6)
        XCTAssertEqual(EditorDocument.surface(from: text), .text("hello\n"))

        let binary = FilePreview(content: "", isBinary: true, isImage: false,
                                 mimeType: nil, byteLength: 12)
        XCTAssertEqual(
            EditorDocument.surface(from: binary),
            .binary(byteLength: 12, isImage: false, mimeType: nil, imageBase64: nil))

        let image = FilePreview(content: "abc", isBinary: true, isImage: true,
                                mimeType: "image/png", byteLength: 3)
        XCTAssertEqual(
            EditorDocument.surface(from: image),
            .binary(byteLength: 3, isImage: true, mimeType: "image/png", imageBase64: "abc"))
    }

    func testSurfaceMapsTypedLoadErrors() {
        XCTAssertEqual(EditorDocument.surface(from: .fileTooLarge), .tooLarge)
        XCTAssertEqual(EditorDocument.surface(from: .notFound("gone.txt")),
                       .missing("no such file: gone.txt"))
        XCTAssertEqual(EditorDocument.surface(from: .notAFile),
                       .missing("path is not a file"))
    }

    func testDirtyIsDraftVersusDisk() {
        var state = EditorDocument.State(diskText: "a")
        XCTAssertFalse(state.isDirty)
        state = EditorDocument.applyEdit(state, draft: "ab")
        XCTAssertTrue(state.isDirty)
        XCTAssertEqual(state.diskText, "a")
        state = EditorDocument.applyEdit(state, draft: "a")
        XCTAssertFalse(state.isDirty)
    }

    func testSaveClearsDirtyAndRecordsOwnWrite() {
        var state = EditorDocument.State(diskText: "a")
        state = EditorDocument.applyEdit(state, draft: "b")
        state = EditorDocument.applySave(state, written: "b", mtime: 10)
        XCTAssertFalse(state.isDirty)
        XCTAssertEqual(state.diskText, "b")
        XCTAssertEqual(state.lastWrittenText, "b")
        XCTAssertEqual(state.lastWriteMTime, 10)
        XCTAssertTrue(EditorDocument.isOwnWrite(incomingText: "b", state: state, incomingMTime: 10))
        XCTAssertTrue(EditorDocument.isOwnWrite(incomingText: "b", state: state, incomingMTime: 99),
                      "bytes we just wrote are own-write even if mtime drifted")
        XCTAssertFalse(EditorDocument.isOwnWrite(incomingText: "c", state: state, incomingMTime: 11))
    }

    func testCleanExternalChangeReloadsSilently() {
        XCTAssertEqual(
            EditorDocument.decideExternalChange(isDirty: false, isOwnWrite: false, diskChanged: true),
            .reloadSilently)
        let state = EditorDocument.State(diskText: "old")
        let reloaded = EditorDocument.applyReload(state, diskText: "new", mtime: 3)
        XCTAssertEqual(reloaded.draft, "new")
        XCTAssertFalse(reloaded.isDirty)
        XCTAssertEqual(reloaded.lastWriteMTime, 3)
    }

    func testDirtyExternalChangePromptsAndKeepMinePreservesDraft() {
        XCTAssertEqual(
            EditorDocument.decideExternalChange(isDirty: true, isOwnWrite: false, diskChanged: true),
            .prompt)
        var state = EditorDocument.State(diskText: "old")
        state = EditorDocument.applyEdit(state, draft: "mine")
        let kept = EditorDocument.applyKeepMine(state, diskText: "theirs", mtime: 8)
        XCTAssertEqual(kept.draft, "mine")
        XCTAssertEqual(kept.diskText, "theirs")
        XCTAssertTrue(kept.isDirty)
        XCTAssertEqual(kept.lastWriteMTime, 8)
    }

    func testOwnWriteAndUnchangedDiskAreIgnored() {
        XCTAssertEqual(
            EditorDocument.decideExternalChange(isDirty: true, isOwnWrite: true, diskChanged: true),
            .ignore)
        XCTAssertEqual(
            EditorDocument.decideExternalChange(isDirty: false, isOwnWrite: false, diskChanged: false),
            .ignore)
        XCTAssertEqual(
            EditorDocument.decideExternalChange(isDirty: true, isOwnWrite: false, diskChanged: false),
            .ignore)
    }

    func testCaretIsOneIndexed() {
        XCTAssertEqual(EditorDocument.caret(in: "", location: 0).line, 1)
        XCTAssertEqual(EditorDocument.caret(in: "", location: 0).column, 1)
        let text = "ab\ncd\n"
        XCTAssertEqual(EditorDocument.caret(in: text, location: 0).column, 1)
        XCTAssertEqual(EditorDocument.caret(in: text, location: 2).line, 1)
        XCTAssertEqual(EditorDocument.caret(in: text, location: 2).column, 3)
        XCTAssertEqual(EditorDocument.caret(in: text, location: 3).line, 2)
        XCTAssertEqual(EditorDocument.caret(in: text, location: 3).column, 1)
        XCTAssertEqual(EditorDocument.caret(in: text, location: 99).line, 3)
    }

    func testModificationsExcludeStructuralPaths() {
        let previous: [String: FileWatchIdentity] = [
            "keep.txt": FileWatchIdentity(inode: 1, mtime: 1),
            "gone.txt": FileWatchIdentity(inode: 2, mtime: 1),
        ]
        let current: [String: FileWatchIdentity] = [
            "keep.txt": FileWatchIdentity(inode: 1, mtime: 2),
            "fresh.txt": FileWatchIdentity(inode: 3, mtime: 2),
        ]
        let mods = FileWatchReconciler.modifications(
            previous: previous, current: current, excluding: ["fresh.txt"])
        XCTAssertEqual(mods.map(\.relativePath), ["keep.txt"])
        XCTAssertEqual(mods.first?.kind, .modified)
    }
}
