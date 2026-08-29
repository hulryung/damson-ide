import Foundation
import OrchardCore

// MARK: - The git seam

/// The git facts opening a pull request depends on.
///
/// A seam rather than direct `GitRunner` calls, for the reason T88 gave: every
/// rung of the eligibility ladder is then testable without building a repository
/// in a temp directory, and the tests that matter most here are the ones about
/// *ordering*, which need to construct states that are awkward to produce for
/// real (detached HEAD with an upstream, an unfetched base).
///
/// Note what is absent: whether a remote is configured. That question is answered
/// by `gh`, not by git — `gh` says "no git remotes found" in its own words and
/// `GitHubPRGateway.classify` already turns that into `.noGitRemote`. Asking git
/// as well would be a second vocabulary for one fact.
public struct PullRequestGitFacts: Equatable, Sendable {
    public var isRepository: Bool
    /// nil = detached HEAD, so there is no branch to propose.
    public var branch: String?
    public var headSha: String?
    /// `origin/topic`, or nil when the branch has no upstream — which is the same
    /// as saying GitHub has never seen it.
    public var upstream: String?
    /// Commits on HEAD that the upstream does not have. nil = we could not count,
    /// which is not the same as zero and is never reported as zero.
    public var aheadOfUpstream: Int?
    /// Remote names, `origin` first when it exists.
    public var remotes: [String]

    public init(isRepository: Bool, branch: String? = nil, headSha: String? = nil,
                upstream: String? = nil, aheadOfUpstream: Int? = nil,
                remotes: [String] = []) {
        self.isRepository = isRepository
        self.branch = branch
        self.headSha = headSha
        self.upstream = upstream
        self.aheadOfUpstream = aheadOfUpstream
        self.remotes = remotes
    }

    /// The remote the branch tracks, read off the upstream rather than guessed.
    public var upstreamRemote: String? {
        guard let upstream, let slash = upstream.firstIndex(of: "/") else { return nil }
        return String(upstream[upstream.startIndex..<slash])
    }

    /// The remote to push a not-yet-pushed branch to. `origin` when there is one,
    /// otherwise the only other candidate; nil when there is nothing to choose
    /// from, which is a refusal rather than a default.
    public var preferredRemote: String? {
        upstreamRemote ?? remotes.first
    }
}

/// Whatever git said when a push did not work. A type rather than a bare `String`
/// only because `Result`'s failure must be an `Error`; the message is git's own.
public struct GitPushFailure: Error, Equatable, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
}

/// Every git operation this feature performs, in one injectable value.
///
/// `push` is deliberately here and deliberately alone: it is the only verb in
/// this file that writes anything, it is never called from `create`, and having
/// it as a separate closure makes "the create path did not push" a fact a test
/// can assert rather than a comment somebody has to keep true.
public struct PullRequestGitSeam: Sendable {
    public var facts: @Sendable (URL) -> PullRequestGitFacts
    /// Commits on HEAD that `ref` does not have (`ref` is a full remote-tracking
    /// ref such as `origin/main`). nil when it could not be counted.
    public var commitsAhead: @Sendable (URL, String) -> Int?
    /// `git push --set-upstream <remote> <branch>`. Success carries git's stdout,
    /// failure carries git's own message.
    public var push: @Sendable (URL, String, String) -> Result<String, GitPushFailure>

    public init(facts: @escaping @Sendable (URL) -> PullRequestGitFacts,
                commitsAhead: @escaping @Sendable (URL, String) -> Int?,
                push: @escaping @Sendable (URL, String, String) -> Result<String, GitPushFailure>) {
        self.facts = facts
        self.commitsAhead = commitsAhead
        self.push = push
    }
}

public extension PullRequestGitSeam {
    /// The production seam.
    ///
    /// Every reading verb here (`rev-parse`, `rev-list`, `for-each-ref`) is in
    /// `GitRunner.readOnlyVerbs`, so reading eligibility invalidates nobody's
    /// `GitFactsCache` entry and adds no git cost to a workspace switch. `push`
    /// is a mutation and is correctly counted as one.
    static let live = PullRequestGitSeam(
        facts: { root in
            let runner = GitRunner.shared
            guard runner.line(in: root, ["rev-parse", "--is-inside-work-tree"]) == "true" else {
                return PullRequestGitFacts(isRepository: false)
            }
            let branch = runner.line(in: root, ["symbolic-ref", "--short", "-q", "HEAD"])
            let head = runner.line(in: root, ["rev-parse", "HEAD"])
            let upstream = runner.line(
                in: root, ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"])
            let ahead = upstream.flatMap { _ in
                runner.line(in: root, ["rev-list", "--count", "@{u}..HEAD"]).flatMap(Int.init)
            }
            return PullRequestGitFacts(
                isRepository: true, branch: branch, headSha: head, upstream: upstream,
                aheadOfUpstream: ahead, remotes: remoteNames(in: root))
        },
        commitsAhead: { root, ref in
            GitRunner.shared.line(in: root, ["rev-list", "--count", "\(ref)..HEAD"])
                .flatMap(Int.init)
        },
        push: { root, remote, branch in
            do {
                return .success(try GitRunner.shared.run(
                    in: root, ["push", "--set-upstream", remote, branch]))
            } catch {
                return .failure(GitPushFailure(String(describing: error)))
            }
        })

    /// Remote names taken from `refs/remotes`, `origin` first.
    ///
    /// `for-each-ref` rather than `git remote`: the latter is not one of
    /// `GitRunner`'s read-only verbs, so asking it would drop the worktree's cached
    /// git facts every time an eligibility banner refreshed.
    private static func remoteNames(in root: URL) -> [String] {
        let listing = GitRunner.shared.query(
            in: root, ["for-each-ref", "--format=%(refname:short)", "refs/remotes"]) ?? ""
        var seen: Set<String> = []
        var names: [String] = []
        for line in listing.split(separator: "\n") {
            guard let slash = line.firstIndex(of: "/") else { continue }
            let name = String(line[line.startIndex..<slash])
            if !name.isEmpty, seen.insert(name).inserted { names.append(name) }
        }
        return names.sorted { lhs, rhs in
            if (lhs == "origin") != (rhs == "origin") { return lhs == "origin" }
            return lhs < rhs
        }
    }
}

// MARK: - Repository identity

/// What `gh repo view` tells us about where a pull request would land.
public struct PullRequestRepositoryIdentity: Equatable, Sendable {
    public var nameWithOwner: String
    /// nil when GitHub did not name one. Never defaulted to `main` — a repository
    /// whose default branch we cannot read is a repository whose base we do not
    /// know, and guessing is how a pull request gets opened against the wrong ref.
    public var defaultBranch: String?

    public init(nameWithOwner: String, defaultBranch: String? = nil) {
        self.nameWithOwner = nameWithOwner
        self.defaultBranch = defaultBranch
    }
}

// MARK: - The service

/// Opening a pull request from a worktree: whether it can be done, and doing it.
///
/// Three rules shape the whole type.
///
/// **Eligibility is evidence, not a boolean.** Every dead end is a named
/// `PullRequestRefusal` carrying `gh`'s own words and one thing to do about it,
/// and the eligibility that carries it also carries everything learned on the way
/// there — the head, the base when one resolved, whether a push is owed. A
/// disabled Create button that cannot say why is the failure this type exists to
/// prevent.
///
/// **A failed lookup is never a negative answer.** `existingLookup` has three
/// values and the third one is load-bearing: `.unavailable` means we could not
/// ask, and it is never reported as `.notFound`. Conflating them is how a second
/// pull request gets opened on a branch that already had one.
///
/// **Nothing is pushed without being asked.** `create` never pushes, whatever
/// eligibility said. `pushHead` is a separate call so the affordance is a button a
/// person presses, not a side effect they discover afterwards.
public struct PullRequestCreationService: Sendable {
    public let gateway: GitHubPRGateway
    public let git: PullRequestGitSeam

    public init(gateway: GitHubPRGateway = GitHubPRGateway(),
                git: PullRequestGitSeam = .live) {
        self.gateway = gateway
        self.git = git
    }

    /// Fields the existing-pull-request lookup asks for. Small on purpose: this is
    /// a "does one exist" question on a UI path, not a detail read.
    static let existingFields = "number,url,state,isDraft,title,headRefName"

    // MARK: - Eligibility

    /// Can a pull request be opened from this worktree right now, and if not, why?
    ///
    /// The ladder is ordered cheapest-and-most-fundamental first, so the common
    /// refusals cost no network at all: a folder that is not a worktree, a machine
    /// with no `gh`, and a detached HEAD are all answered before anything is
    /// launched. `base` is the caller's preference; nil means "use the
    /// repository's default branch".
    public func eligibility(worktree: URL, base: String? = nil,
                            hostId: String = "local") async
        -> PullRequestCreationEligibility {

        // A remote workspace is refused before git runs, not after. The local path
        // of a remote workspace either does not exist or — worse — is some unrelated
        // directory on this machine, and running git on it would answer confidently
        // about a checkout that is not the one the user is looking at.
        if hostId != "local" {
            return PullRequestCreationEligibility(
                refusal: PullRequestRefusal(.remoteWorkspace,
                    detail: "This workspace's files live on \(hostId)."))
        }

        let reader = git.facts
        let facts = await Task.detached(priority: .utility) { reader(worktree) }.value

        guard facts.isRepository else {
            return PullRequestCreationEligibility(
                refusal: PullRequestRefusal(.notAWorktree,
                    detail: "\(worktree.path) is not inside a git work tree."))
        }

        // Read once, here: it is a cheap local read, it is wanted even on the
        // refusal paths (a sheet can prefill the body while the branch still needs
        // a push), and doing it later would mean doing it on every rung.
        let template = PullRequestTemplate.find(in: worktree)

        /// Every early exit carries what was learned before it. Partial evidence is
        /// still evidence, and the banner is better for having it.
        func refuse(_ refusal: PullRequestRefusal,
                    head: String? = facts.branch,
                    resolvedBase: String? = nil,
                    commitsAhead: Int? = nil,
                    needsPush: Bool = false,
                    lookup: PullRequestCreationEligibility.ExistingLookup = .unavailable,
                    existing: PullRequestRef? = nil) -> PullRequestCreationEligibility {
            PullRequestCreationEligibility(
                refusal: refusal, existingLookup: lookup, existing: existing,
                resolvedBase: resolvedBase, head: head, commitsAhead: commitsAhead,
                needsPush: needsPush, template: template?.body)
        }

        // Asked, never launched: "gh is not installed" must be answerable without a
        // process, and must be true for a Dock-launched app whose PATH has no
        // /opt/homebrew/bin.
        guard gateway.probe.resolvedExecutable() != nil else {
            return refuse(PullRequestRefusal(.ghNotInstalled,
                detail: "No gh binary on this machine's PATH or in the usual install locations."))
        }

        guard let head = facts.branch, !head.isEmpty else {
            return refuse(PullRequestRefusal(.detachedHead,
                detail: "HEAD is detached at \(facts.headSha?.prefix(8) ?? "an unknown commit")."),
                head: nil)
        }

        // `gh repo view` answers three questions in one call: is there a remote, is
        // it GitHub, and what is the repository's default branch. Its failures are
        // already classified — "no git remotes found" becomes `.noGitRemote` and
        // "point to a known GitHub host" becomes `.unsupportedForge` — so the forge
        // preconditions arrive here already named, in gh's own words.
        let identity: PullRequestRepositoryIdentity
        switch await repositoryIdentity(worktree: worktree) {
        case .failure(let refusal):
            return refuse(refusal)
        case .success(let value):
            identity = value
        }

        // A branch GitHub has never seen, and a branch GitHub has seen an older
        // version of, are different problems with the same remedy. Both set
        // `needsPush` so the sheet can offer the button; neither pushes anything.
        guard let upstream = facts.upstream, !upstream.isEmpty else {
            return refuse(PullRequestRefusal(.branchNotPushed,
                detail: "\(head) has no upstream branch, so GitHub cannot see it yet."),
                needsPush: true)
        }
        if let ahead = facts.aheadOfUpstream, ahead > 0 {
            return refuse(PullRequestRefusal(.unpushedCommits,
                detail: "\(head) is \(ahead) commit\(ahead == 1 ? "" : "s") ahead of \(upstream)."),
                needsPush: true)
        }

        // Compared before the base is looked up, so proposing a branch onto itself
        // costs no network call.
        let requested = base?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let requested, !requested.isEmpty, requested == head {
            return refuse(PullRequestRefusal(.baseEqualsHead,
                detail: "\(head) cannot be proposed onto itself."), resolvedBase: requested)
        }

        let resolvedBase: String
        if let requested, !requested.isEmpty {
            switch await gateway.remoteBranch(requested, repository: identity.nameWithOwner,
                                              cwd: worktree) {
            case .exists:
                resolvedBase = requested
            case .missing:
                // Deliberately not falling back to the default branch here. Silently
                // retargeting a base the user named is exactly the guess this whole
                // vocabulary exists to refuse — they asked for a branch, and the
                // answer is that it is not there.
                return refuse(PullRequestRefusal(.baseRefMissing,
                    detail: "\(identity.nameWithOwner) has no branch named \(requested)."),
                    resolvedBase: requested)
            case .couldNotTell:
                // Not knowing is not evidence of absence. The base is taken at the
                // caller's word; if it really is missing, `gh pr create` refuses in
                // GitHub's own words and that refusal is classified too.
                resolvedBase = requested
            }
        } else if let fallback = identity.defaultBranch, !fallback.isEmpty {
            resolvedBase = fallback
        } else {
            return refuse(PullRequestRefusal(.noBaseRef,
                detail: "gh could not name a default branch for \(identity.nameWithOwner)."))
        }

        // The default branch can equal the head — a worktree sitting on `main` with
        // no base named is the ordinary way to reach this.
        if resolvedBase == head {
            return refuse(PullRequestRefusal(.baseEqualsHead,
                detail: "\(head) is the base branch; there is nothing to propose it onto."),
                resolvedBase: resolvedBase)
        }

        let remote = facts.upstreamRemote ?? facts.preferredRemote
        let counter = git.commitsAhead
        let ahead: Int? = await {
            guard let remote else { return nil }
            let ref = "\(remote)/\(resolvedBase)"
            return await Task.detached(priority: .utility) { counter(worktree, ref) }.value
        }()
        // Only a counted zero refuses. An uncountable base — one that was never
        // fetched — leaves `commitsAhead` nil and lets GitHub have the last word,
        // because "we could not count" is not "there is nothing".
        if ahead == 0 {
            return refuse(PullRequestRefusal(.nothingToPropose,
                detail: "\(head) has no commits that \(resolvedBase) does not already have."),
                resolvedBase: resolvedBase, commitsAhead: 0)
        }

        let existing = await existingPullRequest(worktree: worktree, head: head,
                                                 repository: identity.nameWithOwner)
        // Only an *open* pull request blocks a new one. GitHub itself allows a fresh
        // pull request on a branch whose previous one was closed or merged, and
        // refusing there would leave the user with no way forward from the UI. The
        // closed one is still reported, because "there was one and it was merged" is
        // worth seeing before proposing the same branch again.
        if existing.lookup == .found, let ref = existing.ref, existing.state == .open {
            return refuse(PullRequestRefusal(.pullRequestExists,
                detail: "#\(ref.number) is already open for \(head): \(ref.url)"),
                resolvedBase: resolvedBase, commitsAhead: ahead,
                lookup: .found, existing: ref)
        }

        return PullRequestCreationEligibility(
            refusal: nil, existingLookup: existing.lookup, existing: existing.ref,
            resolvedBase: resolvedBase, head: head, commitsAhead: ahead,
            needsPush: false, template: template?.body)
    }

    // MARK: - Asking GitHub

    /// `gh repo view` → the repository a pull request from here would land on.
    public func repositoryIdentity(worktree: URL) async
        -> Result<PullRequestRepositoryIdentity, PullRequestRefusal> {
        let result = await gateway.json(
            ["repo", "view", "--json", "nameWithOwner,defaultBranchRef"], cwd: worktree)
        switch result {
        case .failure(let refusal):
            return .failure(refusal)
        case .success(let json):
            guard let name = json["nameWithOwner"] as? String, !name.isEmpty else {
                return .failure(PullRequestRefusal(.apiError,
                    detail: "gh repo view did not name a repository."))
            }
            let branch = (json["defaultBranchRef"] as? [String: Any])?["name"] as? String
            return .success(PullRequestRepositoryIdentity(
                nameWithOwner: name,
                defaultBranch: (branch?.isEmpty == false) ? branch : nil))
        }
    }

    /// Is there already a pull request for `head`?
    ///
    /// **The distinction this whole file is built around.** `gh` answering "no pull
    /// requests found" is a fact: `.notFound`. `gh` failing — a timeout, a 403, an
    /// expired token, output we cannot parse — is *not* that fact, and comes back
    /// `.unavailable`. Orca conflated the two and opened a second pull request on a
    /// branch that already had one; the failure was invisible because "no PR" and
    /// "could not ask" rendered identically.
    public func existingPullRequest(worktree: URL, head: String, repository: String) async
        -> (lookup: PullRequestCreationEligibility.ExistingLookup,
            ref: PullRequestRef?, state: PullRequestState) {
        // An all-digits branch name would be read by gh as a pull-request number, so
        // that one case falls back to gh's own current-branch resolution in `cwd`.
        var arguments = ["pr", "view"]
        if !head.isEmpty, !head.allSatisfy(\.isNumber) { arguments.append(head) }
        arguments += ["--json", Self.existingFields]

        switch await gateway.json(arguments, cwd: worktree) {
        case .failure(let refusal):
            // The one failure that is an answer. Everything else is a gap.
            return refusal.reason == .noPullRequest
                ? (.notFound, nil, .unknown)
                : (.unavailable, nil, .unknown)
        case .success(let json):
            guard let detail = PullRequestDecoder.detail(from: json, repository: repository) else {
                // gh exited zero and we could not read it. We asked and we do not
                // know — which is `.unavailable`, not "there is none".
                return (.unavailable, nil, .unknown)
            }
            return (.found, detail.ref, detail.state)
        }
    }

    // MARK: - Creating

    /// Open the pull request.
    ///
    /// Does exactly one thing. It does not re-run eligibility, and — whatever
    /// eligibility said — it does not push: a tool that pushes a branch because it
    /// judged a push was needed has made a network-visible decision on the user's
    /// behalf. `pushHead` is separate so that decision stays theirs.
    public func create(worktree: URL,
                       draft: PullRequestDraft) async -> Result<PullRequestRef, PullRequestRefusal> {
        // Before anything is launched: GitHub will not take an untitled pull request
        // and we will not invent a title from the branch name or the first commit.
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            return .failure(PullRequestRefusal(.emptyTitle,
                detail: "A pull request needs a title, and Orchard does not write one for you."))
        }
        let base = draft.base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else {
            return .failure(PullRequestRefusal(.noBaseRef,
                detail: "No base branch was given."))
        }
        let head = draft.head.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !head.isEmpty else {
            return .failure(PullRequestRefusal(.detachedHead,
                detail: "No head branch was given."))
        }

        var arguments = ["pr", "create", "--title", title, "--body", draft.body,
                         "--base", base, "--head", head]
        if draft.isDraft { arguments.append("--draft") }

        switch await gateway.run(arguments, cwd: worktree) {
        case .failure(let refusal):
            return .failure(refusal)
        case .success(let stdout):
            guard let ref = PullRequestURL.ref(in: stdout) else {
                // gh exited zero and printed something we cannot read as a pull
                // request. Reporting success here would hand the caller a fabricated
                // number; reporting the real output is the only honest option.
                return .failure(PullRequestRefusal(.apiError,
                    detail: "gh pr create exited 0 without printing a pull-request URL: "
                        + GitHubPRGateway.firstLine(stdout)))
            }
            return .success(ref)
        }
    }

    // MARK: - Pushing

    /// `git push --set-upstream <remote> <branch>`, and nothing else.
    ///
    /// Its own entry point precisely so that pushing is something the user asks
    /// for. The refusals are the same vocabulary as everything else here; a git
    /// failure lands on `apiError` carrying git's own message, which is what that
    /// case is for.
    public func pushHead(worktree: URL,
                         hostId: String = "local") async -> Result<String, PullRequestRefusal> {
        if hostId != "local" {
            return .failure(PullRequestRefusal(.remoteWorkspace,
                detail: "This workspace's files live on \(hostId)."))
        }
        let reader = git.facts
        let facts = await Task.detached(priority: .utility) { reader(worktree) }.value
        guard facts.isRepository else {
            return .failure(PullRequestRefusal(.notAWorktree,
                detail: "\(worktree.path) is not inside a git work tree."))
        }
        guard let branch = facts.branch, !branch.isEmpty else {
            return .failure(PullRequestRefusal(.detachedHead,
                detail: "HEAD is detached; there is no branch to push."))
        }
        guard let remote = facts.preferredRemote else {
            return .failure(PullRequestRefusal(.noGitRemote,
                detail: "This worktree has no remote to push \(branch) to."))
        }
        let push = git.push
        let outcome = await Task.detached(priority: .utility) {
            push(worktree, remote, branch)
        }.value
        switch outcome {
        case .success:
            return .success("\(remote)/\(branch)")
        case .failure(let failure):
            return .failure(PullRequestRefusal(.apiError,
                detail: GitHubPRGateway.firstLine(failure.message)))
        }
    }

    /// Branches a pull request from here could be based on, for the sheet's picker.
    ///
    /// Remote-tracking branches only: a base lives on the remote, and offering a
    /// local-only branch would offer a base that cannot be selected.
    public func candidateBases(worktree: URL) async -> [String] {
        let reader = git.facts
        let facts = await Task.detached(priority: .utility) { reader(worktree) }.value
        guard facts.isRepository, let remote = facts.preferredRemote else { return [] }
        let runner = GitRunner.shared
        let listing = await Task.detached(priority: .utility) {
            runner.query(in: worktree,
                         ["for-each-ref", "--format=%(refname:short)", "refs/remotes/\(remote)"])
        }.value ?? ""
        var seen: Set<String> = []
        var names: [String] = []
        for line in listing.split(separator: "\n") {
            let short = String(line.dropFirst(remote.count + 1))
            // `origin/HEAD` is a symbolic alias, not a branch anybody bases onto.
            guard !short.isEmpty, short != "HEAD", short != facts.branch,
                  seen.insert(short).inserted else { continue }
            names.append(short)
        }
        return names.sorted()
    }
}

// MARK: - Reading gh's own output back

/// The pull-request URL `gh pr create` prints on success.
///
/// Parsed rather than assumed: `gh` prints progress lines ("Creating pull request
/// for X into Y in owner/repo") before the URL, and on some paths a warning after
/// it. The URL is the only line that identifies what was actually created, and if
/// it is not there we say so instead of synthesising a number.
public enum PullRequestURL {
    static let marker = "/pull/"

    /// The first pull-request reference in this text, or nil.
    public static func ref(in text: String) -> PullRequestRef? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if let ref = parse(String(line)) { return ref }
        }
        return nil
    }

    /// `https://github.com/owner/name/pull/42` → repository, number, canonical URL.
    ///
    /// Trailing punctuation and anything after the number (`/files`, a full stop at
    /// the end of a sentence) is dropped, so the URL stored is the canonical one
    /// rather than whatever context it was printed in.
    public static func parse(_ line: String) -> PullRequestRef? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(of: marker) else { return nil }
        let prefix = String(trimmed[trimmed.startIndex..<range.lowerBound])
        let digits = String(trimmed[range.upperBound...].prefix { $0.isNumber })
        guard let number = Int(digits), number > 0 else { return nil }

        // The last two path components are owner and repository. Anything shorter is
        // not a pull-request URL, whatever it looks like.
        let components = prefix.split(separator: "/").map(String.init)
        guard components.count >= 2 else { return nil }
        let repository = components.suffix(2).joined(separator: "/")
        guard !repository.contains(" ") else { return nil }
        return PullRequestRef(repository: repository, number: number,
                              url: "\(prefix)\(marker)\(number)")
    }
}
