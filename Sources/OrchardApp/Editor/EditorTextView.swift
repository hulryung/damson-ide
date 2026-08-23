import AppKit
import SwiftUI
import OrchardRuntime

/// Monospaced `NSTextView` used by the workbench editor tab.
///
/// Highlighting is applied as attributes on the existing storage — the string
/// itself is never rewritten here, so T28 dirty tracking, undo, and caret
/// reporting stay on the raw text.
struct EditorTextView: NSViewRepresentable {
    @Binding var text: String
    var language: SyntaxLanguage
    var highlightingEnabled: Bool
    var onCursorChange: (Int, Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.contentView.postsBoundsChangedNotifications = true

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                       height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        textView.font = font
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.insertionPointColor = .labelColor
        textView.typingAttributes = [
            .font: font,
            .foregroundColor: NSColor.labelColor,
        ]
        textView.string = text
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor.selectedTextBackgroundColor,
            .foregroundColor: NSColor.selectedTextColor,
        ]

        scroll.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.highlighter.textView = textView
        context.coordinator.boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView,
            queue: .main
        ) { [weak coordinator = context.coordinator] _ in
            coordinator?.highlighter.visibleDidChange()
        }
        context.coordinator.applyHighlightSettings()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? NSTextView else { return }
        let settingsChanged = context.coordinator.language != language
            || context.coordinator.highlightingEnabled != highlightingEnabled
        context.coordinator.language = language
        context.coordinator.highlightingEnabled = highlightingEnabled
        if textView.string != text {
            let selected = textView.selectedRange()
            textView.string = text
            let end = (text as NSString).length
            let location = min(selected.location, end)
            let length = min(selected.length, max(0, end - location))
            textView.setSelectedRange(NSRange(location: location, length: length))
            context.coordinator.applyHighlightSettings()
        } else if settingsChanged {
            context.coordinator.applyHighlightSettings()
        }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        if let observer = coordinator.boundsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: EditorTextView
        weak var textView: NSTextView?
        let highlighter = EditorHighlighter()
        var language: SyntaxLanguage
        var highlightingEnabled: Bool
        var boundsObserver: NSObjectProtocol?
        private var pendingEditUTF16 = 0

        init(_ parent: EditorTextView) {
            self.parent = parent
            self.language = parent.language
            self.highlightingEnabled = parent.highlightingEnabled
        }

        func applyHighlightSettings() {
            highlighter.language = language
            highlighter.enabled = highlightingEnabled && language != .plain
            if highlighter.enabled {
                highlighter.restart()
            } else {
                highlighter.disable()
            }
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
                      replacementString: String?) -> Bool {
            pendingEditUTF16 = affectedCharRange.location
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            if parent.text != textView.string {
                parent.text = textView.string
            }
            highlighter.language = language
            highlighter.enabled = highlightingEnabled && language != .plain
            if highlighter.enabled {
                highlighter.documentDidEdit(editUTF16: pendingEditUTF16)
            }
            reportCursor(textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            reportCursor(textView)
        }

        private func reportCursor(_ textView: NSTextView) {
            let caret = EditorDocument.caret(in: textView.string, location: textView.selectedRange().location)
            parent.onCursorChange(caret.line, caret.column)
        }
    }
}
