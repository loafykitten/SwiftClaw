import Foundation
import Testing
@testable import SwiftClaw

/// Focused non-UI coverage for `NoteEditorModel`'s state transitions and the
/// autosave/conflict invariants called out in `docs/NOTES_PLAN.md` Phase 1:
/// the editor must retain the hash of the content it actually loaded, never
/// let a reconcile-triggered reload clobber that hash while dirty, and never
/// silently drop content on an external-conflict save.
///
/// Serialized for the same reason as `NotesFeatureModelTests` — saves here
/// post the shared/unscoped `.notesStoreDidChange`, which races
/// `NotesRepositoryTests`' "no notification posted" assertions.
@Suite(.serialized)
@MainActor
struct NoteEditorModelTests {
    /// Pauses one vault operation at a known point. This keeps race-regression
    /// tests deterministic without adding production-only editor hooks.
    private actor ScopeGate {
        private let blockedCall: Int
        private var callCount = 0
        private var blockedContinuation: CheckedContinuation<Void, Never>?
        private var startedContinuation: CheckedContinuation<Void, Never>?

        init(blockedCall: Int) {
            self.blockedCall = blockedCall
        }

        func access() async {
            callCount += 1
            guard callCount == blockedCall else { return }
            await withCheckedContinuation { continuation in
                blockedContinuation = continuation
                startedContinuation?.resume()
                startedContinuation = nil
            }
        }

        func waitUntilBlocked() async {
            guard blockedContinuation == nil else { return }
            await withCheckedContinuation { continuation in
                startedContinuation = continuation
            }
        }

        func unblock() {
            blockedContinuation?.resume()
            blockedContinuation = nil
        }
    }

    /// Fails one vault operation after the initial selection read. This gives
    /// save-error tests a deterministic I/O failure without relying on host
    /// filesystem permissions.
    private actor FailOnceScope {
        private let failedCall: Int
        private var callCount = 0

        init(failedCall: Int) {
            self.failedCall = failedCall
        }

        func access() async throws -> ScopedURL? {
            callCount += 1
            guard callCount != failedCall else {
                throw NotesVault.VaultError.ioFailure("The vault is read-only.")
            }
            return nil
        }
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeRepository() throws -> (repository: NotesRepository, vault: NotesVault, vaultRoot: URL) {
        let vaultRoot = try makeTempDirectory()
        let revisionsDirectory = try makeTempDirectory()
        let vault = NotesVault(root: vaultRoot)
        let repository = NotesRepository(vault: vault, revisionStore: NoteRevisionStore(directory: revisionsDirectory))
        return (repository, vault, vaultRoot)
    }

    // MARK: - Load / selection

    @Test func selectingANoteLoadsItsContentAndHashAndClearsDirty() async throws {
        let (repository, vault, vaultRoot) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: vaultRoot) }
        _ = try await vault.write(relativePath: "note.md", content: "hello", expectedHash: nil)

        let editor = NoteEditorModel(repository: repository)
        await editor.select(path: "note.md")

        #expect(editor.editedText == "hello")
        #expect(!editor.isDirty)
        #expect(editor.loadError == nil)
    }

    @Test func staleSuccessfulLoadCannotOverwriteANewerSelection() async throws {
        let vaultRoot = try makeTempDirectory()
        let revisionsDirectory = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: vaultRoot)
            try? FileManager.default.removeItem(at: revisionsDirectory)
        }
        let setupVault = NotesVault(root: vaultRoot)
        _ = try await setupVault.write(relativePath: "a.md", content: "first", expectedHash: nil)
        _ = try await setupVault.write(relativePath: "b.md", content: "second", expectedHash: nil)
        let gate = ScopeGate(blockedCall: 1)
        let repository = NotesRepository(
            vault: NotesVault(root: vaultRoot, scopeAccessor: { await gate.access(); return nil }),
            revisionStore: NoteRevisionStore(directory: revisionsDirectory)
        )
        let editor = NoteEditorModel(repository: repository)

        let firstSelection = Task { @MainActor in await editor.select(path: "a.md") }
        await gate.waitUntilBlocked()
        await editor.select(path: "b.md")
        await gate.unblock()
        _ = await firstSelection.value

        #expect(editor.selectedPath == "b.md")
        #expect(editor.editedText == "second")
        #expect(editor.loadError == nil)
    }

    @Test func staleLoadErrorCannotReplaceANewerSelectionState() async throws {
        let vaultRoot = try makeTempDirectory()
        let revisionsDirectory = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: vaultRoot)
            try? FileManager.default.removeItem(at: revisionsDirectory)
        }
        let setupVault = NotesVault(root: vaultRoot)
        _ = try await setupVault.write(relativePath: "b.md", content: "second", expectedHash: nil)
        let gate = ScopeGate(blockedCall: 1)
        let repository = NotesRepository(
            vault: NotesVault(root: vaultRoot, scopeAccessor: { await gate.access(); return nil }),
            revisionStore: NoteRevisionStore(directory: revisionsDirectory)
        )
        let editor = NoteEditorModel(repository: repository)

        let missingSelection = Task { @MainActor in await editor.select(path: "missing.md") }
        await gate.waitUntilBlocked()
        await editor.select(path: "b.md")
        await gate.unblock()
        _ = await missingSelection.value

        #expect(editor.selectedPath == "b.md")
        #expect(editor.editedText == "second")
        #expect(editor.loadError == nil)
    }

    @Test func typingMarksDirtyWithoutTouchingDiskUntilAutosaveFires() async throws {
        let (repository, vault, vaultRoot) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: vaultRoot) }
        _ = try await vault.write(relativePath: "note.md", content: "hello", expectedHash: nil)

        let editor = NoteEditorModel(repository: repository, autosaveDelay: .seconds(60))
        await editor.select(path: "note.md")
        editor.textDidChange("hello world")

        #expect(editor.isDirty)
        let onDisk = try await vault.read(relativePath: "note.md")
        #expect(onDisk.content == "hello")
    }

    @Test func idleAutosaveWritesAfterTheDebounceDelay() async throws {
        let (repository, vault, vaultRoot) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: vaultRoot) }
        _ = try await vault.write(relativePath: "note.md", content: "hello", expectedHash: nil)

        let editor = NoteEditorModel(repository: repository, autosaveDelay: .milliseconds(50))
        await editor.select(path: "note.md")
        editor.textDidChange("hello world")

        try await Task.sleep(for: .milliseconds(300))

        #expect(!editor.isDirty)
        let onDisk = try await vault.read(relativePath: "note.md")
        #expect(onDisk.content == "hello world")
    }

    // MARK: - Save on selection change / flush

    @Test func switchingSelectionFlushesAPendingDirtyEdit() async throws {
        let (repository, vault, vaultRoot) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: vaultRoot) }
        _ = try await vault.write(relativePath: "a.md", content: "a", expectedHash: nil)
        _ = try await vault.write(relativePath: "b.md", content: "b", expectedHash: nil)

        let editor = NoteEditorModel(repository: repository, autosaveDelay: .seconds(60))
        await editor.select(path: "a.md")
        editor.textDidChange("a edited")
        await editor.select(path: "b.md")

        let onDisk = try await vault.read(relativePath: "a.md")
        #expect(onDisk.content == "a edited")
        #expect(editor.editedText == "b")
        #expect(!editor.isDirty)
    }

    @Test func flushPendingSaveIsANoOpWhenClean() async throws {
        let (repository, vault, vaultRoot) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: vaultRoot) }
        _ = try await vault.write(relativePath: "note.md", content: "hello", expectedHash: nil)

        let editor = NoteEditorModel(repository: repository)
        await editor.select(path: "note.md")

        let result = await editor.flushPendingSave()

        #expect(result)
        #expect(!editor.isDirty)
    }

    @Test func failedNonConflictSavePreventsSelectionChangeUntilTheEditIsRetried() async throws {
        let vaultRoot = try makeTempDirectory()
        let revisionsDirectory = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: vaultRoot)
            try? FileManager.default.removeItem(at: revisionsDirectory)
        }
        let setupVault = NotesVault(root: vaultRoot)
        _ = try await setupVault.write(relativePath: "a.md", content: "a", expectedHash: nil)
        _ = try await setupVault.write(relativePath: "b.md", content: "b", expectedHash: nil)
        let scope = FailOnceScope(failedCall: 2)
        let repository = NotesRepository(
            vault: NotesVault(root: vaultRoot, scopeAccessor: { try await scope.access() }),
            revisionStore: NoteRevisionStore(directory: revisionsDirectory)
        )
        let editor = NoteEditorModel(repository: repository, autosaveDelay: .seconds(60))
        await editor.select(path: "a.md")
        editor.textDidChange("a edited")

        await editor.select(path: "b.md")

        #expect(editor.selectedPath == "a.md")
        #expect(editor.editedText == "a edited")
        #expect(editor.isDirty)
        #expect(editor.saveError != nil)
        #expect(editor.loadError == nil)

        #expect(await editor.flushPendingSave())
        await editor.select(path: "b.md")
        #expect(editor.selectedPath == "b.md")
        #expect(editor.editedText == "b")
    }

    @Test func nonConflictSaveErrorKeepsTheEditableBufferAndDoesNotBecomeALoadError() async throws {
        let vaultRoot = try makeTempDirectory()
        let revisionsDirectory = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: vaultRoot)
            try? FileManager.default.removeItem(at: revisionsDirectory)
        }
        let setupVault = NotesVault(root: vaultRoot)
        _ = try await setupVault.write(relativePath: "note.md", content: "original", expectedHash: nil)
        let scope = FailOnceScope(failedCall: 2)
        let repository = NotesRepository(
            vault: NotesVault(root: vaultRoot, scopeAccessor: { try await scope.access() }),
            revisionStore: NoteRevisionStore(directory: revisionsDirectory)
        )
        let editor = NoteEditorModel(repository: repository, autosaveDelay: .seconds(60))
        await editor.select(path: "note.md")
        editor.textDidChange("unsaved text")

        #expect(!(await editor.flushPendingSave()))

        #expect(editor.editedText == "unsaved text")
        #expect(editor.isDirty)
        #expect(editor.saveError != nil)
        #expect(editor.loadError == nil)
    }

    @Test func concurrentFlushesShareOneSaveAndDoNotCreateAConflictCopy() async throws {
        let (repository, vault, vaultRoot) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: vaultRoot) }
        _ = try await vault.write(relativePath: "note.md", content: "original", expectedHash: nil)

        let editor = NoteEditorModel(repository: repository, autosaveDelay: .seconds(60))
        await editor.select(path: "note.md")
        editor.textDidChange("saved once")

        let firstFlush = Task { @MainActor in await editor.flushPendingSave() }
        let secondFlush = Task { @MainActor in await editor.flushPendingSave() }
        let (firstResult, secondResult) = await (firstFlush.value, secondFlush.value)

        #expect(firstResult)
        #expect(secondResult)
        #expect(!editor.isDirty)
        #expect(editor.conflictBanner == nil)
        #expect(try await vault.read(relativePath: "note.md").content == "saved once")
        #expect(try await vault.enumerate() == ["note.md"])
    }

    @Test func editingDuringAnInFlightSaveSchedulesAnotherIdleAutosave() async throws {
        let vaultRoot = try makeTempDirectory()
        let revisionsDirectory = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: vaultRoot)
            try? FileManager.default.removeItem(at: revisionsDirectory)
        }
        let setupVault = NotesVault(root: vaultRoot)
        _ = try await setupVault.write(relativePath: "note.md", content: "original", expectedHash: nil)
        // Selection uses call one; the repository's pre-save read is call two.
        let gate = ScopeGate(blockedCall: 2)
        let vault = NotesVault(root: vaultRoot, scopeAccessor: { await gate.access(); return nil })
        let repository = NotesRepository(vault: vault, revisionStore: NoteRevisionStore(directory: revisionsDirectory))
        let editor = NoteEditorModel(repository: repository, autosaveDelay: .milliseconds(25))
        await editor.select(path: "note.md")
        editor.textDidChange("first edit")

        let firstSave = Task { @MainActor in await editor.flushPendingSave() }
        await gate.waitUntilBlocked()
        editor.textDidChange("latest edit")
        // Let the debounce join the blocked save before completing it.
        try await Task.sleep(for: .milliseconds(75))
        await gate.unblock()
        #expect(await firstSave.value)
        #expect(editor.isDirty)

        try await Task.sleep(for: .milliseconds(150))

        #expect(!editor.isDirty)
        #expect(try await vault.read(relativePath: "note.md").content == "latest edit")
        #expect(try await vault.enumerate() == ["note.md"])
    }

    // MARK: - External reconciliation

    @Test func externalChangeReloadsAWhenTheEditorIsClean() async throws {
        let (repository, vault, vaultRoot) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: vaultRoot) }
        _ = try await vault.write(relativePath: "note.md", content: "original", expectedHash: nil)

        let editor = NoteEditorModel(repository: repository)
        await editor.select(path: "note.md")

        // Simulate an external editor changing the file on disk.
        _ = try await vault.write(relativePath: "note.md", content: "changed externally", expectedHash: try await vault.read(relativePath: "note.md").sha256)

        await editor.handleExternalChange()

        #expect(editor.editedText == "changed externally")
        #expect(!editor.isDirty)
    }

    @Test func externalChangeNeverTouchesTheEditorWhileDirty() async throws {
        let (repository, vault, vaultRoot) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: vaultRoot) }
        _ = try await vault.write(relativePath: "note.md", content: "original", expectedHash: nil)

        let editor = NoteEditorModel(repository: repository, autosaveDelay: .seconds(60))
        await editor.select(path: "note.md")
        editor.textDidChange("my in-progress edit")

        // An external editor changes the on-disk file while this editor is
        // still dirty — the reconciler would call this, but it must not
        // replace the editor's text or its loaded expected hash.
        _ = try await vault.write(relativePath: "note.md", content: "changed externally", expectedHash: try await vault.read(relativePath: "note.md").sha256)
        await editor.handleExternalChange()

        #expect(editor.editedText == "my in-progress edit")
        #expect(editor.isDirty)
    }

    // MARK: - Conflict

    @Test func conflictedSaveKeepsEditorTextAndSurfacesTheCopyPathWithoutLosingData() async throws {
        let (repository, vault, vaultRoot) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: vaultRoot) }
        _ = try await vault.write(relativePath: "note.md", content: "original", expectedHash: nil)

        let editor = NoteEditorModel(repository: repository, autosaveDelay: .seconds(60))
        await editor.select(path: "note.md")
        editor.textDidChange("my in-progress edit")

        // External editor races ahead while this editor is still holding the
        // original expected hash.
        _ = try await vault.write(relativePath: "note.md", content: "changed externally", expectedHash: try await vault.read(relativePath: "note.md").sha256)

        let saved = await editor.flushPendingSave()

        #expect(!saved)
        #expect(editor.editedText == "my in-progress edit")
        #expect(editor.conflictBanner != nil)

        // Nothing was lost: the original on-disk file is untouched, and the
        // attempted content landed at the conflict-copy path.
        let original = try await vault.read(relativePath: "note.md")
        #expect(original.content == "changed externally")
        if let copyPath = editor.conflictBanner?.copyPath {
            let copy = try await vault.read(relativePath: copyPath)
            #expect(copy.content == "my in-progress edit")
        } else {
            Issue.record("Expected a conflict banner with a copy path")
        }
    }

    @Test func dismissingTheConflictBannerClearsItWithoutDiscardingText() async throws {
        let (repository, vault, vaultRoot) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: vaultRoot) }
        _ = try await vault.write(relativePath: "note.md", content: "original", expectedHash: nil)

        let editor = NoteEditorModel(repository: repository, autosaveDelay: .seconds(60))
        await editor.select(path: "note.md")
        editor.textDidChange("my edit")
        _ = try await vault.write(relativePath: "note.md", content: "changed externally", expectedHash: try await vault.read(relativePath: "note.md").sha256)
        _ = await editor.flushPendingSave()
        #expect(editor.conflictBanner != nil)

        editor.dismissConflictBanner()

        #expect(editor.conflictBanner == nil)
        #expect(editor.editedText == "my edit")
    }

    @Test func clearingSelectionResetsEditorState() async throws {
        let (repository, vault, vaultRoot) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: vaultRoot) }
        _ = try await vault.write(relativePath: "note.md", content: "hello", expectedHash: nil)

        let editor = NoteEditorModel(repository: repository)
        await editor.select(path: "note.md")
        await editor.select(path: nil)

        #expect(editor.editedText == "")
        #expect(!editor.isDirty)
        #expect(editor.selectedPath == nil)
    }
}
