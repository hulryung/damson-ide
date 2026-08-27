import XCTest
@testable import OrchardCore

/// T88: worktree links are typed, and nothing is guessed.
final class WorktreeLinkTests: XCTestCase {

    // MARK: - Inference

    func testBareNumberAndHashTypeToTheSlotTheyArrivedThrough() {
        let issue = WorktreeLinkInference.link(from: "#412", slot: .issue)
        XCTAssertEqual(issue?.kind, .issue)
        XCTAssertEqual(issue?.identifier, "412")
        XCTAssertEqual(issue?.raw, "#412")

        let pr = WorktreeLinkInference.link(from: "412", slot: .pullRequest)
        XCTAssertEqual(pr?.kind, .pullRequest)
        XCTAssertEqual(pr?.identifier, "412")

        XCTAssertEqual(WorktreeLinkInference.link(from: "GH-7", slot: .issue)?.identifier, "7")
        XCTAssertEqual(WorktreeLinkInference.link(from: "0042", slot: .issue)?.identifier, "42")
    }

    func testGitHubURLsCarryTheirOwnIdentityRegardlessOfSlot() {
        // Arriving through --issue does not make a /pull/ URL an issue.
        let pr = WorktreeLinkInference.link(
            from: "https://github.com/o/r/pull/9", slot: .issue)
        XCTAssertEqual(pr?.kind, .pullRequest)
        XCTAssertEqual(pr?.identifier, "9")
        XCTAssertEqual(pr?.url, "https://github.com/o/r/pull/9")

        let issue = WorktreeLinkInference.link(
            from: "https://github.com/o/r/issues/12", slot: .pullRequest)
        XCTAssertEqual(issue?.kind, .issue)
        XCTAssertEqual(issue?.identifier, "12")
    }

    func testLinearAndJiraURLsType() {
        let linear = WorktreeLinkInference.link(
            from: "https://linear.app/acme/issue/ENG-412/some-slug", slot: .issue)
        XCTAssertEqual(linear?.kind, .linearIssue)
        XCTAssertEqual(linear?.identifier, "ENG-412")

        let jira = WorktreeLinkInference.link(
            from: "https://acme.atlassian.net/browse/ENG-99", slot: .issue)
        XCTAssertEqual(jira?.kind, .jiraIssue)
        XCTAssertEqual(jira?.identifier, "ENG-99")
    }

    /// The core discipline: an ambiguous tracker key is *not* guessed.
    func testAmbiguousKeyStaysUntypedUntilNamed() {
        let inferred = WorktreeLinkInference.link(from: "ENG-412", slot: .issue)
        XCTAssertEqual(inferred?.kind, .untyped)
        XCTAssertEqual(inferred?.identifier, "ENG-412")
        XCTAssertNil(inferred?.url)

        let named = WorktreeLinkInference.link(from: "ENG-412", slot: .issue,
                                               explicitKind: .jiraIssue)
        XCTAssertEqual(named?.kind, .jiraIssue)
        XCTAssertEqual(named?.identifier, "ENG-412")
    }

    func testUnknownHostsAndFreeTextStayUntypedButKeepTheirURL() {
        let gitlab = WorktreeLinkInference.link(
            from: "https://gitlab.com/o/r/-/merge_requests/3", slot: .pullRequest)
        XCTAssertEqual(gitlab?.kind, .untyped)
        XCTAssertEqual(gitlab?.url, "https://gitlab.com/o/r/-/merge_requests/3")

        XCTAssertEqual(WorktreeLinkInference.link(from: "see the design doc",
                                                  slot: .issue)?.kind, .untyped)
        XCTAssertNil(WorktreeLinkInference.link(from: "   ", slot: .issue))
    }

    func testDisplayAndNumber() {
        XCTAssertEqual(WorktreeLink(kind: .issue, identifier: "412").display, "#412")
        XCTAssertEqual(WorktreeLink(kind: .pullRequest, identifier: "9").number, 9)
        XCTAssertEqual(WorktreeLink(kind: .linearIssue, identifier: "ENG-1").display, "ENG-1")
        XCTAssertNil(WorktreeLink(kind: .linearIssue, identifier: "ENG-1").number)
        XCTAssertEqual(WorktreeLink(kind: .untyped, identifier: "x", raw: "x y").display, "x y")
    }

    // MARK: - Meta slots

    func testSlotsAreIndependentAndClearable() {
        var meta = WorktreeMeta(instanceId: "i", displayName: "d")
        meta.linkedIssue = "#5"
        meta.linkedPR = "https://github.com/o/r/pull/9"
        XCTAssertEqual(meta.links.count, 2)
        XCTAssertEqual(meta.pullRequestLink?.number, 9)
        XCTAssertEqual(meta.linkedIssue, "#5")

        // Setting the issue slot again replaces it and leaves the PR alone.
        meta.linkedIssue = "#6"
        XCTAssertEqual(meta.links.filter { !$0.kind.isPullRequest }.count, 1)
        XCTAssertEqual(meta.linkedIssue, "#6")
        XCTAssertEqual(meta.linkedPR, "https://github.com/o/r/pull/9")

        meta.linkedIssue = nil
        XCTAssertNil(meta.linkedIssue)
        XCTAssertEqual(meta.links.count, 1)
        meta.linkedPR = ""
        XCTAssertNil(meta.linkedPR)
        XCTAssertTrue(meta.links.isEmpty)
    }

    func testSetSlotWithExplicitKindTypesTheIssueSlot() {
        var meta = WorktreeMeta(instanceId: "i", displayName: "d")
        meta.setSlot(.issue, to: "ENG-412", explicitKind: .linearIssue)
        XCTAssertEqual(meta.links.first?.kind, .linearIssue)
        // Re-typing the same key replaces rather than duplicates.
        meta.setSlot(.issue, to: "ENG-412", explicitKind: .jiraIssue)
        XCTAssertEqual(meta.links.count, 1)
        XCTAssertEqual(meta.links.first?.kind, .jiraIssue)
    }

    // MARK: - Persistence

    /// A file written before T88 has only the two strings. It must decode into
    /// typed links rather than failing or losing the values.
    func testDecodesLegacyStringsIntoTypedLinks() throws {
        let json = """
        {"instanceId":"abc","displayName":"kelp","comment":"","isPinned":false,
         "isUnread":false,"isArchived":false,"sortOrder":0,
         "lastActivityAt":760000000,"linkedIssue":"#412",
         "linkedPR":"https://github.com/o/r/pull/9"}
        """
        let meta = try JSONDecoder().decode(WorktreeMeta.self, from: Data(json.utf8))
        XCTAssertEqual(meta.links.count, 2)
        XCTAssertEqual(meta.links.first { !$0.kind.isPullRequest }?.kind, .issue)
        XCTAssertEqual(meta.pullRequestLink?.kind, .pullRequest)
        XCTAssertEqual(meta.linkedIssue, "#412")
    }

    /// And the encode side keeps writing them, so an older build reading the same
    /// file still sees what it wrote.
    func testEncodeKeepsBothTypedLinksAndLegacyStrings() throws {
        var meta = WorktreeMeta(instanceId: "abc", displayName: "kelp")
        meta.setSlot(.issue, to: "ENG-1", explicitKind: .linearIssue)
        meta.linkedPR = "#9"
        let data = try JSONEncoder().encode(meta)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["linkedIssue"] as? String, "ENG-1")
        XCTAssertEqual(object["linkedPR"] as? String, "#9")
        let links = try XCTUnwrap(object["links"] as? [[String: Any]])
        XCTAssertEqual(links.count, 2)

        // Round trip preserves the kind the legacy strings alone could not carry.
        let decoded = try JSONDecoder().decode(WorktreeMeta.self, from: data)
        XCTAssertEqual(decoded.links.first { !$0.kind.isPullRequest }?.kind, .linearIssue)
        XCTAssertEqual(decoded, meta)
    }

    func testTypedLinksInTheFileWinOverTheLegacyMirror() throws {
        // Same key in both places, but only `links` records that it is Linear.
        let json = """
        {"instanceId":"abc","displayName":"kelp","comment":"","isPinned":false,
         "isUnread":false,"isArchived":false,"sortOrder":0,
         "lastActivityAt":760000000,"linkedIssue":"ENG-1",
         "links":[{"kind":"linear-issue","identifier":"ENG-1","raw":"ENG-1"}]}
        """
        let meta = try JSONDecoder().decode(WorktreeMeta.self, from: Data(json.utf8))
        XCTAssertEqual(meta.links.count, 1)
        XCTAssertEqual(meta.links[0].kind, .linearIssue)
        XCTAssertEqual(meta.linkedIssue, "ENG-1")
    }

    func testSelectableExcludesUntyped() {
        XCTAssertFalse(WorktreeLinkKind.selectable.contains(.untyped))
        XCTAssertEqual(WorktreeLinkKind.selectable.map(\.rawValue),
                       ["issue", "linear-issue", "jira-issue", "pr"])
    }
}
