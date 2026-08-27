import OrchardRuntime
import SwiftUI

/// Right-sidebar `checks` section (inventory §6): the workspace's pull request and
/// every check on it, with its conclusion.
///
/// There is no empty state. Either the reading is available — in which case the PR
/// and its checks are drawn — or it carries a named reason, which is drawn as a
/// headline, `gh`'s own words, and the one thing to do about it. The one truly
/// indeterminate moment, the first read, says "reading" and nothing else.
struct ChecksSidebar: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var checks: ChecksModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    content
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // The read happens here, not in `body`: a view body may not run a
        // subprocess, and switching workspaces must not wait on GitHub.
        .task(id: store.selection) {
            guard let target = store.checksTarget() else { return }
            await checks.refresh(target)
        }
        .onAppear { checks.beginObservingAge() }
        .onDisappear { checks.endObservingAge() }
    }

    private var target: ChecksTarget? { store.checksTarget() }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Checks")
                .font(Tokens.fontMeta)
                .foregroundStyle(Tokens.textSecondary)
            Spacer(minLength: 4)
            if checks.isRefreshing(store.selection) {
                ProgressView().controlSize(.small).scaleEffect(0.6)
            }
            Button {
                guard let target else { return }
                Task {
                    await checks.invalidate(target)
                    await checks.refresh(target, force: true)
                }
            } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 10))
            }
            .buttonStyle(.borderless)
            .disabled(target == nil || checks.isRefreshing(store.selection))
            .help("Ask GitHub again now, ignoring the cached reading")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var content: some View {
        if store.selection == nil {
            ChecksNotice(symbol: "square.dashed", headline: "No workspace selected",
                         detail: "Select a workspace to read its pull request and checks.",
                         remedy: nil)
        } else if let snapshot = checks.snapshot(for: store.selection) {
            if let reason = snapshot.unavailable {
                ChecksNotice(symbol: "exclamationmark.triangle",
                             headline: reason.headline,
                             detail: reason.detail,
                             remedy: reason.remedy,
                             code: reason.code)
                footer(snapshot)
            } else {
                available(snapshot)
            }
        } else if checks.isRefreshing(store.selection) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small).scaleEffect(0.6)
                Text("Reading checks from GitHub…")
                    .font(Tokens.fontMeta)
                    .foregroundStyle(Tokens.textSecondary)
            }
        } else {
            ChecksNotice(symbol: "clock.arrow.circlepath", headline: "Not read yet",
                         detail: "Checks have not been read for this workspace.",
                         remedy: "Press the refresh button to ask GitHub.")
        }
    }

    @ViewBuilder
    private func available(_ snapshot: ChecksSnapshot) -> some View {
        if let pr = snapshot.pullRequest {
            VStack(alignment: .leading, spacing: 3) {
                Text(ChecksPresentation.title(pr))
                    .font(Tokens.fontRow)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                HStack(spacing: 5) {
                    Image(systemName: ChecksPresentation.symbol(for: snapshot.rollupValue))
                        .font(.system(size: 10))
                        .foregroundStyle(ChecksPresentation.color(for: snapshot.rollupValue))
                    Text(snapshot.rollupLabel)
                        .font(Tokens.fontMeta)
                        .foregroundStyle(Tokens.textSecondary)
                }
                Text("\(pr.state.capitalized) · \(pr.headRefName)")
                    .font(Tokens.fontMeta)
                    .foregroundStyle(Tokens.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !pr.url.isEmpty, let url = URL(string: pr.url) {
                    Link("Open on GitHub", destination: url)
                        .font(Tokens.fontMeta)
                }
            }
        }

        if snapshot.checks.isEmpty {
            ChecksNotice(symbol: "circle.dashed", headline: "No checks reported",
                         detail: "This pull request has no CI checks attached.",
                         remedy: nil)
        } else {
            Text(ChecksPresentation.countsLine(snapshot))
                .font(Tokens.fontMeta)
                .foregroundStyle(Tokens.textTertiary)
            VStack(alignment: .leading, spacing: 1) {
                ForEach(snapshot.checks) { check in
                    CheckRow(check: check,
                             isSelected: checks.selectedCheckID(for: store.selection) == check.id)
                }
            }
        }
        footer(snapshot)
    }

    /// Every panel ends with when the reading was taken, and against which commit.
    /// This line is the contract that a cached answer is never shown as current.
    @ViewBuilder
    private func footer(_ snapshot: ChecksSnapshot) -> some View {
        Divider().padding(.vertical, 2)
        VStack(alignment: .leading, spacing: 1) {
            Text("checked \(ChecksPresentation.age(checks.age(for: store.selection)))")
            if let sha = snapshot.headSha {
                Text("at \(sha.prefix(8))\(snapshot.branch.map { " · \($0)" } ?? "")")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .font(Tokens.fontPill)
        .foregroundStyle(Tokens.textTertiary)
    }
}

/// One check row. Clicking opens (or refocuses) the check-details tab on it.
private struct CheckRow: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var checks: ChecksModel
    let check: CheckRunSummary
    let isSelected: Bool
    @State private var isHovering = false

    var body: some View {
        Button {
            guard let target = store.checksTarget() else { return }
            checks.select(check, target: target)
            store.openCheckDetails()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: check.bucketValue.symbol)
                    .font(.system(size: 10))
                    .foregroundStyle(ChecksPresentation.color(for: check.bucketValue))
                VStack(alignment: .leading, spacing: 1) {
                    Text(check.name)
                        .font(Tokens.fontRow)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 4) {
                        Text(check.bucketValue.label)
                        if let workflow = check.workflow, !workflow.isEmpty {
                            Text("·")
                            Text(workflow).lineLimit(1)
                        }
                        if let duration = ChecksPresentation.duration(check) {
                            Text("·")
                            Text(duration)
                        }
                    }
                    .font(Tokens.fontPill)
                    .foregroundStyle(Tokens.textTertiary)
                }
                Spacer(minLength: 2)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Tokens.radius)
                .fill(isSelected ? Tokens.rowSelected : (isHovering ? Tokens.rowHover : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        // The raw GitHub words, so a bucket we collapsed is always traceable back
        // to what GitHub actually said.
        .help(helpText)
    }

    private var helpText: String {
        var parts = [check.name]
        let raw = [check.status, check.conclusion].compactMap { $0 }.filter { !$0.isEmpty }
        if !raw.isEmpty { parts.append("GitHub: " + raw.joined(separator: " / ")) }
        if let summary = check.summary, !summary.isEmpty { parts.append(summary) }
        if let url = check.detailsUrl { parts.append(url) }
        return parts.joined(separator: "\n")
    }
}

/// A named dead end. Never rendered without a headline, and never with an empty
/// body — that is the whole point of the type.
struct ChecksNotice: View {
    let symbol: String
    let headline: String
    let detail: String
    var remedy: String?
    var code: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(Tokens.textSecondary)
                Text(headline)
                    .font(Tokens.fontRow)
                    .fontWeight(.medium)
                if let code {
                    Text(code)
                        .font(Tokens.fontPill)
                        .monospaced()
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Tokens.rowHover))
                        .foregroundStyle(Tokens.textTertiary)
                }
            }
            if !detail.isEmpty {
                Text(detail)
                    .font(Tokens.fontMeta)
                    .foregroundStyle(Tokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let remedy, !remedy.isEmpty {
                Text(remedy)
                    .font(Tokens.fontMeta)
                    .foregroundStyle(Tokens.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The card's `ci` property (inventory §2): the rollup for a workspace, shown only
/// when a reading exists. No reading, no chip — a card never guesses a CI state.
struct ChecksCardChip: View {
    let snapshot: ChecksSnapshot?

    var body: some View {
        if let snapshot, snapshot.isAvailable {
            let rollup = snapshot.rollupValue
            HStack(spacing: 3) {
                Image(systemName: ChecksPresentation.symbol(for: rollup))
                    .font(.system(size: 8))
                if snapshot.checks.count > 1 {
                    Text("\(snapshot.checks.count)")
                        .font(Tokens.fontPill)
                        .monospacedDigit()
                }
            }
            .foregroundStyle(ChecksPresentation.color(for: rollup))
            .help("\(snapshot.rollupLabel) — \(ChecksPresentation.countsLine(snapshot))")
        }
    }
}
