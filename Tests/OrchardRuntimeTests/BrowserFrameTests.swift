import XCTest
@testable import OrchardRuntime

/// T21 iframe snapshot traversal: same-origin frames walk inline into the
/// outline with page-unique `@eN` refs that remember their owning frame;
/// cross-origin frames are opaque origin-labeled nodes; and refs die on
/// subframe navigation exactly like on top-level navigation. Headless — the
/// walker's JSON contract is exercised through payloads and script text.
final class BrowserFrameTests: XCTestCase {
    private let ws = "/tmp/ws-frames"

    /// A page with a button before, inside, and after a same-origin "checkout"
    /// frame, plus an opaque cross-origin ad frame.
    static let framePayload = """
        {"title":"Shop","url":"https://shop.test/","truncated":false,"nodes":[
          {"d":0,"role":"button","name":"Top","value":"","i":0},
          {"d":0,"role":"iframe","name":"checkout","value":"","i":-1,"f":"f1"},
          {"d":1,"role":"textbox","name":"Card number","value":"","i":1,"f":"f1"},
          {"d":1,"role":"button","name":"Pay","value":"","i":2,"f":"f1"},
          {"d":0,"role":"iframe","name":"https://ads.example","value":"","i":-1,"x":true},
          {"d":0,"role":"link","name":"Help","value":"","i":3}
        ]}
        """

    private func bootedService(host: FakeBrowserHost) async throws -> BrowserService {
        let service = BrowserService()
        await service.attach(host: host)
        _ = try await service.goto(workspace: ws, url: "https://shop.test/")
        return service
    }

    // MARK: - Outline building (pure)

    func testSameOriginFrameContentInlinesWithFrameScopedRefs() throws {
        let payload = try JSONDecoder().decode(
            BrowserWalkerPayload.self, from: Data(Self.framePayload.utf8))
        let snap = BrowserSnapshotOutline.build(payload: payload, epoch: 1)

        // One numbering across frames: refs stay unique page-wide.
        XCTAssertEqual(snap.refs.count, 4)
        XCTAssertEqual(snap.refs["@e1"]?.name, "Top")
        XCTAssertEqual(snap.refs["@e2"]?.name, "Card number")
        XCTAssertEqual(snap.refs["@e3"]?.name, "Pay")
        XCTAssertEqual(snap.refs["@e4"]?.name, "Help")

        // Each ref remembers its owning frame ("" = main frame).
        XCTAssertEqual(snap.refs["@e1"]?.frame, "")
        XCTAssertEqual(snap.refs["@e2"]?.frame, "f1")
        XCTAssertEqual(snap.refs["@e3"]?.frame, "f1")
        XCTAssertEqual(snap.refs["@e4"]?.frame, "")

        // The frame boundary renders as a node with its content indented under it.
        XCTAssertTrue(snap.outline.contains(#"- iframe "checkout""#))
        XCTAssertTrue(snap.outline.contains(#"  - textbox "Card number" [@e2]"#))
        XCTAssertTrue(snap.outline.contains(#"  - button "Pay" [@e3]"#))
    }

    func testCrossOriginFrameIsOpaqueAndLabeledWithOrigin() throws {
        let payload = try JSONDecoder().decode(
            BrowserWalkerPayload.self, from: Data(Self.framePayload.utf8))
        let snap = BrowserSnapshotOutline.build(payload: payload, epoch: 1)

        XCTAssertTrue(snap.outline.contains(#"- iframe "https://ads.example" (cross-origin)"#))
        XCTAssertFalse(snap.outline.contains(#""https://ads.example" (cross-origin) [@e"#),
                       "opaque frames get no ref")
    }

    func testDuplicateNamesAcrossFramesStillDisambiguate() throws {
        let json = """
            {"title":"T","url":"u","truncated":false,"nodes":[
              {"d":0,"role":"button","name":"Submit","value":"","i":0},
              {"d":0,"role":"iframe","name":"inner","value":"","i":-1,"f":"f1"},
              {"d":1,"role":"button","name":"Submit","value":"","i":1,"f":"f1"}
            ]}
            """
        let payload = try JSONDecoder().decode(BrowserWalkerPayload.self, from: Data(json.utf8))
        let snap = BrowserSnapshotOutline.build(payload: payload, epoch: 1)
        XCTAssertTrue(snap.outline.contains(#"- button "Submit" [@e1]"#))
        XCTAssertTrue(snap.outline.contains(#"- button "Submit (2nd)" [@e2]"#))
        XCTAssertEqual(snap.refs["@e1"]?.frame, "")
        XCTAssertEqual(snap.refs["@e2"]?.frame, "f1")
    }

    // MARK: - Ref lifecycle through the service

    func testFrameRefsResolveThroughTheSharedRegistry() async throws {
        let host = FakeBrowserHost()
        host.snapshotPayload = Self.framePayload
        let service = try await bootedService(host: host)

        let result = try await service.snapshot(workspace: ws)
        XCTAssertEqual(result.refCount, 4)

        // A subframe ref resolves by element index into the page-wide registry
        // — same-origin frame elements live in the one `els` array.
        try await service.click(workspace: ws, ref: "@e3")
        let script = host.evaluated.last?.script ?? ""
        XCTAssertTrue(script.contains("S.els[2]"), "@e3 → element index 2")
        XCTAssertTrue(script.contains("S.owners"),
                      "actions guard the owning frame's document identity")
    }

    func testSubframeNavigationInvalidatesRefs() async throws {
        let host = FakeBrowserHost()
        host.snapshotPayload = Self.framePayload
        let service = try await bootedService(host: host)
        _ = try await service.snapshot(workspace: ws)

        let pageId = host.createdPages[0].pageId
        await service.subframeDidNavigate(pageId: pageId)

        let stored = await service.latestSnapshot(pageId: pageId)
        XCTAssertNil(stored)
        await expectBrowserError("browser_stale_ref") {
            try await service.click(workspace: self.ws, ref: "@e1")
        }
        // Unlike a main-frame commit, page facts are untouched.
        let summary = await service.listTabs(workspace: ws)
        XCTAssertEqual(summary.pages.first?.url, "https://shop.test/")
        XCTAssertEqual(summary.pages.first?.isLoading, false)
    }

    func testResnapshotAfterSubframeNavigationRevivesInteraction() async throws {
        let host = FakeBrowserHost()
        host.snapshotPayload = Self.framePayload
        let service = try await bootedService(host: host)
        _ = try await service.snapshot(workspace: ws)
        let pageId = host.createdPages[0].pageId
        await service.subframeDidNavigate(pageId: pageId)

        let second = try await service.snapshot(workspace: ws)
        XCTAssertEqual(second.epoch, 2)
        try await service.fill(workspace: ws, ref: "@e2", text: "4242")
        let script = host.evaluated.last?.script ?? ""
        XCTAssertTrue(script.contains("S.epoch !== 2"))
    }

    // MARK: - Injected script contract

    func testSnapshotScriptWalksFramesAndRegistersOwners() {
        let script = BrowserScripts.snapshot(epoch: 7)
        XCTAssertTrue(script.contains("contentDocument"), "walker descends into frames")
        XCTAssertTrue(script.contains("cross-origin") || script.contains("x: true"),
                      "walker marks unreachable frames opaque")
        XCTAssertTrue(script.contains("owners: owners"),
                      "registry pairs each element with its owning frame")
        XCTAssertTrue(script.contains("window.__orchardRefs = { epoch: 7"),
                      "registry fragment stays stable (hosts and fakes match on it)")
    }

    func testActionScriptsGuardOwningFrameDocument() {
        for script in [BrowserScripts.click(epoch: 1, index: 0),
                       BrowserScripts.fill(epoch: 1, index: 0, text: "x"),
                       BrowserScripts.type(epoch: 1, index: 0, text: "x")] {
            XCTAssertTrue(script.contains("O.host.contentDocument !== O.doc"),
                          "subframe refs die when their frame shows a new document")
        }
    }

    func testFocusTypingChasesFocusIntoFrames() {
        let script = BrowserScripts.type(epoch: 0, index: -1, text: "hi")
        XCTAssertTrue(script.contains("d.activeElement"),
                      "focus typing follows activeElement through same-origin frames")
        XCTAssertFalse(script.contains("__orchardRefs"))
    }
}
