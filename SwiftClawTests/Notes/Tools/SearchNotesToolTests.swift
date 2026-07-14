import Foundation
import Testing
@testable import SwiftClaw

/// Exercises `SearchNotesTool` against injected `Dependencies` stubs, never
/// the live `NotesFeatureModel` singleton — citation formatting, limit
/// clamping, and the `notConfigured` gate are all deterministic without a
/// real vault/index.
///
/// `@MainActor`: `Dependencies` closures are `@MainActor @Sendable`, and
/// several tests capture a local `var` from the closure body to assert on
/// afterward — under Swift 6 strict concurrency that mutation must happen on
/// the same isolation as the capturing context, so the suite runs on
/// `@MainActor` rather than each closure hopping isolation independently.
@MainActor
struct SearchNotesToolTests {
    private func makeHit(sourceID: String, headingPath: String, snippet: String) -> SearchHit {
        let document = SearchIndex.Document(
            id: 1, sourceType: "note", sourceID: sourceID, title: "Title",
            uri: "file:///\(sourceID)", contentHash: "hash", updatedAt: Date(timeIntervalSince1970: 0)
        )
        let chunk = SearchIndex.Chunk(
            id: 1, documentID: 1, ordinal: 0, headingPath: headingPath,
            byteStart: 0, byteEnd: snippet.utf8.count, content: snippet
        )
        return SearchHit(document: document, chunk: chunk, headingPath: headingPath, snippet: snippet, score: 1.0)
    }

    @Test func citationIncludesHeadingWhenPresent() async throws {
        let hit = makeHit(sourceID: "folder/Note.md", headingPath: "Section One", snippet: "Some snippet.")
        let tool = SearchNotesTool(dependencies: .init(isAvailable: { true }, search: { _, _ in [hit] }))

        let result = try await tool.execute(arguments: ["query": .string("anything")])

        #expect(result == "[[note: folder/Note.md § Section One]]\nSome snippet.")
    }

    @Test func citationOmitsHeadingSeparatorWhenHeadingPathIsEmpty() async throws {
        let hit = makeHit(sourceID: "Note.md", headingPath: "", snippet: "Snippet.")
        let tool = SearchNotesTool(dependencies: .init(isAvailable: { true }, search: { _, _ in [hit] }))

        let result = try await tool.execute(arguments: ["query": .string("q")])

        #expect(result == "[[note: Note.md]]\nSnippet.")
    }

    @Test func defaultLimitIsPassedWhenArgumentIsAbsent() async throws {
        var capturedLimit: Int?
        let tool = SearchNotesTool(dependencies: .init(isAvailable: { true }, search: { _, limit in
            capturedLimit = limit
            return []
        }))

        _ = try await tool.execute(arguments: ["query": .string("q")])

        #expect(capturedLimit == SearchNotesTool.defaultLimit)
    }

    @Test func customLimitIsClampedToTheDocumentedRange() async throws {
        var capturedLimit: Int?
        let tool = SearchNotesTool(dependencies: .init(isAvailable: { true }, search: { _, limit in
            capturedLimit = limit
            return []
        }))

        _ = try await tool.execute(arguments: ["query": .string("q"), "limit": .number(999)])
        #expect(capturedLimit == SearchNotesTool.maxLimit)

        _ = try await tool.execute(arguments: ["query": .string("q"), "limit": .number(0)])
        #expect(capturedLimit == 1)
    }

    @Test func noHitsReturnsAPlainNotFoundMessage() async throws {
        let tool = SearchNotesTool(dependencies: .init(isAvailable: { true }, search: { _, _ in [] }))

        let result = try await tool.execute(arguments: ["query": .string("nothing")])

        #expect(result == "No notes found matching \"nothing\".")
    }

    @Test func executeThrowsMissingArgumentWhenQueryIsAbsent() async {
        let tool = SearchNotesTool(dependencies: .init(isAvailable: { true }, search: { _, _ in [] }))

        await #expect(throws: ToolError.self) {
            _ = try await tool.execute(arguments: [:])
        }
    }

    /// The gate must be rechecked inside `execute` itself — not only by
    /// `ToolRegistry.availableTools` — so a stale registered instance can't
    /// run once Notes is disabled or the vault/index disappears.
    @Test func executeThrowsNotConfiguredWhenUnavailable() async {
        let tool = SearchNotesTool(dependencies: .init(isAvailable: { false }, search: { _, _ in [] }))

        do {
            _ = try await tool.execute(arguments: ["query": .string("q")])
            Issue.record("expected ToolError.notConfigured")
        } catch ToolError.notConfigured(let toolName, let reason) {
            #expect(toolName == tool.displayName)
            #expect(reason.contains("Notes"))
        } catch {
            Issue.record("expected ToolError.notConfigured, got \(error)")
        }
    }

    /// The model facade throws `ToolError.notConfigured` directly when a
    /// vault reset/switch invalidates an in-flight search (see
    /// `NotesFeatureModel.searchNotesForTool`'s generation guard) — `execute`
    /// must let that specific error through rather than flattening it into a
    /// generic `executionFailed`.
    @Test func executePreservesAnExistingNotConfiguredErrorFromTheModelFacadeInsteadOfWrappingIt() async {
        let tool = SearchNotesTool(dependencies: .init(isAvailable: { true }, search: { _, _ in
            throw ToolError.notConfigured(toolName: "Search Notes", reason: "stale generation")
        }))

        do {
            _ = try await tool.execute(arguments: ["query": .string("q")])
            Issue.record("expected ToolError.notConfigured")
        } catch ToolError.notConfigured(let toolName, let reason) {
            #expect(toolName == "Search Notes")
            #expect(reason == "stale generation")
        } catch {
            Issue.record("expected ToolError.notConfigured, got \(error)")
        }
    }

    @Test func sharedRegistryOffersSearchNotesAutomatically() {
        let tool = ToolRegistry.shared.tool(named: "search_notes")
        #expect(tool != nil)
        #expect(tool?.requiresExplicitEnable == false)
    }
}
