/// Extractable window-frame persistence decisions (T62).
///
/// AppKit `setFrameAutosaveName` / `setFrameUsingName` stay in
/// `OrchardAppDelegate`. This type is the decision table those creation sites
/// consult so names, default sizes, "center only when unrestored", and the T51
/// close→reopen reuse rule can be unit-tested without launching the app.
///
/// Dogfood-4: the workbench came back at the compile-time default (1180×760)
/// after relaunch, which is why keeper-adopted panes commonly first painted
/// into a smaller window than the user had left.
public enum WindowFrameAutosave {
    public enum Role: String, CaseIterable, Sendable {
        case main
        case settings
        case dashboard
        case orchestration
        case automations
        case vault
        case space
        case floatingTerminal
    }

    /// Stable UserDefaults keys (`NSWindow Frame <name>`). Changing a name
    /// forgets that window's saved frame.
    public static func name(for role: Role) -> String {
        switch role {
        case .main: return "OrchardMainWindow"
        case .settings: return "OrchardSettingsWindow"
        case .dashboard: return "OrchardDashboardWindow"
        case .orchestration: return "OrchardOrchestrationWindow"
        case .automations: return "OrchardAutomationsWindow"
        case .vault: return "OrchardVaultWindow"
        case .space: return "OrchardSpaceWindow"
        case .floatingTerminal: return "OrchardFloatingTerminalWindow"
        }
    }

    public struct Size: Equatable, Sendable {
        public var width: Double
        public var height: Double

        public init(width: Double, height: Double) {
            self.width = width
            self.height = height
        }
    }

    /// Compile-time content size applied before restore. `nil` means the
    /// hosting view's fitting size is the first-launch default (Settings).
    public static func defaultContentSize(for role: Role) -> Size? {
        switch role {
        case .main: return Size(width: 1180, height: 760)
        case .settings: return nil
        case .dashboard: return Size(width: 960, height: 520)
        case .orchestration: return Size(width: 1040, height: 620)
        case .automations: return Size(width: 1040, height: 620)
        case .vault: return Size(width: 1080, height: 640)
        case .space: return Size(width: 1040, height: 620)
        case .floatingTerminal: return Size(width: 560, height: 320)
        }
    }

    /// After applying the default content size, restore from autosave if one
    /// exists. Center only when no saved frame was applied — centering after a
    /// successful restore is what made relaunch forget the user's frame.
    public static func shouldCenter(didRestoreSavedFrame: Bool) -> Bool {
        !didRestoreSavedFrame
    }

    /// T51 close-then-reopen reuses the same `NSWindow` (`isReleasedWhenClosed
    /// = false`). Recreating or re-centering would drop the in-memory frame
    /// until UserDefaults restore, and would fight a live adopted-pane fit.
    public enum ReopenStrategy: Equatable, Sendable {
        /// Same process, window already exists — order-front, do not recreate
        /// or re-center.
        case orderFrontExisting
        /// First creation this process — apply default size, restore-or-center,
        /// enable autosave.
        case createAndRestore
    }

    public static func reopenStrategy(windowAlreadyCreated: Bool) -> ReopenStrategy {
        windowAlreadyCreated ? .orderFrontExisting : .createAndRestore
    }
}
