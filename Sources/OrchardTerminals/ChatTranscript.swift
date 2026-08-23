import Foundation

/// One row in the native-chat projection of an agent-status stream.
///
/// Chat view-mode is an overlay on the live PTY, not a second session. The
/// transcript is derived only from `AgentStatusSnapshot` (user prompt, last
/// completed assistant message, `working | permission | idle` markers) — never
/// from a grid scrape.
public struct ChatTranscriptItem: Equatable, Sendable, Identifiable {
    public enum Role: String, Equatable, Sendable {
        case user
        case assistant
        case marker
    }

    public let id: String
    public let role: Role
    public let text: String
    /// Snapshot `updatedAt` (ms epoch) for the event that produced this row.
    public let timestamp: Double
    /// Set on marker rows; nil for user/assistant prose.
    public let projection: AgentRuntimeProjection?

    public init(id: String, role: Role, text: String, timestamp: Double,
                projection: AgentRuntimeProjection? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.projection = projection
    }
}

/// Maximum rows kept per pane so a long agent session cannot grow the overlay
/// without bound. Oldest rows drop first.
public let chatTranscriptHistoryMax = 80

/// Folds a stream of `AgentStatusSnapshot`s into a bounded chat transcript.
///
/// Repeat snapshots are common (the status stream re-emits the cached prompt on
/// every tick). The projector treats an unchanged prompt / completed assistant
/// / projection as silence, so the UI does not duplicate bubbles.
public struct ChatTranscriptProjector: Equatable, Sendable {
    private var lastPrompt = ""
    private var lastCompletedAssistant = ""
    private var lastProjection: AgentRuntimeProjection?
    private var sawProjection = false
    private var items: [ChatTranscriptItem] = []
    private var seq = 0

    public init() {}

    public var transcript: [ChatTranscriptItem] { items }

    /// Ingest one snapshot and return the bounded transcript (newest last).
    @discardableResult
    public mutating func apply(_ snapshot: AgentStatusSnapshot) -> [ChatTranscriptItem] {
        let timestamp = snapshot.updatedAt
        let prompt = snapshot.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty, prompt != lastPrompt {
            lastPrompt = prompt
            append(.user, text: prompt, timestamp: timestamp)
        }

        let completed = snapshot.lastCompletedAssistantMessage?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !completed.isEmpty, completed != lastCompletedAssistant {
            lastCompletedAssistant = completed
            append(.assistant, text: completed, timestamp: timestamp)
        }

        if let projection = snapshot.projection,
           projection == .working || projection == .permission || projection == .idle,
           !sawProjection || projection != lastProjection {
            sawProjection = true
            lastProjection = projection
            append(.marker, text: Self.label(for: projection), timestamp: timestamp,
                   projection: projection)
        }

        if items.count > chatTranscriptHistoryMax {
            items.removeFirst(items.count - chatTranscriptHistoryMax)
        }
        return items
    }

    private mutating func append(_ role: ChatTranscriptItem.Role, text: String,
                                 timestamp: Double,
                                 projection: AgentRuntimeProjection? = nil) {
        seq += 1
        items.append(ChatTranscriptItem(
            id: "\(role.rawValue)-\(seq)",
            role: role,
            text: text,
            timestamp: timestamp,
            projection: projection))
    }

    public static func label(for projection: AgentRuntimeProjection) -> String {
        switch projection {
        case .working: return "Working"
        case .permission: return "Needs permission"
        case .idle: return "Idle"
        }
    }
}
