#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import SwiftClaw

/// Integration coverage for the wikilink popup's keyboard path through the
/// REAL AppKit wiring — `NoteEditorView.makeNSView`'s `NSTextView`, its
/// delegate, and the `applyReplacement` closure — not just the controller in
/// isolation (`NoteEditorControllerTests` covers that). AppKit consults
/// `textView(_:doCommandBy:)` from `doCommand(by:)`, so driving that entry
/// point reproduces what Down/Return/Escape key events do while the popup is
/// open.
@Suite(.serialized)
@MainActor
struct NoteEditorViewKeyboardTests {
    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private struct HostedEditor {
        let editor: NoteEditorController
        let textView: NSTextView
        let window: NSWindow
        let vaultRoot: URL
    }

    /// Hosts the editor the way `NotesView` composes it — including the
    /// completion popup overlay — so tests exercise the popup's effect on
    /// the responder chain, not just the bare text view.
    private func makeHostedEditor() throws -> HostedEditor {
        let vaultRoot = try makeTempDirectory()
        let revisionsDirectory = try makeTempDirectory()
        let repository = NotesRepository(
            vault: NotesVault(root: vaultRoot),
            revisionStore: NoteRevisionStore(directory: revisionsDirectory)
        )
        let editor = NoteEditorController(repository: repository)
        editor.candidateNotes = [
            NoteSummary(relativePath: "Daily Review.md", title: "Daily Review", sha256: "a", modifiedAt: .now),
            NoteSummary(relativePath: "Reading Sample.md", title: "Reading Sample", sha256: "b", modifiedAt: .now)
        ]

        let hosting = NSHostingView(
            rootView: NoteEditorView(controller: editor)
                .overlay(alignment: .topLeading) {
                    WikilinkCompletionOverlay(controller: editor)
                }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        // Titled windows default to releasing themselves on close, which
        // double-releases under ARC when the test also holds the reference.
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        hosting.layoutSubtreeIfNeeded()

        let textView = try #require(findTextView(in: hosting))
        window.makeFirstResponder(textView)
        return HostedEditor(editor: editor, textView: textView, window: window, vaultRoot: vaultRoot)
    }

    /// Lets SwiftUI commit pending view updates (popup appearance/removal)
    /// the way the live app would between user keystrokes.
    private func pumpRunLoop(seconds: TimeInterval = 0.2) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    private func findTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView { return textView }
        for subview in view.subviews {
            if let found = findTextView(in: subview) { return found }
        }
        return nil
    }

    @Test func typingATriggerShowsCandidatesAndAnchorsThePopup() throws {
        let hosted = try makeHostedEditor()
        let editor = hosted.editor
        let textView = hosted.textView
        defer {
            hosted.window.close()
            try? FileManager.default.removeItem(at: hosted.vaultRoot)
        }

        textView.insertText("[[Da", replacementRange: NSRange(location: 0, length: 0))

        #expect(editor.wikilinkCandidates.map(\.note.title) == ["Daily Review", "Reading Sample"])
        #expect(editor.selectedWikilinkCandidateIndex == 0)
        // The caret-anchored popup regressed to the top-left fallback when
        // this was nil despite an active trigger.
        #expect(editor.wikilinkAnchorRect != nil)
    }

    @Test func downArrowThenReturnInsertsTheSecondCandidate() throws {
        let hosted = try makeHostedEditor()
        let editor = hosted.editor
        let textView = hosted.textView
        defer {
            hosted.window.close()
            try? FileManager.default.removeItem(at: hosted.vaultRoot)
        }

        textView.insertText("[[Da", replacementRange: NSRange(location: 0, length: 0))
        #expect(editor.wikilinkCandidates.count == 2)

        textView.doCommand(by: #selector(NSResponder.moveDown(_:)))
        #expect(editor.selectedWikilinkCandidateIndex == 1)

        textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(textView.string == "[[Reading Sample]]")
        #expect(editor.wikilinkCandidates.isEmpty)
        #expect(editor.wikilinkTrigger == nil)
    }

    /// The nil-anchor fallback pins the popup to the editor's top-leading
    /// corner (~12pt), which is indistinguishable from a correct anchor when
    /// the caret sits on line 1. Typing at the end of a long document makes a
    /// conversion bug (nil rect, sign error, wrong coordinate space) show up
    /// as an anchor far from the caret line, so assert the anchor lands deep
    /// in the view — near the caret — with the window placed at a realistic
    /// on-screen position.
    @Test func anchorTracksTheCaretLineDeepInTheDocument() throws {
        let hosted = try makeHostedEditor()
        let editor = hosted.editor
        let textView = hosted.textView
        defer {
            hosted.window.close()
            try? FileManager.default.removeItem(at: hosted.vaultRoot)
        }
        hosted.window.setFrameOrigin(NSPoint(x: 280, y: 220))
        hosted.window.orderFront(nil)
        defer { hosted.window.orderOut(nil) }

        let filler = Array(repeating: "line of text", count: 30).joined(separator: "\n")
        textView.insertText(filler + "\n", replacementRange: NSRange(location: 0, length: 0))
        textView.insertText("[[Da", replacementRange: NSRange(location: (filler as NSString).length + 1, length: 0))
        #expect(editor.wikilinkCandidates.count == 2)

        let anchor = try #require(editor.wikilinkAnchorRect)
        let caretScreenRect = textView.firstRect(
            forCharacterRange: textView.selectedRange(), actualRange: nil
        )
        let lineHeight = caretScreenRect.height
        // 31 lines above the caret — a correct anchor must sit far below the
        // top-leading fallback, but still inside the scroll view.
        #expect(anchor.minY > lineHeight * 5, "anchor \(anchor) is pinned near the top — fallback position")
        let scrollHeight = try #require(textView.enclosingScrollView?.bounds.height)
        #expect(anchor.maxY <= scrollHeight, "anchor \(anchor) lies outside the scroll view (height \(scrollHeight))")
    }

    /// Live-app regression seen in GUI verification: once the popup rendered,
    /// keyboard focus left the text view ("AX focus had moved to the window"),
    /// so Down/Return went nowhere. The popup must never join the responder
    /// chain — the text view keeps focus for the popup's whole lifetime.
    @Test func popupAppearanceDoesNotStealFirstResponderFromTheTextView() throws {
        let hosted = try makeHostedEditor()
        let editor = hosted.editor
        let textView = hosted.textView
        defer {
            hosted.window.close()
            try? FileManager.default.removeItem(at: hosted.vaultRoot)
        }

        textView.insertText("[[Da", replacementRange: NSRange(location: 0, length: 0))
        #expect(editor.wikilinkCandidates.count == 2)
        pumpRunLoop()

        let focused = hosted.window.firstResponder
        #expect(
            focused === textView,
            "popup rendering moved first responder to \(String(describing: focused))"
        )

        textView.doCommand(by: #selector(NSResponder.moveDown(_:)))
        pumpRunLoop()
        #expect(editor.selectedWikilinkCandidateIndex == 1)
        #expect(hosted.window.firstResponder === textView)

        textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        pumpRunLoop()
        #expect(textView.string == "[[Reading Sample]]")
        #expect(hosted.window.firstResponder === textView)
    }

    @Test func escapeDismissesThePopupWithoutChangingText() throws {
        let hosted = try makeHostedEditor()
        let editor = hosted.editor
        let textView = hosted.textView
        defer {
            hosted.window.close()
            try? FileManager.default.removeItem(at: hosted.vaultRoot)
        }

        textView.insertText("[[Da", replacementRange: NSRange(location: 0, length: 0))
        #expect(!editor.wikilinkCandidates.isEmpty)

        textView.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(editor.wikilinkCandidates.isEmpty)
        #expect(textView.string == "[[Da")
    }
}
#endif
