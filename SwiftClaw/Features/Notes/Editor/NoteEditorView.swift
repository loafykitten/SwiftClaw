import Foundation
import SwiftUI

#if os(macOS)
import AppKit

/// `NSTextViewDelegate` has no actor metadata, but AppKit invokes these
/// callbacks for this editor on the main thread. This wrapper expresses that
/// invariant when entering `MainActor.assumeIsolated`.
private nonisolated struct MainActorTextView: @unchecked Sendable {
    let value: NSTextView
}

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
        controller.applyReplacement = { [weak textView] range, replacement, reusesTrailingClosingBrackets in
            guard let textView, textView.shouldChangeText(in: range, replacementString: replacement) else { return }
            textView.insertText(replacement, replacementRange: range)
            if reusesTrailingClosingBrackets {
                textView.setSelectedRange(NSRange(location: range.location + (replacement as NSString).length + 2, length: 0))
            }
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
            guard let textView = notification.object as? NSTextView else { return }
            let mainActorTextView = MainActorTextView(value: textView)
            MainActor.assumeIsolated {
                let textView = mainActorTextView.value
                controller.textDidChange(textView.string)
                controller.updateWikilinkCompletion(text: textView.string, cursorLocation: textView.selectedRange().location)
            }
        }

        nonisolated func textDidEndEditing(_ notification: Notification) {
            MainActor.assumeIsolated {
                controller.dismissWikilinkCompletion()
                _ = Task { await self.controller.flushPendingSave() }
            }
        }

        nonisolated func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let mainActorTextView = MainActorTextView(value: textView)
            MainActor.assumeIsolated {
                let textView = mainActorTextView.value
                controller.updateWikilinkCompletion(text: textView.string, cursorLocation: textView.selectedRange().location)
            }
        }

        /// Lets `Escape` dismiss an open wikilink completion popup instead of
        /// falling through to whatever `cancelOperation` would otherwise do.
        nonisolated func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            MainActor.assumeIsolated {
                guard commandSelector == #selector(NSResponder.cancelOperation(_:)), controller.wikilinkTrigger != nil else {
                    return false
                }
                controller.dismissWikilinkCompletion()
                return true
            }
        }
    }
}
#else

/// Non-macOS fallback: a plain `TextEditor` bound through the controller.
/// This reintroduces the SwiftUI `Binding` round trip Phase 2 explicitly
/// avoids on macOS — acceptable here only because there's no styled-source
/// NSTextView-equivalent on this platform yet. Its `TextSelection` binding
/// still gives wikilink completion the actual iOS cursor position.
struct NoteEditorView: View {
    let controller: NoteEditorController
    @State private var textSelection: TextSelection?

    var body: some View {
        TextEditor(
            text: Binding(
                get: { controller.currentText },
                set: { newText in
                    controller.textDidChange(newText)
                    updateWikilinkCompletion(text: newText, selection: textSelection)
                }
            ),
            selection: Binding(
                get: { textSelection },
                set: { newSelection in
                    textSelection = newSelection
                    updateWikilinkCompletion(text: controller.currentText, selection: newSelection)
                }
            )
        )
        .font(.system(.body, design: .monospaced))
        .onAppear { [weak controller] in
            controller?.applyText = { _ in }
            controller?.applyReplacement = { [weak controller] range, replacement, reusesTrailingClosingBrackets in
                guard let controller else { return }
                guard let textRange = Range(range, in: controller.currentText) else { return }
                var updated = controller.currentText
                updated.replaceSubrange(textRange, with: replacement)
                controller.textDidChange(updated)
                let cursorOffset = range.location + replacement.utf16.count + (reusesTrailingClosingBrackets ? 2 : 0)
                let cursor = String.Index(utf16Offset: cursorOffset, in: updated)
                textSelection = TextSelection(insertionPoint: cursor)
                controller.updateWikilinkCompletion(text: updated, cursorLocation: cursorOffset)
            }
        }
    }

    private func updateWikilinkCompletion(text: String, selection: TextSelection?) {
        guard let selection,
              case .selection(let range) = selection.indices,
              range.isEmpty,
              let cursorLocation = WikilinkCompletion.utf16Offset(for: range.lowerBound, in: text)
        else {
            controller.dismissWikilinkCompletion()
            return
        }
        controller.updateWikilinkCompletion(text: text, cursorLocation: cursorLocation)
    }
}
#endif

/// Wikilink autocomplete popup: a small, keyboard-dismissible list anchored
/// to the top of the editor. Not pixel-anchored to the text caret — SwiftUI
/// has no supported way to read the live text view's caret screen position
/// from here — but fully functional and accessible on both platforms: it's
/// plain SwiftUI, dismissible (`controller.dismissWikilinkCompletion()`), and
/// each row is a plain accessible button.
struct WikilinkCompletionOverlay: View {
    let controller: NoteEditorController

    var body: some View {
        if !controller.wikilinkCandidates.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(controller.wikilinkCandidates, id: \.note.relativePath) { candidate in
                    Button {
                        accept(candidate)
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(candidate.note.title)
                                .font(.body)
                            Text(candidate.note.relativePath)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .accessibilityLabel("Link to \(candidate.note.title)")
                }
            }
            .padding(.vertical, 4)
            .background(.regularMaterial, in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.2)))
            .frame(maxWidth: 320)
            .shadow(radius: 6)
            .padding(12)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Wikilink suggestions")
        }
    }

    private func accept(_ candidate: WikilinkCompletion.Candidate) {
        guard let completion = controller.acceptWikilinkCompletion(candidate) else { return }
        controller.applyReplacement?(
            completion.range,
            completion.replacement,
            completion.reusesTrailingClosingBrackets
        )
    }
}
