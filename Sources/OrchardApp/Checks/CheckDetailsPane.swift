import OrchardRuntime
import SwiftUI

/// Center `check-details` tab (inventory §6): one check run — what GitHub said
/// about it, and its job log.
///
/// Same discipline as the sidebar: a log that cannot be fetched is a named reason
/// with a remedy, not an empty text view. The tab is only ever opened for a check
/// the user picked, so "nothing selected" is a real, explainable state too.
struct CheckDetailsPane: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var checks: ChecksModel
    let key: WorkbenchKey

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            body(for: checks.selectedCheck(for: key))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Tokens.background)
        .onAppear { checks.beginObservingAge() }
        .onDisappear { checks.endObservingAge() }
    }

    private var check: CheckRunSummary? { checks.selectedCheck(for: key) }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            if let check {
                Image(systemName: check.bucketValue.symbol)
                    .foregroundStyle(ChecksPresentation.color(for: check.bucketValue))
                VStack(alignment: .leading, spacing: 1) {
                    Text(check.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 5) {
                        Text(check.bucketValue.label)
                        // What GitHub literally said, beside our collapsed bucket,
                        // so the collapse is never the only record.
                        if let raw = rawState(check) {
                            Text("·")
                            Text(raw).monospaced()
                        }
                        if let workflow = check.workflow, !workflow.isEmpty {
                            Text("·")
                            Text(workflow)
                        }
                        if let duration = ChecksPresentation.duration(check) {
                            Text("·")
                            Text(duration)
                        }
                    }
                    .font(Tokens.fontMeta)
                    .foregroundStyle(Tokens.textSecondary)
                    .lineLimit(1)
                }
            } else {
                Text("Check details")
                    .font(.system(size: 13, weight: .semibold))
            }
            Spacer(minLength: 8)
            if let check, let raw = check.detailsUrl, let url = URL(string: raw) {
                Link("Open on GitHub", destination: url).font(Tokens.fontMeta)
            }
            if checks.isLoadingLog(key) {
                ProgressView().controlSize(.small).scaleEffect(0.6)
            }
            if let check {
                Button {
                    guard let target = store.checksTarget() else { return }
                    Task { await checks.loadLog(check, target: target) }
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .disabled(checks.isLoadingLog(key))
                .help("Fetch this job's log again")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Tokens.surface)
    }

    private func rawState(_ check: CheckRunSummary) -> String? {
        let parts = [check.status, check.conclusion].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }

    @ViewBuilder
    private func body(for check: CheckRunSummary?) -> some View {
        if check == nil {
            padded {
                ChecksNotice(symbol: "list.bullet.rectangle",
                             headline: "No check selected",
                             detail: "This tab shows one check run's output.",
                             remedy: "Pick a check in the Checks sidebar section.")
            }
        } else if let result = checks.log(for: key) {
            if result.isAvailable, let log = result.log {
                logView(log, result: result)
            } else {
                padded {
                    ChecksNotice(symbol: "exclamationmark.triangle",
                                 headline: result.headline ?? "No log",
                                 detail: result.detail ?? "",
                                 remedy: result.remedy,
                                 code: result.reason)
                    if let summary = check?.summary, !summary.isEmpty {
                        Divider().padding(.vertical, 4)
                        Text(summary)
                            .font(Tokens.fontMeta)
                            .foregroundStyle(Tokens.textSecondary)
                            .textSelection(.enabled)
                    }
                }
            }
        } else if checks.isLoadingLog(key) {
            padded {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                    Text("Fetching the job log from GitHub…")
                        .font(Tokens.fontMeta)
                        .foregroundStyle(Tokens.textSecondary)
                }
            }
        } else {
            padded {
                ChecksNotice(symbol: "clock.arrow.circlepath", headline: "Log not fetched",
                             detail: "This check's log has not been read yet.",
                             remedy: "Press refresh to fetch it.")
            }
        }
    }

    @ViewBuilder
    private func logView(_ log: String, result: CheckLogResult) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Truncation is stated, never silent: a tail presented as a whole log
            // is the same class of lie as a cached status presented as current.
            HStack(spacing: 6) {
                if result.truncated {
                    Text("last \(result.returnedLines) of \(result.totalLines) lines")
                } else {
                    Text("\(result.totalLines) lines")
                }
                Text("·")
                Text("fetched " + ChecksPresentation.age(
                    max(0, Date().timeIntervalSince(result.observedDate))))
            }
            .font(Tokens.fontPill)
            .foregroundStyle(Tokens.textTertiary)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            ScrollView([.vertical, .horizontal]) {
                Text(log)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func padded<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) { content() }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
