import SwiftUI
import OrchardRuntime

/// Disabled-state body for an affordance the runtime types as `remote_unsupported`.
/// Used when a tab or sidebar already exists so a click cannot fall through to a
/// local filesystem that happens to share the remote path's name.
struct RemoteUnsupportedView: View {
    let affordance: RemoteAffordance
    let hostId: String?

    var body: some View {
        PlaceholderPane(
            symbol: symbol,
            title: title,
            detail: RemoteWorkspacePolicy.unsupportedExplanation(affordance, hostId: hostId)
                ?? "This surface is not available on a remote workspace.")
    }

    private var symbol: String {
        switch affordance {
        case .fileExplorer: return "folder"
        case .diff: return "plusminus"
        case .editor: return "doc.text"
        case .agents, .composer: return "plus.rectangle.on.folder"
        case .browser: return "globe"
        }
    }

    private var title: String {
        switch affordance {
        case .fileExplorer: return "Files unavailable"
        case .diff: return "Diff unavailable"
        case .editor: return "Editor unavailable"
        case .agents: return "Agents unavailable"
        case .composer: return "Composer unavailable"
        case .browser: return "Browser unavailable"
        }
    }
}

extension View {
    /// Disable the control and attach the remote_unsupported explanation when
    /// the current workspace is remote. Local workspaces are unchanged.
    func disabledForRemote(_ affordance: RemoteAffordance, hostId: String?) -> some View {
        let reason = RemoteWorkspacePolicy.unsupportedExplanation(affordance, hostId: hostId)
        return self
            .disabled(reason != nil)
            .help(reason ?? "")
    }
}
