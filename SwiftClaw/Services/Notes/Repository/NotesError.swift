import Foundation

/// User-facing errors surfaced by `NotesRepository`. Every case renders a
/// plain sentence suitable for a UI banner — no vault internals leak through.
enum NotesError: LocalizedError, Equatable {
    /// A `save` lost its hash-guard race against an external editor. The
    /// caller's content was never discarded — it landed at `copyPath`
    /// (a "Name (conflict …).md" sibling) and the original file on disk is
    /// untouched.
    case externalConflict(copyPath: String)
    /// `reload` enumerated the vault but one or more notes couldn't be read
    /// (unreadable encoding, externally deleted mid-scan, …) and were
    /// skipped rather than failing the whole catalog load.
    case partialLoadFailure(count: Int)
    /// `create` exhausted its deterministic suffix search without landing on
    /// a filename nothing else claimed.
    case createFailed(title: String)
    /// `createExactPath` lost the exact-path collision race: something
    /// already exists at that path. Nothing was written — no overwrite, no
    /// conflict-copy sibling — see `NotesVault.createExclusive`.
    case pathAlreadyExists(String)
    /// An exact-path create was asked to target a path the vault would not
    /// expose as a Markdown note (for example a hidden or non-Markdown path).
    case invalidNotePath(String)
    /// Wraps an error from `NotesVault`/`NoteRevisionStore` (or anything
    /// else) that doesn't need its own case — its message is reused as-is.
    case underlying(String)

    var errorDescription: String? {
        switch self {
        case .externalConflict(let copyPath):
            "This note changed outside the app. Your edits were saved to \"\(copyPath)\" — review and merge manually."
        case .partialLoadFailure(let count):
            count == 1
                ? "1 note couldn't be read and was skipped."
                : "\(count) notes couldn't be read and were skipped."
        case .createFailed(let title):
            "Couldn't create a new note for \"\(title)\" — no available filename was found."
        case .pathAlreadyExists(let path):
            "\"\(path)\" already exists."
        case .invalidNotePath(let path):
            "\"\(path)\" isn't a visible Markdown note path."
        case .underlying(let message):
            message
        }
    }

    /// Maps any error into a `NotesError`, reusing an existing
    /// `NotesError`/`LocalizedError` message where available rather than
    /// falling back to a generic description.
    static func from(_ error: Error) -> NotesError {
        if let notesError = error as? NotesError {
            return notesError
        }
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return .underlying(description)
        }
        return .underlying(error.localizedDescription)
    }
}
