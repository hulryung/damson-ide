import Foundation

/// UI-free editor document policy: dirty tracking and external-change resolution.
///
/// The workbench pane is a client of this type. Decisions live here so they can
/// be unit-tested without AppKit or SwiftUI.
public enum EditorDocument: Sendable {
    public enum Surface: Equatable, Sendable {
        case text(String)
        case binary(byteLength: Int, isImage: Bool, mimeType: String?, imageBase64: String?)
        /// A perfectly good file whose bytes are not UTF-8 (Latin-1, UTF-16, a binary
        /// tail with no NUL in the head). Distinct from `.binary` because the pane owes
        /// the user a different sentence: this one *looks* like text and isn't.
        case notUTF8(byteLength: Int)
        case tooLarge
        case missing(String)
    }

    /// Why a save was refused. Every refusal carries a code so the pane, a log line, or
    /// a test names the reason instead of matching prose — and so ⌘S on a file the
    /// editor cannot represent says something rather than quietly doing nothing.
    public enum SaveRefusal: Equatable, Sendable {
        case notUTF8(byteLength: Int)
        case notText(byteLength: Int, isImage: Bool)
        case tooLarge
        case notLoaded(String)

        public var code: String {
            switch self {
            case .notUTF8: return "not_utf8"
            case .notText: return "not_text"
            case .tooLarge: return "file_too_large"
            case .notLoaded: return "not_loaded"
            }
        }

        public var message: String {
            switch self {
            case .notUTF8(let bytes):
                return "This file's \(bytes) bytes are not UTF-8 text. Saving would rewrite "
                     + "every byte the editor could not decode, so it was not saved."
            case .notText(let bytes, let isImage):
                return "This \(isImage ? "image" : "binary file") is \(bytes) bytes of content "
                     + "the editor cannot represent as text, so it was not saved."
            case .tooLarge:
                return "This file is larger than the editor's preview budget, so what is on "
                     + "screen is not the whole file and saving would truncate it."
            case .notLoaded(let detail):
                return "Nothing to save: \(detail)"
            }
        }

        /// `code — message`, the line a pane renders so a refusal is never a silent no-op.
        public var displayText: String { "\(code) — \(message)" }
    }

    public enum ExternalAction: Equatable, Sendable {
        case ignore
        case reloadSilently
        case prompt
    }

    public struct State: Equatable, Sendable {
        public var diskText: String
        public var draft: String
        public var lastWrittenText: String?
        public var lastWriteMTime: Double?

        public init(diskText: String, draft: String? = nil,
                    lastWrittenText: String? = nil, lastWriteMTime: Double? = nil) {
            self.diskText = diskText
            self.draft = draft ?? diskText
            self.lastWrittenText = lastWrittenText
            self.lastWriteMTime = lastWriteMTime
        }

        /// Byte-level, not `==`. Swift compares Strings by canonical equivalence, so a
        /// precomposed "é" and its decomposed form are equal while their UTF-8 differs —
        /// and what we write is the UTF-8. Comparing text would report such an edit clean
        /// and drop it on the floor at save time.
        public var isDirty: Bool { !EditorDocument.bytesEqual(draft, diskText) }
    }

    /// Do these two strings encode to the same UTF-8 bytes? The count check is O(1) for
    /// native strings, so the common "unchanged" case never walks the buffer.
    public static func bytesEqual(_ a: String, _ b: String) -> Bool {
        a.utf8.count == b.utf8.count && a.utf8.elementsEqual(b.utf8)
    }

    public static func surface(from preview: FilePreview) -> Surface {
        // A truncated preview is not the file. It never becomes an editable buffer,
        // because saving one writes the prefix over the whole file.
        if preview.truncated { return .tooLarge }
        if preview.notTextReason == .notUTF8 {
            return .notUTF8(byteLength: preview.byteLength)
        }
        if preview.isBinary || preview.isImage {
            return .binary(
                byteLength: preview.byteLength,
                isImage: preview.isImage,
                mimeType: preview.mimeType,
                imageBase64: preview.isImage ? preview.content : nil)
        }
        return .text(preview.content)
    }

    /// Nil when this surface may be saved; otherwise the typed reason it may not.
    ///
    /// Only `.text` is ever a faithful, complete in-memory copy of the file — every other
    /// surface is a *description* of one, and writing a description back is the corruption
    /// this wave exists to stop.
    public static func saveRefusal(for surface: Surface) -> SaveRefusal? {
        switch surface {
        case .text:
            return nil
        case .notUTF8(let bytes):
            return .notUTF8(byteLength: bytes)
        case .binary(let bytes, let isImage, _, _):
            return .notText(byteLength: bytes, isImage: isImage)
        case .tooLarge:
            return .tooLarge
        case .missing(let message):
            return .notLoaded(message)
        }
    }

    public static func surface(from error: FileServiceError) -> Surface {
        if error.code == "file_too_large" { return .tooLarge }
        return .missing(error.message)
    }

    /// A watcher event caused by our own ⌘S. Matching the bytes we just wrote
    /// is authoritative; mtime is a fallback for the same-content race.
    public static func isOwnWrite(incomingText: String, state: State, incomingMTime: Double?) -> Bool {
        if let written = state.lastWrittenText, bytesEqual(incomingText, written) {
            return true
        }
        if let incomingMTime, let last = state.lastWriteMTime,
           abs(incomingMTime - last) <= 0.0015 {
            return true
        }
        return false
    }

    public static func decideExternalChange(isDirty: Bool, isOwnWrite: Bool,
                                            diskChanged: Bool) -> ExternalAction {
        if isOwnWrite || !diskChanged { return .ignore }
        return isDirty ? .prompt : .reloadSilently
    }

    public static func applyEdit(_ state: State, draft: String) -> State {
        var next = state
        next.draft = draft
        return next
    }

    public static func applySave(_ state: State, written: String, mtime: Double) -> State {
        State(diskText: written, draft: written, lastWrittenText: written, lastWriteMTime: mtime)
    }

    public static func applyReload(_ state: State, diskText: String, mtime: Double?) -> State {
        State(diskText: diskText, draft: diskText,
              lastWrittenText: state.lastWrittenText,
              lastWriteMTime: mtime ?? state.lastWriteMTime)
    }

    /// Remember the new disk bytes so later identical events do not re-prompt,
    /// but keep the user's draft. Dirty iff the draft still differs.
    public static func applyKeepMine(_ state: State, diskText: String, mtime: Double?) -> State {
        var next = state
        next.diskText = diskText
        if let mtime { next.lastWriteMTime = mtime }
        return next
    }

    /// 1-indexed line/column at a UTF-16 offset, matching `NSTextView` caret math.
    public static func caret(in text: String, location: Int) -> (line: Int, column: Int) {
        let ns = text as NSString
        let clamped = max(0, min(location, ns.length))
        var line = 1
        var column = 1
        var index = 0
        while index < clamped {
            if ns.character(at: index) == 10 {
                line += 1
                column = 1
            } else {
                column += 1
            }
            index += 1
        }
        return (line, column)
    }
}
