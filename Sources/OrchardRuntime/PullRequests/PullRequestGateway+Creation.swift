import Foundation
import OrchardCore

/// The two things the creation path needs from `GitHubPRGateway` that the spine
/// does not offer, kept apart from the shared file because three features are
/// being built on that file at once.
///
/// Both exist for the same reason: `run()` collapses every nonzero exit into a
/// classified refusal, which is right when a failure is a failure. Asking whether
/// a branch exists is the one place where a nonzero exit is an *answer* — HTTP 404
/// means "no such branch", not "something went wrong" — so this file needs the
/// exit status itself. Nothing here launches `gh` outside the gateway; `probe`
/// stays the single door.

/// Whether a ref exists on the remote, with "we could not tell" kept apart from
/// "it is not there".
///
/// The third case is the whole point. Answering `missing` when the network was
/// down would refuse a perfectly good base and tell the user to push a branch
/// that is already pushed — the same class of lie as reporting a failed pull
/// request lookup as "no pull request exists".
public enum RemoteBranchLookup: Equatable, Sendable {
    case exists
    case missing
    case couldNotTell(PullRequestRefusal)
}

extension GitHubPRGateway {

    /// Run `gh` and hand back the raw outcome, or nil when there is no `gh` to run.
    ///
    /// Deliberately not public: exactly one caller is entitled to see an exit
    /// status, and widening this would put a second stderr vocabulary back in the
    /// codebase — the thing `classify` exists to prevent.
    func outcome(_ arguments: [String], cwd: URL,
                 timeout override: TimeInterval? = nil) async -> GitHubCLIOutcome? {
        guard probe.resolvedExecutable() != nil else { return nil }
        return await probe.run(arguments, cwd: cwd, timeout: override ?? timeout)
    }

    /// Does `branch` exist on `repository`?
    ///
    /// Asked of GitHub rather than of the local remote-tracking refs on purpose: a
    /// base that exists but was never fetched reads as missing locally, and
    /// `refs/remotes/origin/main` can be months stale. The base is where the pull
    /// request will land, so the forge is the only authority worth asking.
    public func remoteBranch(_ branch: String, repository: String,
                             cwd: URL) async -> RemoteBranchLookup {
        let trimmed = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .couldNotTell(PullRequestRefusal(.noBaseRef, detail: "No branch name was given."))
        }
        let path = "repos/\(repository)/branches/\(Self.pathEscaped(trimmed))"
        guard let outcome = await outcome(["api", path, "--jq", ".name"], cwd: cwd) else {
            return .couldNotTell(PullRequestRefusal(.ghNotInstalled,
                detail: "No gh binary on this machine's PATH or in the usual install locations."))
        }
        if outcome.timedOut {
            return .couldNotTell(PullRequestRefusal(.ghTimedOut,
                detail: "gh api \(path) did not answer in time."))
        }
        if outcome.status == 0 { return .exists }
        // GitHub's own 404 is the "no such branch" answer. Every other nonzero exit
        // — 401, 403, a rate limit, a DNS failure — is a gap in our knowledge and
        // is reported as one.
        let lowered = (outcome.stderr.isEmpty ? outcome.stdout : outcome.stderr).lowercased()
        if lowered.contains("http 404") || lowered.contains("not found") {
            return .missing
        }
        return .couldNotTell(Self.classify(outcome))
    }

    /// Percent-escape a ref for a `gh api` path. Branch names may contain `#`, `?`
    /// and other characters that would otherwise be read as URL syntax; `/` is left
    /// alone because `release/1.0` is a path in GitHub's own API.
    static func pathEscaped(_ ref: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#")
        return ref.addingPercentEncoding(withAllowedCharacters: allowed) ?? ref
    }
}
