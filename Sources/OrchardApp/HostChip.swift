import SwiftUI
import OrchardRuntime

/// The execution-host chip shown on sidebar cards, repo headers, and terminal tabs.
/// Nil/`local` renders nothing — local is the default, not a claim worth labelling.
struct HostChip: View {
    let hostId: String?
    var compact: Bool = true

    private var label: String? {
        guard RemoteWorkspacePolicy.isRemote(hostId: hostId) else { return nil }
        return RemoteWorkspacePolicy.hostLabel(hostId)
    }

    var body: some View {
        if let label {
            Text(label)
                .font(Tokens.fontPill)
                .padding(.horizontal, compact ? 4 : 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(Tokens.rowHover))
                .help("This workspace lives on \(label) over SSH")
        }
    }
}
