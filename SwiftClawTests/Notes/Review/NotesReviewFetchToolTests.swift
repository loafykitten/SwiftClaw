import Foundation
@testable import SwiftClaw
import Testing

@MainActor
struct NotesReviewFetchToolTests {
    @Test func digestIncludesEveryDimensionAndRegistersEphemeralIDs() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let source = NotesReviewSourceStub(now: now)
        let collector = NotesReviewFindingCollector()
        let fixture = try UserDefaultsFixture(); defer { fixture.cleanup() }
        fixture.defaults.set("Daily", forKey: SettingsKeys.notesDailyNoteFolder)
        let tool = NotesReviewFetchTool(dataSource: source, collector: collector, userDefaults: fixture.defaults, now: { now })

        let output = try await tool.execute(arguments: [:])
        #expect(output.contains("Unchecked task")); #expect(output.contains("Buy milk"))
        #expect(output.contains("Conflict copy")); #expect(output.contains("Broken link"))
        #expect(output.contains("Recent note")); #expect(output.contains("Index health"))
        #expect(collector.findings.count == 6)
        #expect(try output.contains(#require(collector.findings.keys.first?.uuidString)))
    }

    @Test func everyDimensionIsBoundedAndTaskTextIsTruncated() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let source = NotesReviewSourceStub(now: now, count: 30)
        let collector = NotesReviewFindingCollector()
        let tool = NotesReviewFetchTool(dataSource: source, collector: collector, now: { now })
        _ = try await tool.execute(arguments: ["limit_per_section": .number(999)])
        let grouped = Dictionary(grouping: collector.findings.values, by: \.kind)
        #expect(grouped.values.allSatisfy { $0.count <= NotesReviewFetchTool.maximumPerDimension })
        #expect(collector.findings.values.allSatisfy { $0.subject.count <= NotesReviewFetchTool.taskExcerptLimit })
    }

    @Test func unavailableSourceFailsWithoutReading() async throws {
        let source = NotesReviewSourceStub(now: .now); source.available = false
        let tool = NotesReviewFetchTool(dataSource: source, collector: NotesReviewFindingCollector())
        await #expect(throws: ToolError.self) { _ = try await tool.execute(arguments: [:]) }
        #expect(source.readCount == 0)
    }

    @Test func vaultRootDailyFolderReadsOnlyDateNamedRootNotes() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let source = NotesReviewSourceStub(now: now)
        source.suppliedNotes = [
            .init(relativePath: "2026-07-15.md", title: "Daily", sha256: "d", modifiedAt: now),
            .init(relativePath: "Project.md", title: "Project", sha256: "p", modifiedAt: now),
            .init(relativePath: "Archive/2026-07-14.md", title: "Nested", sha256: "n", modifiedAt: now),
        ]
        source.contents = [
            "2026-07-15.md": "- [ ] Daily root task",
            "Project.md": "- [ ] Project task",
            "Archive/2026-07-14.md": "- [ ] Nested task",
        ]
        let fixture = try UserDefaultsFixture(); defer { fixture.cleanup() }
        fixture.defaults.set("", forKey: SettingsKeys.notesDailyNoteFolder)
        let tool = NotesReviewFetchTool(
            dataSource: source,
            collector: NotesReviewFindingCollector(),
            userDefaults: fixture.defaults,
            now: { now }
        )

        let output = try await tool.execute(arguments: [:])
        #expect(output.contains("Daily root task"))
        #expect(!output.contains("Project task"))
        #expect(!output.contains("Nested task"))
        #expect(source.readPaths == ["2026-07-15.md"])
    }
}

@MainActor
final class NotesReviewSourceStub: NotesReviewDataSource, @unchecked Sendable {
    var available = true
    var readCount = 0
    var readPaths: [String] = []
    var suppliedNotes: [NoteSummary]?
    var contents: [String: String] = [:]
    private let now: Date
    private let count: Int
    init(now: Date, count: Int = 1) {
        self.now = now; self.count = count
    }

    func prepare() async {}
    var isAvailable: Bool {
        available
    }

    func notes() -> [NoteSummary] {
        if let suppliedNotes {
            return suppliedNotes
        }
        var notes: [NoteSummary] = []
        for index in 0 ..< count {
            let day = String(format: "%02d", locale: Locale(identifier: "en_US_POSIX"), index + 1)
            notes.append(.init(relativePath: "Daily/2026-07-\(day).md", title: "Daily \(index)", sha256: "d\(index)", modifiedAt: now))
            notes.append(.init(relativePath: "Note \(index) (conflict 2026-07-13 143022).md", title: "Conflict \(index)", sha256: "c\(index)", modifiedAt: now))
            notes.append(.init(relativePath: "Recent \(index).md", title: "Recent \(index)", sha256: "r\(index)", modifiedAt: now))
        }
        return notes
    }

    func read(relativePath: String) async throws -> NoteFileSnapshot {
        readCount += 1
        readPaths.append(relativePath)
        return .init(
            relativePath: relativePath,
            content: contents[relativePath] ?? "- [ ] Buy milk " + String(repeating: "x", count: 300),
            sha256: "x",
            modifiedAt: now
        )
    }

    func brokenLinks() async -> [ResolvedLink] {
        (0 ..< count).map { .init(sourcePath: "Source \($0).md", kind: .link, pagePath: "Missing \($0)", heading: nil, alias: nil, resolvedPath: nil) }
    }

    func healthSummary() async -> NotesHealthSummary? {
        .init(brokenLinkCount: count, conflictCopyCount: count, ftsAvailable: false, embeddingAvailable: true, lastIndexSuccessAt: nil, lastIndexFailedPaths: [], indexError: nil)
    }
}
