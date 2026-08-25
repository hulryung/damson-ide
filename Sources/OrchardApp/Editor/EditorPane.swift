import AppKit
import SwiftUI
import OrchardRuntime

/// Workbench `editor` tab body: monospaced text, a thin path/caret footer,
/// and an inline banner when the file changes on disk while dirty.
struct EditorPane: View {
    @EnvironmentObject var store: AppStore
    let tab: WorkbenchTab
    let key: WorkbenchKey

    var body: some View {
        if store.unsupportedReason(RemoteAffordance.editor, for: key) != nil {
            RemoteUnsupportedView(affordance: .editor, hostId: store.executionHostId(for: key))
        } else if let path = tab.filePath, let root = store.workspaceRoot(for: key) {
            EditorDocumentView(
                controller: store.editorController(root: root, path: path),
                tabID: tab.id,
                key: key)
        } else {
            PlaceholderPane(
                symbol: "doc.text",
                title: "Editor",
                detail: "Open a file from the explorer, the jump palette, or orchard file open-changed --mode edit.")
        }
    }
}

private struct EditorDocumentView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var controller: EditorDocumentController
    let tabID: UUID
    let key: WorkbenchKey

    var body: some View {
        VStack(spacing: 0) {
            if let conflict = controller.conflict {
                conflictBanner(conflict)
            }
            if let error = controller.saveError {
                errorBanner(error)
            }
            content
            Divider()
            footer
        }
        .background(Tokens.background)
        .onChange(of: controller.isDirty) { dirty in
            store.setEditorDirty(tabID, dirty, key: key)
        }
        .onAppear {
            store.setEditorDirty(tabID, controller.isDirty, key: key)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch controller.surface {
        case .text:
            EditorTextView(
                text: Binding(
                    get: { controller.draft },
                    set: { controller.edit($0) }),
                language: SyntaxLanguage.infer(fromPath: controller.relativePath),
                highlightingEnabled: !SyntaxHighlightEngine.exceedsBudget(controller.draft),
                onCursorChange: { line, column in
                    controller.line = line
                    controller.column = column
                })
        case .binary(let bytes, let isImage, let mime, let imageBase64):
            EditorPreviewNotice(
                title: isImage ? "Image preview" : "Binary file",
                detail: binaryDetail(bytes: bytes, mime: mime),
                imageBase64: imageBase64)
        case .notUTF8(let bytes):
            EditorPreviewNotice(
                title: "Not UTF-8 text",
                detail: "\(byteCount(bytes)) that are not valid UTF-8 — Latin-1, UTF-16, or "
                    + "another encoding. Opening it as text would show U+FFFD where those "
                    + "bytes are, and saving that back would make the replacement permanent, "
                    + "so it is shown read-only.")
        case .tooLarge:
            EditorPreviewNotice(
                title: "File too large",
                detail: "This file exceeds the \(FileService.defaultTextBudget / 1024) KB preview budget, so it is not opened in the editor.")
        case .missing(let message):
            EditorPreviewNotice(title: "Cannot open file", detail: message)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(controller.relativePath)
                .lineLimit(1)
                .truncationMode(.head)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            if highlightBudgetExceeded {
                Text(SyntaxHighlightEngine.budgetNotice(
                    for: SyntaxLanguage.infer(fromPath: controller.relativePath)))
            }
            if controller.isDirty {
                Text("Unsaved")
                    .foregroundStyle(Tokens.textSecondary)
            }
            if case .text = controller.surface {
                Text("\(controller.line):\(controller.column)")
                    .monospacedDigit()
            }
        }
        .font(Tokens.fontMono)
        .foregroundStyle(Tokens.textTertiary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Tokens.surface)
    }

    private var highlightBudgetExceeded: Bool {
        guard case .text = controller.surface else { return false }
        return SyntaxHighlightEngine.exceedsBudget(controller.draft)
    }

    private func conflictBanner(_ conflict: EditorDocumentController.Conflict) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(conflict.fileMissing
                 ? "This file changed on disk and no longer exists."
                 : "This file changed on disk.")
                .font(Tokens.fontMeta)
                .foregroundStyle(Tokens.textSecondary)
            Spacer(minLength: 8)
            Button("Keep Mine") { controller.keepMine() }
                .controlSize(.small)
            Button("Reload") { controller.acceptReload() }
                .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12))
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(Tokens.fontMeta)
                .foregroundStyle(Tokens.textSecondary)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.red.opacity(0.1))
    }

    private func byteCount(_ bytes: Int) -> String {
        bytes < 1024 ? "\(bytes) B" : "\(bytes / 1024) KB"
    }

    private func binaryDetail(bytes: Int, mime: String?) -> String {
        let size = byteCount(bytes)
        if let mime, !mime.isEmpty {
            return "\(mime) · \(size). Binary and over-budget files stay as a preview notice this wave."
        }
        return "\(size). Binary and over-budget files stay as a preview notice this wave."
    }
}

/// Fallback shown instead of the text editor for binary / over-budget files.
struct EditorPreviewNotice: View {
    let title: String
    let detail: String
    var imageBase64: String? = nil

    var body: some View {
        VStack(spacing: 12) {
            if let imageBase64, let data = Data(base64Encoded: imageBase64),
               let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 360, maxHeight: 240)
            } else {
                Image(systemName: "doc.questionmark")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(Tokens.textTertiary)
            }
            Text(title)
                .font(.title3)
                .foregroundStyle(Tokens.textSecondary)
            Text(detail)
                .font(Tokens.fontMeta)
                .foregroundStyle(Tokens.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.background)
    }
}
