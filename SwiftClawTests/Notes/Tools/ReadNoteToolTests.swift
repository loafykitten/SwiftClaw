import Foundation
import Testing
@testable import SwiftClaw

/// Exercises `ReadNoteTool` against injected `Dependencies` stubs, never the
/// live `NotesFeatureModel` singleton — front matter, heading extraction,
/// the truncation cap, and the `notConfigured` gate are all deterministic
/// without a real vault/index.
struct ReadNoteToolTests {
    private func makeTool(content: String) -> ReadNoteTool {
        ReadNoteTool(dependencies: .init(
            isAvailable: { true },
            readNote: { path in
                NoteFileSnapshot(relativePath: path, content: content, sha256: "hash", modifiedAt: Date(timeIntervalSince1970: 0))
            }
        ))
    }

    @Test func wholeNoteReadIncludesFrontMatterVerbatim() async throws {
        let source = "---\ntitle: Hello\n---\n# Body\n\nSome text.\n"
        let tool = makeTool(content: source)

        let result = try await tool.execute(arguments: ["path": .string("Note.md")])

        #expect(result == source)
    }

    @Test func headingArgumentReturnsExactMatchingSectionOnly() async throws {
        let source = """
            # Title

            Intro.

            ## Section One

            First body.

            ## Section Two

            Second body.
            """
        let tool = makeTool(content: source)

        let result = try await tool.execute(arguments: ["path": .string("Note.md"), "heading": .string("Section One")])

        #expect(result == "## Section One\n\nFirst body.\n\n")
        #expect(!result.contains("Section Two"))
    }

    @Test func headingSectionIncludesNestedSubheadingsUntilASameOrShallowerHeading() async throws {
        let source = """
            ## Parent

            Parent body.

            ### Child

            Child body.

            ## Next Sibling

            Sibling body.
            """
        let tool = makeTool(content: source)

        let result = try await tool.execute(arguments: ["path": .string("Note.md"), "heading": .string("Parent")])

        #expect(result.contains("Child body."))
        #expect(!result.contains("Sibling body."))
    }

    /// A `search_notes` citation's `headingPath` (built by `TextChunker`
    /// with a " > " separator, e.g. "Top > Middle > Leaf") must round-trip
    /// straight into `read_note`'s `heading` argument. Includes a duplicate
    /// leaf title ("Leaf") under two different parents to prove the full
    /// path disambiguates them, unlike a bare-leaf match.
    @Test func hierarchicalHeadingPathFromASearchCitationResolvesTheExactDescendantSection() async throws {
        let source = """
            # Top

            Intro.

            ## Middle

            Middle body.

            ### Leaf

            First leaf body.

            ### Other Leaf

            Other leaf body.

            ## Second Middle

            Second middle body.

            ### Leaf

            Second leaf body.
            """
        let tool = makeTool(content: source)

        let result = try await tool.execute(arguments: [
            "path": .string("Note.md"),
            "heading": .string("Top > Second Middle > Leaf"),
        ])

        #expect(result == "### Leaf\n\nSecond leaf body.")
        #expect(!result.contains("First leaf body."))
    }

    /// A heading whose own title literally contains the " > " hierarchy
    /// separator (e.g. copy-pasted from a build log) must resolve by exact
    /// title match, not get misread as a two-level ancestry path ("Build",
    /// "Test") that doesn't exist in the document.
    @Test func literalHeadingContainingTheHierarchyDelimiterResolvesByExactTitleMatch() async throws {
        let source = """
            # Title

            Intro.

            ## Build > Test

            CI body.

            ## Other Section

            Other body.
            """
        let tool = makeTool(content: source)

        let result = try await tool.execute(arguments: ["path": .string("Note.md"), "heading": .string("Build > Test")])

        #expect(result == "## Build > Test\n\nCI body.\n\n")
        #expect(!result.contains("Other body."))
    }

    @Test func unmatchedHeadingReturnsAClearNotFoundMessageListingAvailableHeadings() async throws {
        let source = "# Title\n\n## Real Heading\n\nBody.\n"
        let tool = makeTool(content: source)

        let result = try await tool.execute(arguments: ["path": .string("Note.md"), "heading": .string("Missing Heading")])

        #expect(result.contains("No heading \"Missing Heading\" found"))
        #expect(result.contains("Real Heading"))
    }

    @Test func outputIsTruncatedAtTheCapWithoutSplittingAUnicodeGraphemeCluster() async throws {
        // A flag emoji is a multi-scalar grapheme cluster — truncating by
        // raw Unicode scalar or UTF-16 code unit could split it. Repeat past
        // the cap so truncation must land exactly at that boundary.
        let unit = "🇯🇵"
        let source = String(repeating: unit, count: ReadNoteTool.maxOutputCharacters + 500)
        let tool = makeTool(content: source)

        let result = try await tool.execute(arguments: ["path": .string("Note.md")])

        #expect(result.count <= ReadNoteTool.maxOutputCharacters)
        #expect(result.contains("Truncated"))
        // Every character in the kept prefix must be a whole, valid grapheme cluster.
        let noticeRange = result.range(of: "\n\n[Truncated")
        let kept = noticeRange.map { String(result[result.startIndex..<$0.lowerBound]) } ?? result
        #expect(kept.allSatisfy { $0 == Character(unit) })

        // The notice must claim exactly how many characters were retained,
        // not the nominal cap (the notice itself eats into that cap).
        #expect(result.contains("showing the first \(kept.count) of \(source.count) characters."))
        #expect(kept.count < ReadNoteTool.maxOutputCharacters)
    }

    @Test func executeThrowsMissingArgumentWhenPathIsAbsent() async {
        let tool = makeTool(content: "# Title\n")

        await #expect(throws: ToolError.self) {
            _ = try await tool.execute(arguments: [:])
        }
    }

    /// The gate must be rechecked inside `execute` itself — not only by
    /// `ToolRegistry.availableTools` — so a stale registered instance can't
    /// run once Notes is disabled or the vault/index disappears.
    @Test func executeThrowsNotConfiguredWhenUnavailable() async {
        let tool = ReadNoteTool(dependencies: .init(
            isAvailable: { false },
            readNote: { path in NoteFileSnapshot(relativePath: path, content: "", sha256: "h", modifiedAt: Date(timeIntervalSince1970: 0)) }
        ))

        do {
            _ = try await tool.execute(arguments: ["path": .string("Note.md")])
            Issue.record("expected ToolError.notConfigured")
        } catch ToolError.notConfigured(let toolName, let reason) {
            #expect(toolName == tool.displayName)
            #expect(reason.contains("Notes"))
        } catch {
            Issue.record("expected ToolError.notConfigured, got \(error)")
        }
    }

    /// The model facade throws `ToolError.notConfigured` directly when a
    /// vault reset/switch invalidates an in-flight read (see
    /// `NotesFeatureModel.readNoteForTool`'s generation guard) — `execute`
    /// must let that specific error through rather than flattening it into a
    /// generic `executionFailed`.
    @Test func executePreservesAnExistingNotConfiguredErrorFromTheModelFacadeInsteadOfWrappingIt() async {
        let tool = ReadNoteTool(dependencies: .init(
            isAvailable: { true },
            readNote: { _ in throw ToolError.notConfigured(toolName: "Read Note", reason: "stale generation") }
        ))

        do {
            _ = try await tool.execute(arguments: ["path": .string("Note.md")])
            Issue.record("expected ToolError.notConfigured")
        } catch ToolError.notConfigured(let toolName, let reason) {
            #expect(toolName == "Read Note")
            #expect(reason == "stale generation")
        } catch {
            Issue.record("expected ToolError.notConfigured, got \(error)")
        }
    }

    /// The vault's containment check alone would still serve dotfiles and
    /// non-Markdown files; the tool must refuse them before any read.
    @Test(arguments: [".env", ".git/config", ".obsidian/workspace.json", "folder/.hidden.md", ".git/Note.md", "notes.txt", "../Note.md"])
    func hiddenOrNonMarkdownPathsAreRejectedWithoutReading(path: String) async {
        let readCount = LockedValue(0)
        let tool = ReadNoteTool(dependencies: .init(
            isAvailable: { true },
            readNote: { path in
                readCount.update { $0 += 1 }
                return NoteFileSnapshot(relativePath: path, content: "SECRET=1", sha256: "h", modifiedAt: Date(timeIntervalSince1970: 0))
            }
        ))

        await #expect(throws: ToolError.self) {
            _ = try await tool.execute(arguments: ["path": .string(path)])
        }
        #expect(readCount.value == 0)
    }

    @Test func sharedRegistryOffersReadNoteAutomatically() {
        let tool = ToolRegistry.shared.tool(named: "read_note")
        #expect(tool != nil)
        #expect(tool?.requiresExplicitEnable == false)
    }
}
