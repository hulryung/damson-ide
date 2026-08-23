import XCTest
@testable import OrchardRuntime

/// T37: probe-status wording and affordance gating. UI-free so the Open Remote
/// sheet and the disabled chrome cannot invent a fourth verdict or call loss of
/// contact a deletion.
final class RemoteWorkspacePolicyTests: XCTestCase {
    func testLocalHostKeepsEveryAffordance() {
        for affordance in RemoteAffordance.allCases {
            XCTAssertTrue(RemoteWorkspacePolicy.isAvailable(affordance, hostId: "local"),
                          affordance.rawValue)
            XCTAssertNil(RemoteWorkspacePolicy.unsupportedExplanation(affordance, hostId: "local"),
                         affordance.rawValue)
        }
        XCTAssertFalse(RemoteWorkspacePolicy.isRemote(hostId: "local"))
        XCTAssertFalse(RemoteWorkspacePolicy.isRemote(hostId: nil))
    }

    func testRemoteHostDisablesTypedAffordances() {
        let host = "ssh:build"
        XCTAssertTrue(RemoteWorkspacePolicy.isRemote(hostId: host))
        for affordance in RemoteAffordance.allCases {
            XCTAssertFalse(RemoteWorkspacePolicy.isAvailable(affordance, hostId: host),
                           affordance.rawValue)
            let reason = RemoteWorkspacePolicy.unsupportedExplanation(affordance, hostId: host)
            XCTAssertNotNil(reason, affordance.rawValue)
            XCTAssertFalse(reason!.localizedCaseInsensitiveContains("deleted"),
                           "\(affordance): \(reason!)")
            if affordance != .browser {
                XCTAssertTrue(reason!.contains("remote_unsupported")
                              || reason!.contains("local-only"),
                              "\(affordance): \(reason!)")
            }
        }
        XCTAssertTrue(
            RemoteWorkspacePolicy.unsupportedExplanation(.agents, hostId: host)!
                .contains("remote_unsupported"))
        XCTAssertTrue(
            RemoteWorkspacePolicy.unsupportedExplanation(.browser, hostId: host)!
                .contains("local-only"))
    }

    func testUnparseableHostIdDoesNotFallThroughToLocal() {
        // Rule 1: an id that does not parse must never be read as local.
        XCTAssertTrue(RemoteWorkspacePolicy.isRemote(hostId: "runtime:vm-1"))
        XCTAssertFalse(RemoteWorkspacePolicy.isAvailable(.editor, hostId: "runtime:vm-1"))
    }

    func testProbeStatusLineUsesVerdictVocabulary() {
        let reachable = HostProbeResult(
            name: "build", executionHostId: "ssh:build", status: .reachable,
            detail: "authenticated and ran the probe command", command: "ssh …",
            timedOut: false)
        XCTAssertEqual(RemoteWorkspacePolicy.probeStatusLine(reachable), "Reachable")
        XCTAssertEqual(RemoteWorkspacePolicy.probeStatusChip(.reachable), "reachable")

        let auth = HostProbeResult(
            name: "build", executionHostId: "ssh:build", status: .authRequired,
            detail: "ci@build: Permission denied (publickey).", command: "ssh …",
            timedOut: false)
        let authLine = RemoteWorkspacePolicy.probeStatusLine(auth)
        XCTAssertTrue(authLine.hasPrefix("Auth required"))
        XCTAssertTrue(authLine.contains("Permission denied"))
        XCTAssertFalse(authLine.localizedCaseInsensitiveContains("deleted"))
        XCTAssertEqual(RemoteWorkspacePolicy.probeStatusChip(.authRequired), "auth-required")

        let unreachable = HostProbeResult(
            name: "build", executionHostId: "ssh:build", status: .unreachable,
            detail: "connection refused", command: "ssh …", timedOut: false,
            note: "Unreachable is loss of contact, not evidence that anything on build stopped.")
        let line = RemoteWorkspacePolicy.probeStatusLine(unreachable)
        XCTAssertTrue(line.hasPrefix("Unreachable"))
        XCTAssertTrue(line.contains("loss of contact"))
        XCTAssertFalse(line.localizedCaseInsensitiveContains("deleted"))
        XCTAssertEqual(RemoteWorkspacePolicy.probeStatusChip(.unreachable), "unreachable")
        XCTAssertEqual(RemoteWorkspacePolicy.probeStatusChip(nil), "checking")
    }

    func testRegistrationFailureNeverSaysDeleted() {
        let unverifiable = RemoteWorkspacePolicy.registrationFailure(
            code: "host_unverifiable",
            message: "checking /srv/app on build is unverifiable — connection refused. Loss of contact is not evidence that anything on build changed.",
            hostName: "build")
        XCTAssertTrue(unverifiable.hasPrefix("Unreachable"))
        XCTAssertTrue(unverifiable.contains("loss of contact"))
        XCTAssertFalse(unverifiable.localizedCaseInsensitiveContains("deleted"))

        let auth = RemoteWorkspacePolicy.registrationFailure(
            code: "host_unverifiable",
            message: "checking /srv/app on build is unverifiable — Permission denied (publickey).",
            hostName: "build")
        XCTAssertTrue(auth.hasPrefix("Auth required"))
        XCTAssertFalse(auth.localizedCaseInsensitiveContains("deleted"))

        let missing = RemoteWorkspacePolicy.registrationFailure(
            code: "remote_not_a_repo",
            message: "/srv/app on build is not a git checkout (no .git directory)",
            hostName: "build")
        XCTAssertTrue(missing.contains("not a git checkout"))
        XCTAssertFalse(missing.localizedCaseInsensitiveContains("deleted"))

        let unknown = RemoteWorkspacePolicy.registrationFailure(
            code: "unknown_host", message: "", hostName: "ghost")
        XCTAssertTrue(unknown.contains("ghost"))
        XCTAssertFalse(unknown.localizedCaseInsensitiveContains("deleted"))
    }

    func testHostLabelPrefersTheRegisteredName() {
        XCTAssertEqual(RemoteWorkspacePolicy.hostLabel("ssh:build"), "build")
        XCTAssertEqual(RemoteWorkspacePolicy.hostLabel("local"), "Local")
        XCTAssertEqual(RemoteWorkspacePolicy.hostLabel(nil), "the remote host")
    }
}
