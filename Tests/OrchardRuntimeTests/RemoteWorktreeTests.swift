import XCTest
import OrchardProtocol
import OrchardTerminals
@testable import OrchardRuntime

/// A `HostCommandRunner` that answers from a script instead of spawning `ssh`.
///
/// Every remote worktree fact in T32 arrives as `ssh` stdout, so scripting that one seam
/// exercises the whole stack — probe, listing, create, preflight, delete — with no host,
/// no network and no key. It also records every argv, which is how the tests pin the
/// hardening flags and the `--no-track` / pinned-SHA create.
final class ScriptedSSHRunner: HostCommandRunner, @unchecked Sendable {
    private struct Rule {
        let match: String
        let result: HostCommandResult
        let once: Bool
    }

    private let lock = NSLock()
    private var rules: [Rule] = []
    private var calls: [[String]] = []
    /// Answer for a command no rule matched: success with empty output.
    var fallback = HostCommandResult(exitCode: 0)

    /// Most recently registered rule wins, so a test can override a shared fixture's
    /// answer for one command without rebuilding the whole script.
    func on(_ match: String, _ result: HostCommandResult) {
        lock.lock(); rules.insert(Rule(match: match, result: result, once: false), at: 0); lock.unlock()
    }

    var commandLines: [String] {
        lock.lock(); defer { lock.unlock() }
        return calls.map { $0.joined(separator: " ") }
    }

    func ran(_ fragment: String) -> Bool {
        commandLines.contains { $0.contains(fragment) }
    }

    func run(_ argv: [String], timeout: TimeInterval) async -> HostCommandResult {
        answer(argv)
    }

    /// The locked half, kept out of the async function so the lock is never held across
    /// a suspension point.
    private func answer(_ argv: [String]) -> HostCommandResult {
        let line = argv.joined(separator: " ")
        lock.lock(); defer { lock.unlock() }
        calls.append(argv)
        for (index, rule) in rules.enumerated() where line.contains(rule.match) {
            if rule.once { rules.remove(at: index) }
            return rule.result
        }
        return fallback
    }
}

private func stdout(_ text: String) -> HostCommandResult {
    HostCommandResult(exitCode: 0, stdout: text)
}

/// OpenSSH's own transport failure — the one status that says nothing about the far side.
private func transportFailure(_ stderr: String = "ssh: connect to host build.internal port 22: Connection refused") -> HostCommandResult {
    HostCommandResult(exitCode: 255, stderr: stderr + "\n")
}

/// T32 — remote worktrees over a scripted ssh runner: registration probe, listing,
/// create, delete preflight, the 255-is-unverifiable rule, and the surfaces that must
/// refuse rather than guess.
@MainActor
final class RemoteWorktreeTests: XCTestCase {
    private var tmp: URL!
    private var store: OrchardDataStore!
    private var service: WorkspaceService!
    private var runner: ScriptedSSHRunner!
    private var hosts: HostRegistry!
    private var server: InMemoryRuntimeServer!
    private var terminalSpecs: [TerminalCreateSpec] = []

    private let repoPath = "/srv/work/orchard"
    private let porcelain = """
        worktree /srv/work/orchard
        HEAD 1111111111111111111111111111111111111111
        branch refs/heads/main

        worktree /home/ci/Orchard/worktrees/orchard/apricot
        HEAD 2222222222222222222222222222222222222222
        branch refs/heads/ci/apricot

        """

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orchard-remote-wt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        store = OrchardDataStore(url: tmp.appendingPathComponent("orchard-data.json"))
        runner = ScriptedSSHRunner()
        hosts = HostRegistry(store: store, sshConfig: { [] })
        try hosts.add(name: "build", hostname: "build.internal", user: "ci", port: nil)

        service = WorkspaceService(store: store, worktreesRoot: tmp.appendingPathComponent("wt"))
        service.hostCommandRunner = runner
        service.remoteCommandTimeout = 1

        terminalSpecs = []
        let terminals = TerminalService(factory: { [weak self] spec, _ in
            self?.terminalSpecs.append(spec)
            return ScriptedTerminalSession()
        })
        var registry = CommandRegistry()
        registry.register(RepoRegistryHandler(service: service))
        registry.register(WorkspaceCommandHandler(service: service))
        registry.register(TerminalCommandHandler(service: terminals, workspaces: service,
                                                 hosts: hosts, hostRunner: runner))
        registry.register(FileCommandHandler(workspaces: service))
        registry.register(ConflictsCommandHandler(workspaces: service))
        server = InMemoryRuntimeServer(registry: registry, runtimeId: "rt_remote")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func call(_ method: String, _ params: [String: JSONValue] = [:]) async -> RPCResponse {
        await server.perform(RPCRequest(method: method, params: .object(params)))
    }

    /// Script the happy-path answers a remote repo add + listing needs.
    private func scriptHealthyHost() {
        runner.on("test -d /srv/work/orchard/.git", stdout(""))
        runner.on("for-each-ref '--format=%(refname)' refs/remotes",
                  stdout("refs/remotes/origin/main\n"))
        runner.on("worktree list --porcelain", stdout(porcelain))
    }

    @discardableResult
    private func addRemoteRepo() async throws -> RepoRecord {
        scriptHealthyHost()
        let added = await call("repo-add", ["path": .string(repoPath),
                                            "host": .string("ssh:build")])
        XCTAssertTrue(added.ok, String(describing: added.error))
        return try XCTUnwrap(service.listRepos().first)
    }

    // MARK: - Registration

    func testRepoAddProbesTheRemotePathBeforeRegistering() async throws {
        let repo = try await addRemoteRepo()
        XCTAssertEqual(repo.hostId, "ssh:build")
        XCTAssertEqual(repo.path, repoPath)
        XCTAssertEqual(repo.baseRef, "origin/main")
        // Bounded twice and never interactive: BatchMode is what makes an unattended
        // probe safe, ConnectTimeout is what keeps the connect phase from eating the
        // whole deadline.
        let probe = try XCTUnwrap(runner.commandLines.first { $0.contains("test -d") })
        XCTAssertTrue(probe.contains("/usr/bin/ssh"))
        XCTAssertTrue(probe.contains("-o BatchMode=yes"))
        XCTAssertTrue(probe.contains("-o ConnectTimeout=5"))
        XCTAssertTrue(probe.contains("ci@build.internal"))
        XCTAssertTrue(probe.hasSuffix("test -d /srv/work/orchard/.git"), probe)
    }

    func testRepoAddRefusesAnUnregisteredHost() async {
        let added = await call("repo-add", ["path": .string(repoPath),
                                            "host": .string("ssh:nope")])
        XCTAssertEqual(added.error?.code, "unknown_host")
        XCTAssertTrue(service.listRepos().isEmpty)
        XCTAssertTrue(runner.commandLines.isEmpty, "nothing may be probed for an unknown host")
    }

    func testRepoAddRefusesAHostIdThatDoesNotParse() async {
        let added = await call("repo-add", ["path": .string(repoPath),
                                            "host": .string("runtime:vm-1")])
        XCTAssertEqual(added.error?.code, "invalid_argument")
        XCTAssertTrue(service.listRepos().isEmpty)
    }

    func testRepoAddRefusesAPathThatIsNotACheckout() async {
        // `test -d` answered — through a working connection — that there is no .git.
        runner.on("test -d", HostCommandResult(exitCode: 1))
        let added = await call("repo-add", ["path": .string(repoPath),
                                            "host": .string("ssh:build")])
        XCTAssertEqual(added.error?.code, "remote_not_a_repo")
        XCTAssertTrue(service.listRepos().isEmpty)
    }

    func testRepoAddRegistersNothingWhenTheHostCannotBeReached() async {
        runner.on("test -d", transportFailure())
        let added = await call("repo-add", ["path": .string(repoPath),
                                            "host": .string("ssh:build")])
        // "We could not look" is not "it is there" — and it is not "it is missing"
        // either, so the message carries the rule-2 reminder rather than a verdict.
        XCTAssertEqual(added.error?.code, "host_unverifiable")
        XCTAssertTrue(added.error?.message.contains("not evidence") ?? false,
                      added.error?.message ?? "")
        XCTAssertTrue(service.listRepos().isEmpty)
    }

    // MARK: - List

    func testRemoteWorktreesProjectIntoTheWorkspaceRegistry() async throws {
        let repo = try await addRemoteRepo()
        let listed = await call("worktree-list", ["repo": .string(repo.id)])
        XCTAssertTrue(listed.ok, String(describing: listed.error))
        let rows = listed.result?.objectValue?["worktrees"]?.arrayValue ?? []
        XCTAssertEqual(rows.count, 2)
        let ids = rows.compactMap { $0.objectValue?["id"]?.stringValue }
        XCTAssertTrue(ids.contains("\(repo.id)::/srv/work/orchard"))
        XCTAssertTrue(ids.contains("\(repo.id)::/home/ci/Orchard/worktrees/orchard/apricot"))
        // Every projected row carries the host it lives on; nothing reads as local.
        XCTAssertEqual(Set(rows.compactMap { $0.objectValue?["hostId"]?.stringValue }),
                       ["ssh:build"])
        let apricot = try XCTUnwrap(rows.first {
            $0.objectValue?["branch"]?.stringValue == "ci/apricot"
        })
        XCTAssertEqual(apricot.objectValue?["head"]?.stringValue,
                       "2222222222222222222222222222222222222222")
    }

    func testAnUnreachableHostKeepsTheLastKnownWorktreesInsteadOfListingNone() async throws {
        let repo = try await addRemoteRepo()
        _ = await call("worktree-list", ["repo": .string(repo.id)])
        // The host goes away. An empty listing here would read as "the worktrees are
        // gone" — the classic false `exited` — so the last known set stands and the
        // caller is told the answer is stale.
        runner.on("worktree list --porcelain", transportFailure())
        let listed = await call("worktree-list", ["repo": .string(repo.id)])
        XCTAssertTrue(listed.ok)
        XCTAssertEqual(listed.result?.objectValue?["worktrees"]?.arrayValue?.count, 2)
        let warning = try XCTUnwrap(listed.result?.objectValue?["warning"]?.stringValue)
        XCTAssertTrue(warning.contains("ssh:build"), warning)
        XCTAssertTrue(warning.contains("last known"), warning)
        XCTAssertEqual(store.load().remoteWorktrees.count, 2)
    }

    func testAHostThatAnswersRetiresWorktreesItNoLongerLists() async throws {
        let repo = try await addRemoteRepo()
        _ = await call("worktree-list", ["repo": .string(repo.id)])
        XCTAssertEqual(store.load().remoteWorktrees.count, 2)
        // This time the host answered, so absence is evidence.
        runner.on("worktree list --porcelain", stdout("""
            worktree /srv/work/orchard
            HEAD 1111111111111111111111111111111111111111
            branch refs/heads/main

            """))
        let listed = await call("worktree-list", ["repo": .string(repo.id)])
        XCTAssertNil(listed.result?.objectValue?["warning"]?.stringValue)
        XCTAssertEqual(listed.result?.objectValue?["worktrees"]?.arrayValue?.count, 1)
        XCTAssertEqual(store.load().remoteWorktrees.count, 1)
    }

    // MARK: - Create

    func testCreatePinsTheForkPointAndDoesNotTrack() async throws {
        let repo = try await addRemoteRepo()
        runner.on("printf %s \"$HOME\"", stdout("/home/ci\n"))
        runner.on("rev-parse origin/main", stdout("abc1234def5678\n"))
        runner.on("config user.name", stdout("ci\n"))
        runner.on("'--format=%(refname:short)' refs/heads", stdout("main\nci/apricot\n"))
        runner.on("mkdir -p", stdout(".\n..\napricot\n"))

        let created = await call("worktree-create", ["repo": .string(repo.id),
                                                     "name": .string("apricot")])
        XCTAssertTrue(created.ok, String(describing: created.error))
        let workspace = try XCTUnwrap(created.result?.objectValue?["worktree"]?.objectValue)
        // Both the branch and the directory collide with what the host already has, so
        // both take the readable `-2` suffix rather than a UUID salt.
        XCTAssertEqual(workspace["branch"]?.stringValue, "ci/apricot-2")
        XCTAssertEqual(workspace["path"]?.stringValue,
                       "/home/ci/Orchard/worktrees/orchard/apricot-2")
        XCTAssertEqual(workspace["hostId"]?.stringValue, "ssh:build")
        XCTAssertEqual(workspace["id"]?.stringValue,
                       "\(repo.id)::/home/ci/Orchard/worktrees/orchard/apricot-2")
        // The fork point is a resolved commit, not the moving ref: `--no-track` so the
        // fresh worktree does not read as "behind by N".
        XCTAssertTrue(runner.ran("worktree add --no-track -b ci/apricot-2 "
            + "/home/ci/Orchard/worktrees/orchard/apricot-2 abc1234def5678"),
                      runner.commandLines.joined(separator: "\n"))
        XCTAssertEqual(workspace["baseRef"]?.stringValue, "abc1234def5678")
    }

    func testCreateRefusesWhenTheHostStopsAnswering() async throws {
        let repo = try await addRemoteRepo()
        runner.on("printf %s \"$HOME\"", transportFailure())
        let created = await call("worktree-create", ["repo": .string(repo.id),
                                                     "name": .string("apricot")])
        XCTAssertEqual(created.error?.code, "host_unverifiable")
        // Nothing was created and nothing was recorded: the worktree base could not even
        // be resolved, so guessing one would have picked an `rm -rf` target by hand.
        XCTAssertFalse(runner.ran("worktree add"))
        XCTAssertEqual(store.load().remoteWorktrees.count, 2)
    }

    // MARK: - Delete

    private func scriptCreatedWorktree(repo: RepoRecord) async -> String {
        runner.on("printf %s \"$HOME\"", stdout("/home/ci\n"))
        runner.on("rev-parse origin/main", stdout("abc1234\n"))
        runner.on("'--format=%(refname:short)' refs/heads", stdout("main\n"))
        runner.on("mkdir -p", stdout(".\n..\n"))
        let created = await call("worktree-create", ["repo": .string(repo.id),
                                                     "name": .string("bramble")])
        // The host now lists it too — a delete confirms its target against this.
        runner.on("worktree list --porcelain", stdout(porcelain + """
            worktree /home/ci/Orchard/worktrees/orchard/bramble
            HEAD abc1234
            branch refs/heads/ci/bramble

            """))
        return created.result?.objectValue?["worktree"]?.objectValue?["id"]?.stringValue ?? ""
    }

    func testDeletePreflightCountsUncommittedAndUnpushedOnTheHost() async throws {
        let repo = try await addRemoteRepo()
        let id = await scriptCreatedWorktree(repo: repo)
        runner.on("status --porcelain", stdout(" M src/a.swift\n?? src/b.swift\n"))
        runner.on("rev-parse --abbrev-ref --symbolic-full-name @{u}", stdout("origin/ci/bramble\n"))
        runner.on("rev-list --count", stdout("3\n"))

        let removed = await call("worktree-rm", ["worktree": .string(id)])
        XCTAssertEqual(removed.error?.code, "worktree_dirty")
        let message = removed.error?.message ?? ""
        XCTAssertTrue(message.contains("2 uncommitted files on build"), message)
        XCTAssertTrue(message.contains("3 commits are not pushed"), message)
        XCTAssertFalse(runner.ran("worktree remove"), "a refused delete must not run")
        XCTAssertTrue(store.load().remoteWorktrees.contains { $0.id == id })
    }

    func testDeleteRefusesWhenThePreflightCannotBeCounted() async throws {
        let repo = try await addRemoteRepo()
        let id = await scriptCreatedWorktree(repo: repo)
        runner.on("status --porcelain", transportFailure())

        let removed = await call("worktree-rm", ["worktree": .string(id), "force": .bool(true)])
        // Even with --force: an uncounted preflight is not a clean one. Guessing here
        // destroys an agent's only output on a machine nothing local can recover from.
        XCTAssertEqual(removed.error?.code, "host_unverifiable")
        XCTAssertFalse(runner.ran("worktree remove"))
        XCTAssertTrue(store.load().remoteWorktrees.contains { $0.id == id })
    }

    func testForcedDeleteRemovesTheWorktreeAndItsRecord() async throws {
        let repo = try await addRemoteRepo()
        let id = await scriptCreatedWorktree(repo: repo)
        runner.on("status --porcelain", stdout(" M src/a.swift\n"))
        runner.on("rev-parse --abbrev-ref --symbolic-full-name @{u}", HostCommandResult(exitCode: 128))
        runner.on("rev-list --count", stdout("0\n"))
        runner.on("worktree remove", stdout(""))

        let removed = await call("worktree-rm", ["worktree": .string(id), "force": .bool(true)])
        XCTAssertTrue(removed.ok, String(describing: removed.error))
        XCTAssertEqual(removed.result?.objectValue?["removed"]?.boolValue, true)
        XCTAssertTrue(runner.ran("worktree remove /home/ci/Orchard/worktrees/orchard/bramble --force"),
                      runner.commandLines.joined(separator: "\n"))
        XCTAssertFalse(store.load().remoteWorktrees.contains { $0.id == id })
        XCTAssertNil(store.load().worktreeMeta[id])
    }

    func testDeleteRefusesAPathTheHostDoesNotListAsAWorktreeOfThisRepo() async throws {
        let repo = try await addRemoteRepo()
        let id = await scriptCreatedWorktree(repo: repo)
        runner.on("status --porcelain", stdout(""))
        runner.on("rev-parse --abbrev-ref --symbolic-full-name @{u}", HostCommandResult(exitCode: 128))
        // The record says one thing, the host says another. A recursive delete on a
        // machine nothing local can inspect goes with the host.
        runner.on("worktree list --porcelain", stdout(porcelain))
        let removed = await call("worktree-rm", ["worktree": .string(id), "force": .bool(true)])
        XCTAssertEqual(removed.error?.code, "remote_git_failed")
        XCTAssertFalse(runner.ran("worktree remove"))
        XCTAssertTrue(store.load().remoteWorktrees.contains { $0.id == id })
    }

    func testDeleteRefusesTheReposOwnCheckout() async throws {
        let repo = try await addRemoteRepo()
        _ = await call("worktree-list", ["repo": .string(repo.id)])
        let removed = await call("worktree-rm", [
            "worktree": .string("\(repo.id)::/srv/work/orchard"), "force": .bool(true)])
        XCTAssertEqual(removed.error?.code, "invalid_argument")
        XCTAssertFalse(runner.ran("worktree remove"))
    }

    // MARK: - Terminals

    func testTerminalInARemoteWorktreeOpensAnSSHLoginShellThere() async throws {
        let repo = try await addRemoteRepo()
        _ = await call("worktree-list", ["repo": .string(repo.id)])
        let id = "\(repo.id)::/home/ci/Orchard/worktrees/orchard/apricot"

        let created = await call("terminal-create", ["worktree": .string(id)])
        XCTAssertTrue(created.ok, String(describing: created.error))
        XCTAssertEqual(created.result?.objectValue?["executionHostId"]?.stringValue, "ssh:build")
        XCTAssertEqual(created.result?.objectValue?["worktreeId"]?.stringValue, id)

        let spec = try XCTUnwrap(terminalSpecs.last)
        XCTAssertEqual(spec.executionHostId, "ssh:build")
        // A local PTY whose child is `ssh -tt`, cd-ing on the far side. The local cwd is
        // deliberately untouched: a remote path handed to a local chdir either fails or
        // finds a same-named local directory.
        XCTAssertTrue(spec.prompt.contains("/usr/bin/ssh -tt ci@build.internal"), spec.prompt)
        XCTAssertTrue(spec.prompt.contains("cd /home/ci/Orchard/worktrees/orchard/apricot &&"),
                      spec.prompt)
        XCTAssertTrue(spec.prompt.contains("exec \"${SHELL:-/bin/sh}\" -l"), spec.prompt)
    }

    /// T39 replaced T32's refusal here: an agent engine in a remote worktree now
    /// launches the agent *there*. With no hook channel installed in this fixture the
    /// pane degrades typed to fingerprint-only rather than claiming a channel it does
    /// not have — the behaviour T39's own suite pins in both directions.
    func testTerminalInARemoteWorktreeLaunchesTheAgentOnTheFarSide() async throws {
        let repo = try await addRemoteRepo()
        _ = await call("worktree-list", ["repo": .string(repo.id)])
        let created = await call("terminal-create", [
            "worktree": .string("\(repo.id)::/home/ci/Orchard/worktrees/orchard/apricot"),
            "engine": .string("claude-code")])
        XCTAssertTrue(created.ok, String(describing: created.error))
        XCTAssertEqual(created.result?.objectValue?["engine"]?.stringValue, "claude-code")
        XCTAssertEqual(
            created.result?.objectValue?["statusDetection"]?.objectValue?["mode"]?.stringValue,
            "fingerprint-only")
        let argv = try XCTUnwrap(terminalSpecs.last?.launchArgv)
        XCTAssertEqual(argv.first, "/usr/bin/ssh")
        XCTAssertTrue(argv.last?.hasSuffix("exec claude'") ?? false, argv.last ?? "")
    }

    func testAgentFirstCreateOnARemoteRepoIsRefused() async throws {
        let repo = try await addRemoteRepo()
        runner.on("printf %s \"$HOME\"", stdout("/home/ci\n"))
        runner.on("rev-parse origin/main", stdout("abc1234\n"))
        runner.on("'--format=%(refname:short)' refs/heads", stdout("main\n"))
        runner.on("mkdir -p", stdout(".\n..\n"))
        let created = await call("worktree-create", ["repo": .string(repo.id),
                                                     "name": .string("cherry"),
                                                     "agent": .string("claude-code")])
        XCTAssertEqual(created.error?.code, "remote_unsupported")
    }

    // MARK: - Files

    func testFileServiceRefusesARemoteWorkspace() async throws {
        let repo = try await addRemoteRepo()
        _ = await call("worktree-list", ["repo": .string(repo.id)])
        let read = await call("file-read-dir", [
            "worktree": .string("\(repo.id)::/home/ci/Orchard/worktrees/orchard/apricot")])
        XCTAssertEqual(read.error?.code, "remote_unsupported")
        XCTAssertTrue(read.error?.message.contains("ssh:build") ?? false,
                      read.error?.message ?? "")
    }

    func testConflictsRefuseARemoteWorkspace() async throws {
        let repo = try await addRemoteRepo()
        _ = await call("worktree-list", ["repo": .string(repo.id)])
        let listed = await call("conflicts-list", [
            "worktree": .string("\(repo.id)::/home/ci/Orchard/worktrees/orchard/apricot")])
        XCTAssertEqual(listed.error?.code, "remote_unsupported")
        XCTAssertTrue(listed.error?.message.contains("ssh:build") ?? false,
                      listed.error?.message ?? "")
    }

    func testForgetUnregistersWithoutIssuingRemoteWorktreeDeletes() async throws {
        let repo = try await addRemoteRepo()
        let listed = await call("worktree-list", ["repo": .string(repo.id)])
        XCTAssertEqual(listed.result?.objectValue?["worktrees"]?.arrayValue?.count, 2)

        let refused = await call("repo-remove", ["repo": .string(repo.id)])
        XCTAssertEqual(refused.error?.code, "repo_in_use")

        let before = runner.commandLines
        let forgotten = await call("repo-remove", [
            "repo": .string(repo.id), "forget": .bool(true),
        ])
        XCTAssertTrue(forgotten.ok, String(describing: forgotten.error))
        XCTAssertEqual(forgotten.result?.objectValue?["forgotten"]?.boolValue, true)
        XCTAssertEqual(forgotten.result?.objectValue?["hostUntouched"]?.boolValue, true)
        XCTAssertEqual(runner.commandLines, before,
                       "forget must not ssh or git-worktree-remove on the host")
        XCTAssertFalse(runner.ran("worktree remove"), runner.commandLines.joined(separator: "\n"))
        XCTAssertTrue(service.listRepos().isEmpty)
        XCTAssertTrue(store.load().remoteWorktrees.isEmpty)
        let afterList = await call("worktree-list")
        let remaining = afterList.result?.objectValue?["worktrees"]?.arrayValue ?? []
        XCTAssertTrue(remaining.isEmpty, String(describing: remaining))
    }
}

/// Rule-1 edges that must never resolve to "local": a workspace whose host stamp cannot
/// be read, and a local `cwd` that happens to spell a remote worktree's path.
@MainActor
final class RemoteHostStampTests: XCTestCase {
    private var tmp: URL!
    private var store: OrchardDataStore!
    private var service: WorkspaceService!
    private var server: InMemoryRuntimeServer!
    private var terminalSpecs: [TerminalCreateSpec] = []

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orchard-stamp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        store = OrchardDataStore(url: tmp.appendingPathComponent("orchard-data.json"))
        service = WorkspaceService(store: store, worktreesRoot: tmp.appendingPathComponent("wt"))
        terminalSpecs = []
        let terminals = TerminalService(factory: { [weak self] spec, _ in
            self?.terminalSpecs.append(spec)
            return ScriptedTerminalSession()
        })
        var registry = CommandRegistry()
        registry.register(TerminalCommandHandler(service: terminals, workspaces: service,
                                                 hosts: HostRegistry(store: store, sshConfig: { [] })))
        registry.register(WorkspaceCommandHandler(service: service))
        server = InMemoryRuntimeServer(registry: registry, runtimeId: "rt_stamp")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    /// Seed a repo + one remote worktree record directly, so the stamp under test is
    /// exactly what the store holds.
    @discardableResult
    private func seed(hostId: String, path: String) throws -> String {
        let repo = RepoRecord(path: "/srv/repo", displayName: "repo", kind: .git,
                              hostId: hostId)
        let id = RemoteWorktreeRecord.id(repoId: repo.id, path: path)
        try store.modify { data in
            data.repos.append(repo)
            data.remoteWorktrees.append(RemoteWorktreeRecord(
                id: id, repoId: repo.id, hostId: hostId, path: path, branch: "main"))
        }
        return id
    }

    func testAnUnreadableHostStampOpensNothingRatherThanALocalShell() async throws {
        // `runtime:vm-1` is Orca's ephemeral-VM kind, which Orchard has no equivalent
        // for. Reading it as local would run the work here under another host's name.
        let id = try seed(hostId: "runtime:vm-1", path: "/srv/repo/wt")
        let created = await server.perform(RPCRequest(method: "terminal-create",
                                                      params: .object(["worktree": .string(id)])))
        XCTAssertEqual(created.error?.code, "invalid_argument")
        XCTAssertTrue(terminalSpecs.isEmpty)
    }

    func testALocalCwdNeverResolvesToARemoteWorktreeThatSpellsTheSamePath() throws {
        let path = tmp.appendingPathComponent("coincidence").path
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: path),
                                                withIntermediateDirectories: true)
        try seed(hostId: "ssh:build", path: path)
        // `active`/`current` means "the workspace enclosing this local directory", and a
        // remote worktree can never be that however its path reads.
        XCTAssertThrowsError(try service.current(cwd: path)) { error in
            XCTAssertEqual((error as? WorkspaceError)?.code, "not_in_worktree")
        }
    }

    func testClosingAProjectDropsItsRemoteWorktreeRecords() throws {
        try seed(hostId: "ssh:build", path: "/srv/repo/wt")
        let repo = try XCTUnwrap(service.listRepos().first)
        _ = try service.removeRepo(repo.id)
        XCTAssertTrue(store.load().remoteWorktrees.isEmpty)
    }
}
