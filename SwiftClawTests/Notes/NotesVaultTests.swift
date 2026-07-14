import Foundation
import Testing
@testable import SwiftClaw

struct NotesVaultTests {
    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func roundTripsContentByteForByte() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = NotesVault(root: root)

        let content = "# Title\n\nSome body with emoji \u{1F389} and trailing spaces  \n"
        let outcome = try await vault.write(relativePath: "note.md", content: content, expectedHash: nil)
        guard case .wrote(let snapshot) = outcome else {
            Issue.record("expected a successful write")
            return
        }
        #expect(snapshot.content == content)

        let read = try await vault.read(relativePath: "note.md")
        #expect(read.content == content)
        #expect(read.sha256 == snapshot.sha256)

        let onDisk = try Data(contentsOf: root.appendingPathComponent("note.md"))
        #expect(onDisk == Data(content.utf8))
    }

    @Test func hashMismatchWritesConflictCopyAndLeavesOriginalIntact() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = NotesVault(root: root)

        let original = try await vault.write(relativePath: "note.md", content: "original", expectedHash: nil)
        guard case .wrote(let originalSnapshot) = original else {
            Issue.record("expected a successful create")
            return
        }

        // Simulate an external editor changing the file after our last read.
        try Data("changed externally".utf8).write(to: root.appendingPathComponent("note.md"))

        let outcome = try await vault.write(
            relativePath: "note.md",
            content: "our stale edit",
            expectedHash: originalSnapshot.sha256
        )
        guard case .conflict(let conflictSnapshot) = outcome else {
            Issue.record("expected a conflict")
            return
        }
        #expect(conflictSnapshot.content == "our stale edit")
        #expect(conflictSnapshot.relativePath.contains("conflict"))
        #expect(conflictSnapshot.relativePath != "note.md")

        let originalOnDisk = try String(contentsOf: root.appendingPathComponent("note.md"), encoding: .utf8)
        #expect(originalOnDisk == "changed externally")

        // Both files present: nothing was silently discarded.
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(names.count == 2)
    }

    @Test func createOnlyWriteDoesNotClobberAnExistingFile() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = NotesVault(root: root)

        _ = try await vault.write(relativePath: "note.md", content: "first", expectedHash: nil)
        let outcome = try await vault.write(relativePath: "note.md", content: "second", expectedHash: nil)

        guard case .conflict(let conflictSnapshot) = outcome else {
            Issue.record("expected the create collision to produce a conflict, not a clobber")
            return
        }
        #expect(conflictSnapshot.content == "second")

        let originalOnDisk = try String(contentsOf: root.appendingPathComponent("note.md"), encoding: .utf8)
        #expect(originalOnDisk == "first")
    }

    @Test func renameMovesTheFile() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = NotesVault(root: root)

        _ = try await vault.write(relativePath: "old.md", content: "content", expectedHash: nil)
        let renamed = try await vault.rename(from: "old.md", to: "new.md")

        #expect(renamed.content == "content")
        #expect(renamed.relativePath == "new.md")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("old.md").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("new.md").path))
    }

    @Test func renameNeverClobbersAnExistingDestination() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = NotesVault(root: root)

        _ = try await vault.write(relativePath: "source.md", content: "source content", expectedHash: nil)
        _ = try await vault.write(relativePath: "destination.md", content: "destination content", expectedHash: nil)

        await #expect(throws: NotesVault.VaultError.self) {
            _ = try await vault.rename(from: "source.md", to: "destination.md")
        }

        let destinationOnDisk = try String(contentsOf: root.appendingPathComponent("destination.md"), encoding: .utf8)
        #expect(destinationOnDisk == "destination content")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("source.md").path))
    }

    @Test func enumerateSkipsHiddenEntriesAndNonMarkdownFiles() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = NotesVault(root: root)

        _ = try await vault.write(relativePath: "kept.md", content: "kept", expectedHash: nil)
        _ = try await vault.write(relativePath: "folder/nested.md", content: "nested", expectedHash: nil)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".obsidian"),
            withIntermediateDirectories: true
        )
        try Data("config".utf8).write(to: root.appendingPathComponent(".obsidian/config.json"))
        try Data("not markdown".utf8).write(to: root.appendingPathComponent("notes.txt"))
        try Data("hidden".utf8).write(to: root.appendingPathComponent(".hidden.md"))

        let entries = try await vault.enumerate()

        #expect(entries == ["folder/nested.md", "kept.md"])
    }

    @Test func writeRejectsPathTraversalEscapes() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = NotesVault(root: root)

        await #expect(throws: NotesVault.VaultError.self) {
            _ = try await vault.write(relativePath: "../escape.md", content: "x", expectedHash: nil)
        }
        await #expect(throws: NotesVault.VaultError.self) {
            _ = try await vault.write(relativePath: "/etc/escape.md", content: "x", expectedHash: nil)
        }
    }

    @Test func mutationTargetsCannotEscapeThroughASymlinkedParent() async throws {
        let root = try makeTempDirectory()
        let outside = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let vault = NotesVault(root: root)
        let linkedDirectory = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: outside)

        await #expect(throws: NotesVault.VaultError.self) {
            _ = try await vault.write(relativePath: "linked/new.md", content: "must stay in vault", expectedHash: nil)
        }

        _ = try await vault.write(relativePath: "source.md", content: "source", expectedHash: nil)
        await #expect(throws: NotesVault.VaultError.self) {
            _ = try await vault.rename(from: "source.md", to: "linked/renamed.md")
        }

        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("new.md").path))
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("renamed.md").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("source.md").path))
    }

    @Test func enumerateSkipsDirectorySymlinkLoops() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = NotesVault(root: root)
        _ = try await vault.write(relativePath: "folder/note.md", content: "kept", expectedHash: nil)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("folder/loop"),
            withDestinationURL: root.appendingPathComponent("folder")
        )

        let entries = try await vault.enumerate()

        #expect(entries == ["folder/note.md"])
    }

    @Test func symbolicMarkdownFilesCannotEscapeTheVaultOrAppearInEnumeration() async throws {
        let root = try makeTempDirectory()
        let outside = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let vault = NotesVault(root: root)
        let outsideNote = outside.appendingPathComponent("private.md")
        try Data("outside vault".utf8).write(to: outsideNote)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked.md"),
            withDestinationURL: outsideNote
        )
        _ = try await vault.write(relativePath: "kept.md", content: "inside vault", expectedHash: nil)

        #expect(try await vault.enumerate() == ["kept.md"])
        await #expect(throws: NotesVault.VaultError.self) {
            _ = try await vault.read(relativePath: "linked.md")
        }
        await #expect(throws: NotesVault.VaultError.self) {
            _ = try await vault.write(relativePath: "linked.md", content: "must not escape", expectedHash: nil)
        }
    }

    @Test func createSucceedsWhenRootIsGivenInAnAlternateLexicalForm() async throws {
        // `/tmp` is itself a symlink to `/private/tmp` on macOS, and
        // Foundation's `standardizedFileURL` only strips the "/private"
        // prefix consistently when applied to the root path alone — not when
        // re-applied after appending a not-yet-existing filename. This
        // reproduces an externally-selected vault root arriving in the
        // "/private/tmp/..." lexical form (e.g. via NSOpenPanel) rather than
        // the shortened "/tmp/..." form.
        let uuid = UUID().uuidString
        let canonicalRoot = URL(fileURLWithPath: "/tmp/SwiftClawVaultTests-\(uuid)")
        try FileManager.default.createDirectory(at: canonicalRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: canonicalRoot) }

        let alternateRoot = URL(fileURLWithPath: "/private/tmp/SwiftClawVaultTests-\(uuid)")
        let vault = NotesVault(root: alternateRoot)

        let outcome = try await vault.write(relativePath: "Untitled.md", content: "new note", expectedHash: nil)
        guard case .wrote(let snapshot) = outcome else {
            Issue.record("expected a successful create through an alternate-lexical-form root")
            return
        }
        #expect(snapshot.relativePath == "Untitled.md")
        #expect(FileManager.default.fileExists(atPath: canonicalRoot.appendingPathComponent("Untitled.md").path))
    }

    @Test func hashMismatchThroughAnAlternateLexicalFormRootWritesAConflictCopyWithACorrectRelativePath() async throws {
        // Same "/private/tmp" vs "/tmp" lexical-form root as
        // `createSucceedsWhenRootIsGivenInAnAlternateLexicalForm`, but forcing
        // the conflict branch: `computeRelativePath` is only exercised for a
        // `.wrote` outcome there, never for the `makeConflictURL` path this
        // covers.
        let uuid = UUID().uuidString
        let canonicalRoot = URL(fileURLWithPath: "/tmp/SwiftClawVaultTests-\(uuid)")
        try FileManager.default.createDirectory(at: canonicalRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: canonicalRoot) }

        let alternateRoot = URL(fileURLWithPath: "/private/tmp/SwiftClawVaultTests-\(uuid)")
        let vault = NotesVault(root: alternateRoot)

        let original = try await vault.write(relativePath: "note.md", content: "original", expectedHash: nil)
        guard case .wrote(let originalSnapshot) = original else {
            Issue.record("expected a successful create through an alternate-lexical-form root")
            return
        }

        // Simulate an external editor changing the file after our last read.
        try Data("changed externally".utf8).write(to: canonicalRoot.appendingPathComponent("note.md"))

        let outcome = try await vault.write(
            relativePath: "note.md",
            content: "our stale edit",
            expectedHash: originalSnapshot.sha256
        )
        guard case .conflict(let conflictSnapshot) = outcome else {
            Issue.record("expected a conflict through an alternate-lexical-form root")
            return
        }
        #expect(conflictSnapshot.relativePath.contains("conflict"))
        #expect(conflictSnapshot.relativePath != "note.md")
        #expect(FileManager.default.fileExists(atPath: canonicalRoot.appendingPathComponent(conflictSnapshot.relativePath).path))
        #expect(conflictSnapshot.content == "our stale edit")

        let originalOnDisk = try String(contentsOf: canonicalRoot.appendingPathComponent("note.md"), encoding: .utf8)
        #expect(originalOnDisk == "changed externally")
    }

    @Test func deleteMovesTheFileOutOfTheVault() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = NotesVault(root: root)

        _ = try await vault.write(relativePath: "note.md", content: "content", expectedHash: nil)
        try await vault.delete(relativePath: "note.md")

        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("note.md").path))
    }
}
