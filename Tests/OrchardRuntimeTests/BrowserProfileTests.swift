import XCTest
@testable import OrchardRuntime
import OrchardProtocol

/// T21 session profiles: one profile ⇒ one data-store partition. The service
/// owns the model + workspace bindings (persisted in orchard-data.json through
/// `OrchardDataStore`); the host only ever sees the resolved profile riding on
/// `createPage`. All headless via `FakeBrowserHost`.
final class BrowserProfileTests: XCTestCase {
    private let wsA = "/tmp/ws-a"
    private let wsB = "/tmp/ws-b"
    private var storeDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        storeDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orchard-browser-profiles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: storeDir)
        try super.tearDownWithError()
    }

    private func makeStore() -> OrchardDataStore {
        OrchardDataStore(url: storeDir.appendingPathComponent("orchard-data.json"))
    }

    private func makeService(host: FakeBrowserHost, store: OrchardDataStore? = nil,
                             resolver: BrowserService.WorkspaceResolver? = nil) async -> BrowserService {
        let service = BrowserService(resolver: resolver, store: store)
        await service.attach(host: host)
        return service
    }

    // MARK: - Model

    func testListStartsWithBuiltInDefault() async {
        let service = BrowserService()
        let profiles = await service.listProfiles()
        XCTAssertEqual(profiles.map(\.id), ["default"])
        XCTAssertEqual(profiles[0].scope, .default)
    }

    func testCreateMintsIsolatedProfileAndPersists() async throws {
        let store = makeStore()
        let service = await makeService(host: FakeBrowserHost(), store: store)
        let profile = try await service.createProfile(label: "Work")

        XCTAssertTrue(profile.id.hasPrefix("pf_"))
        XCTAssertEqual(profile.scope, .isolated)
        XCTAssertEqual(profile.label, "Work")

        // Written through to orchard-data.json: a fresh store over the same file
        // (and a fresh service over that) sees the profile.
        let reread = OrchardDataStore(url: store.url)
        XCTAssertEqual(reread.load().browserProfiles, [profile])
        let revived = BrowserService(store: reread)
        let listed = await revived.listProfiles()
        XCTAssertEqual(listed.map(\.id), ["default", profile.id])
    }

    func testCreateRejectsEmptyAndDuplicateLabels() async throws {
        let service = await makeService(host: FakeBrowserHost())
        await expectBrowserError("invalid_argument") {
            try await service.createProfile(label: "   ")
        }
        _ = try await service.createProfile(label: "Work")
        await expectBrowserError("browser_profile_exists") {
            try await service.createProfile(label: "work")
        }
        // The built-in default's label is reserved too — `set` accepts labels.
        await expectBrowserError("browser_profile_exists") {
            try await service.createProfile(label: "Default")
        }
    }

    // MARK: - Workspace binding

    func testBoundProfileDefaultsWhenUnset() async {
        let service = await makeService(host: FakeBrowserHost())
        let bound = await service.boundProfile(workspace: wsA)
        XCTAssertEqual(bound.profile, .defaultProfile)
        XCTAssertEqual(bound.workspace, wsA)
    }

    func testBindByIdAndByLabelThenBackToDefault() async throws {
        let store = makeStore()
        let service = await makeService(host: FakeBrowserHost(), store: store)
        let profile = try await service.createProfile(label: "Testing")

        _ = try await service.bindProfile(workspace: wsA, profile: profile.id)
        var bound = await service.boundProfile(workspace: wsA)
        XCTAssertEqual(bound.profile.id, profile.id)

        _ = try await service.bindProfile(workspace: wsB, profile: "testing")
        bound = await service.boundProfile(workspace: wsB)
        XCTAssertEqual(bound.profile.id, profile.id, "labels resolve case-insensitively")

        // Rebinding to the default clears the stored entry rather than pinning
        // a redundant one.
        _ = try await service.bindProfile(workspace: wsA, profile: "default")
        bound = await service.boundProfile(workspace: wsA)
        XCTAssertEqual(bound.profile, .defaultProfile)
        XCTAssertEqual(store.load().browserWorkspaceProfiles, [wsB: profile.id])
    }

    func testBindUnknownProfileFailsTyped() async {
        let service = await makeService(host: FakeBrowserHost())
        await expectBrowserError("browser_profile_not_found") {
            try await service.bindProfile(workspace: self.wsA, profile: "pf_missing")
        }
    }

    func testBindingSurvivesServiceRestart() async throws {
        let store = makeStore()
        let first = await makeService(host: FakeBrowserHost(), store: store)
        let profile = try await first.createProfile(label: "Durable")
        _ = try await first.bindProfile(workspace: wsA, profile: profile.id)

        let second = BrowserService(store: OrchardDataStore(url: store.url))
        let bound = await second.boundProfile(workspace: wsA)
        XCTAssertEqual(bound.profile.id, profile.id)
    }

    func testDanglingBindingFallsBackToDefault() async throws {
        let store = makeStore()
        try store.modify { $0.browserWorkspaceProfiles = [wsA: "pf_deleted"] }
        let service = BrowserService(store: store)
        let bound = await service.boundProfile(workspace: wsA)
        XCTAssertEqual(bound.profile, .defaultProfile)
    }

    func testBindingUsesResolverCanonicalKey() async throws {
        let service = await makeService(host: FakeBrowserHost(), resolver: { selector in
            selector == "feature-x" ? "/repo/worktrees/feature-x" : nil
        })
        let profile = try await service.createProfile(label: "Feature")
        let bound = try await service.bindProfile(workspace: "feature-x", profile: profile.id)
        XCTAssertEqual(bound.workspace, "/repo/worktrees/feature-x")
        let byPath = await service.boundProfile(workspace: "/repo/worktrees/feature-x")
        XCTAssertEqual(byPath.profile.id, profile.id)
    }

    // MARK: - Host handoff

    func testCreatePageCarriesTheBoundProfile() async throws {
        let host = FakeBrowserHost()
        let service = await makeService(host: host)
        let profile = try await service.createProfile(label: "Partitioned")
        _ = try await service.bindProfile(workspace: wsA, profile: profile.id)

        _ = try await service.goto(workspace: wsA, url: "https://a.test")
        _ = try await service.goto(workspace: wsB, url: "https://b.test")

        XCTAssertEqual(host.createdPages.count, 2)
        XCTAssertEqual(host.createdPages[0].profile.id, profile.id)
        XCTAssertEqual(host.createdPages[0].profile.scope, .isolated)
        XCTAssertEqual(host.createdPages[1].profile, .defaultProfile,
                       "unbound workspaces ride the shared default store")
    }

    // MARK: - RPC surface (`browser tab profile …`)

    private func makeServer(service: BrowserService) -> InMemoryRuntimeServer {
        var registry = CommandRegistry()
        registry.register(BrowserCommandHandler(service: service))
        return InMemoryRuntimeServer(registry: registry, runtimeId: "rt_test")
    }

    private func callTab(_ server: InMemoryRuntimeServer, _ args: [String],
                         _ extra: [String: JSONValue] = [:]) async -> RPCResponse {
        var params = extra
        params["worktree"] = params["worktree"] ?? .string(wsA)
        params["_args"] = .array(args.map { .string($0) })
        return await server.perform(RPCRequest(method: "browser-tab", params: .object(params)))
    }

    func testProfileVerbRoundTripsOverRPC() async throws {
        let service = await makeService(host: FakeBrowserHost())
        let server = makeServer(service: service)

        let created = await callTab(server, ["profile", "create"], ["label": .string("Work")])
        XCTAssertTrue(created.ok)
        let profileId = created.result?.objectValue?["profile"]?.objectValue?["id"]?.stringValue ?? ""
        XCTAssertTrue(profileId.hasPrefix("pf_"))

        let list = await callTab(server, ["profile", "list"])
        let profiles = list.result?.objectValue?["profiles"]?.arrayValue
        XCTAssertEqual(profiles?.count, 2)
        XCTAssertEqual(profiles?.first?.objectValue?["id"]?.stringValue, "default")

        let set = await callTab(server, ["profile", "set"], ["profile": .string(profileId)])
        XCTAssertTrue(set.ok)
        XCTAssertEqual(set.result?.objectValue?["workspace"]?.stringValue, wsA)

        let show = await callTab(server, ["profile", "show"])
        XCTAssertEqual(show.result?.objectValue?["profile"]?.objectValue?["id"]?.stringValue,
                       profileId)

        // Verbs bind/show state only — no web view involved, so no host needed:
        // profile management must work before the app pane ever opens.
        let bare = makeServer(service: BrowserService())
        let headless = await callTab(bare, ["profile", "list"])
        XCTAssertTrue(headless.ok)
    }

    func testProfileVerbArgumentErrorsAreTyped() async {
        let service = await makeService(host: FakeBrowserHost())
        let server = makeServer(service: service)

        let createNoLabel = await callTab(server, ["profile", "create"])
        XCTAssertEqual(createNoLabel.error?.code, "invalid_argument")

        let setNoProfile = await callTab(server, ["profile", "set"])
        XCTAssertEqual(setNoProfile.error?.code, "invalid_argument")

        let setUnknown = await callTab(server, ["profile", "set"],
                                       ["profile": .string("nope")])
        XCTAssertEqual(setUnknown.error?.code, "browser_profile_not_found")

        let bogus = await callTab(server, ["profile", "teleport"])
        XCTAssertEqual(bogus.error?.code, "invalid_argument")
    }

    func testBrowserCommandSpecCarriesProfileFlags() {
        // The CLI parser only accepts declared flags, so `--label`/`--profile`
        // must exist in the spec for `browser tab profile create|set` to parse.
        let browser = OrchardCommands.all.first { $0.name == "browser" }
        let flags = browser?.flags.map(\.name) ?? []
        XCTAssertTrue(flags.contains("label"))
        XCTAssertTrue(flags.contains("profile"))
    }
}
