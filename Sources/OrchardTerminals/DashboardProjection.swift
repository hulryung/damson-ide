import Foundation
import OrchardCore

/// Kanban column for the agent dashboard (Orca `DashboardBucket`).
public enum DashboardBucket: String, CaseIterable, Sendable, Hashable, Identifiable {
    case attention, working, done, idle
    public var id: String { rawValue }
}

/// Precise live-state glyph. Kept distinct from `DashboardBucket` so a done
/// card that has been acknowledged can sit in idle while still reading as done
/// internally (Orca `dashboardCardDisplayState`).
public enum DashboardDotState: String, Sendable, Hashable {
    case working, blocked, waiting, done, idle
}

/// UI-free projection of an `AgentStatusSnapshot` onto the dashboard board.
///
/// Observation only — bucketing never writes orchestration or terminal state.
/// Matches Orca's `dashboard-card-bucket` + `dashboardCardDisplayState`:
/// permission/blocked/waiting → attention; a `done` entry stays in done until
/// the user acknowledges it, then settles to idle.
public enum DashboardProjection {

    /// Orca `DASHBOARD_MAX_LABEL_LENGTH` — unbounded OSC titles cannot cost a
    /// card its place on the board.
    public static let maxLabelLength = 1_024

    /// Per-column cap so a huge fleet cannot blank the dashboard (inventory §6).
    public static let maxCardsPerBucket = 40

    /// Map a status-entry snapshot to the precise dot (Orca `row.state`).
    public static func dotState(from snapshot: AgentStatusSnapshot) -> DashboardDotState {
        switch snapshot.state {
        case .working: return .working
        case .blocked: return .blocked
        case .waiting: return .waiting
        case .done: return .done
        }
    }

    /// Fallback when the status stream has not yet published a snapshot.
    /// `idle`/`finished`/`errored` all record as status-entry `done` (see
    /// `AgentRuntimeState.statusState`); display + unseen decide the bucket.
    public static func dotState(runtime: AgentRuntimeState) -> DashboardDotState {
        switch runtime {
        case .starting, .working: return .working
        case .awaitingApproval: return .blocked
        case .awaitingInput: return .waiting
        case .idle, .finished, .errored: return .done
        }
    }

    /// Completed agents stay in `done` until acknowledged (`unseen`), then settle to idle.
    public static func displayState(dotState: DashboardDotState, unseen: Bool) -> DashboardDotState {
        (dotState == .done && !unseen) ? .idle : dotState
    }

    public static func bucket(for displayState: DashboardDotState) -> DashboardBucket {
        switch displayState {
        case .working: return .working
        case .done: return .done
        case .idle: return .idle
        case .blocked, .waiting: return .attention
        }
    }

    public static func bucket(snapshot: AgentStatusSnapshot, unseen: Bool) -> DashboardBucket {
        bucket(for: displayState(dotState: dotState(from: snapshot), unseen: unseen))
    }

    public static func bucket(runtime: AgentRuntimeState, unseen: Bool) -> DashboardBucket {
        bucket(for: displayState(dotState: dotState(runtime: runtime), unseen: unseen))
    }

    public static func glyph(for dotState: DashboardDotState) -> String {
        switch dotState {
        case .working: return "⟳"
        case .blocked: return "⚠"
        case .waiting: return "✎"
        case .done: return "✓"
        case .idle: return "●"
        }
    }

    /// Elapsed time in the current state. `stateStartedAtMs` is ms epoch, matching
    /// `AgentStatusSnapshot.stateStartedAt`.
    public static func elapsedInterval(stateStartedAtMs: Double, now: Date = Date()) -> TimeInterval {
        max(0, now.timeIntervalSince1970 - stateStartedAtMs / 1000)
    }

    public static func formatElapsed(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }

    /// One-line card body: prefer the live prompt, then the last assistant line.
    public static func detailLine(prompt: String, lastAssistant: String?) -> String? {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPrompt.isEmpty { return trimmedPrompt }
        let assistant = lastAssistant?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return assistant.isEmpty ? nil : assistant
    }

    /// Truncate a display label so an unbounded name cannot drop the card.
    public static func boundedLabel(_ value: String) -> String {
        if value.count <= maxLabelLength { return value }
        return String(value.prefix(maxLabelLength))
    }

    public static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `paneKey` is `"<tabId>:<leafUUID>"`. First colon splits the two sides.
    public static func parsePaneKey(_ paneKey: String) -> (tabId: String, leafId: String)? {
        guard let idx = paneKey.firstIndex(of: ":") else { return nil }
        let tabId = String(paneKey[..<idx])
        let leafId = String(paneKey[paneKey.index(after: idx)...])
        guard !tabId.isEmpty, !leafId.isEmpty else { return nil }
        return (tabId, leafId)
    }

    /// Prefer an explicit task title, then the live user prompt (Orca `rowTask`).
    public static func task(title: String?, prompt: String?) -> String {
        if let title = nonempty(title) { return boundedLabel(title) }
        if let prompt = nonempty(prompt) { return boundedLabel(prompt) }
        return ""
    }

    /// When the agent last entered `done`, or nil if it never finished.
    public static func lastEnteredDoneAt(snapshot: AgentStatusSnapshot?,
                                         dotState: DashboardDotState) -> Double? {
        if dotState == .done, let snapshot {
            return snapshot.stateStartedAt
        }
        if let history = snapshot?.stateHistory.reversed().first(where: { $0.state == .done }) {
            return history.startedAt
        }
        return nil
    }

    /// Pending-question text is only meaningful on the attention column.
    public static func askSummary(bucket: DashboardBucket,
                                  interactivePrompt: String?,
                                  toolName: String? = nil) -> String? {
        guard bucket == .attention else { return nil }
        if let prompt = nonempty(interactivePrompt) {
            return boundedLabel(extractAskText(prompt) ?? firstLine(prompt))
        }
        if let tool = nonempty(toolName) { return boundedLabel(tool) }
        return nil
    }

    /// Project one agent onto a dashboard card. Observation only.
    public static func card(from input: DashboardCardInput) -> DashboardCard {
        let snapshot = input.snapshot
        let paneKey = boundedLabel(
            nonempty(input.paneKey) ?? nonempty(snapshot?.paneKey) ?? input.agentID.uuidString)
        let agentType = boundedLabel(
            nonempty(snapshot?.agentType) ?? nonempty(input.agentType) ?? "agent")
        let rawDot = snapshot.map(dotState(from:)) ?? dotState(runtime: input.runtime)
        let display = displayState(dotState: rawDot, unseen: input.unseen)
        let bucket = Self.bucket(for: display)
        let lastUser = nonempty(snapshot?.prompt) ?? nonempty(input.taskPrompt)
        let lastAgent = nonempty(snapshot?.lastAssistantMessage)
            ?? nonempty(snapshot?.lastCompletedAssistantMessage)
        let task = self.task(title: input.taskTitle, prompt: lastUser)
        let parsed = parsePaneKey(paneKey)
        let startedAt = input.startedAtMs
        let finishedAt = input.finishedAtMs
            ?? lastEnteredDoneAt(snapshot: snapshot, dotState: rawDot)
        let stateChangedAt = snapshot?.stateStartedAt ?? startedAt
        let ask = askSummary(
            bucket: bucket,
            interactivePrompt: input.interactivePrompt ?? snapshot?.interactivePrompt,
            toolName: snapshot?.toolName)
        let parent = nonempty(input.parentPaneKey).map(boundedLabel)
        return DashboardCard(
            paneKey: paneKey,
            agentType: agentType,
            bucket: bucket,
            dotState: rawDot,
            task: task,
            lastUserMessage: lastUser.map(boundedLabel),
            lastAgentMessage: lastAgent.map(boundedLabel),
            focus: DashboardFocusRoute(
                agentID: input.agentID,
                paneKey: paneKey,
                repoId: input.repoId,
                worktreeId: nonempty(input.worktreeId) ?? nonempty(snapshot?.worktreeId),
                tabId: input.tabId ?? parsed?.tabId,
                leafId: input.leafId ?? parsed?.leafId),
            parentPaneKey: parent,
            workspaceName: boundedLabel(input.workspaceName),
            workspaceStatusId: nonempty(input.workspaceStatusId),
            workspaceStatusLabel: input.workspaceStatusLabel.map(boundedLabel),
            startedAt: startedAt,
            finishedAt: finishedAt,
            stateChangedAt: stateChangedAt,
            unseen: input.unseen,
            askSummary: ask)
    }

    /// Bucket, sort (most recently moved first), and cap each column.
    public static func board(from inputs: [DashboardCardInput],
                             capPerBucket: Int = maxCardsPerBucket) -> DashboardBoard {
        let cap = max(0, capPerBucket)
        var byBucket: [DashboardBucket: [DashboardCard]] = [:]
        for input in inputs {
            let projected = card(from: input)
            byBucket[projected.bucket, default: []].append(projected)
        }
        var visible: [DashboardCard] = []
        var totals: [DashboardBucket: Int] = [:]
        var overflow: [DashboardBucket: Int] = [:]
        for bucket in DashboardBucket.allCases {
            let items = (byBucket[bucket] ?? [])
                .sorted { lhs, rhs in
                    if lhs.stateChangedAt != rhs.stateChangedAt {
                        return lhs.stateChangedAt > rhs.stateChangedAt
                    }
                    return lhs.paneKey < rhs.paneKey
                }
            totals[bucket] = items.count
            let capped = Array(items.prefix(cap))
            overflow[bucket] = max(0, items.count - capped.count)
            visible.append(contentsOf: capped)
        }
        return DashboardBoard(
            cards: visible, totalByBucket: totals,
            overflowByBucket: overflow, capPerBucket: cap)
    }

    private static func firstLine(_ value: String) -> String {
        value.split(whereSeparator: \.isNewline).first.map(String.init) ?? value
    }

    /// Pull a human question out of AskUserQuestion-shaped JSON when we can.
    private static func extractAskText(_ raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        if let dict = object as? [String: Any] {
            if let question = nonempty(dict["question"] as? String) { return question }
            if let header = nonempty(dict["header"] as? String) { return header }
            if let questions = dict["questions"] as? [[String: Any]],
               let question = nonempty(questions.first?["question"] as? String) {
                return question
            }
        }
        return nil
    }
}
