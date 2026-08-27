import Foundation

/// What a worktree's link points at. Inventory §2 lists the card properties as
/// `issue`, `linear-issue`, `jira-issue`, `pr` — four *typed* things, not one
/// string each for "issue" and "PR".
///
/// `untyped` is the honest fifth: text a user attached that types to nothing we
/// recognise. It is recorded and shown as untyped rather than guessed into a
/// tracker, because "ENG-412" is a Linear key and a Jira key and a branch name,
/// and picking one would be a fabrication the UI then presents as fact.
public enum WorktreeLinkKind: String, Codable, Equatable, Sendable, CaseIterable {
    /// An issue on the repo's own forge. GitHub here (T88 builds against `gh`).
    case issue
    case linearIssue = "linear-issue"
    case jiraIssue = "jira-issue"
    case pullRequest = "pr"
    /// Recorded text that matched no known form. Never promoted to a tracker.
    case untyped

    public var label: String {
        switch self {
        case .issue: return "Issue"
        case .linearIssue: return "Linear"
        case .jiraIssue: return "Jira"
        case .pullRequest: return "Pull request"
        case .untyped: return "Link"
        }
    }

    /// SF Symbol the sidebar/card draws for this kind.
    public var symbol: String {
        switch self {
        case .issue: return "smallcircle.circle"
        case .linearIssue: return "l.square"
        case .jiraIssue: return "j.square"
        case .pullRequest: return "arrow.triangle.pull"
        case .untyped: return "link"
        }
    }

    /// Whether this kind occupies the PR slot rather than the issue slot. The two
    /// legacy fields (`linkedIssue`, `linkedPR`) are exactly these two slots.
    public var isPullRequest: Bool { self == .pullRequest }

    /// The kinds a caller may name explicitly on `worktree set --link-kind`.
    /// `untyped` is a result, never a request.
    public static var selectable: [WorktreeLinkKind] {
        allCases.filter { $0 != .untyped }
    }
}

/// One typed link on a worktree.
///
/// `raw` is what the user actually wrote and is what round-trips back through the
/// legacy `linkedIssue`/`linkedPR` string fields; `identifier` is the normalised
/// key (`"123"`, `"ENG-412"`); `url` is only ever set when it is *known*, i.e. the
/// user pasted one or the form is unambiguous enough to rebuild it.
public struct WorktreeLink: Codable, Equatable, Sendable, Identifiable, Hashable {
    public var kind: WorktreeLinkKind
    public var identifier: String
    public var url: String?
    public var raw: String

    public var id: String { "\(kind.rawValue):\(raw)" }

    public init(kind: WorktreeLinkKind, identifier: String, url: String? = nil,
                raw: String? = nil) {
        self.kind = kind
        self.identifier = identifier
        self.url = url
        self.raw = raw ?? identifier
    }

    /// `#412`, `ENG-412`, `PR #7`. What a card badge shows.
    public var display: String {
        switch kind {
        case .issue, .pullRequest:
            return identifier.hasPrefix("#") ? identifier : "#\(identifier)"
        case .linearIssue, .jiraIssue:
            return identifier
        case .untyped:
            return raw
        }
    }

    /// The numeric id, when this link names one. `checks` needs it to address a PR.
    public var number: Int? {
        guard kind == .issue || kind == .pullRequest else { return nil }
        return Int(identifier.hasPrefix("#") ? String(identifier.dropFirst()) : identifier)
    }
}

/// Turns the strings users and the CLI actually type into typed links.
///
/// Only forms that are unambiguous become typed. Everything else becomes
/// `.untyped`, which the UI shows as untyped — the discipline is the same one
/// the checks panel keeps: name what is not known instead of inventing it.
public enum WorktreeLinkInference {
    /// Infer a link from raw text. `slot` says which of the two legacy fields the
    /// text arrived through, which is the only thing that can tell `#7` as an issue
    /// from `#7` as a PR.
    public static func link(from raw: String, slot: WorktreeLinkKind = .issue,
                            explicitKind: WorktreeLinkKind? = nil) -> WorktreeLink? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let explicitKind, explicitKind != .untyped {
            let inferred = infer(text, slot: explicitKind)
            // An explicit kind wins over inference, but a URL that already carries
            // its own identity keeps that identity's number/url.
            return WorktreeLink(kind: explicitKind,
                                identifier: inferred?.identifier ?? normalisedIdentifier(text),
                                url: inferred?.url ?? absoluteURL(text),
                                raw: text)
        }
        if let inferred = infer(text, slot: slot) { return inferred }
        return WorktreeLink(kind: .untyped, identifier: text, url: absoluteURL(text), raw: text)
    }

    private static func infer(_ text: String, slot: WorktreeLinkKind) -> WorktreeLink? {
        if let fromURL = fromURL(text) { return fromURL }
        // `#412` / `412` / `GH-412`: the repo's own forge, in whichever slot it
        // arrived through. A bare number is the only form the legacy fields ever
        // carried for GitHub, so this is a migration rule, not a guess.
        if let number = bareNumber(text) {
            let kind: WorktreeLinkKind = slot.isPullRequest ? .pullRequest : .issue
            return WorktreeLink(kind: kind, identifier: number, url: nil, raw: text)
        }
        // `ENG-412` is a Linear key and a Jira key. Both. It stays untyped unless
        // the caller says which.
        return nil
    }

    /// `#412` → `412`; `412` → `412`; `GH-412` → `412`; anything else → nil.
    static func bareNumber(_ text: String) -> String? {
        var body = text
        if body.hasPrefix("#") { body = String(body.dropFirst()) }
        else if body.lowercased().hasPrefix("gh-") { body = String(body.dropFirst(3)) }
        guard !body.isEmpty, body.allSatisfy(\.isNumber) else { return nil }
        // Strip leading zeros but keep a single "0" from becoming empty.
        let trimmed = String(body.drop(while: { $0 == "0" }))
        return trimmed.isEmpty ? "0" : trimmed
    }

    static func absoluteURL(_ text: String) -> String? {
        guard text.hasPrefix("http://") || text.hasPrefix("https://"),
              URL(string: text) != nil else { return nil }
        return text
    }

    /// The URL forms that carry their own identity. Anything else is not a link
    /// we can type from its address alone.
    static func fromURL(_ text: String) -> WorktreeLink? {
        guard let url = absoluteURL(text).flatMap(URL.init(string:)),
              let host = url.host?.lowercased() else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }

        if host == "github.com" || host.hasSuffix(".github.com") {
            // /<owner>/<repo>/pull/<n>  ·  /<owner>/<repo>/issues/<n>
            if parts.count >= 4, let number = bareNumber(parts[3]) {
                switch parts[2] {
                case "pull", "pulls":
                    return WorktreeLink(kind: .pullRequest, identifier: number,
                                        url: text, raw: text)
                case "issues":
                    return WorktreeLink(kind: .issue, identifier: number, url: text, raw: text)
                default: break
                }
            }
            return nil
        }
        if host == "linear.app" || host.hasSuffix(".linear.app") {
            // /<team>/issue/<KEY-n>[/<slug>]
            if let index = parts.firstIndex(of: "issue"), parts.count > index + 1 {
                return WorktreeLink(kind: .linearIssue, identifier: parts[index + 1],
                                    url: text, raw: text)
            }
            return nil
        }
        if host.hasSuffix(".atlassian.net") {
            // /browse/<KEY-n>
            if let index = parts.firstIndex(of: "browse"), parts.count > index + 1 {
                return WorktreeLink(kind: .jiraIssue, identifier: parts[index + 1],
                                    url: text, raw: text)
            }
            return nil
        }
        return nil
    }

    static func normalisedIdentifier(_ text: String) -> String {
        bareNumber(text) ?? text
    }
}
