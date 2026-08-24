import SwiftUI
import OrchardRuntime

/// The Vault's reader pane. Text comes from the same decode `worker-read` serves:
/// a terminal tail's cleaned lines with a raw toggle for the untouched capture, and a
/// transcript pin as its message stream when it parses as one — otherwise verbatim.
struct VaultReaderView: View {
    @ObservedObject var browser: VaultBrowser

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Archive")
                .font(Tokens.fontHeader)
                .foregroundStyle(Tokens.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Divider()
            if let location = browser.selectedLocation {
                content(location)
            } else {
                Text("Select an archive to read it.")
                    .font(Tokens.fontMeta)
                    .foregroundStyle(Tokens.textTertiary)
                    .padding(14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background(Tokens.background)
    }

    @ViewBuilder
    private func content(
        _ location: (run: VaultRunGroup, task: VaultTaskGroup, archive: VaultArchiveRow)
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            metadata(location)
            Divider()
            toolbar(location.archive)
            archiveBody
        }
    }

    private func metadata(
        _ location: (run: VaultRunGroup, task: VaultTaskGroup, archive: VaultArchiveRow)
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                StatusChip(text: location.archive.kindLabel,
                           color: location.archive.isTranscript ? .purple : .teal)
                StatusChip(text: location.archive.dispatchStatus,
                           color: StatusChip.color(forDispatch: location.archive.dispatchStatus))
                StatusChip(text: location.archive.workerState,
                           color: StatusChip.color(forWorker: location.archive.workerState))
                if location.run.isLive {
                    StatusChip(text: "live run", color: .blue)
                }
            }
            labeled("Run", location.run.objective)
            labeled("Task", location.task.label)
            labeled("Dispatch", location.archive.dispatchID)
            if let engine = location.archive.engineID {
                labeled("Agent", engine)
            }
            if let handle = location.archive.agentHandle {
                labeled("Terminal", handle)
            }
            labeled("Archived", location.archive.createdAt)
            labeled("Size", location.archive.sizeLabel)
        }
        .padding(14)
    }

    private func toolbar(_ archive: VaultArchiveRow) -> some View {
        HStack(spacing: 10) {
            if archive.isTranscript {
                if browser.parsedTranscript != nil {
                    Toggle("Raw JSONL", isOn: $browser.showTranscriptSource)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .help("Show the pinned transcript exactly as stored, instead of its message stream")
                }
            } else {
                Toggle("Raw", isOn: $browser.showRaw)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .help("Untouched capture — the same text worker-read --raw serves")
            }
            Spacer()
            Text(readerNote)
                .font(Tokens.fontMeta)
                .foregroundStyle(Tokens.textTertiary)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }

    private var readerNote: String {
        guard let archive = browser.archive else { return "" }
        if archive.isTranscript {
            guard browser.parsedTranscript != nil else { return "Transcript pin · plain text" }
            return browser.showTranscriptSource
                ? "Transcript pin · raw JSONL"
                : "Transcript pin · message stream"
        }
        return browser.showRaw ? "Untouched capture" : "Cleaned capture"
    }

    @ViewBuilder
    private var archiveBody: some View {
        if let archive = browser.archive {
            if let messages = browser.transcriptMessages {
                transcriptStream(messages)
            } else {
                textLines(archive.lines(showRaw: browser.showRaw))
            }
        } else {
            // The row is in the listing, so name what is missing rather than
            // rendering an empty pane.
            Text("This archive is recorded but its content could not be read.")
                .font(Tokens.fontMeta)
                .foregroundStyle(Tokens.textTertiary)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func textLines(_ lines: [String]) -> some View {
        Group {
            if lines.isEmpty {
                Text("Archive is empty.")
                    .font(Tokens.fontMeta)
                    .foregroundStyle(Tokens.textTertiary)
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            Text(line.isEmpty ? " " : line)
                                .font(Tokens.fontMono)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(10)
                }
                .background(Tokens.surface)
            }
        }
    }

    private func transcriptStream(_ messages: [VaultTranscriptMessage]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(messages) { message in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            StatusChip(text: message.role, color: Self.roleColor(message.role))
                            if let timestamp = message.timestamp {
                                Text(timestamp)
                                    .font(Tokens.fontMeta)
                                    .foregroundStyle(Tokens.textTertiary)
                            }
                        }
                        Text(message.text)
                            .font(Tokens.fontMono)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: Tokens.radius)
                            .fill(Tokens.surface)
                    )
                }
            }
            .padding(10)
        }
    }

    private static func roleColor(_ role: String) -> Color {
        switch role {
        case "user": return .blue
        case "assistant": return Tokens.Git.added
        case "system": return .orange
        default: return Tokens.textTertiary
        }
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(Tokens.fontMeta)
                .foregroundStyle(Tokens.textTertiary)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(Tokens.fontMono)
                .textSelection(.enabled)
                .lineLimit(3)
        }
    }
}
