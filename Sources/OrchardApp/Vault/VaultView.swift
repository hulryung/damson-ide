import AppKit
import SwiftUI
import OrchardRuntime

/// The Vault (docs/REBUILD-PLAN.md T49): every dispatch's leftovers across every run
/// — cleaned terminal tails, their raw captures, transcript pins — grouped run → task
/// → dispatch, with a text filter and a reader that serves exactly what `worker-read`
/// serves. The only mutation is a prune, and it is unreachable without its dry run.
struct VaultView: View {
    @EnvironmentObject var store: AppStore
    @StateObject private var browser = VaultBrowser()

    var body: some View {
        HSplitView {
            archiveList
                .frame(minWidth: 340, idealWidth: 420, maxWidth: 620)
            VaultReaderView(browser: browser)
                .frame(minWidth: 420)
        }
        .background(Tokens.background)
        .frame(minWidth: 940, minHeight: 520)
        .onAppear { Task { await browser.refresh(from: store) } }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            guard let window = note.object as? NSWindow, window.title == "Vault" else { return }
            Task { await browser.refresh(from: store) }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(VaultBrowser.refreshInterval * 1_000_000_000))
                await browser.refresh(from: store)
            }
        }
        .sheet(isPresented: Binding(
            get: { browser.prunePlan != nil },
            set: { if !$0 { browser.cancelPrune() } })) {
            if let plan = browser.prunePlan {
                VaultPruneSheet(plan: plan, isPruning: browser.isPruning,
                                confirm: { Task { await browser.confirmPrune(from: store) } },
                                cancel: { browser.cancelPrune() })
            }
        }
    }

    // MARK: - List

    private var archiveList: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            filterField
            Divider()
            if let lastError = browser.lastError {
                Text(lastError)
                    .font(Tokens.fontMeta)
                    .foregroundStyle(.red)
                    .padding(10)
            }
            if let receipt = browser.pruneReceipt {
                pruneOutcome(receipt)
            }
            if browser.snapshot.isEmpty {
                emptyState
            } else if browser.filtered.isEmpty {
                noMatchesState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(browser.filtered.runs) { run in
                            runGroup(run)
                        }
                    }
                    .padding(8)
                }
            }
            Divider()
            footer
        }
        .background(Tokens.sidebar)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Archives")
                .font(Tokens.fontHeader)
                .foregroundStyle(Tokens.textSecondary)
            Spacer()
            if let lastRefreshed = browser.lastRefreshed {
                ElapsedLabel(since: lastRefreshed)
                    .font(Tokens.fontMeta)
                    .foregroundStyle(Tokens.textTertiary)
                    .help("Seconds since the last inventory read")
            }
            Button("Refresh") { Task { await browser.refresh(from: store) } }
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var filterField: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .foregroundStyle(Tokens.textTertiary)
                TextField("Filter by run, task, dispatch, agent, or archive text", text: $browser.filter)
                    .textFieldStyle(.roundedBorder)
                if !browser.filter.isEmpty {
                    Button {
                        browser.filter = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Tokens.textTertiary)
                }
            }
            if !browser.filter.isEmpty, browser.snapshot.scanTruncated {
                Text("Content matching only sees the first \(browser.snapshot.scanLimit) characters of each archive.")
                    .font(Tokens.fontMeta)
                    .foregroundStyle(Tokens.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(inventorySummary)
                .font(Tokens.fontMeta)
                .foregroundStyle(Tokens.textTertiary)
            Spacer()
            Button("Prune…") { Task { await browser.preparePrune(from: store) } }
                .controlSize(.small)
                .disabled(browser.snapshot.isEmpty)
                .help("Preview what the retention caps in Settings would delete. Nothing is deleted without confirming.")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var inventorySummary: String {
        let snapshot = browser.snapshot
        guard snapshot.archiveCount > 0 else { return "No archives" }
        let base = "\(snapshot.archiveCount) archive\(snapshot.archiveCount == 1 ? "" : "s")"
            + " · \(snapshot.sizeLabel)"
        let shown = browser.filtered.archiveCount
        return shown == snapshot.archiveCount ? base : "\(shown) of \(base)"
    }

    private func pruneOutcome(_ receipt: ArchivePruneReceipt) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(receipt.deletedCount == 0
                 ? "Nothing was deleted."
                 : "Deleted \(receipt.deletedCount) archive\(receipt.deletedCount == 1 ? "" : "s"), freed \(receipt.freedLabel).")
                .font(Tokens.fontMeta)
            if !receipt.skippedDispatchIDs.isEmpty {
                Text("\(receipt.skippedDispatchIDs.count) skipped — their run went live again since the preview.")
                    .font(Tokens.fontMeta)
                    .foregroundStyle(Tokens.textTertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.surface)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No worker archives")
                .font(Tokens.fontRow)
                .foregroundStyle(Tokens.textSecondary)
            Text("A dispatch's output is pinned here when its terminal is released. Live workers keep their output on their own pane until then.")
                .font(Tokens.fontMeta)
                .foregroundStyle(Tokens.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var noMatchesState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No archive matches “\(browser.filter)”")
                .font(Tokens.fontRow)
                .foregroundStyle(Tokens.textSecondary)
            if browser.snapshot.scanTruncated {
                Text("Long archives are only scanned to their first \(browser.snapshot.scanLimit) characters, so a term deeper in one will not match here.")
                    .font(Tokens.fontMeta)
                    .foregroundStyle(Tokens.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func runGroup(_ run: VaultRunGroup) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(run.objective)
                        .font(Tokens.fontRow)
                        .lineLimit(2)
                    if run.isLive {
                        StatusChip(text: "live", color: .blue)
                            .help("This run still has live dispatches — prune never deletes its archives.")
                    }
                }
                HStack(spacing: 8) {
                    Text(run.createdAt)
                    Text("\(run.archiveCount) archive\(run.archiveCount == 1 ? "" : "s")")
                    Text(run.sizeLabel)
                }
                .font(Tokens.fontMeta)
                .foregroundStyle(Tokens.textTertiary)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(run.tasks) { task in
                taskGroup(task)
            }
        }
    }

    private func taskGroup(_ task: VaultTaskGroup) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            VStack(alignment: .leading, spacing: 1) {
                Text(task.label)
                    .font(Tokens.fontRow)
                    .lineLimit(1)
                if task.title != task.label {
                    Text(task.title)
                        .font(Tokens.fontMeta)
                        .foregroundStyle(Tokens.textTertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
            .padding(.leading, 12)

            ForEach(task.archives) { archive in
                archiveRow(archive)
            }
        }
    }

    private func archiveRow(_ archive: VaultArchiveRow) -> some View {
        let selected = browser.selection == archive.dispatchID
        return Button {
            Task { await browser.select(archive.dispatchID, store: store) }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    StatusChip(text: archive.kindLabel, color: archive.isTranscript ? .purple : .teal)
                    StatusChip(text: archive.workerState,
                               color: StatusChip.color(forWorker: archive.workerState))
                    Spacer()
                    Text(archive.sizeLabel)
                        .font(Tokens.fontMeta)
                        .monospacedDigit()
                        .foregroundStyle(Tokens.textTertiary)
                }
                Text(archive.dispatchID)
                    .font(Tokens.fontMono)
                    .foregroundStyle(Tokens.textSecondary)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(archive.producerLabel)
                    Text(archive.createdAt)
                }
                .font(Tokens.fontMeta)
                .foregroundStyle(Tokens.textTertiary)
                .lineLimit(1)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Tokens.radius)
                    .fill(selected ? Tokens.rowSelected : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .padding(.leading, 24)
    }
}
