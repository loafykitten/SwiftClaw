import Foundation

/// Which vault entries `NotesVault` should pretend don't exist. Applies
/// uniformly to enumeration, reconciliation, and the FSEvents monitor's
/// watch set — nothing hidden is ever observed, indexed, or rewritten.
nonisolated enum VaultIgnoreRules {
    /// The suffix `AtomicFileWriter` uses for its in-place temp files
    /// (`.<uuid>.tmp`) — already dot-prefixed, listed for clarity at call
    /// sites that only check the suffix.
    static let temporaryArtifactSuffix = ".tmp"

    /// True for any dotfile/dot-directory name, including `.obsidian` and
    /// `.git` — vault contents this app must treat as opaque.
    static func isHidden(name: String) -> Bool {
        name.hasPrefix(".")
    }

    /// A directory this app should never descend into: any dotfile/dot-
    /// directory (`.obsidian`, `.git`, `.trash`, …).
    static func isIgnoredDirectory(name: String) -> Bool {
        isHidden(name: name)
    }

    /// A file this app should never treat as vault content: hidden files,
    /// this app's own temp write artifacts, and anything that isn't a
    /// Markdown note.
    static func isIgnoredFile(name: String) -> Bool {
        if isHidden(name: name) { return true }
        if name.hasSuffix(temporaryArtifactSuffix) { return true }
        return name.lowercased().hasSuffix(".md") == false
    }
}
