import Foundation
import Testing
@testable import SwiftClaw

/// Byte-for-byte coverage of `FrontMatterBlock`: every assertion here checks
/// that untouched bytes stay untouched, since the whole point of a
/// line-based (not YAML) implementation is to never normalize content it
/// doesn't understand.
struct FrontMatterBlockTests {
    @Test func noFrontMatterWhenDocumentDoesNotOpenWithADelimiter() {
        let source = "# Title\n\nBody text.\n"
        #expect(FrontMatterBlock(source: source) == nil)
    }

    @Test func noFrontMatterWhenTheOpeningFenceIsNeverClosed() {
        let source = "---\ntitle: Draft\nBody without a closing fence.\n"
        #expect(FrontMatterBlock(source: source) == nil)
    }

    @Test func parsesAMinimalBlockAndPreservesTheBodyByteForByte() throws {
        let source = "---\ntitle: Hello\n---\n# Body\n\nSome text.\n"
        let frontMatter = try #require(FrontMatterBlock(source: source))
        #expect(source[frontMatter.range] == "---\ntitle: Hello\n---\n")
        #expect(frontMatter.value(for: "title") == "Hello")
    }

    @Test func unknownKeysAndCommentsArePreservedVerbatim() throws {
        let source = """
        ---
        title: Hello
        # a YAML-style comment
        mystery_key: some value
        ---
        Body
        """
        let frontMatter = try #require(FrontMatterBlock(source: source))
        #expect(frontMatter.value(for: "title") == "Hello")
        #expect(frontMatter.value(for: "mystery_key") == "some value")
        // Replacing a known key must not disturb the comment or the unknown key.
        let updated = frontMatter.settingValue("Updated", for: "title")
        #expect(updated.contains("# a YAML-style comment"))
        #expect(updated.contains("mystery_key: some value"))
        #expect(updated.contains("title: Updated"))
    }

    @Test func aThematicBreakInTheBodyIsNeverMistakenForTheClosingFence() throws {
        let source = """
        ---
        title: Hello
        ---
        Above the break.

        ---

        Below the break.
        """
        let frontMatter = try #require(FrontMatterBlock(source: source))
        // The block closes at the *first* bare "---" after the opener.
        #expect(source[frontMatter.range] == "---\ntitle: Hello\n---\n")
        let updated = frontMatter.settingValue("Changed", for: "title")
        // The body's thematic break survives completely untouched.
        #expect(updated.contains("Above the break.\n\n---\n\nBelow the break."))
    }

    @Test func settingValueReplacesOnlyThatKeysLine() throws {
        let source = "---\ntitle: Old\ntags: [a, b]\n---\nBody\n"
        let frontMatter = try #require(FrontMatterBlock(source: source))
        let updated = frontMatter.settingValue("New", for: "title")
        #expect(updated == "---\ntitle: New\ntags: [a, b]\n---\nBody\n")
    }

    @Test func settingValueAppendsAMissingKeyJustBeforeTheClosingFence() throws {
        let source = "---\ntitle: Hello\n---\nBody\n"
        let frontMatter = try #require(FrontMatterBlock(source: source))
        let updated = frontMatter.settingValue("2026-07-13", for: "date")
        #expect(updated == "---\ntitle: Hello\ndate: 2026-07-13\n---\nBody\n")
    }

    @Test func crlfLineEndingsArePreservedByBothReadsAndWrites() throws {
        let source = "---\r\ntitle: Hello\r\n---\r\nBody\r\n"
        let frontMatter = try #require(FrontMatterBlock(source: source))
        #expect(frontMatter.value(for: "title") == "Hello")
        let updated = frontMatter.settingValue("New", for: "title")
        #expect(updated == "---\r\ntitle: New\r\n---\r\nBody\r\n")

        let appended = frontMatter.settingValue("x", for: "extra")
        #expect(appended == "---\r\ntitle: Hello\r\nextra: x\r\n---\r\nBody\r\n")
    }

    @Test func readsInlineBracketedTags() throws {
        let source = "---\ntags: [work, ideas, \"quoted tag\"]\n---\nBody\n"
        let frontMatter = try #require(FrontMatterBlock(source: source))
        #expect(frontMatter.tags == ["work", "ideas", "quoted tag"])
    }

    @Test func readsInlineCommaSeparatedTagsWithoutBrackets() throws {
        let source = "---\ntags: work, ideas\n---\nBody\n"
        let frontMatter = try #require(FrontMatterBlock(source: source))
        #expect(frontMatter.tags == ["work", "ideas"])
    }

    @Test func readsDashListFormTags() throws {
        let source = """
        ---
        title: Hello
        tags:
          - work
          - ideas
        ---
        Body
        """
        let frontMatter = try #require(FrontMatterBlock(source: source))
        #expect(frontMatter.tags == ["work", "ideas"])
    }

    @Test func noTagsKeyProducesAnEmptyArray() throws {
        let source = "---\ntitle: Hello\n---\nBody\n"
        let frontMatter = try #require(FrontMatterBlock(source: source))
        #expect(frontMatter.tags.isEmpty)
    }
}
