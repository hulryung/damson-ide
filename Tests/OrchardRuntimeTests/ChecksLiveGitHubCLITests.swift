import XCTest
@testable import OrchardRuntime

/// The unavailable paths, run against the **real** `gh` on this machine.
///
/// The fixture tests pin our classification of gh's wording; these pin that the
/// wording is still gh's. A `gh` release that changes a message would otherwise
/// silently downgrade a precise reason ("not authenticated") to `api_error`, and
/// the panel would still look fine — which is exactly the failure T88 exists to
/// prevent.
///
/// Read-only throughout: `gh pr view` and `gh auth status` only. No PR is opened,
/// no comment posted, nothing pushed. The user's own credentials are never
/// touched: the unauthenticated cases run with `GH_CONFIG_DIR` pointed at an
/// empty scratch directory and `GH_TOKEN` cleared.
final class ChecksLiveGitHubCLITests: XCTestCase {
    private var tmp: URL!
    private var ghConfig: URL!

    override func setUpWithError() throws {
        try XCTSkipIf(SystemGitHubCLI().resolvedExecutable() == nil,
                      "gh is not installed on this machine")
        try XCTSkipIf(!FileManager.default.isExecutableFile(atPath: "/usr/bin/git"),
                      "git unavailable")
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orchard-checks-live-\(UUID().uuidString)")
        ghConfig = tmp.appendingPathComponent("gh-config")
        try FileManager.default.createDirectory(at: ghConfig, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    @discardableResult
    private func git(_ args: [String], cwd: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = cwd
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// A throwaway checkout with one empty commit, and whatever remote the case needs.
    private func makeRepo(_ name: String, remote: String? = nil,
                          branch: String = "orchard-t88-probe") throws -> URL {
        let repo = tmp.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        XCTAssertEqual(try git(["init", "-q", "-b", branch], cwd: repo), 0)
        try git(["config", "user.email", "t@o.app"], cwd: repo)
        try git(["config", "user.name", "T"], cwd: repo)
        try git(["commit", "-q", "--allow-empty", "-m", "init"], cwd: repo)
        if let remote { try git(["remote", "add", "origin", remote], cwd: repo) }
        return repo
    }

    /// A service pointed at the real `gh`, with the environment each case needs.
    private func service(environment: [String: String] = [:],
                         executablePath: String? = nil) -> ChecksService {
        ChecksService(probe: SystemGitHubCLI(executablePath: executablePath,
                                             environmentOverrides: environment),
                      ttl: 0.001, timeout: 30)
    }

    /// An empty gh config plus no token: gh has nobody to be.
    private var unauthenticatedEnvironment: [String: String] {
        ["GH_CONFIG_DIR": ghConfig.path, "GH_TOKEN": "", "GITHUB_TOKEN": "",
         "GH_ENTERPRISE_TOKEN": "", "GITHUB_ENTERPRISE_TOKEN": ""]
    }

    // MARK: - Cases that need no network

    func testNoGitRemote() async throws {
        let repo = try makeRepo("no-remote")
        let snapshot = await service().snapshot(worktreeId: "w", path: repo.path)
        XCTAssertEqual(snapshot.unavailable?.reason, .noGitRemote,
                       "gh said: \(snapshot.unavailable?.detail ?? "-")")
        XCTAssertEqual(snapshot.branch, "orchard-t88-probe")
    }

    func testRemoteThatIsNotGitHub() async throws {
        let repo = try makeRepo("gitlab", remote: "https://gitlab.com/acme/widget.git")
        let snapshot = await service().snapshot(worktreeId: "w", path: repo.path)
        XCTAssertEqual(snapshot.unavailable?.reason, .unsupportedForge,
                       "gh said: \(snapshot.unavailable?.detail ?? "-")")
    }

    func testDetachedHeadIsRefusedBeforeGhRuns() async throws {
        let repo = try makeRepo("detached", remote: "https://github.com/o/r.git")
        XCTAssertEqual(try git(["checkout", "-q", "--detach", "HEAD"], cwd: repo), 0)
        let snapshot = await service().snapshot(worktreeId: "w", path: repo.path)
        XCTAssertEqual(snapshot.unavailable?.reason, .detachedHead)
        XCTAssertNil(snapshot.branch)
    }

    func testNotAGitWorktree() async throws {
        let plain = tmp.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        let snapshot = await service().snapshot(worktreeId: "w", path: plain.path)
        XCTAssertEqual(snapshot.unavailable?.reason, .notAWorktree)
    }

    func testMissingGhBinary() async throws {
        let repo = try makeRepo("no-gh", remote: "https://github.com/o/r.git")
        let missing = service(executablePath: tmp.appendingPathComponent("nope/gh").path)
        let snapshot = await missing.snapshot(worktreeId: "w", path: repo.path)
        XCTAssertEqual(snapshot.unavailable?.reason, .ghNotInstalled)
    }

    // MARK: - Cases that talk to GitHub (read-only)

    /// gh with an empty config and no token. Reaches gh, not the network.
    func testNotAuthenticated() async throws {
        let repo = try makeRepo("unauthed", remote: "https://github.com/cli/cli.git")
        let snapshot = await service(environment: unauthenticatedEnvironment)
            .snapshot(worktreeId: "w", path: repo.path)
        XCTAssertEqual(snapshot.unavailable?.reason, .ghNotAuthenticated,
                       "gh said: \(snapshot.unavailable?.detail ?? "-")")
        XCTAssertFalse(snapshot.unavailable?.remedy.isEmpty ?? true)
    }

    /// A syntactically valid but rejected token: GitHub answers HTTP 401. This is
    /// the one case that proves a *credential* failure is not reported as
    /// "no pull request" — the two are one exit code apart.
    func testRejectedCredentialsAreNotReportedAsNoPullRequest() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["ORCHARD_SKIP_NETWORK_TESTS"] == "1",
                      "network tests disabled")
        let repo = try makeRepo("badtoken", remote: "https://github.com/cli/cli.git")
        var environment = unauthenticatedEnvironment
        environment["GH_TOKEN"] = "ghp_orchardT88invalidtokenforprobing0000"
        let snapshot = await service(environment: environment)
            .snapshot(worktreeId: "w", path: repo.path)
        // Either the request was refused before it left (auth) or GitHub rejected
        // it (401 → also auth). What it must never be is `no_pull_request`.
        XCTAssertNotEqual(snapshot.unavailable?.reason, .noPullRequest)
        XCTAssertTrue([.ghNotAuthenticated, .apiError, .ghTimedOut]
            .contains(snapshot.unavailable?.reason),
            "unexpected \(snapshot.unavailable?.code ?? "nil"): "
                + (snapshot.unavailable?.detail ?? "-"))
    }

    /// A GitHub repo, a real login, and a branch that has no pull request. Needs
    /// the developer's own gh auth; skipped when there is none.
    func testNoPullRequestForThisBranch() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["ORCHARD_SKIP_NETWORK_TESTS"] == "1",
                      "network tests disabled")
        let authenticated = await isAuthenticated()
        try XCTSkipUnless(authenticated, "gh is not logged in on this machine")
        let repo = try makeRepo("nopr", remote: "https://github.com/cli/cli.git",
                                branch: "orchard-t88-branch-that-has-no-pr")
        let snapshot = await service().snapshot(worktreeId: "w", path: repo.path)
        XCTAssertEqual(snapshot.unavailable?.reason, .noPullRequest,
                       "gh said: \(snapshot.unavailable?.detail ?? "-")")
    }

    /// The one available path we can reach read-only: a real open PR on a public
    /// repo, read through the same parser the sidebar uses.
    func testRealPullRequestParsesIntoTypedChecks() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["ORCHARD_SKIP_NETWORK_TESTS"] == "1",
                      "network tests disabled")
        let authenticated = await isAuthenticated()
        try XCTSkipUnless(authenticated, "gh is not logged in on this machine")
        let probe = SystemGitHubCLI()
        let numbers = await probe.run(
            ["pr", "list", "--repo", "cli/cli", "--limit", "1", "--json", "number",
             "--jq", ".[0].number"],
            cwd: tmp, timeout: 30)
        let number = numbers.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        try XCTSkipIf(number.isEmpty, "cli/cli has no open pull request to read")

        let outcome = await probe.run(
            ["pr", "view", number, "--repo", "cli/cli", "--json", ChecksService.prFields],
            cwd: tmp, timeout: 30)
        switch GitHubChecksParser.parsePullRequest(outcome) {
        case .failure(let reason):
            XCTFail("live read failed: \(reason.code) — \(reason.detail)")
        case .success(let (pr, checks)):
            XCTAssertEqual(String(pr.number), number)
            XCTAssertEqual(pr.repository, "cli/cli")
            XCTAssertFalse(pr.headRefOid.isEmpty)
            // Whatever the checks are today, every one must land in a named bucket
            // and none may be silently dropped.
            for check in checks {
                XCTAssertFalse(check.name.isEmpty)
                XCTAssertNotNil(CheckBucket(rawValue: check.bucket))
                XCTAssertFalse(check.bucketLabel.isEmpty)
            }
            let rollup = ChecksRollup.from(checks)
            XCTAssertEqual(rollup == .none, checks.isEmpty)
        }
    }

    private func isAuthenticated() async -> Bool {
        await SystemGitHubCLI().run(["auth", "status"], cwd: tmp, timeout: 20).status == 0
    }
}
