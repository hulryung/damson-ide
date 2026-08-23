import SwiftUI
import OrchardRuntime

/// Compact ports chip on a sidebar workspace card. Hidden when the worktree
/// has no attributed listeners.
struct WorkspacePortsChip: View {
    let ports: [WorkspaceListeningPort]

    var body: some View {
        if !ports.isEmpty {
            HStack(spacing: 3) {
                Image(systemName: "cable.connector")
                    .font(.system(size: 8, weight: .semibold))
                Text(label)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .font(Tokens.fontPill)
            .foregroundStyle(Tokens.textSecondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill(Tokens.rowHover))
            .help(help)
        }
    }

    private var label: String {
        let shown = ports.prefix(2).map { String($0.port) }.joined(separator: ",")
        if ports.count > 2 { return "\(shown)+\(ports.count - 2)" }
        return shown
    }

    private var help: String {
        let list = ports.map { port in
            let process = port.processName.map { " \($0)" } ?? ""
            return "\(port.connectHost):\(port.port)\(process)"
        }.joined(separator: "\n")
        let noun = ports.count == 1 ? "port" : "ports"
        return "\(ports.count) live \(noun)\n\(list)"
    }
}
