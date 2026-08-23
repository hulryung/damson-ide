import Foundation

/// The local end of an agent's Tier-1 lifecycle-hook channel: a loopback port agent
/// CLIs POST to, and a token → handler table that routes each POST to the pane that
/// owns it.
///
/// `AgentSupervisor` has always owned one of these privately for app-spawned agents.
/// It is a protocol here because the *runtime* now needs the same channel for a remote
/// agent pane (T39): the far side's hooks reach this port through an SSH reverse
/// tunnel, so the port has to be a value the launch path can read and write into a
/// remote config file before the agent starts.
///
/// `localHookPort` returning 0 means no channel — the caller degrades to
/// fingerprint-only detection rather than installing a config that points nowhere.
public protocol AgentHookChannel: AnyObject {
    /// The loopback port the hook server listens on, starting it if needed. 0 when it
    /// could not bind.
    var localHookPort: UInt16 { get }

    /// Route hook events carrying `token` to `handler` (event name, raw JSON body).
    /// Called on a background queue, so the handler must hop to its own isolation.
    func register(token: String, handler: @escaping @Sendable (String, Data) -> Void)

    func unregister(token: String)
}

/// `AgentHookChannel` over a real `HookServer`.
///
/// The server binds lazily on the first `localHookPort` read: a runtime that never
/// launches an agent with hooks should not be holding a listening socket, and the app
/// already runs its own server for supervisor-spawned agents.
public final class HookServerChannel: AgentHookChannel, @unchecked Sendable {
    private let server = HookServer()
    private let lock = NSLock()
    /// Held across the bind so two panes opening at once cannot both see "not started
    /// yet" and race to a port of 0 — which would degrade a perfectly good agent to
    /// fingerprints for no reason. The bind is itself bounded (`HookServer.start`), so
    /// the wait is finite.
    private let startLock = NSLock()
    private var handlers: [String: @Sendable (String, Data) -> Void] = [:]
    private var started = false

    /// Rebind this port if it is free (keeper restoration's rule, §T23): agents whose
    /// hook config was written against the previous generation keep landing here.
    public var preferredPort: UInt16?

    public init(preferredPort: UInt16? = nil) {
        self.preferredPort = preferredPort
    }

    public var localHookPort: UInt16 {
        startLock.lock()
        defer { startLock.unlock() }
        guard !started else { return server.port }
        started = true
        _ = server.start(preferredPort: preferredPort)
        server.onEvent = { [weak self] event in
            guard let self else { return }
            self.lock.lock()
            let handler = self.handlers[event.token]
            self.lock.unlock()
            handler?(event.event, event.body)
        }
        return server.port
    }

    public func register(token: String, handler: @escaping @Sendable (String, Data) -> Void) {
        lock.lock(); handlers[token] = handler; lock.unlock()
    }

    public func unregister(token: String) {
        lock.lock(); handlers.removeValue(forKey: token); lock.unlock()
    }

    public func stop() {
        lock.lock(); handlers.removeAll(); lock.unlock()
        startLock.lock(); started = false; startLock.unlock()
        server.stop()
    }
}
