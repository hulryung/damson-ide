import Foundation

/// Extractable floating-terminal decisions (T71).
///
/// The window is a second *view* of an existing pane's live session — never a
/// second PTY. Closing it unbinds the window; the session stays with the pane.
/// AppKit creation and Damson surface hosting stay in OrchardApp.
public enum FloatingTerminalPolicy {
    /// Always-on-top relative to other Orchard windows and other apps.
    public static var staysOnTop: Bool { true }

    /// Closing the floating window must not terminate the pane's session.
    public static var closeTerminatesSession: Bool { false }

    /// One floating window. Opening from another pane rebinds it.
    public static func binding(current: UUID?, opening tabID: UUID) -> UUID {
        tabID
    }

    /// Close restores the workbench surface; the session is not dropped.
    public static func bindingAfterClose() -> UUID? { nil }

    /// The workbench must not host a DamsonSurfaceView for a pane that is
    /// already in the floating window — two surfaces on one session fight
    /// over PTY size (SIGWINCH).
    public static func workbenchHoldsSurface(tabID: UUID, floatingTabID: UUID?) -> Bool {
        floatingTabID != tabID
    }
}
