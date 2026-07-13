import Foundation
import Testing
@testable import SwiftClaw

/// Serialized: several tests assert on `NotificationCenter.default` posts of
/// `.notesStoreDidChange`, a global/unscoped signal (matches
/// `ReminderRepository`'s `object: nil` convention) that would otherwise
/// cross-contaminate between concurrently-running tests in this suite.
@Suite(.serialized)
@MainActor
struct NotesRepositoryTests {
    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeRepository() throws -> (repository: NotesRepository, vaultRoot: URL, revisionsDirectory: URL) {
        let vaultRoot = try makeTempDirectory()
        let revisionsDirectory = try makeTempDirectory()
        let repository = NotesRepository(
            vault: NotesVault(root: vaultRoot),
            revisionStore: NoteRevisionStore(directory: revisionsDirectory)
        )
        return (repository, vaultRoot, revisionsDirectory)
    }

    // MARK: - Reload / bootstrap

    @Test func reloadBuildsASortedCatalogAndPostsNoNotification() async throws {
        let (repository, vaultRoot, _) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: vaultRoot) }

        let vault = NotesVault(root: vaultRoot)
        _ = try await vault.write(relativePath: "zebra.md", content: "z", expectedHash: nil)
        _ = try await vault.write(relativePath: "alpha.md", content: "a", expectedHash: nil)

        var notified = false
        let observer = NotificationCenter.default.addObserver(forName: .notesStoreDidChange, object: nil, queue: nil) { _ in
            notified = true
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        await repository.reload()

        #expect(repository.notes.map(\.relativePath) == ["alpha.md", "zebra.md"])
        #expect(repository.lastError == nil)
        #expect(!notified)
    }

    @Test func reloadSkipsAnUnreadableNoteAndSurfacesAPartialError() async throws {
        let (repository, vaultRoot, _) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: vaultRoot) }

        let vault = NotesVault(root: vaultRoot)
        _ = try await vault.write(relativePath: "good.md", content: "fine", expectedHash: nil)
        // Invalid UTF-8 bytes make the file unreadable as a note.
        try Data([0xFF, 0xFE, 0xFD]).write(to: vaultRoot.appendingPathComponent("bad.md"))

        await repository.reload()

        #expect(repository.notes.map(\.relativePath) == ["good.md"])
        #expect(repository.lastError == .partialLoadFailure(count: 1))
    }

    // MARK: - Delta application

    @Test func applyDeltaReadsAddedAndModifiedPathsAndPostsNotification() async throws {
        let (repository, vaultRoot, _) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: vaultRoot) }
        let vault = NotesVault(root: vaultRoot)
        _ = try await vault.write(relativePath: "note.md", content: "hello", expectedHash: nil)

        var notified = false
        let observer = NotificationCenter.default.addObserver(forName: .notesStoreDidChange, object: nil, queue: nil) { _ in
            notified = true
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let delta = VaultReconciler.ReconcileDelta(
            added: ["note.md"],
            modified: [],
            removed: [],
            renamedPairs: []
        )
        let mutated = await repository.apply(delta: delta)

        #expect(mutated)
        #expect(repository.notes.count == 1)
        #expect(repository.notes.first?.relativePath == "note.md")
        #expect(notified)
    }

    @Test func applyDeltaHandlesRenamedPairsWithoutRereadingContent() async throws {
        let (repository, vaultRoot, _) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: vaultRoot) }
        let vault = NotesVault(root: vaultRoot)
        _ = try await vault.write(relativePath: "old.md", content: "content", expectedHash: nil)
        await repository.reload()
        #expect(repository.notes.map(\.relativePath) == ["old.md"])

        // Simulate the rename having already happened on disk (a reconciler
        // rescan observed it after the fact); apply(delta:) only needs to
        // fold the pairing into the catalog.
        _ = try await vault.rename(from: "old.md", to: "new.md")

        let delta = VaultReconciler.ReconcileDelta(
            added: [],
            modified: [],
            removed: [],
            renamedPairs: [.init(from: "old.md", to: "new.md")]
        )
        let mutated = await repository.apply(delta: delta)

        #expect(mutated)
        #expect(repository.notes.map(\.relativePath) == ["new.md"])
        #expect(repository.notes.first?.title == "new")
    }

    @Test func applyDeltaRemovesDeletedPaths() async throws {
        let (repository, vaultRoot, _) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: vaultRoot) }
        let vault = NotesVault(root: vaultRoot)
        _ = try await vault.write(relativePath: "note.md", content: "hello", expectedHash: nil)
        await repository.reload()

        let delta = VaultReconciler.ReconcileDelta(added: [], modified: [], removed: ["note.md"], renamedPairs: [])
        let mutated = await repository.apply(delta: delta)

        #expect(mutated)
        #expect(repository.notes.isEmpty)
    }

    @Test func applyingAnEmptyDeltaDoesNothingAndPostsNoNotification() async throws {
        let (repository, vaultRoot, _) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: vaultRoot) }

        var notified = false
        let observer = NotificationCenter.default.addObserver(forName: .notesStoreDidChange, object: nil, queue: nil) { _ in
            notified = true
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let mutated = await repository.apply(delta: .empty)

        #expect(!mutated)
        #expect(!notified)
    }

    // MARK: - Create / filename collisions

    @Test func createSanitizesForbiddenCharactersAndControlCharacters() async throws {
        let (repository, vaultRoot, _) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: vaultRoot) }

        let summary = try await repository.create(title: "a/b:c\u{0007}d")

        #expect(summary.relativePath == "abcd.md")
    }

    @Test func createFallsBackToUntitledWhenSanitizedTitleIsEmpty() async throws {
        let (repository, vaultRoot, _) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: vaultRoot) }

        let summary = try await repository.create(title: "...")

        #expect(summary.relativePath == "Untitled.md")
    }

    @Test func createTriesDeterministicSuffixesOnCollision() async throws {
        let (repository, vaultRoot, _) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: vaultRoot) }

        let first = try await repository.create(title: "Ideas")
        let second = try await repository.create(title: "Ideas")
        let third = try await repository.create(title: "Ideas")

        #expect(first.relativePath == "Ideas.md")
        #expect(second.relativePath == "Ideas 2.md")
        #expect(third.relativePath == "Ideas 3.md")
        #expect(repository.notes.count == 3)

        // No stray conflict copies should have been created for a
        // foreseeable (existence-checked) collision.
        let names = try FileManager.default.contentsOfDirectory(atPath: vaultRoot.path)
        #expect(Set(names) == ["Ideas.md", "Ideas 2.md", "Ideas 3.md"])
    }

    @Test func createPreservesASafeSubfolder() async throws {
        let (repository, vaultRoot, _) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: vaultRoot) }

        let summary = try await repository.create(title: "Note", folder: "Projects/Work")

        #expect(summary.relativePath == "Projects/Work/Note.md")
    }

    @Test func createIgnoresAnUnsafeSubfolder() async throws {
        let (repository, vaultRoot, _) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: vaultRoot) }

        let summary = try await repository.create(title: "Note", folder: "../escape")

        #expect(summary.relativePath == "Note.md")
    }

    // MARK: - Save / revisions / conflicts

    @Test func saveSnapshotsPreMutationContentBeforeWriting() async throws {
        let (repository, vaultRoot, revisionsDirectory) = try makeRepository()
        defer {
            try? FileManager.default.removeItem(at: vaultRoot)
            try? FileManager.default.removeItem(at: revisionsDirectory)
        }
        let vault = NotesVault(root: vaultRoot)
        let created = try await vault.write(relativePath: "note.md", content: "original", expectedHash: nil)
        guard case .wrote(let originalSnapshot) = created else {
            Issue.record("expected a successful create")
            return
        }
        await repository.reload()

        _ = try await repository.save(relativePath: "note.md", content: "updated", expectedHash: originalSnapshot.sha256)

        let revisionStore = NoteRevisionStore(directory: revisionsDirectory)
        let revisions = try await revisionStore.revisions(forKey: "note.md")
        #expect(revisions.count == 1)
        #expect(revisions.first?.content == "original")
    }

    @Test func saveUpdatesTheCatalogSummaryOnSuccess() async throws {
        let (repository, vaultRoot, _) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: vaultRoot) }
        let created = try await repository.create(title: "Note")

        let updated = try await repository.save(relativePath: created.relativePath, content: "new body", expectedHash: created.sha256)

        #expect(updated.sha256 != created.sha256)
        #expect(repository.summary(forRelativePath: created.relativePath)?.sha256 == updated.sha256)
    }

    @Test func saveOnHashMismatchThrowsExternalConflictAndKeepsOriginalIntact() async throws {
        let (repository, vaultRoot, _) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: vaultRoot) }
        let vault = NotesVault(root: vaultRoot)
        let created = try await vault.write(relativePath: "note.md", content: "original", expectedHash: nil)
        guard case .wrote(let originalSnapshot) = created else {
            Issue.record("expected a successful create")
            return
        }
        await repository.reload()

        // Simulate an external editor changing the file after our last read.
        try Data("changed externally".utf8).write(to: vaultRoot.appendingPathComponent("note.md"))

        await #expect(throws: NotesError.self) {
            _ = try await repository.save(
                relativePath: "note.md",
                content: "our stale edit",
                expectedHash: originalSnapshot.sha256
            )
        }

        // The original catalog entry is untouched...
        let original = repository.summary(forRelativePath: "note.md")
        #expect(original?.sha256 == originalSnapshot.sha256)
        // ...and the conflict copy was added alongside it.
        #expect(repository.notes.count == 2)
        let conflictEntry = repository.notes.first { $0.relativePath != "note.md" }
        #expect(conflictEntry?.relativePath.contains("conflict") == true)

        let originalOnDisk = try String(contentsOf: vaultRoot.appendingPathComponent("note.md"), encoding: .utf8)
        #expect(originalOnDisk == "changed externally")
    }

    // MARK: - Rename

    @Test func renameSnapshotsBeforeMutationAndUpdatesIdentity() async throws {
        let (repository, vaultRoot, revisionsDirectory) = try makeRepository()
        defer {
            try? FileManager.default.removeItem(at: vaultRoot)
            try? FileManager.default.removeItem(at: revisionsDirectory)
        }
        let created = try await repository.create(title: "Old Name")

        let renamed = try await repository.rename(from: created.relativePath, to: "New Name.md")

        #expect(renamed.relativePath == "New Name.md")
        #expect(renamed.title == "New Name")
        #expect(repository.summary(forRelativePath: created.relativePath) == nil)
        #expect(repository.summary(forRelativePath: "New Name.md") != nil)

        let revisionStore = NoteRevisionStore(directory: revisionsDirectory)
        let revisions = try await revisionStore.revisions(forKey: created.relativePath)
        #expect(revisions.count == 1)
    }

    // MARK: - Delete

    @Test func deleteSnapshotsBeforeMutationAndRemovesCatalogEntryOnlyAfterSuccess() async throws {
        let (repository, vaultRoot, revisionsDirectory) = try makeRepository()
        defer {
            try? FileManager.default.removeItem(at: vaultRoot)
            try? FileManager.default.removeItem(at: revisionsDirectory)
        }
        let created = try await repository.create(title: "Doomed")

        try await repository.delete(relativePath: created.relativePath)

        #expect(repository.summary(forRelativePath: created.relativePath) == nil)
        #expect(!FileManager.default.fileExists(atPath: vaultRoot.appendingPathComponent(created.relativePath).path))

        let revisionStore = NoteRevisionStore(directory: revisionsDirectory)
        let revisions = try await revisionStore.revisions(forKey: created.relativePath)
        #expect(revisions.count == 1)
    }
}
