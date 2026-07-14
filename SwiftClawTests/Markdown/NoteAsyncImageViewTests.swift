import Testing
@testable import SwiftClaw

#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct NoteAsyncImageViewTests {
    @Test func startingANewRelativePathClearsBothThePriorImageAndFailureState() {
        var state = NoteAsyncImageLoadState()
        #if os(macOS)
        let image = NSImage(size: NSSize(width: 1, height: 1))
        #else
        let image = UIImage()
        #endif

        state.receive(image)
        #expect(state.loadedImage != nil)
        #expect(!state.didFail)

        state.reset()
        #expect(state.loadedImage == nil)
        #expect(!state.didFail)

        state.receive(nil)
        #expect(state.didFail)

        state.reset()
        #expect(state.loadedImage == nil)
        #expect(!state.didFail)
    }

    /// Regression coverage for the review finding that `NoteAsyncImageView`
    /// keyed its `.task(id:)` by `relativePath` alone, so switching between
    /// two different notes that both reference an identically-named image
    /// (e.g. both use `image.png`) left SwiftUI's task-identity unchanged
    /// across the switch — the second note's load never restarted and kept
    /// showing the first note's already-loaded image. `imageLoadScope`
    /// (typically the owning note's path) must be part of that identity, so
    /// the same `relativePath` under a different scope is a different task.
    @Test func taskIdentityChangesWhenTheOwningNoteChangesEvenWithAnIdenticalRelativePath() {
        let noteAImage = NoteAsyncImageView.ImageLoadTaskID(scope: "noteA.md", relativePath: "image.png")
        let noteBImage = NoteAsyncImageView.ImageLoadTaskID(scope: "noteB.md", relativePath: "image.png")

        #expect(noteAImage != noteBImage)
    }

    @Test func taskIdentityIsStableForTheSameNoteAndRelativePath() {
        let first = NoteAsyncImageView.ImageLoadTaskID(scope: "noteA.md", relativePath: "image.png")
        let second = NoteAsyncImageView.ImageLoadTaskID(scope: "noteA.md", relativePath: "image.png")

        #expect(first == second)
    }

    @Test func taskIdentityAlsoChangesForADifferentRelativePathWithinTheSameNote() {
        let first = NoteAsyncImageView.ImageLoadTaskID(scope: "noteA.md", relativePath: "image.png")
        let second = NoteAsyncImageView.ImageLoadTaskID(scope: "noteA.md", relativePath: "other.png")

        #expect(first != second)
    }
}
