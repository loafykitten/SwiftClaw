import SwiftUI

#if os(macOS)
import AppKit

/// The styled-source editor. `NSTextView`'s own text storage is the single
/// source of truth for what's on screen — this view never binds the
/// document through a SwiftUI `@State`/`Binding` round trip. Content only
/// ever flows into the view via `controller.applyText` (load, reconcile
/// reload, Take Theirs) and only ever flows out via the delegate's
/// `textDidChange`/`textDidEndEditing` callbacks into
/// `controller.textDidChange(_:)`/`flushPendingSave()`.
struct NoteEditorView: NSViewRepresentable {
    let controller: NoteEditorController

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.allowsUndo = true
        let theme = MarkdownEditorTheme.current
        textView.font = theme.bodyFont
        textView.textColor = theme.textColor
        textView.drawsBackground = true
        textView.backgroundColor = theme.backgroundColor
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]
        textView.delegate = context.coordinator

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.documentView = textView
        scrollView.drawsBackground = false

        context.coordinator.textView = textView
        // Attach the highlighter before the first content assignment so
        // even the initial load goes through the same styling path as
        // every later edit.
        textView.textStorage?.delegate = context.coordinator.highlighter

        controller.applyText = { [weak textView] text in
            guard let textView, textView.string != text else { return }
            textView.string = text
        }
        textView.string = controller.currentText

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        // Deliberately empty: the live document is driven one-way by
        // `controller.applyText`, never by SwiftUI re-evaluating this
        // view's body, so typing never fights a competing update here.
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let controller: NoteEditorController
        let highlighter = MarkdownSourceHighlighter()
        weak var textView: NSTextView?

        init(controller: NoteEditorController) {
            self.controller = controller
        }

        nonisolated func textDidChange(_ notification: Notification) {
            MainActor.assumeIsolated {
                guard let textView = notification.object as? NSTextView else { return }
                controller.textDidChange(textView.string)
            }
        }

        nonisolated func textDidEndEditing(_ notification: Notification) {
            MainActor.assumeIsolated {
                _ = Task { await self.controller.flushPendingSave() }
            }
        }
    }
}
#else

/// Non-macOS fallback: a plain `TextEditor` bound through the controller.
/// This reintroduces the SwiftUI `Binding` round trip Phase 2 explicitly
/// avoids on macOS — acceptable here only because there's no styled-source
/// NSTextView-equivalent on this platform yet; a UIKit `UITextView`-backed
/// controller-owned editor is future iOS work, not part of this package.
struct NoteEditorView: View {
    let controller: NoteEditorController

    var body: some View {
        TextEditor(text: Binding(
            get: { controller.currentText },
            set: { controller.textDidChange($0) }
        ))
        .font(.system(.body, design: .monospaced))
        .onAppear {
            controller.applyText = { _ in }
        }
    }
}
#endif
