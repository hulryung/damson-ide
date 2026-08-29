import Foundation

/// Where a destructive action came from.
///
/// This is the field the log exists for. On 2026-08-29 three repositories lost
/// their registration and every worktree record, unread flag, display name and
/// lineage entry that belonged to them. The *what* was recoverable from the
/// wreckage — the surviving data had no orphans, which is `removeRepo`'s
/// fingerprint — but the *who* was not, because nothing recorded it. That is why
/// this is a required parameter and not an optional one with a friendly default:
/// a caller that cannot say where it came from should not compile.
public enum ActionOrigin: String, Codable, Equatable, Sendable {
    /// A person clicking in the Orchard window.
    case gui
    /// `orchard <verb>` — the CLI, whoever or whatever ran it.
    case cli
    /// The runtime acting on its own behalf (automations, cleanup).
    case runtime
    /// A test. Never written by shipping code paths.
    case test

    public var label: String {
        switch self {
        case .gui: return "the Orchard window"
        case .cli: return "the orchard CLI"
        case .runtime: return "the runtime itself"
        case .test: return "a test"
        }
    }
}

/// One destructive act, as it happened.
public struct DestructiveAction: Codable, Equatable, Sendable {
    /// What was done, as a stable slug: `repo_removed`, `worktree_deleted`, …
    public var action: String
    public var origin: ActionOrigin
    public var at: Date
    /// Stable id of the thing acted on, where there is one.
    public var targetID: String?
    /// What a person would call it.
    public var targetName: String?
    public var targetPath: String?
    /// What went with it — `["worktreeMeta": 4, "lineage": 2]`. Counts rather
    /// than contents: the log must not become a second copy of the data, and a
    /// count is enough to tell "this removed a populated repo" from "this
    /// removed an empty one".
    public var discarded: [String: Int]

    public init(action: String, origin: ActionOrigin, at: Date,
                targetID: String? = nil, targetName: String? = nil,
                targetPath: String? = nil, discarded: [String: Int] = [:]) {
        self.action = action
        self.origin = origin
        self.at = at
        self.targetID = targetID
        self.targetName = targetName
        self.targetPath = targetPath
        self.discarded = discarded
    }

    /// One line a person can read without a decoder.
    public var sentence: String {
        let name = targetName ?? targetID ?? targetPath ?? "something unnamed"
        let extras = discarded
            .filter { $0.value > 0 }
            .sorted { $0.key < $1.key }
            .map { "\($0.value) \($0.key)" }
            .joined(separator: ", ")
        let tail = extras.isEmpty ? "" : " (with \(extras))"
        return "\(action) \(name)\(tail) — from \(origin.label)"
    }
}

/// An append-only record of the actions that cannot be undone.
///
/// JSONL beside `orchard-data.json`, one object per line, so a half-written line
/// costs the last entry and not the file. Deliberately *not* inside
/// `orchard-data.json`: the whole point is to survive the operation that rewrites
/// it, and a log stored in the thing it audits is no log at all.
///
/// Never load-bearing. A failure to write is swallowed on purpose — losing an
/// audit line must never turn into a failed removal, because that would make the
/// safety feature the thing that breaks the app.
public final class DestructiveActionLog: @unchecked Sendable {
    public let url: URL
    /// Entries kept before the oldest are dropped. Generous: at one destructive
    /// act a day this is years, and the file is a few hundred KB at worst.
    public let limit: Int
    private let lock = NSLock()
    private let now: () -> Date

    public init(url: URL, limit: Int = 2000, now: @escaping () -> Date = Date.init) {
        self.url = url
        self.limit = limit
        self.now = now
    }

    /// Beside the data file it audits.
    public static func beside(_ dataURL: URL) -> DestructiveActionLog {
        DestructiveActionLog(url: dataURL
            .deletingLastPathComponent()
            .appendingPathComponent("orchard-audit.jsonl"))
    }

    public func record(_ action: String, origin: ActionOrigin,
                       targetID: String? = nil, targetName: String? = nil,
                       targetPath: String? = nil, discarded: [String: Int] = [:]) {
        append(DestructiveAction(action: action, origin: origin, at: now(),
                                 targetID: targetID, targetName: targetName,
                                 targetPath: targetPath, discarded: discarded))
    }

    public func append(_ entry: DestructiveAction) {
        lock.lock()
        defer { lock.unlock() }
        guard let line = try? JSONBridge.encoder.encode(entry),
              let text = String(data: line, encoding: .utf8) else { return }
        let payload = text.replacingOccurrences(of: "\n", with: " ") + "\n"
        guard let bytes = payload.data(using: .utf8) else { return }

        let manager = FileManager.default
        try? manager.createDirectory(at: url.deletingLastPathComponent(),
                                     withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: bytes)
        } else {
            try? bytes.write(to: url)
        }
        trimIfNeeded()
    }

    /// Read the log back, oldest first. Unparseable lines are skipped rather than
    /// failing the read: one corrupt line must not hide the rest of the history.
    public func entries() -> [DestructiveAction] {
        lock.lock()
        defer { lock.unlock() }
        return Self.parse(url: url)
    }

    private static func parse(url: URL) -> [DestructiveAction] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? JSONBridge.decoder.decode(DestructiveAction.self, from: data)
        }
    }

    private func trimIfNeeded() {
        let kept = Self.parse(url: url)
        guard kept.count > limit else { return }
        let tail = kept.suffix(limit)
        let lines = tail.compactMap { entry -> String? in
            guard let data = try? JSONBridge.encoder.encode(entry) else { return nil }
            return String(data: data, encoding: .utf8)?
                .replacingOccurrences(of: "\n", with: " ")
        }
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true,
                                                          encoding: .utf8)
    }
}
