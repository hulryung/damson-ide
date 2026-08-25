import XCTest
@testable import OrchardCore

/// T71: the floating window is a second view of an existing pane's session.
final class FloatingTerminalPolicyTests: XCTestCase {
    func testStaysOnTopAndCloseDoesNotKillTheSession() {
        XCTAssertTrue(FloatingTerminalPolicy.staysOnTop)
        XCTAssertFalse(FloatingTerminalPolicy.closeTerminatesSession,
                       "closing the window must leave the pane's PTY running")
    }

    func testOpeningRebindsTheSingleWindow() {
        let first = UUID()
        let second = UUID()
        XCTAssertEqual(FloatingTerminalPolicy.binding(current: nil, opening: first), first)
        XCTAssertEqual(FloatingTerminalPolicy.binding(current: first, opening: second), second,
                       "a second pane takes over the one floating window")
    }

    func testCloseClearsTheBindingWithoutAReplacementSession() {
        XCTAssertNil(FloatingTerminalPolicy.bindingAfterClose())
    }

    func testWorkbenchDropsItsSurfaceOnlyForTheFloatedPane() {
        let floated = UUID()
        let other = UUID()
        XCTAssertFalse(
            FloatingTerminalPolicy.workbenchHoldsSurface(tabID: floated, floatingTabID: floated),
            "two DamsonSurfaceViews on one session fight over SIGWINCH")
        XCTAssertTrue(
            FloatingTerminalPolicy.workbenchHoldsSurface(tabID: other, floatingTabID: floated))
        XCTAssertTrue(
            FloatingTerminalPolicy.workbenchHoldsSurface(tabID: floated, floatingTabID: nil),
            "closing the float returns the surface to the workbench pane")
    }
}
