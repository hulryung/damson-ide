/// Extractable window-lifecycle decisions for the in-process runtime host (T51).
///
/// AppKit callbacks stay in `OrchardAppDelegate`. This type is the decision table
/// those callbacks consult so the rules can be unit-tested without launching the app.
///
/// The product rule (dogfood-3): closing the workbench must not kill the runtime
/// or its supervised workers. Cmd-Q is the only full termination path (T23).
public enum WindowLifecycle {
    /// Cocoa asks whether to quit when the last window closes. A process that
    /// hosts the in-process runtime must answer no — Dock reopen restores the
    /// workbench. A process that is not hosting one keeps Cocoa's default yes.
    public static func shouldTerminateAfterLastWindowClosed(
        hostsInProcessRuntime: Bool
    ) -> Bool {
        !hostsInProcessRuntime
    }

    /// Why the main workbench might be ordered front.
    public enum RestoreTrigger: Equatable, Sendable {
        /// Dock icon click or Finder reopen. Always order-front the workbench,
        /// even when an auxiliary window is already visible.
        case dockOrFinder
        /// App became active (Cmd-Tab). Restore a hidden workbench only when
        /// no Orchard window is visible — a focused Settings/Vault window is
        /// not stolen. Dock reopen still fronts the workbench in that case.
        case activation
        /// Menu, Dock-menu, or programmatic "Show Orchard".
        case explicitShow
    }

    /// Whether to make the main workbench key and visible.
    ///
    /// `mainWindowOnScreen` is visible and not miniaturized. A miniaturized
    /// workbench is treated as off-screen so Dock reopen / Show Orchard can
    /// deminiaturize it; activation leaves a user-miniaturized window alone
    /// unless the app has no visible windows at all.
    public static func shouldOrderFrontMainWindow(
        mainWindowOnScreen: Bool,
        hasAnyVisibleWindow: Bool = false,
        trigger: RestoreTrigger
    ) -> Bool {
        switch trigger {
        case .dockOrFinder, .explicitShow:
            return true
        case .activation:
            return !mainWindowOnScreen && !hasAnyVisibleWindow
        }
    }

    /// Truthful control-plane presence. "Alive" only when this process has a
    /// listening runtime socket — a constructed-but-unbound host is not alive,
    /// and neither is a missing host.
    public enum RuntimeIndication: Equatable, Sendable {
        case alive(runtimeId: String)
        case notListening
        case unavailable

        public var menuTitle: String {
            switch self {
            case .alive(let id):
                return "Runtime alive · \(id)"
            case .notListening:
                return "Runtime not listening"
            case .unavailable:
                return "Runtime unavailable"
            }
        }

        public var isAlive: Bool {
            if case .alive = self { return true }
            return false
        }
    }

    public static func runtimeIndication(
        hostConstructed: Bool,
        socketListening: Bool,
        runtimeId: String?
    ) -> RuntimeIndication {
        guard hostConstructed else { return .unavailable }
        guard socketListening, let runtimeId, !runtimeId.isEmpty else {
            return .notListening
        }
        return .alive(runtimeId: runtimeId)
    }
}
