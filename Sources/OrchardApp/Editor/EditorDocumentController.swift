import Foundation
import OrchardRuntime

/// Per-file editor session. Load/save go through `FileService`; external
/// changes arrive as `FileWatchBatch` from the workspace watcher.
@MainActor
final class EditorDocumentController: ObservableObject {
    let root: URL
    let relativePath: String

    @Published private(set) var surface: EditorDocument.Surface
    @Published private(set) var state: EditorDocument.State?
    @Published private(set) var isDirty = false
    @Published var line = 1
    @Published var column = 1
    @Published var conflict: Conflict?
    @Published var saveError: String?
    @Published var isSaving = false

    struct Conflict: Equatable {
        var incomingText: String
        var incomingMTime: Double?
        var fileMissing: Bool
    }

    private let files: FileService

    init(root: URL, relativePath: String, files: FileService) {
        self.root = root
        self.relativePath = relativePath
        self.files = files
        self.surface = .missing("Loading…")
    }

    var draft: String { state?.draft ?? "" }

    func load() {
        do {
            let preview = try files.preview(root: root, relativePath: relativePath)
            apply(surface: EditorDocument.surface(from: preview))
        } catch let err as FileServiceError {
            apply(surface: EditorDocument.surface(from: err))
        } catch {
            apply(surface: .missing(String(describing: error)))
        }
    }

    func edit(_ text: String) {
        guard let state else { return }
        commit(EditorDocument.applyEdit(state, draft: text))
    }

    @discardableResult
    func save() -> Bool {
        guard let state else { return false }
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        do {
            let written = state.draft
            let info = try files.write(root: root, relativePath: relativePath, contents: written)
            commit(EditorDocument.applySave(state, written: written, mtime: info.mtime))
            surface = .text(written)
            conflict = nil
            return true
        } catch {
            saveError = String(describing: error)
            return false
        }
    }

    func handleWatch(_ batch: FileWatchBatch) {
        if batch.rootDeleted {
            handleMissing("This folder was deleted")
            return
        }
        let hits = batch.changes.filter { change in
            change.relativePath == relativePath || change.previousRelativePath == relativePath
        }
        guard !hits.isEmpty else { return }
        let vanished = hits.contains { change in
            change.kind == .deleted
                || (change.kind == .renamed
                    && change.previousRelativePath == relativePath
                    && change.relativePath != relativePath)
        }
        if vanished {
            handleMissing("This file was deleted")
            return
        }
        reloadFromDisk()
    }

    func keepMine() {
        guard let state, let conflict else { return }
        if conflict.fileMissing {
            self.conflict = nil
            return
        }
        commit(EditorDocument.applyKeepMine(state, diskText: conflict.incomingText,
                                            mtime: conflict.incomingMTime))
        self.conflict = nil
    }

    func acceptReload() {
        guard let conflict else { return }
        if conflict.fileMissing {
            apply(surface: .missing("This file was deleted"))
            self.conflict = nil
            return
        }
        if let state {
            commit(EditorDocument.applyReload(state, diskText: conflict.incomingText,
                                              mtime: conflict.incomingMTime))
        } else {
            commit(EditorDocument.State(diskText: conflict.incomingText))
        }
        surface = .text(conflict.incomingText)
        self.conflict = nil
    }

    private func reloadFromDisk() {
        do {
            let preview = try files.preview(root: root, relativePath: relativePath)
            let info = try files.stat(root: root, relativePath: relativePath)
            let next = EditorDocument.surface(from: preview)
            guard case .text(let text) = next else {
                if state?.isDirty == true {
                    conflict = Conflict(incomingText: "", incomingMTime: info.mtime, fileMissing: false)
                } else {
                    apply(surface: next)
                }
                return
            }
            guard let state else {
                apply(surface: next)
                return
            }
            let own = EditorDocument.isOwnWrite(incomingText: text, state: state, incomingMTime: info.mtime)
            let diskChanged = text != state.diskText
            switch EditorDocument.decideExternalChange(isDirty: state.isDirty, isOwnWrite: own,
                                                       diskChanged: diskChanged) {
            case .ignore:
                break
            case .reloadSilently:
                commit(EditorDocument.applyReload(state, diskText: text, mtime: info.mtime))
                surface = .text(text)
                conflict = nil
            case .prompt:
                conflict = Conflict(incomingText: text, incomingMTime: info.mtime, fileMissing: false)
            }
        } catch let err as FileServiceError where err.code == "not_found" {
            handleMissing("This file was deleted")
        } catch {
            saveError = String(describing: error)
        }
    }

    private func handleMissing(_ message: String) {
        guard let state else {
            apply(surface: .missing(message))
            return
        }
        switch EditorDocument.decideExternalChange(isDirty: state.isDirty, isOwnWrite: false,
                                                   diskChanged: true) {
        case .ignore:
            break
        case .reloadSilently:
            apply(surface: .missing(message))
        case .prompt:
            conflict = Conflict(incomingText: "", incomingMTime: nil, fileMissing: true)
        }
    }

    private func apply(surface: EditorDocument.Surface) {
        self.surface = surface
        if case .text(let text) = surface {
            commit(EditorDocument.State(diskText: text))
        } else {
            commit(nil)
        }
        conflict = nil
    }

    private func commit(_ state: EditorDocument.State?) {
        self.state = state
        isDirty = state?.isDirty ?? false
    }
}
