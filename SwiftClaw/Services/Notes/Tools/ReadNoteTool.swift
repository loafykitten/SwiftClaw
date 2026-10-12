import Foundation

/// Verbatim, capped reads from the user's notes vault. Always offered when
/// Notes is enabled and a vault/index exist — reads are always allowed,
/// matching `WebSearchTool`'s posture — and vanishes from every chat the
/// moment Notes is disabled via `ToolRegistry.availableTools`.
struct ReadNoteTool: Tool {
    /// Character budget for the returned text, chosen to keep a single tool
    /// result compact in the model's context; the truncation notice itself
    /// counts against this budget, so the total output never exceeds it.
    static let maxOutputCharacters = 8_000

    /// Seam so gating/reads can be exercised with stubs in tests instead of
    /// the live `NotesFeatureModel` singleton. The closures are `@MainActor`
    /// because the model they wrap is; building `.live`'s closure values
    /// here doesn't run any MainActor code, only *calling* them does.
    struct Dependencies: Sendable {
        var isAvailable: @MainActor @Sendable () -> Bool
        var readNote: @MainActor @Sendable (_ relativePath: String) async throws -> NoteFileSnapshot

        static let live = Dependencies(
            isAvailable: { NotesFeatureModel.shared.isAvailableForReadTools },
            readNote: { path in try await NotesFeatureModel.shared.readNoteForTool(relativePath: path) }
        )
    }

    let dependencies: Dependencies

    init(dependencies: Dependencies = .live) {
        self.dependencies = dependencies
    }

    let name = "read_note"
    let displayName = "Read Note"
    let description = """
        Read a note's exact source content by its vault-relative path (as \
        cited by search_notes, e.g. "folder/Note.md"). Returns the verbatim \
        Markdown, including front matter, when reading the whole note. Pass \
        heading to return only that heading's exact section instead. Output \
        is length-capped; long notes are truncated with a clear notice.
        """
    let systemImage = "note.text"

    let parameters = [
        ToolParameter(
            name: "path",
            type: .string,
            description: "Vault-relative Markdown path, e.g. \"folder/Note.md\".",
            isRequired: true
        ),
        ToolParameter(
            name: "heading",
            type: .string,
            description: "Optional heading text to return only that section's exact source."
        ),
    ]

    /// `MainActor.assumeIsolated` is safe here: both call sites that read
    /// `Tool.isConfigured` (`ChatCompletionService`, `ToolsView`) are
    /// themselves `@MainActor`.
    var isConfigured: Bool {
        MainActor.assumeIsolated {
            dependencies.isAvailable()
        }
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        guard await dependencies.isAvailable() else {
            throw ToolError.notConfigured(
                toolName: displayName,
                reason: "Notes is disabled, or no vault/index is configured."
            )
        }

        guard let path = arguments["path"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !path.isEmpty else {
            throw ToolError.missingArgument("path")
        }
        // The vault's containment checks alone would still serve dotfiles
        // (`.env`, `.git/config`) and non-Markdown files; the model may only
        // read what enumeration exposes.
        guard VaultIgnoreRules.isVisibleMarkdownNotePath(path) else {
            throw ToolError.invalidArguments("path must be a visible vault-relative Markdown note")
        }

        let rawHeading = arguments["heading"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedHeading = (rawHeading?.isEmpty ?? true) ? nil : rawHeading

        let snapshot: NoteFileSnapshot
        do {
            snapshot = try await dependencies.readNote(path)
        } catch let toolError as ToolError {
            // The model facade throws `ToolError.notConfigured` directly when
            // a vault reset/switch invalidates an in-flight read — that must
            // reach the caller as-is, not get flattened into a generic
            // `executionFailed`.
            throw toolError
        } catch {
            throw ToolError.executionFailed((error as? LocalizedError)?.errorDescription ?? String(describing: error))
        }

        guard let requestedHeading else {
            return Self.capped(snapshot.content)
        }

        guard let section = NoteHeadingSectionExtractor.section(matching: requestedHeading, in: snapshot.content) else {
            let available = MarkdownDocument(source: snapshot.content).headings.map(\.text)
            guard !available.isEmpty else {
                return "No heading \"\(requestedHeading)\" found in \(path) (the note has no headings)."
            }
            return "No heading \"\(requestedHeading)\" found in \(path). Available headings: \(available.joined(separator: ", "))."
        }

        return Self.capped(section)
    }

    /// Caps `text` to `maxOutputCharacters`, appending an unambiguous
    /// truncation notice whose length is itself subtracted from the budget
    /// so the total never exceeds the cap. `.prefix` operates on
    /// `Character`s, so this never splits a Unicode grapheme cluster.
    private static func capped(_ text: String) -> String {
        guard text.count > maxOutputCharacters else { return text }
        // The notice names the retained-character count, but the notice's
        // own length (and thus the budget it leaves for retained text)
        // depends on how many digits that count has — self-referential, so
        // resolve it to a fixpoint rather than assuming one pass lands
        // exactly on the true retained count.
        var budget = maxOutputCharacters
        var notice = ""
        for _ in 0..<3 {
            let candidateNotice = "\n\n[Truncated: showing the first \(budget) of \(text.count) characters.]"
            let candidateBudget = max(maxOutputCharacters - candidateNotice.count, 0)
            guard candidateBudget != budget || candidateNotice != notice else { break }
            budget = candidateBudget
            notice = candidateNotice
        }
        return String(text.prefix(budget)) + notice
    }
}

/// Extracts a single heading's exact source section (its heading line
/// through, but not including, the next heading of the same or shallower
/// level, or the end of the document) — the section a `[[note: path §
/// Heading]]` citation refers to.
///
/// Accepts either a bare leaf heading ("Leaf") or a full hierarchical path
/// ("Top > Middle > Leaf") using the same " > " separator `TextChunker`
/// joins with when it builds `SearchHit.headingPath` — so a citation copied
/// verbatim out of `search_notes` resolves here without the caller having to
/// strip it down to a leaf. A bare leaf still matches by title alone
/// (case/whitespace-insensitive, first match wins on duplicate titles); a
/// full path disambiguates duplicate leaf titles that live under different
/// parents by matching the whole ancestry chain.
///
/// A literal heading whose own title contains " > " (e.g. "Build > Test")
/// is tried first as an exact whole-string title match, before the text is
/// ever split into hierarchy segments — otherwise such a heading could never
/// be reached, since it would always be misread as a two-level ancestry path.
private nonisolated enum NoteHeadingSectionExtractor {
    static func section(matching headingText: String, in source: String) -> String? {
        let document = MarkdownDocument(source: source)
        let headings = document.headings
        let target = normalize(headingText)

        if let literalIndex = headings.firstIndex(where: { normalize($0.text) == target }) {
            return section(at: literalIndex, headings: headings, source: source)
        }

        let segments = splitPath(headingText)
        guard segments.count > 1 else { return nil }
        let targetPath = segments.map(normalize)
        let ancestryPaths = ancestryPaths(for: headings)
        guard let matchIndex = ancestryPaths.firstIndex(where: { $0.map(normalize) == targetPath }) else { return nil }
        return section(at: matchIndex, headings: headings, source: source)
    }

    private static func section(at matchIndex: Int, headings: [MarkdownDocument.HeadingEntry], source: String) -> String {
        let matched = headings[matchIndex]
        let start = matched.range.lowerBound
        let end = headings[(matchIndex + 1)...]
            .first { $0.level <= matched.level }?
            .range.lowerBound ?? source.endIndex
        return String(source[start..<end])
    }

    /// Each heading's full ancestry chain, index-aligned with `headings`.
    /// Mirrors `TextChunker.chunk`'s `headingStack` bookkeeping exactly
    /// (popping while `stack.count >= heading.level`, not just comparing to
    /// the last entry's level) so a path built here matches the
    /// `headingPath` `TextChunker` produced for the same document.
    private static func ancestryPaths(for headings: [MarkdownDocument.HeadingEntry]) -> [[String]] {
        var stack: [String] = []
        return headings.map { heading in
            while stack.count >= heading.level {
                stack.removeLast()
            }
            stack.append(heading.text)
            return stack
        }
    }

    private static func splitPath(_ headingText: String) -> [String] {
        headingText.components(separatedBy: " > ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
