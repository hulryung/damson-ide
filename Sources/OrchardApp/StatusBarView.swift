import SwiftUI
import AppKit
import OrchardRuntime

/// Bottom status bar. The ports summary is the T20 surface: count plus the first
/// few ports; click reveals the full attributed list.
struct StatusBarView: View {
    @EnvironmentObject var store: AppStore
    @State private var showingPorts = false

    var body: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 8)
            PortsStatusChip(ports: store.portSnapshot.ports, isPresented: $showingPorts)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Tokens.sidebar)
        .overlay(alignment: .top) { Divider() }
    }
}

struct PortsStatusChip: View {
    let ports: [WorkspaceListeningPort]
    @Binding var isPresented: Bool

    var body: some View {
        Button { isPresented.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: "cable.connector")
                    .font(.system(size: 10, weight: .semibold))
                Text(summary)
                    .font(Tokens.fontMeta)
                    .monospacedDigit()
            }
            .foregroundStyle(Tokens.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(ports.isEmpty
              ? "No workspace listening ports"
              : "\(ports.count) workspace \(ports.count == 1 ? "port" : "ports")")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            PortsListPopover(ports: ports)
        }
    }

    private var summary: String {
        if ports.isEmpty { return "0 ports" }
        let first = ports.prefix(3).map { String($0.port) }.joined(separator: ", ")
        if ports.count > 3 {
            return "\(ports.count) · \(first)…"
        }
        return "\(ports.count) · \(first)"
    }
}

struct PortsListPopover: View {
    let ports: [WorkspaceListeningPort]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "cable.connector")
                    .foregroundStyle(Tokens.textTertiary)
                Text("Ports")
                    .font(Tokens.fontHeader)
                Spacer()
                Text("\(ports.count)")
                    .font(Tokens.fontMeta)
                    .foregroundStyle(Tokens.textTertiary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            if ports.isEmpty {
                Text("No listening ports attributed to open workspaces.")
                    .font(Tokens.fontMeta)
                    .foregroundStyle(Tokens.textSecondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(ports) { port in
                            PortRow(port: port)
                            if port.id != ports.last?.id { Divider() }
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
        }
        .frame(width: 360)
    }
}

private struct PortRow: View {
    let port: WorkspaceListeningPort

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(port.port)")
                .font(Tokens.fontMono)
                .monospacedDigit()
                .frame(width: 48, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(port.displayName)
                    .font(Tokens.fontRow)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text("\(port.connectHost):\(port.port)")
                    if let process = port.processName, !process.isEmpty {
                        Text(process)
                    }
                    if let pid = port.pid {
                        Text("pid \(pid)")
                    }
                }
                .font(Tokens.fontMeta)
                .foregroundStyle(Tokens.textTertiary)
                .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button {
                let url = URL(string: "http://\(port.connectHost):\(port.port)")
                if let url { NSWorkspace.shared.open(url) }
            } label: {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10))
            }
            .buttonStyle(.borderless)
            .help("Open http://\(port.connectHost):\(port.port)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}
