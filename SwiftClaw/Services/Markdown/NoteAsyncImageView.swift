import SwiftUI

/// Loads a relative image for reading-mode rendering strictly through the
/// caller-supplied `loadImage` closure — never `FileManager` directly. The
/// closure is expected to resolve `relativePath` through whatever
/// vault/repository abstraction the caller owns, so this view stays free of
/// any notion of "vault" or file access.
struct NoteAsyncImageView: View {
    let relativePath: String
    let altText: String
    /// Identifies which note's rendering this image belongs to (its
    /// relative path, typically). Folded into the `.task(id:)` below
    /// alongside `relativePath` so that switching from one note to another
    /// that happens to reference the same `relativePath` (e.g. both use
    /// `image.png`) always restarts the load — without this, SwiftUI sees
    /// an unchanged task id across the note switch and keeps showing the
    /// previous note's already-loaded image.
    let imageLoadScope: String
    let loadImage: ((String) async -> PlatformImage?)?

    @State private var loadState = NoteAsyncImageLoadState()

    /// Not `private` so `NoteAsyncImageViewTests` can verify the identity
    /// behavior directly (that scope is load-bearing, not just
    /// `relativePath`) without depending on SwiftUI view-tree introspection.
    struct ImageLoadTaskID: Hashable {
        let scope: String
        let relativePath: String
    }

    var body: some View {
        Group {
            if let loadedImage = loadState.loadedImage {
                #if os(macOS)
                Image(nsImage: loadedImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                #else
                Image(uiImage: loadedImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                #endif
            } else if loadState.didFail {
                Label(altText.isEmpty ? relativePath : altText, systemImage: "photo.badge.exclamationmark")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 40)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(altText.isEmpty ? relativePath : altText)
        .task(id: ImageLoadTaskID(scope: imageLoadScope, relativePath: relativePath)) {
            // Reset before the first `await` below: `.task(id:)` restarts
            // this closure whenever the scope or path changes, but the
            // previous result's `loadedImage`/`didFail` otherwise persists
            // on screen (or gets treated as this load's result) until the
            // new load resolves — briefly showing a stale image or error for
            // the wrong note/path.
            loadState.reset()
            guard let loadImage else {
                loadState.receive(nil)
                return
            }
            let image = await loadImage(relativePath)
            guard !Task.isCancelled else { return }
            loadState.receive(image)
        }
    }
}

/// Mutable task state kept separate from the SwiftUI view so the reset that
/// runs when `.task(id:)` changes can be verified without a view-inspection
/// dependency. A new path must start as a loading state, never by retaining
/// a prior image or failure label while its own load is pending.
struct NoteAsyncImageLoadState {
    private(set) var loadedImage: PlatformImage?
    private(set) var didFail = false

    mutating func reset() {
        loadedImage = nil
        didFail = false
    }

    mutating func receive(_ image: PlatformImage?) {
        if let image {
            loadedImage = image
            didFail = false
        } else {
            loadedImage = nil
            didFail = true
        }
    }
}
