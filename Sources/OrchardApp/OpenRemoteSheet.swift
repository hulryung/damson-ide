import SwiftUI
import OrchardRuntime

/// File → Open Remote… / sidebar folder-plus. Host picker is the registry
/// (re-probed on open); submit registers through `WorkspaceService.addRemoteRepo`,
/// the same path as `orchard repo add --host`.
struct OpenRemoteSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var selectedHostName: String = ""
    @State private var remotePath: String = ""
    @State private var probeByName: [String: HostProbeResult] = [:]
    @State private var probing = false
    @State private var submitting = false
    @State private var errorMessage: String?
    @FocusState private var pathFocused: Bool

    private var hosts: [HostRecord] { store.registeredHosts }

    private var selectedHost: HostRecord? {
        hosts.first { $0.name == selectedHostName }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    hostPicker
                    pathField
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(Tokens.fontMeta)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(width: 520)
        .frame(maxHeight: 560)
        .onAppear {
            if selectedHostName.isEmpty { selectedHostName = hosts.first?.name ?? "" }
            pathFocused = true
            Task { await reprobeHosts() }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "network")
                .foregroundStyle(Tokens.textSecondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Open Remote…")
                    .font(.system(size: 13, weight: .semibold))
                Text("Register a git checkout that lives on a host.")
                    .font(Tokens.fontMeta)
                    .foregroundStyle(Tokens.textSecondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var hostPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Host")
                    .font(Tokens.fontHeader)
                    .foregroundStyle(Tokens.textSecondary)
                Spacer()
                if probing {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
            if hosts.isEmpty {
                Text("No hosts are registered. Add one with `orchard host add`, then open this again.")
                    .font(Tokens.fontMeta)
                    .foregroundStyle(Tokens.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(hosts) { host in
                    hostRow(host)
                }
            }
        }
    }

    private func hostRow(_ host: HostRecord) -> some View {
        let selected = host.name == selectedHostName
        let probe = probeByName[host.name]
        return Button {
            selectedHostName = host.name
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(selected ? Color.accentColor : Tokens.textTertiary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(host.name)
                            .font(Tokens.fontRow)
                        HostChip(hostId: host.executionHostId?.rawValue)
                        Spacer(minLength: 4)
                        Text(RemoteWorkspacePolicy.probeStatusChip(probe?.status))
                            .font(Tokens.fontPill)
                            .foregroundStyle(probeColor(probe?.status))
                    }
                    Text(host.displayTarget)
                        .font(Tokens.fontMeta)
                        .foregroundStyle(Tokens.textTertiary)
                        .lineLimit(1)
                    if let probe {
                        Text(RemoteWorkspacePolicy.probeStatusLine(probe))
                            .font(Tokens.fontMeta)
                            .foregroundStyle(Tokens.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: Tokens.radius)
                    .fill(selected ? Tokens.rowSelected : Tokens.rowHover)
            )
        }
        .buttonStyle(.plain)
    }

    private var pathField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Remote path")
                .font(Tokens.fontHeader)
                .foregroundStyle(Tokens.textSecondary)
            TextField("/home/ci/src/app", text: $remotePath)
                .textFieldStyle(.roundedBorder)
                .font(Tokens.fontMono)
                .focused($pathFocused)
                .onSubmit { Task { await submit() } }
            Text("Absolute path of the git checkout on the host. Orchard probes it over SSH before registering anything.")
                .font(Tokens.fontMeta)
                .foregroundStyle(Tokens.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Open") { Task { await submit() } }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(selectedHost == nil || remotePath.trimmingCharacters(in: .whitespaces).isEmpty || submitting)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func probeColor(_ status: HostReachability?) -> Color {
        switch status {
        case .reachable: return .green
        case .authRequired: return .orange
        case .unreachable: return .orange
        case nil: return Tokens.textTertiary
        }
    }

    private func reprobeHosts() async {
        let snapshot = hosts
        guard !snapshot.isEmpty else { return }
        probing = true
        defer { probing = false }
        // Re-probe on open: a cached check is a claim the host may no longer
        // support, and Open Remote must not present a stale reachable chip.
        await withTaskGroup(of: (String, HostProbeResult).self) { group in
            for host in snapshot {
                group.addTask {
                    (host.name, await HostProbe.check(host: host))
                }
            }
            for await (name, result) in group {
                probeByName[name] = result
            }
        }
    }

    private func submit() async {
        let path = remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let host = selectedHost, !path.isEmpty else { return }
        submitting = true
        errorMessage = nil
        defer { submitting = false }
        do {
            try await store.addRemoteProject(host: host, path: path)
            dismiss()
        } catch let error as WorkspaceError {
            errorMessage = RemoteWorkspacePolicy.registrationFailure(
                code: error.code, message: error.message, hostName: host.name)
        } catch {
            errorMessage = RemoteWorkspacePolicy.registrationFailure(
                code: "internal_error", message: String(describing: error),
                hostName: host.name)
        }
    }
}
