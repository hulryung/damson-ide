import AppKit
import SwiftUI
import WebKit

/// The `browser` workbench tab body: the per-workspace embedded browser
/// (tab strip, URL bar, back/forward, loading state) over web views owned by
/// `BrowserManager` — so CLI automation verbs and this pane drive the same tabs.
struct BrowserPane: View {
    @EnvironmentObject var store: AppStore
    let key: WorkbenchKey

    var body: some View {
        if let manager = store.browser, let wsKey = store.browserWorkspaceKey(for: key) {
            WorkspaceBrowserView(manager: manager, controller: manager.controller(for: wsKey))
        } else {
            PlaceholderPane(symbol: "globe", title: "Browser",
                            detail: "The runtime is unavailable, so the browser cannot start.")
        }
    }
}

extension AppStore {
    /// Browser workspaces are keyed by worktree path — the same key the CLI's
    /// `--worktree` selector resolves to, which is what makes the pane and the
    /// automation verbs land on the same tabs.
    func browserWorkspaceKey(for key: WorkbenchKey) -> String? {
        switch key {
        case .projectRoot(let id):
            return projects.first { $0.id == id }?.repo.standardizedFileURL.path
        case .worktree(let id):
            for project in projects {
                if let record = project.record(id: id) {
                    return record.path.standardizedFileURL.path
                }
            }
            return nil
        }
    }
}

struct WorkspaceBrowserView: View {
    @EnvironmentObject var store: AppStore
    let manager: BrowserManager
    @ObservedObject var controller: WorkspaceBrowserController

    var body: some View {
        VStack(spacing: 0) {
            if !controller.tabs.isEmpty {
                tabStrip
                Divider()
            }
            if let tab = controller.activeTab {
                BrowserToolbar(manager: manager, workspaceKey: controller.key, tab: tab)
                Divider()
                BrowserWebContainer(tab: tab)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                emptyState
            }
        }
        .background(Tokens.background)
    }

    private var tabStrip: some View {
        HStack(spacing: 2) {
            ForEach(controller.tabs) { tab in
                BrowserTabChip(tab: tab, isSelected: tab.id == controller.activeTab?.id,
                               select: { manager.selectTab(workspaceKey: controller.key, pageId: tab.id) },
                               close: { manager.closeTab(workspaceKey: controller.key, pageId: tab.id) })
            }
            Spacer(minLength: 4)
            Button { store.openBrowserTab(workspaceKey: controller.key) } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10))
            }
            .buttonStyle(.borderless)
            .help("New browser tab")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Tokens.surface)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "globe")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Tokens.textTertiary)
            Text("No pages open")
                .font(.title3)
                .foregroundStyle(Tokens.textSecondary)
            Button("New Tab") { store.openBrowserTab(workspaceKey: controller.key) }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.background)
    }
}

private struct BrowserTabChip: View {
    @ObservedObject var tab: BrowserTabModel
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            if tab.isLoading {
                ProgressView().controlSize(.mini).scaleEffect(0.6)
            } else {
                Image(systemName: "globe").font(.system(size: 9))
            }
            Text(tab.title)
                .font(Tokens.fontRow)
                .lineLimit(1)
                .frame(maxWidth: 140, alignment: .leading)
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 7, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Tokens.textTertiary)
            .help("Close tab")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: Tokens.radius)
                .fill(isSelected ? Tokens.background : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.radius)
                .strokeBorder(isSelected ? Tokens.border : .clear, lineWidth: 1)
        )
        .foregroundStyle(isSelected ? Tokens.text : Tokens.textSecondary)
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
    }
}

private struct BrowserToolbar: View {
    let manager: BrowserManager
    let workspaceKey: String
    @ObservedObject var tab: BrowserTabModel
    @State private var address = ""
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { manager.goBack(workspaceKey: workspaceKey, pageId: tab.id) } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .disabled(!tab.canGoBack)
                .help("Back")

                Button { manager.goForward(workspaceKey: workspaceKey, pageId: tab.id) } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.borderless)
                .disabled(!tab.canGoForward)
                .help("Forward")

                Button {
                    if tab.isLoading {
                        tab.stopLoading()
                    } else {
                        manager.reload(workspaceKey: workspaceKey, pageId: tab.id)
                    }
                } label: {
                    Image(systemName: tab.isLoading ? "xmark" : "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help(tab.isLoading ? "Stop" : "Reload")

                TextField("Enter URL", text: $address)
                    .textFieldStyle(.plain)
                    .font(Tokens.fontMono)
                    .focused($addressFocused)
                    .onSubmit {
                        manager.openURL(address, workspaceKey: workspaceKey, pageId: tab.id)
                        addressFocused = false
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: Tokens.radius)
                            .fill(Tokens.background)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Tokens.radius)
                            .strokeBorder(Tokens.border, lineWidth: 1)
                    )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Tokens.surface)

            if tab.isLoading {
                ProgressView(value: max(0.05, tab.progress))
                    .progressViewStyle(.linear)
                    .frame(height: 2)
            }

            if let error = tab.loadError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(Tokens.fontMeta)
                        .foregroundStyle(Tokens.textSecondary)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.orange.opacity(0.1))
            }
        }
        .onAppear { address = tab.urlString }
        .onChange(of: tab.urlString) { newValue in
            // The page navigated under us; keep the field honest unless the
            // user is mid-edit.
            if !addressFocused { address = newValue }
        }
        .onChange(of: tab.id) { _ in address = tab.urlString }
    }
}

/// Adopts the tab's `WKWebView` into the SwiftUI hierarchy. The web view is
/// created (possibly offscreen, by a CLI verb) before this container exists and
/// survives after it disappears — tabs persist in memory per workspace.
private struct BrowserWebContainer: NSViewRepresentable {
    let tab: BrowserTabModel

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ container: NSView, context: Context) {
        let webView = tab.webView
        guard webView.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
    }
}
