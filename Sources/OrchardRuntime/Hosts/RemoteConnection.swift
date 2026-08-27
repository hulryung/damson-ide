import Foundation

/// The name of one continuous span of contact with a host.
///
/// A counter alone would not be enough. Two runs of the runtime both start at 1, so
/// `build#1` from yesterday and `build#1` from this boot would compare equal and a
/// record from the first would silently claim continuity with the second. The `epoch`
/// is minted per `RemoteConnection` instance, which makes every generation label
/// unique for as long as anything can still be holding one.
///
/// The label is deliberately human-readable and greppable (`build#3.7a1c9f02`): it
/// appears in refusal copy, in pane records, and in `host connection --json`, and an
/// operator reading two of them must be able to see at a glance that they are not the
/// same span.
public struct RemoteConnectionGeneration: Codable, Equatable, Hashable, Sendable,
                                          CustomStringConvertible {
    /// Registered host name (the `ssh:<name>` suffix).
    public let host: String
    /// 1-based, monotonic within one `RemoteConnection`. Never reused, never reset.
    public let sequence: Int
    /// Per-`RemoteConnection` nonce, so a sequence number cannot repeat across
    /// runtime restarts.
    public let epoch: String

    public init(host: String, sequence: Int, epoch: String) {
        self.host = host
        self.sequence = sequence
        self.epoch = epoch
    }

    public var label: String { "\(host)#\(sequence).\(epoch)" }
    public var description: String { label }

    /// Parse a label back. Used where a generation travels as a string (a pane's
    /// create spec, a keeper record) rather than as a nested object.
    public static func parse(_ raw: String) -> RemoteConnectionGeneration? {
        guard let hash = raw.lastIndex(of: "#") else { return nil }
        let host = String(raw[raw.startIndex..<hash])
        let rest = raw[raw.index(after: hash)...]
        guard let dot = rest.firstIndex(of: ".") else { return nil }
        guard let sequence = Int(rest[rest.startIndex..<dot]), sequence > 0 else { return nil }
        let epoch = String(rest[rest.index(after: dot)...])
        guard !host.isEmpty, !epoch.isEmpty else { return nil }
        return RemoteConnectionGeneration(host: host, sequence: sequence, epoch: epoch)
    }
}

/// Where a host connection stands right now.
///
/// `lost` and `closed` are kept apart on purpose. `closed` is a decision somebody made
/// here; `lost` is contact ending on its own, which under rule 2 proves nothing about
/// the far side and must never read as a stop.
public enum RemoteConnectionState: Equatable, Sendable {
    /// Nothing has ever been opened on this host in this runtime.
    case never
    case open(RemoteConnectionGeneration)
    /// Contact ended without anybody deciding it should. Carries the generation that
    /// ended, because "which span ended" is the fact a caller needs.
    case lost(RemoteConnectionGeneration, reason: String)
    /// Closed here, deliberately.
    case closed(RemoteConnectionGeneration)

    public var generation: RemoteConnectionGeneration? {
        switch self {
        case .never: return nil
        case .open(let generation), .closed(let generation): return generation
        case .lost(let generation, _): return generation
        }
    }

    public var name: String {
        switch self {
        case .never: return "never"
        case .open: return "open"
        case .lost: return "lost"
        case .closed: return "closed"
        }
    }
}

/// A snapshot a verb can print. Deliberately flat and Codable — this is what
/// `host connection --json` answers with.
public struct RemoteConnectionStatus: Codable, Equatable, Sendable {
    public let host: String
    /// `never | open | lost | closed`.
    public let state: String
    /// The generation this state is about, as its label. nil only for `never`.
    public let generation: String?
    public let sequence: Int
    /// Whether commands on this connection actually share one `ssh` transport. False
    /// means multiplexing was unavailable and every command is its own connection —
    /// which is not a failure, but it *is* a different claim about continuity.
    public let multiplexed: Bool
    /// The OpenSSH control socket backing the current generation, when there is one.
    public let controlPath: String?
    public let openedAt: Double?
    public let endedAt: Double?
    /// Why contact ended, for `lost`.
    public let reason: String?
    /// One sentence of verdict-safe copy.
    public let note: String
}

/// What `acquire` decided.
public enum RemoteConnectionAcquisition: Sendable {
    /// Run the command. `generation` is nil when there is no durable connection to
    /// attribute the answer to (multiplexing unavailable); `options` are the extra
    /// `ssh` arguments that put the command onto the shared transport.
    case ready(generation: RemoteConnectionGeneration?, options: [String])
    /// Refused, and the refusal is the answer. Never downgraded into a run on some
    /// other generation.
    case refused(RemoteHostError)
}

/// A durable, generation-counted connection to one host, multiplexed over a single
/// OpenSSH `ControlMaster`.
///
/// Two things this buys, and they are the same thing seen from two sides.
///
/// **Cost.** Before this, every remote command was its own `ssh`: a TCP connect, a
/// key exchange and an authentication for a `git worktree list`. A remote worktree
/// listing is several such commands. They now share one transport.
///
/// **Meaning.** A shared transport is the first thing Orchard has ever had that could
/// be *the same connection* twice — and the moment that exists, the interesting
/// question is not "is it up" but "is it still the one you were talking about". The
/// generation counter answers that. It increments on every open, never on a reuse, and
/// the control socket path carries it, so a stale master from generation 3 physically
/// cannot serve generation 4. A caller that names a generation gets refused when that
/// generation has ended (`RemoteHostError.generationEnded`) rather than being answered
/// from the new one — because "the connection you meant is gone" and "here is an answer
/// from a connection you have never seen" are different facts, and only the first one
/// is true.
///
/// Rule 2 applies unchanged: losing the master is `unverifiable`, never a stop, and
/// nothing here ever concludes that anything on the far side ended.
public actor RemoteConnection {
    /// How long a master with no clients survives before OpenSSH retires it. Bounded
    /// so a leaked master cannot outlive the runtime that opened it by much.
    public static let defaultPersistSeconds = 120
    /// Ceiling on establishing the master. Short: a host that cannot authenticate
    /// quickly is a host whose *commands* would have been slow anyway, and the caller
    /// falls back to a direct connection rather than waiting.
    public static let defaultOpenTimeout: TimeInterval = 20
    /// How long an unfenced caller stops trying to open a master after one failure.
    public static let openRetryBackoff: TimeInterval = 30

    /// OpenSSH's stderr when the control socket is there but nothing is behind it. Its
    /// presence means the command did **not** travel on the multiplexed transport,
    /// whatever its exit status says.
    ///
    /// It only covers the *stale socket* case. When the file is simply gone — which is
    /// what a master's own exit leaves behind — OpenSSH says nothing at all and connects
    /// directly with a clean status (verified against a real `sshd`). That silence is
    /// why `verifyControlSocket` checks the file before every acquisition instead of
    /// trusting stderr to confess.
    static let controlSocketFallbackMarker = "control socket connect("

    public let host: HostRecord
    private let runner: HostCommandRunner
    private let controlDirectory: URL
    private let connectTimeoutSeconds: Int
    private let openTimeout: TimeInterval
    private let persistSeconds: Int
    private let fileManager: FileManager
    private let epoch: String

    private var state: RemoteConnectionState = .never
    private var sequence = 0
    private var controlPath: String?
    private var openedAt: Double?
    private var endedAt: Double?
    private var lossReason: String?
    /// Set once when the control path cannot be used at all, so the fallback is
    /// decided (and reported) once instead of being retried on every command.
    private var multiplexRefusal: String?
    /// When the last attempt to establish a master failed. A failed open must not be
    /// retried in front of every command — that would double the cost of talking to a
    /// host that is having a bad minute.
    private var openFailureAt: Double?
    private var opening: Task<RemoteConnectionAcquisition, Never>?

    public init(host: HostRecord,
                runner: HostCommandRunner = ProcessHostCommandRunner(),
                controlDirectory: URL,
                connectTimeoutSeconds: Int = 5,
                openTimeout: TimeInterval = RemoteConnection.defaultOpenTimeout,
                persistSeconds: Int = RemoteConnection.defaultPersistSeconds,
                fileManager: FileManager = .default,
                epoch: String = String(UUID().uuidString.replacingOccurrences(of: "-", with: "")
                    .lowercased().prefix(8))) {
        self.host = host
        self.runner = runner
        self.controlDirectory = controlDirectory
        self.connectTimeoutSeconds = connectTimeoutSeconds
        self.openTimeout = openTimeout
        self.persistSeconds = persistSeconds
        self.fileManager = fileManager
        self.epoch = epoch
    }

    public var hostName: String { host.name }

    public func currentState() -> RemoteConnectionState { state }

    /// The generation that is open right now, or nil. A `lost` or `closed` generation
    /// is deliberately not returned: it is not something a caller may still use.
    public func currentGeneration() -> RemoteConnectionGeneration? {
        if case .open(let generation) = state { return generation }
        return nil
    }

    public func status() -> RemoteConnectionStatus {
        verifyControlSocket()
        return RemoteConnectionStatus(
            host: host.name,
            state: state.name,
            generation: state.generation?.label,
            sequence: sequence,
            multiplexed: multiplexRefusal == nil,
            controlPath: { if case .open = state { return controlPath } else { return nil } }(),
            openedAt: openedAt,
            endedAt: endedAt,
            reason: lossReason,
            note: note())
    }

    // MARK: - Open / close

    /// Establish a fresh transport and mint the generation that names it.
    ///
    /// Always a *new* generation, even when the previous one is still open: reopening
    /// is by definition not continuing. Callers that want the existing one call
    /// `acquire` instead.
    @discardableResult
    public func open() async -> RemoteConnectionAcquisition {
        if let opening { return await opening.value }
        let task = Task { await performOpen() }
        opening = task
        let result = await task.value
        opening = nil
        return result
    }

    private func performOpen() async -> RemoteConnectionAcquisition {
        if case .open(let previous) = state {
            // Tear the old master down first. Leaving it behind would leave a socket
            // that answers for a generation nothing will ever ask about again. The old
            // generation is `closed`, not `lost` — somebody decided to reopen, and the
            // two readings are kept apart on every other surface too.
            await tearDownMaster(path: controlPath)
            state = .closed(previous)
            controlPath = nil
            endedAt = Date().timeIntervalSince1970 * 1000
        }
        guard multiplexRefusal == nil else {
            return .ready(generation: nil, options: [])
        }
        let next = sequence + 1
        guard let path = try? prepareControlPath(sequence: next) else {
            multiplexRefusal = "the control socket path for \(host.name) does not fit in "
                + "a unix socket address, so commands cannot share one connection"
            return .ready(generation: nil, options: [])
        }
        let argv = SSHCommand.controlMasterArgv(
            for: host, controlPath: path,
            connectTimeoutSeconds: connectTimeoutSeconds,
            persistSeconds: persistSeconds)
        let result = await runner.run(argv, timeout: openTimeout)
        switch SSHRunner.classify(result, host: host) {
        case .unverifiable(let reason):
            // Contact could not be made. This is not a failure of multiplexing, so it
            // does not disable it — the next attempt tries again — and it is emphatically
            // not evidence about anything running on the far side.
            // The state is left as it was — `never`, or the `closed` generation this
            // attempt was replacing. Overwriting it with `never` would erase *which*
            // span of contact ended, which is the fact a fenced caller is asking about.
            lossReason = reason
            openFailureAt = Date().timeIntervalSince1970 * 1000
            return .refused(.unverifiable(host: host.name,
                                          doing: "opening a connection", reason: reason))
        case .answered(let code, _, let stderr):
            guard code == 0 else {
                let detail = SSHRunner.firstLine(stderr) ?? "ssh exited \(code)"
                lossReason = detail
                openFailureAt = Date().timeIntervalSince1970 * 1000
                return .refused(RemoteHostError(
                    "connection_refused",
                    "could not open a shared connection to \(host.name): \(detail)"))
            }
        }
        sequence = next
        controlPath = path
        openFailureAt = nil
        let generation = RemoteConnectionGeneration(host: host.name, sequence: next, epoch: epoch)
        state = .open(generation)
        openedAt = Date().timeIntervalSince1970 * 1000
        endedAt = nil
        lossReason = nil
        return .ready(generation: generation, options: SSHCommand.controlClientArguments(controlPath: path))
    }

    /// Close the transport deliberately. The generation ends; it never comes back.
    @discardableResult
    public func close() async -> RemoteConnectionStatus {
        if case .open(let generation) = state {
            await tearDownMaster(path: controlPath)
            state = .closed(generation)
            endedAt = Date().timeIntervalSince1970 * 1000
            lossReason = nil
        }
        controlPath = nil
        return status()
    }

    /// `ssh -O exit` and unlink. A deliberate ending, never a stop: it ends a
    /// connection and says nothing about what was running on the far side.
    private func tearDownMaster(path: String?) async {
        guard let path else { return }
        _ = await runner.run(SSHCommand.controlExitArgv(for: host, controlPath: path),
                             timeout: min(10, openTimeout))
        try? fileManager.removeItem(atPath: path)
    }

    // MARK: - Acquire + settle

    /// Decide how — and whether — one command may run.
    ///
    /// `fencedTo: nil` is "any connection will do": the transport is opened on demand
    /// and the answer is stamped with whichever generation served it. That is the right
    /// question for a stateless read (a `git worktree list`, a file, a process id) where
    /// nothing about the answer depends on which span of contact produced it.
    ///
    /// `fencedTo: g` is "answer me on generation `g` or not at all", and it is refused
    /// the moment `g` is not the open generation. This is the whole point of the
    /// counter: a caller holding a generation is holding a claim about *continuity*, and
    /// silently serving it from a later connection would turn a reconnect into a claim
    /// nobody is entitled to make.
    public func acquire(fencedTo fence: RemoteConnectionGeneration? = nil) async
        -> RemoteConnectionAcquisition {
        verifyControlSocket()
        guard let fence else {
            if case .open(let generation) = state, let path = controlPath {
                return .ready(generation: generation,
                              options: SSHCommand.controlClientArguments(controlPath: path))
            }
            if multiplexRefusal != nil { return .ready(generation: nil, options: []) }
            if let openFailureAt,
               Date().timeIntervalSince1970 * 1000 - openFailureAt < Self.openRetryBackoff * 1000 {
                return .ready(generation: nil, options: [])
            }
            switch await open() {
            case .ready(let generation, let options):
                return .ready(generation: generation, options: options)
            case .refused:
                // A connection Orchard could not establish must never become a verdict
                // about the work. Run the command on its own `ssh` instead — that is
                // exactly the pre-T89 behaviour, and whatever *it* answers is the
                // honest answer: if the host really is unreachable, the command says so
                // itself, and if the problem was local (a control socket that could not
                // be bound) nothing was lost but the sharing.
                return .ready(generation: nil, options: [])
            }
        }
        guard multiplexRefusal == nil else {
            return .refused(RemoteHostError(
                "connection_generation_unavailable",
                "\(host.name) has no durable connection in this runtime "
                    + "(\(multiplexRefusal ?? "multiplexing is unavailable")), so nothing "
                    + "here can answer for generation \(fence.label)."))
        }
        switch state {
        case .open(let generation) where generation == fence:
            guard let path = controlPath else {
                return .refused(.generationEnded(fence, current: nil,
                                                 reason: "its control socket is gone"))
            }
            return .ready(generation: generation,
                          options: SSHCommand.controlClientArguments(controlPath: path))
        case .open(let generation):
            return .refused(.generationEnded(fence, current: generation, reason: nil))
        case .lost(let generation, let reason) where generation == fence:
            return .refused(.generationEnded(fence, current: nil, reason: reason))
        case .lost(let generation, let reason):
            return .refused(.generationEnded(fence, current: generation, reason: reason))
        case .closed(let generation) where generation == fence:
            return .refused(.generationEnded(fence, current: nil, reason: "it was closed here"))
        case .closed(let generation):
            return .refused(.generationEnded(fence, current: generation,
                                             reason: "it was closed here"))
        case .never:
            return .refused(.generationEnded(fence, current: nil,
                                             reason: "no connection has been opened here"))
        }
    }

    /// Fold what one command's raw result says about the *connection* back into the
    /// connection, and hand back what the caller is allowed to have.
    ///
    /// Two things are decided here.
    ///
    /// 1. **A transport failure ends the generation.** `ssh` 255 or our own deadline
    ///    means contact is gone; the outcome is already `unverifiable`, and what changes
    ///    is that later *fenced* calls on that generation are now refused instead of
    ///    quietly reopening.
    /// 2. **An answer that bypassed the master did not come from this generation.**
    ///    OpenSSH says so on its own stderr when the control socket is not there, and it
    ///    connects directly anyway. What that means depends entirely on what was asked:
    ///
    ///    - a **fenced** caller named a span of contact, so the answer is refused. It is
    ///      not a smaller answer, it is an answer to a different question — and
    ///      accepting it is precisely how a reconnect passes for continuity, with a
    ///      clean exit status on top to make it convincing.
    ///    - an **unfenced** caller asked a question about the *machine* (a file, a
    ///      process, a git tree). A direct connection answers that exactly as well;
    ///      throwing the answer away would invent a failure. The generation still ends,
    ///      and the returned attribution is nil so nothing records the answer as having
    ///      come from a span it did not.
    public func settle(generation: RemoteConnectionGeneration?,
                       result: HostCommandResult,
                       outcome: RemoteCommandOutcome,
                       fenced: Bool) -> (outcome: RemoteCommandOutcome,
                                         generation: RemoteConnectionGeneration?) {
        guard let generation else { return (outcome, nil) }
        let strayed = result.stderr.lowercased().contains(Self.controlSocketFallbackMarker)
        if strayed {
            markLost(generation: generation,
                     reason: "its shared connection was gone when a command ran, so the "
                        + "answer came from a different connection")
            guard fenced else { return (outcome, nil) }
            return (.unverifiable(
                reason: "connection \(generation.label) had already ended when this command "
                    + "ran; the answer that came back was not from it. "
                    + "\(HostLiveness.generationRefusalReminder)"), nil)
        }
        if case .unverifiable(let reason) = outcome {
            markLost(generation: generation, reason: reason)
        }
        return (outcome, generation)
    }

    /// A connection whose socket is gone has ended, and it must be known to have ended
    /// *before* the next command runs — not after, from a confession OpenSSH does not
    /// make. Without this a killed master would leave the state reading `open` while
    /// every command quietly opened its own connection, and a fenced caller would be
    /// served from a span of contact that no longer existed.
    ///
    /// It is a `stat`, not a process: cheap enough to do in front of every command,
    /// which is the only place it is worth anything.
    private func verifyControlSocket() {
        guard case .open(let generation) = state else { return }
        guard let path = controlPath, !fileManager.fileExists(atPath: path) else { return }
        markLost(generation: generation,
                 reason: "its control socket is gone, so the connection it named has ended")
    }

    private func markLost(generation: RemoteConnectionGeneration, reason: String) {
        guard case .open(let current) = state, current == generation else { return }
        state = .lost(generation, reason: reason)
        lossReason = reason
        endedAt = Date().timeIntervalSince1970 * 1000
        if let path = controlPath { try? fileManager.removeItem(atPath: path) }
        controlPath = nil
    }

    // MARK: - Control path

    /// `<dir>/<8 hex of the host name>-<sequence>`.
    ///
    /// The sequence is in the path on purpose: a master left over from generation 3
    /// listens on a socket generation 4 never names, so continuity cannot be inherited
    /// by accident. Short by construction, because a unix socket address is 104 bytes
    /// on Darwin and OpenSSH fails to bind a longer one — with a message about the
    /// socket, not about the length, which is a bad hour for whoever debugs it.
    private func prepareControlPath(sequence: Int) throws -> String {
        try fileManager.createDirectory(at: controlDirectory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        let path = controlDirectory
            .appendingPathComponent("\(Self.shortName(host.name))-\(sequence)").path
        guard path.utf8.count < RuntimePaths.unixSocketPathLimit - 8 else {
            throw RemoteHostError("control_path_too_long", path)
        }
        try? fileManager.removeItem(atPath: path)
        return path
    }

    /// A stable 8-hex-character digest of the host name, so `ssh-config/alias@weird`
    /// and a 60-character alias both make a short, unambiguous file name.
    static func shortName(_ name: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in Array(name.utf8) {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%08x", UInt32(truncatingIfNeeded: hash))
    }

    private func note() -> String {
        switch state {
        case .never:
            if let refusal = multiplexRefusal {
                return "No shared connection to \(host.name): \(refusal). Each command is "
                    + "its own connection, so no continuity can be claimed between them."
            }
            if let reason = lossReason {
                return "No connection to \(host.name) is open — the last attempt did not "
                    + "reach it (\(reason)). \(HostLiveness.lossOfContactReminder(host: host.name)) "
                    + "Commands still run, each on its own connection."
            }
            return "No connection to \(host.name) has been opened in this runtime."
        case .open(let generation):
            return "Connection \(generation.label) is open. Commands issued on it share "
                + "one transport; a question asked about any earlier generation is "
                + "refused, not answered from this one."
        case .lost(let generation, let reason):
            return "Connection \(generation.label) ended — \(reason). "
                + "\(HostLiveness.lossOfContactReminder(host: host.name)) Reopening makes a "
                + "new generation; it does not continue this one."
        case .closed(let generation):
            return "Connection \(generation.label) was closed here. Reopening makes a new "
                + "generation; it does not continue this one."
        }
    }
}

extension RemoteHostError {
    /// The generation fence, in words. Says which span was asked about, which one is
    /// current (if any), and — the part that matters — that the difference is not
    /// something Orchard will paper over.
    public static func generationEnded(_ asked: RemoteConnectionGeneration,
                                       current: RemoteConnectionGeneration?,
                                       reason: String?) -> RemoteHostError {
        var message = "connection \(asked.label) to \(asked.host) has ended"
        if let reason, !reason.isEmpty { message += " — \(reason)" }
        message += "."
        if let current {
            message += " The connection open now is \(current.label), which is a different "
                + "span of contact; answering from it would present a reconnect as continuity."
        } else {
            message += " Nothing is open in its place."
        }
        message += " \(HostLiveness.generationRefusalReminder)"
        return RemoteHostError("connection_generation_ended", message)
    }
}

/// One `RemoteConnection` per host name, shared by everything in a runtime that talks
/// to that host.
///
/// A pool rather than a connection per caller, because the whole point is that the
/// callers share a transport — and because the generation counter only means anything
/// if there is exactly one place counting.
public final class RemoteConnectionPool: @unchecked Sendable {
    private let runner: HostCommandRunner
    private let controlDirectory: URL
    private let connectTimeoutSeconds: Int
    private let lock = NSLock()
    private var connections: [String: RemoteConnection] = [:]

    public init(controlDirectory: URL,
                runner: HostCommandRunner = ProcessHostCommandRunner(),
                connectTimeoutSeconds: Int = 5) {
        self.controlDirectory = controlDirectory
        self.runner = runner
        self.connectTimeoutSeconds = connectTimeoutSeconds
    }

    /// The default control directory: `<run>/mux`. It sits beside the runtime socket
    /// rather than in the data directory because it holds live sockets, not state, and
    /// because the run directory is already the one chosen to fit `sun_path`.
    public static func defaultControlDirectory(runDirectory: URL) -> URL {
        runDirectory.appendingPathComponent("mux", isDirectory: true)
    }

    public func connection(for host: HostRecord) -> RemoteConnection {
        lock.lock(); defer { lock.unlock() }
        if let existing = connections[host.name] { return existing }
        let made = RemoteConnection(host: host, runner: runner,
                                    controlDirectory: controlDirectory,
                                    connectTimeoutSeconds: connectTimeoutSeconds)
        connections[host.name] = made
        return made
    }

    /// Every connection this pool has ever handed out, in name order.
    public func all() -> [RemoteConnection] {
        lock.lock(); defer { lock.unlock() }
        return connections.keys.sorted().compactMap { connections[$0] }
    }

    public func existing(name: String) -> RemoteConnection? {
        lock.lock(); defer { lock.unlock() }
        return connections[name]
    }

    /// Close every master. Called at runtime shutdown so a quit does not leave
    /// `ssh` masters behind holding connections nobody will ever ask about again.
    public func closeAll() async {
        for connection in all() { _ = await connection.close() }
    }
}
