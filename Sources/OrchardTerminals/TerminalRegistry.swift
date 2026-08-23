import Foundation
import Combine

/// One registered terminal: the two-identity model plus everything the service tracks
/// per pane.
///
/// Identity layers (all of them matter — rebuild checklist #1):
///   • `handle` (`term_<uuid>`) — runtime-scoped and **remintable**. A superseded
///     handle answers `terminal_handle_stale`; callers re-list and use only the
///     replacement, never both.
///   • `paneKey` (`"<tabId>:<leafUUID>"`) — durable. Survives handle reminting and PTY
///     respawns; orchestration authority keys on it, not the handle.
///   • `incarnation` — respawn counter for the pane's PTY channel (host-issued proof
///     material for dispatch authority).
@MainActor
public final class TerminalRecord {
    public let paneKey: String
    public private(set) var handle: String
    public private(set) var incarnation: Int = 1
    public let worktreeId: String?
    public var title: String?
    public let engine: AgentEngine
    public let createdAt = Date()
    /// The create spec, retained so a respawn can re-run the factory for this pane.
    let spec: TerminalCreateSpec

    public private(set) var session: TerminalSession
    public private(set) var agentSession: AgentSession

    /// Accumulated parsed-text stream (the `read` default source). Pane-scoped: it
    /// survives respawns so the pane's history reads continuously.
    var buffer = TerminalStreamBuffer()
    let tracker = AgentStatusTracker()

    public private(set) var lastOutputAt: Date?
    /// Set once the PTY child is gone (process exit or deliberate close).
    public internal(set) var exited = false
    public internal(set) var exitCode: Int32?

    /// Pending `terminal wait` continuations, resolved/rejected by state transitions.
    struct Waiter {
        let condition: TerminalWaitCondition
        let continuation: CheckedContinuation<TerminalWaitResult, Error>
    }
    var waiters: [UUID: Waiter] = [:]

    /// Live agent-status stream subscribers.
    var statusContinuations: [UUID: AsyncStream<AgentStatusSnapshot>.Continuation] = [:]

    /// Per-PTY submission serialization (rebuild checklist #6: injections must not
    /// interleave at their await points).
    let sendGate = SerialGate()

    /// Once-only guard for the initial `.typeWhenIdle` prompt delivery.
    var initialPromptStarted = false

    /// Once-only guard for the T11 `onTerminalExit` event (per pane incarnation).
    var exitNotified = false

    private var cancellables = Set<AnyCancellable>()

    init(handle: String, spec: TerminalCreateSpec, engine: AgentEngine,
         session: TerminalSession, agentSession: AgentSession) {
        self.paneKey = spec.paneKey
        self.handle = handle
        self.worktreeId = spec.worktreeId
        self.title = spec.title
        self.engine = engine
        self.spec = spec
        self.session = session
        self.agentSession = agentSession
        attach(session: session)
    }

    /// Whether an agent process is live in this terminal. Drives the `no-agent` send
    /// refusal and nils the status projection for plain shells.
    public var isRunningAgent: Bool {
        engine.usesLongRunningTUI && !exited && !session.processExited
    }

    public var connected: Bool { !exited && !session.processExited }

    /// Subscribe this record's stream buffer and activity clock to a session's output.
    private func attach(session: TerminalSession) {
        session.outputEvents
            .sink { [weak self] event in
                guard let self else { return }
                switch event {
                case .text(let s):
                    self.buffer.appendText(s)
                case .control(let byte):
                    self.buffer.appendControl(byte)
                case .osc:
                    break
                }
            }
            .store(in: &cancellables)
        // The raw byte stream is the activity clock: it fires for every output chunk,
        // including repaint-only bursts (pure CSI) that yield no text/control events —
        // so previews/staleness read correctly without piggybacking on `gridChanged`,
        // which also fires for local mutations like a resize.
        session.outputBytes
            .sink { [weak self] _ in self?.lastOutputAt = Date() }
            .store(in: &cancellables)
    }

    /// Swap in a freshly spawned PTY for this pane (respawn): new handle, next
    /// incarnation, fresh sessions; the stream buffer and status record carry over.
    func adopt(handle: String, session: TerminalSession, agentSession: AgentSession) {
        cancellables.removeAll()
        self.handle = handle
        self.incarnation += 1
        self.session = session
        self.agentSession = agentSession
        self.exited = false
        self.exitCode = nil
        self.exitNotified = false          // the new incarnation can exit again
        self.initialPromptStarted = true   // the task prompt belongs to incarnation 1
        attach(session: session)
    }

    /// Re-issue this pane's handle without touching the process (registry-driven).
    func remint(handle: String) {
        self.handle = handle
    }

    func summary() -> TerminalSummary {
        TerminalSummary(
            handle: handle,
            paneKey: paneKey,
            incarnation: incarnation,
            worktreeId: worktreeId,
            title: title,
            engine: engine.id,
            connected: connected,
            writable: connected,
            lastOutputAt: lastOutputAt.map { $0.timeIntervalSince1970 * 1000 },
            preview: buffer.previewTail,
            agentState: isRunningAgent ? tracker.currentState.runtimeProjection : nil)
    }

    func statusSnapshot() -> AgentStatusSnapshot {
        tracker.snapshot(handle: handle, paneKey: paneKey, worktreeId: worktreeId,
                         title: title, agentType: engine.agentType,
                         isRunningAgent: isRunningAgent)
    }
}

/// The terminal registry: mints identities, owns the records, and answers lookups with
/// the typed stale/not-found split callers must branch on.
@MainActor
public final class TerminalRegistry {
    /// Records by durable paneKey.
    private var records: [String: TerminalRecord] = [:]
    /// Live handle → paneKey.
    private var livePanes: [String: String] = [:]
    /// Superseded handle → paneKey, so a stale handle answers `terminal_handle_stale`
    /// with its replacement instead of pretending the terminal never existed.
    private var stalePanes: [String: String] = [:]

    /// Nonisolated so it can be a default argument (all stored state has defaults).
    public nonisolated init() {}

    static func mintHandle() -> String {
        "term_" + UUID().uuidString.lowercased()
    }

    static func mintPaneKey() -> String {
        "tab_\(UUID().uuidString.lowercased()):\(UUID().uuidString.lowercased())"
    }

    func register(_ record: TerminalRecord) {
        records[record.paneKey] = record
        livePanes[record.handle] = record.paneKey
    }

    /// Resolve a handle to its record, or throw the typed reason it can't be used.
    public func resolve(_ handle: String) throws -> TerminalRecord {
        if let paneKey = livePanes[handle], let record = records[paneKey] {
            return record
        }
        if let paneKey = stalePanes[handle] {
            throw TerminalServiceError.handleStale(handle: handle,
                                                   replacement: records[paneKey]?.handle)
        }
        throw TerminalServiceError.notFound(handle: handle)
    }

    public func record(forPaneKey paneKey: String) -> TerminalRecord? {
        records[paneKey]
    }

    /// Re-issue a pane's handle. The old handle keeps answering — as
    /// `terminal_handle_stale` pointing at the replacement.
    @discardableResult
    public func remintHandle(paneKey: String) throws -> TerminalRecord {
        guard let record = records[paneKey] else {
            throw TerminalServiceError.notFound(handle: paneKey)
        }
        retireHandle(record.handle, paneKey: paneKey)
        let newHandle = Self.mintHandle()
        record.remint(handle: newHandle)
        livePanes[newHandle] = paneKey
        return record
    }

    /// Move a handle from live to stale (remint/respawn bookkeeping).
    func retireHandle(_ handle: String, paneKey: String) {
        livePanes.removeValue(forKey: handle)
        stalePanes[handle] = paneKey
    }

    func unregister(_ record: TerminalRecord) {
        records.removeValue(forKey: record.paneKey)
        livePanes.removeValue(forKey: record.handle)
        // Drop the pane's stale aliases too: a closed terminal is not-found, not stale.
        stalePanes = stalePanes.filter { $0.value != record.paneKey }
    }

    public func list(worktreeId: String? = nil) -> [TerminalRecord] {
        records.values
            .filter { worktreeId == nil || $0.worktreeId == worktreeId }
            .sorted { $0.createdAt < $1.createdAt }
    }
}

/// An ordered async gate: operations run strictly in submission order, one at a time,
/// even across their internal `await`s. Used per-PTY so two concurrent `send`s can't
/// interleave their chunked writes (checklist #6's "serialize submissions per-PTY").
@MainActor
final class SerialGate {
    private var tail: Task<Void, Never>?

    func run<T: Sendable>(_ op: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task { @MainActor () throws -> T in
            await previous?.value
            return try await op()
        }
        tail = Task { @MainActor in _ = try? await task.value }
        return try await task.value
    }
}
