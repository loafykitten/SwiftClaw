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

private final class CenteredMeasureScrollView: NSScrollView {
    weak var editorTextView: NSTextView?
    var maximumContentWidth: CGFloat = 0

    override func layout() {
        super.layout()
        guard let editorTextView else { return }
        let horizontalInset = max(10, (contentView.bounds.width - maximumContentWidth) / 2)
        let inset = NSSize(width: horizontalInset, height: 10)
        // Only assign on change: setting `textContainerInset` invalidates
        // layout, so an unconditional write from inside `layout()` can spin
        // the layout pass at full CPU.
        if editorTextView.textContainerInset != inset {
            editorTextView.textContainerInset = inset
        }
    }
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
        // Set these directly on the native editor so VoiceOver gets useful
        // context without replacing NSTextView's editable-text role or value.
        textView.setAccessibilityLabel("Note editor")
        textView.setAccessibilityHelp("Edit the Markdown content of this note.")
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

        let scrollView = CenteredMeasureScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.editorTextView = textView
        scrollView.maximumContentWidth = 72 * ("0" as NSString).size(withAttributes: [.font: theme.bodyFont]).width

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
                updateWikilinkAnchor(for: textView)
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
                updateWikilinkAnchor(for: textView)
            }
        }

        /// Handles keyboard navigation while the completion popup is open.
        nonisolated func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            MainActor.assumeIsolated {
                guard !controller.wikilinkCandidates.isEmpty else { return false }

                switch commandSelector {
                case #selector(NSResponder.cancelOperation(_:)):
                    controller.dismissWikilinkCompletion()
                    return true
                case #selector(NSResponder.moveUp(_:)):
                    controller.moveWikilinkCompletionSelection(.up)
                    return true
                case #selector(NSResponder.moveDown(_:)):
                    controller.moveWikilinkCompletionSelection(.down)
                    return true
                case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
                    guard let candidate = controller.selectedWikilinkCandidate,
                          let completion = controller.acceptWikilinkCompletion(candidate)
                    else { return false }
                    controller.applyReplacement?(
                        completion.range,
                        completion.replacement,
                        completion.reusesTrailingClosingBrackets
                    )
                    return true
                default:
                    return false
                }
            }
        }

        private func updateWikilinkAnchor(for textView: NSTextView) {
            guard controller.wikilinkTrigger != nil,
                  let scrollView = textView.enclosingScrollView,
                  let window = textView.window
            else {
                controller.updateWikilinkAnchorRect(nil)
                return
            }

            var actualRange = NSRange()
            let screenRect = textView.firstRect(
                forCharacterRange: textView.selectedRange(),
                actualRange: &actualRange
            )
            guard !screenRect.isNull, !screenRect.isInfinite, screenRect.height > 0 else {
                controller.updateWikilinkAnchorRect(nil)
                return
            }

            let windowRect = window.convertFromScreen(screenRect)
            let localRect = scrollView.convert(windowRect, from: nil)
            let bounds = scrollView.bounds
            let topLeadingY = scrollView.isFlipped
                ? localRect.minY - bounds.minY
                : bounds.maxY - localRect.maxY
            controller.updateWikilinkAnchorRect(
                CGRect(
                    x: localRect.minX - bounds.minX,
                    y: topLeadingY,
                    width: localRect.width,
                    height: localRect.height
                )
            )
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

/// Wikilink autocomplete popup. On macOS its custom layout uses the caret
/// rectangle reported by the live `NSTextView`; other platforms retain the
/// editor's top-leading placement.
struct WikilinkCompletionOverlay: View {
    let controller: NoteEditorController

    @ViewBuilder
    var body: some View {
        if !controller.wikilinkCandidates.isEmpty {
            #if os(macOS)
            WikilinkCompletionLayout(anchorRect: controller.wikilinkAnchorRect) {
                completionList
            }
            #else
            completionList
                .padding(12)
            #endif
        }
    }

    private var completionList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Identity must live on the candidate, never the index:
                // accepting/dismissing empties the array while SwiftUI may
                // still evaluate children for the old identities, and a
                // stale index subscript then traps (seen as a live crash on
                // Return/Escape).
                ForEach(
                    Array(controller.wikilinkCandidates.enumerated()),
                    id: \.element.note.relativePath
                ) { index, candidate in
                    let isSelected = index == controller.selectedWikilinkCandidateIndex
                    Button {
                        accept(candidate)
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(candidate.note.title)
                                .font(.body)
                            if !candidate.note.hasRedundantRootPathCaption {
                                Text(candidate.note.relativePath)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(
                        Color.accentColor.opacity(isSelected ? 0.18 : 0),
                        in: .rect(cornerRadius: 4)
                    )
                    .accessibilityLabel("Link to \(candidate.note.title)")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxHeight: 320)
        .background(.regularMaterial, in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.2)))
        .frame(maxWidth: 320)
        .shadow(radius: 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Wikilink suggestions")
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

#if os(macOS)
/// Measures the popup before placing it, so it can flip above the caret when
/// there is not enough room below and remain inside the editor horizontally.
private struct WikilinkCompletionLayout: Layout {
    let anchorRect: CGRect?

    private let edgeMargin: CGFloat = 12
    private let caretSpacing: CGFloat = 4
    private let maximumWidth: CGFloat = 320

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard let popup = subviews.first else { return }
        let popupWidth = max(0, min(maximumWidth, bounds.width - edgeMargin * 2))
        let naturalPopupSize = popup.sizeThatFits(ProposedViewSize(width: popupWidth, height: nil))
        let anchor = anchorRect ?? CGRect(x: edgeMargin, y: edgeMargin, width: 0, height: 0)

        let minimumX = bounds.minX + edgeMargin
        let maximumX = max(minimumX, bounds.maxX - edgeMargin - naturalPopupSize.width)
        let x = min(max(bounds.minX + anchor.minX, minimumX), maximumX)

        let belowY = bounds.minY + anchor.maxY + caretSpacing
        let aboveBottom = bounds.minY + anchor.minY - caretSpacing
        let belowSpace = max(0, bounds.maxY - edgeMargin - belowY)
        let aboveSpace = max(0, aboveBottom - bounds.minY - edgeMargin)
        let placeBelow = naturalPopupSize.height <= belowSpace
            || (naturalPopupSize.height > aboveSpace && belowSpace >= aboveSpace)
        let availableHeight = placeBelow ? belowSpace : aboveSpace
        let popupHeight = min(naturalPopupSize.height, availableHeight)
        let y = placeBelow ? belowY : aboveBottom - popupHeight

        popup.place(
            at: CGPoint(x: x, y: y),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: naturalPopupSize.width, height: popupHeight)
        )
    }
}
#endif
