import AppKit
import SwiftUI
import OrchardRuntime

/// Workspace disk usage and reclaimable extra-worktree storage (T90).
/// Scan is off the main actor; the view never walks disk in `body`.
struct SpaceView: View {
    @EnvironmentObject var store: AppStore
    @StateObject private var browser = SpaceBrowser()

    var body: some View {
        HSplitView {
            listPane
                .frame(minWidth: 380, idealWidth: 520, maxWidth: 720)
            detailPane
                .frame(minWidth: 280)
        }
        .background(Tokens.background)
        .frame(minWidth: 880, minHeight: 480)
        .onAppear { browser.refresh(from: store) }
        .onDisappear { browser.stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            guard let window = note.object as? NSWindow, window.title == "Space" else { return }
            if !browser.isScanning { browser.refresh(from: store) }
        }
        .sheet(item: $browser.pendingDeletion) { pending in
            if let project = store.projects.first(where: { $0.id == pending.projectID }) {
                DeleteWorktreeSheet(project: project, record: pending.record)
                    .environmentObject(store)
            }
        }
        .onChange(of: browser.pendingDeletion != nil) { presented in
            if !presented { browser.refresh(from: store) }
        }
    }

    // MARK: - List

    private var listPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            filters
            Divider()
            if let lastError = browser.lastError {
                Text(lastError)
                    .font(Tokens.fontMeta)
                    .foregroundStyle(.red)
                    .padding(10)
            }
            if browser.subjects.isEmpty {
                emptyState
            } else if browser.visibleRows.isEmpty {
                noMatchesState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4, pinnedViews: [.sectionHeaders]) {
                        ForEach(browser.visibleGroups) { group in
                            Section {
                                ForEach(group.rows) { row in
                                    rowView(row)
                                }
                            } header: {
                                repoHeader(group)
                            }
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
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Space")
                        .font(Tokens.fontHeader)
                        .foregroundStyle(Tokens.textSecondary)
                    Text("Beta")
                        .font(Tokens.fontPill)
                        .foregroundStyle(Tokens.textTertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Tokens.rowHover))
                }
                Text("Workspace disk usage and reclaimable worktree storage.")
                    .font(Tokens.fontMeta)
                    .foregroundStyle(Tokens.textTertiary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                browser.refresh(from: store)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(browser.isScanning)
            .help("Rescan workspace sizes")
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(Tokens.textTertiary)
                TextField("Filter worktrees", text: $browser.query)
                    .textFieldStyle(.plain)
                    .font(Tokens.fontMeta)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 4).fill(Tokens.rowHover))

            HStack(spacing: 8) {
                Picker("Sort", selection: $browser.sortKey) {
                    ForEach(WorkspaceSpaceSortKey.allCases, id: \.self) { key in
                        Text(key.label).tag(key)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.mini)
                .frame(maxWidth: 120)

                Button {
                    browser.sortAscending.toggle()
                } label: {
                    Image(systemName: browser.sortAscending
                          ? "arrow.up" : "arrow.down")
                }
                .buttonStyle(.borderless)
                .help(browser.sortAscending ? "Ascending" : "Descending")

                Toggle("Extra only", isOn: $browser.onlyDeletable)
                    .toggleStyle(.checkbox)
                    .font(Tokens.fontMeta)
                    .help("Show only extra worktrees that can be deleted")
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func repoHeader(_ group: WorkspaceSpaceRepoGroup) -> some View {
        HStack(spacing: 6) {
            Text(group.repoName)
                .font(Tokens.fontHeader)
                .foregroundStyle(Tokens.textSecondary)
                .lineLimit(1)
            if group.isRemote {
                Text("remote")
                    .font(Tokens.fontPill)
                    .foregroundStyle(Tokens.textTertiary)
            }
            Spacer()
            Text("\(group.sizeLabel) · \(group.reclaimableLabel) reclaimable")
                .font(Tokens.fontMeta)
                .foregroundStyle(Tokens.textTertiary)
                .monospacedDigit()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.sidebar)
    }

    private func rowView(_ row: WorkspaceSpaceRow) -> some View {
        let selected = browser.selection == row.id
        return Button {
            browser.selection = row.id
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(row.displayName)
                        .font(Tokens.fontRow)
                        .foregroundStyle(Tokens.text)
                        .lineLimit(1)
                    if row.isMainWorktree {
                        Text("main")
                            .font(Tokens.fontPill)
                            .foregroundStyle(Tokens.textTertiary)
                    }
                    Spacer(minLength: 4)
                    Text(row.sizeLabel)
                        .font(Tokens.fontMono)
                        .foregroundStyle(Tokens.textSecondary)
                        .monospacedDigit()
                }
                HStack(spacing: 6) {
                    Text(row.branchLabel)
                        .font(Tokens.fontMeta)
                        .foregroundStyle(Tokens.textTertiary)
                        .lineLimit(1)
                    if row.status != .ok {
                        Text(row.statusLabel)
                            .font(Tokens.fontPill)
                            .foregroundStyle(statusColor(row.status))
                    } else if row.reclaimableBytes > 0 {
                        Text("\(row.reclaimableLabel) reclaimable")
                            .font(Tokens.fontMeta)
                            .foregroundStyle(Tokens.textTertiary)
                    }
                    if row.subject.isArchived {
                        Text("archived")
                            .font(Tokens.fontPill)
                            .foregroundStyle(Tokens.textTertiary)
                    }
                    Spacer()
                }
                sizeBar(fraction: WorkspaceSpaceProjection.sizeFraction(
                    sizeBytes: row.sizeBytes, largestBytes: browser.largestVisibleBytes))
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Tokens.radius)
                    .fill(selected ? Tokens.rowSelected : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(row.error ?? row.path)
        .contextMenu {
            Button("Open workspace") { browser.open(row, store: store) }
            if row.canDelete {
                Button("Delete worktree…", role: .destructive) {
                    browser.requestDelete(row, store: store)
                }
            }
        }
    }

    private func sizeBar(fraction: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Tokens.rowHover)
                Capsule()
                    .fill(Color.accentColor.opacity(0.55))
                    .frame(width: max(0, geo.size.width * fraction))
            }
        }
        .frame(height: 4)
    }

    private func statusColor(_ status: WorkspaceSpaceScanStatus) -> Color {
        switch status {
        case .ok: return Tokens.textTertiary
        case .unavailable: return Tokens.textTertiary
        case .missing, .permissionDenied, .error: return .orange
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No workspaces")
                .font(Tokens.fontRow)
                .foregroundStyle(Tokens.textSecondary)
            Text("Open a project to measure its checkout and extra worktrees.")
                .font(Tokens.fontMeta)
                .foregroundStyle(Tokens.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var noMatchesState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(browser.onlyDeletable ? "No extra worktrees" : "No matches")
                .font(Tokens.fontRow)
                .foregroundStyle(Tokens.textSecondary)
            Text(browser.onlyDeletable
                 ? "Primary checkouts are not reclaimable. Extra worktrees you create show up here with a size."
                 : "Nothing matches this filter.")
                .font(Tokens.fontMeta)
                .foregroundStyle(Tokens.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let progress = browser.progressLabel {
                Text(progress)
                    .font(Tokens.fontMeta)
                    .foregroundStyle(Tokens.textTertiary)
            } else {
                Text("\(browser.snapshot.sizeLabel) · \(browser.snapshot.reclaimableLabel) reclaimable · \(browser.snapshot.worktreeCount) workspaces")
                    .font(Tokens.fontMeta)
                    .foregroundStyle(Tokens.textTertiary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Spacer()
            if let scanned = browser.lastRefreshed {
                ElapsedLabel(since: scanned)
                    .font(Tokens.fontMeta)
                    .foregroundStyle(Tokens.textTertiary)
                    .help("Seconds since the last finished scan")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    // MARK: - Detail

    private var detailPane: some View {
        Group {
            if let row = browser.selectedRow {
                detail(row)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Select a workspace")
                        .font(Tokens.fontRow)
                        .foregroundStyle(Tokens.textSecondary)
                    Text("Sizes are measured on this machine. Remote rows stay Unavailable — walking a remote path locally would be a lie.")
                        .font(Tokens.fontMeta)
                        .foregroundStyle(Tokens.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background(Tokens.background)
    }

    private func detail(_ row: WorkspaceSpaceRow) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.displayName)
                        .font(Tokens.fontRow)
                        .lineLimit(1)
                    Text(row.path)
                        .font(Tokens.fontMono)
                        .foregroundStyle(Tokens.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Open") { browser.open(row, store: store) }
                    .controlSize(.small)
                    .disabled(row.status == .missing)
                if row.canDelete {
                    Button("Delete…", role: .destructive) {
                        browser.requestDelete(row, store: store)
                    }
                    .controlSize(.small)
                }
            }
            .padding(12)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                metric(label: "Size", value: row.sizeLabel)
                metric(label: "Reclaimable", value: row.isMainWorktree
                       ? "0 B — primary checkout"
                       : row.reclaimableLabel)
                metric(label: "Status", value: row.error.map { "\(row.statusLabel) — \($0)" } ?? row.statusLabel)
                metric(label: "Branch", value: row.branchLabel)
                metric(label: "Kind", value: row.isMainWorktree ? "Primary checkout" : "Extra worktree")
                if row.skippedEntryCount > 0 {
                    metric(label: "Skipped", value: "\(row.skippedEntryCount) entries")
                }
            }
            .padding(12)
            Divider()
            Text("Top-level")
                .font(Tokens.fontHeader)
                .foregroundStyle(Tokens.textSecondary)
                .padding(.horizontal, 12)
                .padding(.top, 10)
            if row.topLevelItems.isEmpty {
                Text(row.status == .ok
                     ? "Empty directory."
                     : "No breakdown until a local scan succeeds.")
                    .font(Tokens.fontMeta)
                    .foregroundStyle(Tokens.textTertiary)
                    .padding(12)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(row.topLevelItems) { item in
                            HStack {
                                Image(systemName: itemIcon(item.kind))
                                    .font(.system(size: 10))
                                    .foregroundStyle(Tokens.textTertiary)
                                    .frame(width: 12)
                                Text(item.name)
                                    .font(Tokens.fontMeta)
                                    .lineLimit(1)
                                Spacer()
                                Text(item.sizeLabel)
                                    .font(Tokens.fontMono)
                                    .foregroundStyle(Tokens.textTertiary)
                                    .monospacedDigit()
                            }
                            .padding(.vertical, 2)
                        }
                        if row.omittedTopLevelItemCount > 0 {
                            Text("\(row.omittedTopLevelItemCount) more folded into Other")
                                .font(Tokens.fontMeta)
                                .foregroundStyle(Tokens.textTertiary)
                                .padding(.top, 4)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func metric(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(Tokens.fontMeta)
                .foregroundStyle(Tokens.textTertiary)
                .frame(width: 92, alignment: .leading)
            Text(value)
                .font(Tokens.fontMeta)
                .foregroundStyle(Tokens.text)
                .textSelection(.enabled)
        }
    }

    private func itemIcon(_ kind: WorkspaceSpaceItemKind) -> String {
        switch kind {
        case .directory: return "folder"
        case .file: return "doc"
        case .symlink: return "link"
        case .other: return "ellipsis.rectangle"
        }
    }
}
