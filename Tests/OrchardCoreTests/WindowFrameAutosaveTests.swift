import XCTest
@testable import OrchardCore

/// T62: main + auxiliary windows persist frames via named autosave; T51
/// close→reopen must reuse the existing window instead of re-centering.
final class WindowFrameAutosaveTests: XCTestCase {
    func testEveryRoleHasAUniqueStableAutosaveName() {
        let names = WindowFrameAutosave.Role.allCases.map(WindowFrameAutosave.name(for:))
        XCTAssertEqual(names, [
            "OrchardMainWindow",
            "OrchardSettingsWindow",
            "OrchardDashboardWindow",
            "OrchardOrchestrationWindow",
            "OrchardAutomationsWindow",
            "OrchardVaultWindow",
            "OrchardSpaceWindow",
            "OrchardFloatingTerminalWindow",
        ])
        XCTAssertEqual(Set(names).count, names.count, "autosave names must stay unique")
        XCTAssertTrue(names.allSatisfy { !$0.isEmpty })
    }

    func testDefaultContentSizesMatchThePreAutosaveCreationSites() {
        XCTAssertEqual(
            WindowFrameAutosave.defaultContentSize(for: .main),
            WindowFrameAutosave.Size(width: 1180, height: 760))
        XCTAssertNil(
            WindowFrameAutosave.defaultContentSize(for: .settings),
            "Settings has no compile-time size; position still autosaves")
        XCTAssertEqual(
            WindowFrameAutosave.defaultContentSize(for: .dashboard),
            WindowFrameAutosave.Size(width: 960, height: 520))
        XCTAssertEqual(
            WindowFrameAutosave.defaultContentSize(for: .orchestration),
            WindowFrameAutosave.Size(width: 1040, height: 620))
        XCTAssertEqual(
            WindowFrameAutosave.defaultContentSize(for: .automations),
            WindowFrameAutosave.Size(width: 1040, height: 620))
        XCTAssertEqual(
            WindowFrameAutosave.defaultContentSize(for: .vault),
            WindowFrameAutosave.Size(width: 1080, height: 640))
        XCTAssertEqual(
            WindowFrameAutosave.defaultContentSize(for: .space),
            WindowFrameAutosave.Size(width: 1040, height: 620))
        XCTAssertEqual(
            WindowFrameAutosave.defaultContentSize(for: .floatingTerminal),
            WindowFrameAutosave.Size(width: 560, height: 320),
            "floating terminal is a small always-on-top window, not a second workbench")
    }

    func testCenterOnlyWhenNoSavedFrameWasRestored() {
        XCTAssertFalse(WindowFrameAutosave.shouldCenter(didRestoreSavedFrame: true),
                       "centering after restore is what forgot the user's frame")
        XCTAssertTrue(WindowFrameAutosave.shouldCenter(didRestoreSavedFrame: false))
    }

    func testT51CloseThenReopenReusesTheExistingWindow() {
        XCTAssertEqual(
            WindowFrameAutosave.reopenStrategy(windowAlreadyCreated: true),
            .orderFrontExisting)
        XCTAssertEqual(
            WindowFrameAutosave.reopenStrategy(windowAlreadyCreated: false),
            .createAndRestore)
    }
}
