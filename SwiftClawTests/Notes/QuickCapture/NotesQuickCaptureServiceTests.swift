import Foundation
@testable import SwiftClaw
import Testing

@Suite(.serialized)
@MainActor
struct NotesQuickCaptureServiceTests {
    private struct Fixture {
        let repository: NotesRepository
        let vault: NotesVault
        let root: URL
        let revisions: URL
        let defaults: UserDefaultsFixture
        let service: NotesQuickCaptureService
        let now: Date

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: revisions)
            defaults.cleanup()
        }
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let revisions = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: revisions, withIntermediateDirectories: true)
        let defaults = try UserDefaultsFixture()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 7, day: 15, hour: 13, minute: 4))!
        let vault = NotesVault(root: root)
        let repository = NotesRepository(vault: vault, revisionStore: NoteRevisionStore(directory: revisions))
        let stats = NotesCaptureStatsStore(userDefaults: defaults.defaults, calendar: calendar)
        let service = NotesQuickCaptureService(repository: repository, statsStore: stats, calendar: calendar, now: { now })
        return Fixture(
            repository: repository, vault: vault, root: root, revisions: revisions,
            defaults: defaults, service: service, now: now
        )
    }

    @Test func createsNewDailyNoteWithLockedTemplateAndTrimmedText() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let result = try await fixture.service.captureDaily("  buy milk  \n", folder: "Daily Notes")
        let snapshot = try await fixture.repository.read(relativePath: result.path)

        #expect(result == .init(path: "Daily Notes/2026-07-15.md", destination: .dailyNote))
        #expect(snapshot.content == "# 2026-07-15\n\n- 13:04 buy milk")
        #expect(fixture.service.capturedTodayCount(now: fixture.now) == 1)
    }

    @Test func appendsToExistingDailyNoteWithoutRewritingItsBytes() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.repository.createExactPath(
            relativePath: "Daily Notes/2026-07-15.md",
            content: "custom heading\nkept byte-for-byte"
        )

        _ = try await fixture.service.captureDaily(" next ", folder: "Daily Notes")
        let snapshot = try await fixture.repository.read(relativePath: "Daily Notes/2026-07-15.md")

        #expect(snapshot.content == "custom heading\nkept byte-for-byte\n- 13:04 next")
    }

    @Test func staleCatalogCreateCollisionRetriesAsHashGuardedAppend() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.vault.write(
            relativePath: "Daily Notes/2026-07-15.md",
            content: "external\n",
            expectedHash: nil
        )
        #expect(fixture.repository.notes.isEmpty)

        _ = try await fixture.service.captureDaily("captured", folder: "Daily Notes")
        let snapshot = try await fixture.repository.read(relativePath: "Daily Notes/2026-07-15.md")

        #expect(snapshot.content == "external\n- 13:04 captured")
    }

    @Test func emptyInputDoesNotWriteOrIncrementStats() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        await #expect(throws: NotesQuickCaptureService.CaptureError.emptyText) {
            _ = try await fixture.service.captureDaily(" \n\t ", folder: "Daily Notes")
        }
        #expect(fixture.repository.notes.isEmpty)
        #expect(fixture.service.capturedTodayCount(now: fixture.now) == 0)
    }

    @Test func standaloneUsesSanitizedFirstLineAndCollisionSafeCreation() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let first = try await fixture.service.captureStandalone("  Project/Idea\nDetails  ")
        let second = try await fixture.service.captureStandalone("Project/Idea\nDifferent")

        #expect(first.path == "ProjectIdea.md")
        #expect(second.path == "ProjectIdea 2.md")
        #expect(try await fixture.repository.read(relativePath: first.path).content == "Project/Idea\nDetails")
        #expect(try await fixture.repository.read(relativePath: second.path).content == "Project/Idea\nDifferent")
        #expect(fixture.service.capturedTodayCount(now: fixture.now) == 2)
    }

    @Test func failedSaveDoesNotIncrementStats() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try FileManager.default.removeItem(at: fixture.revisions)
        try Data("not a directory".utf8).write(to: fixture.revisions)

        await #expect(throws: NotesError.self) {
            _ = try await fixture.service.captureStandalone("Will fail to save")
        }
        #expect(fixture.service.capturedTodayCount(now: fixture.now) == 0)
    }

    @Test func capturesInjectedNowOncePerOperation() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        var nowCallCount = 0
        let service = NotesQuickCaptureService(
            repository: fixture.repository,
            statsStore: NotesCaptureStatsStore(userDefaults: fixture.defaults.defaults),
            now: {
                nowCallCount += 1
                return fixture.now
            }
        )

        _ = try await service.captureStandalone("One timestamp")

        #expect(nowCallCount == 1)
    }
}
