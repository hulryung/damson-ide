import SwiftUI
import OrchardRuntime

/// The execution-host chip shown on sidebar cards, repo headers, and terminal tabs.
/// Nil/`local` renders nothing — local is the default, not a claim worth labelling.
///
/// When the T45 producer has published, the chip also shows live reachability and
/// last-checked age. A status change updates this presentation only.
struct HostChip: View {
    @EnvironmentObject var store: AppStore
    let hostId: String?
    var compact: Bool = true

    private var label: String? {
        guard RemoteWorkspacePolicy.isRemote(hostId: hostId) else { return nil }
        return RemoteWorkspacePolicy.hostLabel(hostId)
    }

    private var liveness: HostProbeResult? {
        store.hostLiveness.status(forHostId: hostId)
    }

    var body: some View {
        if let label {
            HStack(spacing: 4) {
                Text(label)
                    .font(Tokens.fontPill)
                    .padding(.horizontal, compact ? 4 : 5)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 2).fill(Tokens.rowHover))
                if let liveness {
                    Text(compact
                         ? HostLivenessPresentation.chipStatusLine(liveness)
                         : liveness.status.rawValue)
                        .font(Tokens.fontPill)
                        .foregroundStyle(statusColor(liveness.status))
                        .lineLimit(1)
                }
            }
            .help(helpText(label: label, liveness: liveness))
            .accessibilityIdentifier("host-chip")
            .accessibilityLabel(label)
        }
    }

    private func helpText(label: String, liveness: HostProbeResult?) -> String {
        let lives = "This workspace lives on \(label) over SSH."
        guard let liveness else { return lives }
        return lives + " " + HostLivenessPresentation.chipHelp(name: label, result: liveness)
    }

    private func statusColor(_ status: HostReachability) -> Color {
        switch status {
        case .reachable: return .green
        case .authRequired, .unreachable: return .orange
        }
    }
}
