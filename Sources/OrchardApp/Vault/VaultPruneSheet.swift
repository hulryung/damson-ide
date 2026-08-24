import SwiftUI
import OrchardRuntime

/// The mandatory dry run. Deleting an archive is unrecoverable, so the plan is named
/// in full — every dispatch, its run and task, its size and age reason — before the
/// button that executes it exists. Runs with live dispatches never appear here; the
/// sheet says how much they hold and why it stays.
struct VaultPruneSheet: View {
    let plan: ArchivePrunePlan
    let isPruning: Bool
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if plan.isEmpty {
                emptyBody
            } else {
                entryList
            }
            Divider()
            footer
        }
        .frame(width: 620, height: 520)
        .background(Tokens.background)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Prune worker archives")
                .font(.system(size: 15, weight: .semibold))
            Text(plan.summary)
                .font(Tokens.fontRow)
                .foregroundStyle(plan.isEmpty ? Tokens.textSecondary : Tokens.text)
                .fixedSize(horizontal: false, vertical: true)
            Text(policyLine)
                .font(Tokens.fontMeta)
                .foregroundStyle(Tokens.textTertiary)
            if plan.protectedCount > 0 {
                Text(protectedLine)
                    .font(Tokens.fontMeta)
                    .foregroundStyle(Tokens.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if plan.remainingOverBytes > 0 {
                Text("Still \(VaultProjection.byteLabel(plan.remainingOverBytes)) over the size cap afterwards — held by runs that are still live.")
                    .font(Tokens.fontMeta)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var policyLine: String {
        var parts: [String] = []
        parts.append(plan.policy.enforcesSize
                     ? "keep at most \(VaultProjection.byteLabel(plan.policy.maxTotalBytes))"
                     : "no size cap")
        parts.append(plan.policy.enforcesAge
                     ? "keep for at most \(plan.policy.maxAgeDays) days"
                     : "no age cap")
        return "Caps: " + parts.joined(separator: " · ") + " (change them in Settings ▸ Services)."
    }

    private var protectedLine: String {
        let runs = plan.protectedRunIDs.count
        return "\(plan.protectedCount) archive\(plan.protectedCount == 1 ? "" : "s") "
            + "(\(VaultProjection.byteLabel(plan.protectedBytes))) in \(runs) live "
            + "run\(runs == 1 ? "" : "s") are never deleted."
    }

    private var emptyBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Nothing would be deleted.")
                .font(Tokens.fontRow)
                .foregroundStyle(Tokens.textSecondary)
            Text("Every archive is inside the caps, or belongs to a run that still has live dispatches. \(plan.totalCount) archive\(plan.totalCount == 1 ? "" : "s") totalling \(plan.totalLabel) stay.")
                .font(Tokens.fontMeta)
                .foregroundStyle(Tokens.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var entryList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(plan.entries) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            StatusChip(text: entry.reason.rawValue,
                                       color: entry.reason == .age ? .orange : .yellow)
                            StatusChip(text: entry.kindLabel,
                                       color: entry.kind == "transcript_pin" ? .purple : .teal)
                            Text(entry.taskLabel)
                                .font(Tokens.fontRow)
                                .lineLimit(1)
                            Spacer()
                            Text(entry.sizeLabel)
                                .font(Tokens.fontMeta)
                                .monospacedDigit()
                                .foregroundStyle(Tokens.textTertiary)
                        }
                        HStack(spacing: 8) {
                            Text(entry.dispatchID)
                            Text(entry.createdAt)
                            Text(entry.runObjective)
                                .lineLimit(1)
                        }
                        .font(Tokens.fontMeta)
                        .foregroundStyle(Tokens.textTertiary)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: Tokens.radius)
                            .fill(Tokens.surface)
                    )
                }
            }
            .padding(10)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("Deleting an archive cannot be undone. Messages, tasks and dispatches are never touched.")
                .font(Tokens.fontMeta)
                .foregroundStyle(Tokens.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Cancel", action: cancel)
                .keyboardShortcut(.cancelAction)
            if !plan.isEmpty {
                Button(isPruning ? "Deleting…" : "Delete \(plan.entries.count)", action: confirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isPruning)
            }
        }
        .padding(14)
    }
}
