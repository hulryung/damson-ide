import Foundation

/// UI-free editor document policy: dirty tracking and external-change resolution.
///
/// The workbench pane is a client of this type. Decisions live here so they can
/// be unit-tested without AppKit or SwiftUI.
public enum EditorDocument: Sendable {
    public enum Surface: Equatable, Sendable {
        case text(String)
        case binary(byteLength: Int, isImage: Bool, mimeType: String?, imageBase64: String?)
        case tooLarge
        case missing(String)
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

        public var isDirty: Bool { draft != diskText }
    }

    public static func surface(from preview: FilePreview) -> Surface {
        if preview.isBinary || preview.isImage {
            return .binary(
                byteLength: preview.byteLength,
                isImage: preview.isImage,
                mimeType: preview.mimeType,
                imageBase64: preview.isImage ? preview.content : nil)
        }
        return .text(preview.content)
    }

    public static func surface(from error: FileServiceError) -> Surface {
        if error.code == "file_too_large" { return .tooLarge }
        return .missing(error.message)
    }

    /// A watcher event caused by our own ⌘S. Matching the bytes we just wrote
    /// is authoritative; mtime is a fallback for the same-content race.
    public static func isOwnWrite(incomingText: String, state: State, incomingMTime: Double?) -> Bool {
        if let written = state.lastWrittenText, incomingText == written {
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
