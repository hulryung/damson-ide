import Foundation
import OrchardRuntime

/// In-memory editor documents keyed by `(workspace root, relative path)`, plus
/// one `FileWatcher` per root so a save or an external write lands on every
/// open buffer of that tree.
@MainActor
final class EditorSessionStore {
    private var documents: [String: EditorDocumentController] = [:]
    private var watchers: [String: FileWatcher] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    func controller(root: URL, path: String, files: FileService) -> EditorDocumentController {
        let key = sessionKey(root: root, path: path)
        if let existing = documents[key] { return existing }
        let doc = EditorDocumentController(root: root, relativePath: path, files: files)
        documents[key] = doc
        ensureWatch(root: root)
        doc.load()
        return doc
    }

    func document(root: URL, path: String) -> EditorDocumentController? {
        documents[sessionKey(root: root, path: path)]
    }

    func drop(root: URL, path: String) {
        documents[sessionKey(root: root, path: path)] = nil
        let prefix = rootKey(root) + "\u{1e}"
        if !documents.keys.contains(where: { $0.hasPrefix(prefix) }) {
            stopWatch(root: root)
        }
    }

    @discardableResult
    func save(root: URL, path: String) -> Bool {
        documents[sessionKey(root: root, path: path)]?.save() ?? false
    }

    private func sessionKey(root: URL, path: String) -> String {
        rootKey(root) + "\u{1e}" + path
    }

    private func rootKey(_ root: URL) -> String {
        root.standardizedFileURL.path
    }

    private func ensureWatch(root: URL) {
        let key = rootKey(root)
        if watchers[key] != nil { return }
        let watcher = FileWatcher()
        watchers[key] = watcher
        let stream = watcher.events()
        tasks[key] = Task { [weak self] in
            for await batch in stream {
                if Task.isCancelled { break }
                await MainActor.run { self?.fanout(root: root, batch: batch) }
            }
        }
        do {
            try watcher.start(root: root)
        } catch {
            NSLog("orchard: editor watcher failed: %@", String(describing: error))
        }
    }

    private func fanout(root: URL, batch: FileWatchBatch) {
        let prefix = rootKey(root) + "\u{1e}"
        for (key, doc) in documents where key.hasPrefix(prefix) {
            doc.handleWatch(batch)
        }
    }

    private func stopWatch(root: URL) {
        let key = rootKey(root)
        tasks[key]?.cancel()
        tasks[key] = nil
        watchers[key]?.stop()
        watchers[key] = nil
    }
}
