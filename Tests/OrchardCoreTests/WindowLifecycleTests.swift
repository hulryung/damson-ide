import XCTest
@testable import OrchardCore

/// T51: closing the last window must not quit a runtime-hosting app; Dock
/// reopen restores the workbench; the menu indication is truthful about the
/// control plane (not merely "the process is still running").
final class WindowLifecycleTests: XCTestCase {
    func testRuntimeHostDoesNotQuitWhenLastWindowCloses() {
        XCTAssertFalse(WindowLifecycle.shouldTerminateAfterLastWindowClosed(
            hostsInProcessRuntime: true))
    }

    func testNonHostKeepsCocoaDefaultAndQuitsWithLastWindow() {
        XCTAssertTrue(WindowLifecycle.shouldTerminateAfterLastWindowClosed(
            hostsInProcessRuntime: false))
    }

    func testDockReopenAlwaysOrdersFrontMainWindow() {
        XCTAssertTrue(WindowLifecycle.shouldOrderFrontMainWindow(
            mainWindowOnScreen: true, trigger: .dockOrFinder))
        XCTAssertTrue(WindowLifecycle.shouldOrderFrontMainWindow(
            mainWindowOnScreen: false, trigger: .dockOrFinder))
    }

    func testActivationRestoresOnlyAWindowlessHiddenWorkbench() {
        XCTAssertFalse(WindowLifecycle.shouldOrderFrontMainWindow(
            mainWindowOnScreen: true, hasAnyVisibleWindow: true, trigger: .activation))
        XCTAssertFalse(WindowLifecycle.shouldOrderFrontMainWindow(
            mainWindowOnScreen: false, hasAnyVisibleWindow: true, trigger: .activation),
            "a focused Settings/Vault/… window must not be stolen on Cmd-Tab")
        XCTAssertTrue(WindowLifecycle.shouldOrderFrontMainWindow(
            mainWindowOnScreen: false, hasAnyVisibleWindow: false, trigger: .activation),
            "Cmd-Tab after closing every window must bring the workbench back")
    }

    func testExplicitShowAlwaysOrdersFront() {
        XCTAssertTrue(WindowLifecycle.shouldOrderFrontMainWindow(
            mainWindowOnScreen: true, trigger: .explicitShow))
        XCTAssertTrue(WindowLifecycle.shouldOrderFrontMainWindow(
            mainWindowOnScreen: false, trigger: .explicitShow))
    }

    func testRuntimeIndicationIsAliveOnlyWhenTheSocketIsListening() {
        XCTAssertEqual(
            WindowLifecycle.runtimeIndication(
                hostConstructed: true, socketListening: true, runtimeId: "rt_abc"),
            .alive(runtimeId: "rt_abc"))
        XCTAssertTrue(WindowLifecycle.runtimeIndication(
            hostConstructed: true, socketListening: true, runtimeId: "rt_abc").isAlive)
    }

    func testRuntimeIndicationIsNotListeningWhenHostExistsButSocketDoesNot() {
        XCTAssertEqual(
            WindowLifecycle.runtimeIndication(
                hostConstructed: true, socketListening: false, runtimeId: "rt_abc"),
            .notListening)
        XCTAssertEqual(
            WindowLifecycle.runtimeIndication(
                hostConstructed: true, socketListening: true, runtimeId: nil),
            .notListening)
        XCTAssertEqual(
            WindowLifecycle.runtimeIndication(
                hostConstructed: true, socketListening: true, runtimeId: ""),
            .notListening)
        XCTAssertFalse(WindowLifecycle.RuntimeIndication.notListening.isAlive)
    }

    func testRuntimeIndicationIsUnavailableWithoutAHost() {
        XCTAssertEqual(
            WindowLifecycle.runtimeIndication(
                hostConstructed: false, socketListening: false, runtimeId: nil),
            .unavailable)
        XCTAssertFalse(WindowLifecycle.RuntimeIndication.unavailable.isAlive)
    }

    func testRuntimeIndicationMenuTitlesStayTruthful() {
        XCTAssertEqual(
            WindowLifecycle.RuntimeIndication.alive(runtimeId: "rt_abc").menuTitle,
            "Runtime alive · rt_abc")
        XCTAssertEqual(
            WindowLifecycle.RuntimeIndication.notListening.menuTitle,
            "Runtime not listening")
        XCTAssertEqual(
            WindowLifecycle.RuntimeIndication.unavailable.menuTitle,
            "Runtime unavailable")
    }
}
