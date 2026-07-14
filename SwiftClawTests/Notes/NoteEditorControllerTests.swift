import Foundation
import Testing
@testable import SwiftClaw

/// Focused non-UI coverage for `NoteEditorController`'s state transitions
/// and the autosave/conflict/reconcile invariants called out in
/// `docs/NOTES_PLAN.md` Phase 2: the editor must retain the hash of the
/// content it actually loaded, never let a reconcile-triggered reload
/// clobber that hash while dirty, never silently drop content on an
/// external-conflict save, and present exactly the Keep Mine/Take Theirs
/// choice when a reconcile delta touches a dirty note. `applyText` is left
/// unset in these tests (no live `NSTextView` exists here) — `currentText`
/// is the controller's own authoritative copy either way.
///
/// Serialized for the same reason as `NotesFeatureModelTests` — saves here
/// post the shared/unscoped `.notesStoreDidChange`, which races
/// `NotesRepositoryTests`' "no notification posted" assertions.
@Suite(.serialized)
@MainActor
struct NoteEditorControllerTests {
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

        func calls() -> Int {
            callCount
        }
    }

    /// Pauses two distinct vault operations (by call number), each released
    /// independently, so a test can keep two loads in flight simultaneously
    /// and control the order they resume in.
    private actor DualGate {
        private let blockedCalls: Set<Int>
        private var callCount = 0
        private var blockedContinuations: [Int: CheckedContinuation<Void, Never>] = [:]
        private var startedContinuations: [Int: CheckedContinuation<Void, Never>] = [:]

        init(blockedCalls: Set<Int>) {
            self.blockedCalls = blockedCalls
        }

        func access() async {
            callCount += 1
            let current = callCount
            guard blockedCalls.contains(current) else { return }
            await withCheckedContinuation { continuation in
                blockedContinuations[current] = continuation
                if let started = startedContinuations.removeValue(forKey: current) {
                    started.resume()
                }
            }
        }

        func waitUntilBlocked(_ call: Int) async {
            guard blockedContinuations[call] == nil else { return }
            await withCheckedContinuation { continuation in
                startedContinuations[call] = continuation
            }
        }

        func unblock(_ call: Int) {
            blockedContinuations[call]?.resume()
            blockedContinuations[call] = nil
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

        let editor = NoteEditorController(repository: repository)
        await editor.select(path: "note.md")

        #expect(editor.currentText == "hello")
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
        let editor = NoteEditorController(repository: repository)

        let firstSelection = Task { @MainActor in await editor.select(path: "a.md") }
        await gate.waitUntilBlocked()
        await editor.select(path: "b.md")
        await gate.unblock()
        _ = await firstSelection.value

        #expect(editor.selectedPath == "b.md")
        #expect(editor.currentText == "second")
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
        let editor = NoteEditorController(repository: repository)

        let missingSelection = Task { @MainActor in await editor.select(path: "missing.md") }
        await gate.waitUntilBlocked()
        await editor.select(path: "b.md")
        await gate.unblock()
        _ = await missingSelection.value

        #expect(editor.selectedPath == "b.md")
        #expect(editor.currentText == "second")
        #expect(editor.loadError == nil)
    }

    @Test func retargetingDuringAGuardedPostConflictReloadClearsTheSpinnerWithoutClobberingTheChoice() async throws {
        let vaultRoot = try makeTempDirectory()
        let revisionsDirectory = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: vaultRoot)
            try? FileManager.default.removeItem(at: revisionsDirectory)
        }
        let setupVault = NotesVault(root: vaultRoot)
        _ = try await setupVault.write(relativePath: "note.md", content: "original", expectedHash: nil)

        // Call #1 is the initial select's read. keepMine() then snapshots the
        // current revision with read #2 and attempts its guarded write at #3;
        // both proceed to produce the conflict copy. Call #4 is the
        // post-conflict `repository.read`, which this test suspends mid-flight.
        let gate = ScopeGate(blockedCall: 4)
        let repository = NotesRepository(
            vault: NotesVault(root: vaultRoot, scopeAccessor: { await gate.access(); return nil }),
            revisionStore: NoteRevisionStore(directory: revisionsDirectory)
        )
        let editor = NoteEditorController(repository: repository, autosaveDelay: .seconds(60))
        await editor.select(path: "note.md")
        editor.textDidChange("pre-conflict buffer")

        _ = try await setupVault.write(relativePath: "note.md", content: "changed externally", expectedHash: try await setupVault.read(relativePath: "note.md").sha256)
        await editor.handleExternalChange()
        #expect(editor.externalChangeChoice != nil)

        let keepMineTask = Task { @MainActor in await editor.keepMine() }
        await gate.waitUntilBlocked()
        #expect(editor.isLoading)

        // Retarget (as if the note were renamed externally) while the guarded
        // post-conflict reload is suspended. This advances `selectionGeneration`
        // and changes `selectedPath` without itself starting a new `load`, so
        // the resuming reload's stale-selection guard fires — the bug this
        // regresses is that branch previously returned without clearing
        // `isLoading`, leaving the spinner stuck forever.
        editor.retarget(to: "renamed.md")

        await gate.unblock()
        await keepMineTask.value

        #expect(!editor.isLoading)
        // The reload's snapshot was correctly discarded (it named the old
        // path), so nothing here was ever silently applied: the dirty buffer
        // and the actionable choice remain exactly as before the retarget.
        #expect(editor.isDirty)
        #expect(editor.currentText == "pre-conflict buffer")
        #expect(editor.externalChangeChoice != nil)
    }

    @Test func anOlderStaleLoadCannotClearANewerActiveLoadsSpinner() async throws {
        let vaultRoot = try makeTempDirectory()
        let revisionsDirectory = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: vaultRoot)
            try? FileManager.default.removeItem(at: revisionsDirectory)
        }
        let setupVault = NotesVault(root: vaultRoot)
        _ = try await setupVault.write(relativePath: "a.md", content: "a", expectedHash: nil)
        _ = try await setupVault.write(relativePath: "b.md", content: "b", expectedHash: nil)

        // Blocks both the first selection's read (call #1) and the second
        // selection's read (call #2) so both loads can be kept in flight at
        // once, released in a chosen order.
        let gate = DualGate(blockedCalls: [1, 2])
        let repository = NotesRepository(
            vault: NotesVault(root: vaultRoot, scopeAccessor: { await gate.access(); return nil }),
            revisionStore: NoteRevisionStore(directory: revisionsDirectory)
        )
        let editor = NoteEditorController(repository: repository)

        let selectA = Task { @MainActor in await editor.select(path: "a.md") }
        await gate.waitUntilBlocked(1)
        #expect(editor.isLoading)

        // `select` sets `selectedPath` to "b.md" synchronously before
        // awaiting its own load, so by the time `a`'s stale load resumes
        // below, it will fail the selection guard rather than applying.
        let selectB = Task { @MainActor in await editor.select(path: "b.md") }
        await gate.waitUntilBlocked(2)
        #expect(editor.isLoading)

        // Release the older, now-stale `a` load. It resumes, fails the
        // selection guard, and must not clear `isLoading` while `b`'s load
        // is still active.
        await gate.unblock(1)
        _ = await selectA.value
        #expect(editor.isLoading)

        // Release the newer, still-active `b` load. Only this one may clear
        // the spinner.
        await gate.unblock(2)
        _ = await selectB.value

        #expect(!editor.isLoading)
        #expect(editor.selectedPath == "b.md")
        #expect(editor.currentText == "b")
    }

    @Test func typingMarksDirtyWithoutTouchingDiskUntilAutosaveFires() async throws {
        let (repository, vault, vaultRoot) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: vaultRoot) }
        _ = try await vault.write(relativePath: "note.md", content: "hello", expectedHash: nil)

        let editor = NoteEditorController(repository: repository, autosaveDelay: .seconds(60))
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

        let editor = NoteEditorController(repository: repository, autosaveDelay: .milliseconds(50))
        await editor.select(path: "note.md")
        editor.textDidChange("hello world")

        try await Task.sleep(for: .milliseconds(300))

        #expect(!editor.isDirty)
        let onDisk = try await vault.read(relativePath: "note.md")
        #expect(onDisk.content == "hello world")
    }

    // MARK: - Save on selection change / flush (blur autosave)

    @Test func switchingSelectionFlushesAPendingDirtyEdit() async throws {
        let (repository, vault, vaultRoot) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: vaultRoot) }
        _ = try await vault.write(relativePath: "a.md", content: "a", expectedHash: nil)
        _ = try await vault.write(relativePath: "b.md", content: "b", expectedHash: nil)

        let editor = NoteEditorController(repository: repository, autosaveDelay: .seconds(60))
        await editor.select(path: "a.md")
        editor.textDidChange("a edited")
        await editor.select(path: "b.md")

        let onDisk = try await vault.read(relativePath: "a.md")
        #expect(onDisk.content == "a edited")
        #expect(editor.currentText == "b")
        #expect(!editor.isDirty)
    }

    @Test func selectionWaitsForNewerTypingAfterAnOlderInFlightSaveSucceeds() async throws {
        let vaultRoot = try makeTempDirectory()
        let revisionsDirectory = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: vaultRoot)
            try? FileManager.default.removeItem(at: revisionsDirectory)
        }
        let setupVault = NotesVault(root: vaultRoot)
        _ = try await setupVault.write(relativePath: "a.md", content: "original", expectedHash: nil)
        _ = try await setupVault.write(relativePath: "b.md", content: "other", expectedHash: nil)

        // #1 is the initial load. Save A blocks at its revision snapshot
        // (#2); after it writes at #3, saving newer buffer B blocks at its
        // own snapshot (#4). That second pause proves selection cannot finish
        // solely because the older save succeeded.
        let gate = DualGate(blockedCalls: [2, 4])
        let repository = NotesRepository(
            vault: NotesVault(root: vaultRoot, scopeAccessor: { await gate.access(); return nil }),
            revisionStore: NoteRevisionStore(directory: revisionsDirectory)
        )
        let editor = NoteEditorController(repository: repository, autosaveDelay: .seconds(60))
        await editor.select(path: "a.md")
        editor.textDidChange("buffer A")

        let firstFlush = Task { @MainActor in await editor.flushPendingSave() }
        await gate.waitUntilBlocked(2)
        editor.textDidChange("buffer B")
        let selection = Task { @MainActor in await editor.select(path: "b.md") }
        await Task.yield()

        await gate.unblock(2)
        await gate.waitUntilBlocked(4)

        #expect(editor.selectedPath == "a.md")
        #expect(editor.currentText == "buffer B")
        #expect(editor.isDirty)
        #expect((try await setupVault.read(relativePath: "a.md")).content == "buffer A")

        await gate.unblock(4)
        // Its selection generation is now stale, so the original flush
        // stops rather than claiming that A settled the later selection.
        #expect(!(await firstFlush.value))
        #expect(await selection.value)
        #expect((try await setupVault.read(relativePath: "a.md")).content == "buffer B")
        #expect(editor.selectedPath == "b.md")
        #expect(editor.currentText == "other")
    }

    @Test func selectionWaitsForNewerTypingAfterAnOlderInFlightSaveConflicts() async throws {
        let vaultRoot = try makeTempDirectory()
        let revisionsDirectory = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: vaultRoot)
            try? FileManager.default.removeItem(at: revisionsDirectory)
        }
        let setupVault = NotesVault(root: vaultRoot)
        _ = try await setupVault.write(relativePath: "a.md", content: "original", expectedHash: nil)
        _ = try await setupVault.write(relativePath: "b.md", content: "other", expectedHash: nil)

        // The operation order mirrors the success case, but changing a.md
        // while A is blocked makes #3 preserve A in a conflict copy. B then
        // blocks at #4 and must get its own copy before selection may leave.
        let gate = DualGate(blockedCalls: [2, 4])
        let repository = NotesRepository(
            vault: NotesVault(root: vaultRoot, scopeAccessor: { await gate.access(); return nil }),
            revisionStore: NoteRevisionStore(directory: revisionsDirectory)
        )
        let editor = NoteEditorController(repository: repository, autosaveDelay: .seconds(60))
        await editor.select(path: "a.md")
        editor.textDidChange("buffer A")

        let firstFlush = Task { @MainActor in await editor.flushPendingSave() }
        await gate.waitUntilBlocked(2)
        _ = try await setupVault.write(
            relativePath: "a.md",
            content: "external original",
            expectedHash: try await setupVault.read(relativePath: "a.md").sha256
        )
        editor.textDidChange("buffer B")
        let selection = Task { @MainActor in await editor.select(path: "b.md") }
        await Task.yield()

        await gate.unblock(2)
        await gate.waitUntilBlocked(4)

        #expect(editor.selectedPath == "a.md")
        #expect(editor.currentText == "buffer B")
        #expect(editor.isDirty)
        #expect((try await setupVault.read(relativePath: "a.md")).content == "external original")
        let copiesBeforeB = try await setupVault.enumerate().filter { $0.contains("conflict") }
        #expect(copiesBeforeB.count == 1)
        #expect((try await setupVault.read(relativePath: copiesBeforeB[0])).content == "buffer A")

        await gate.unblock(4)
        #expect(!(await firstFlush.value))
        #expect(await selection.value)
        #expect((try await setupVault.read(relativePath: "a.md")).content == "external original")
        let conflictCopies = try await setupVault.enumerate().filter { $0.contains("conflict") }
        #expect(conflictCopies.count == 2)
        var conflictContents: [String] = []
        for copyPath in conflictCopies {
            conflictContents.append(try await setupVault.read(relativePath: copyPath).content)
        }
        #expect(conflictContents.contains("buffer B"))
        #expect(editor.selectedPath == "b.md")
    }

    @Test func ordinaryFailureAfterAnOlderConflictCopyDoesNotNavigate() async throws {
        let vaultRoot = try makeTempDirectory()
        let revisionsDirectory = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: vaultRoot)
            try? FileManager.default.removeItem(at: revisionsDirectory)
        }
        let setupVault = NotesVault(root: vaultRoot)
        _ = try await setupVault.write(relativePath: "a.md", content: "original", expectedHash: nil)
        _ = try await setupVault.write(relativePath: "b.md", content: "other", expectedHash: nil)

        // #1 loads A, #2/#3 preserve buffer A in a conflict copy, then #4
        // fails buffer B's save. The older copy must not authorize leaving B.
        let scope = FailOnceScope(failedCall: 4)
        let repository = NotesRepository(
            vault: NotesVault(root: vaultRoot, scopeAccessor: { try await scope.access() }),
            revisionStore: NoteRevisionStore(directory: revisionsDirectory)
        )
        let editor = NoteEditorController(repository: repository, autosaveDelay: .seconds(60))
        await editor.select(path: "a.md")
        editor.textDidChange("buffer A")
        _ = try await setupVault.write(
            relativePath: "a.md",
            content: "external original",
            expectedHash: try await setupVault.read(relativePath: "a.md").sha256
        )

        #expect(!(await editor.flushPendingSave()))
        #expect(editor.conflictBanner != nil)
        editor.textDidChange("buffer B")

        #expect(!(await editor.select(path: "b.md")))
        #expect(editor.selectedPath == "a.md")
        #expect(editor.currentText == "buffer B")
        #expect(editor.isDirty)
        #expect(editor.conflictBanner == nil)
        #expect(editor.saveError != nil)
    }

    @Test func flushPendingSaveIsANoOpWhenClean() async throws {
        let (repository, vault, vaultRoot) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: vaultRoot) }
        _ = try await vault.write(relativePath: "note.md", content: "hello", expectedHash: nil)

        let editor = NoteEditorController(repository: repository)
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
        let editor = NoteEditorController(repository: repository, autosaveDelay: .seconds(60))
        await editor.select(path: "a.md")
        editor.textDidChange("a edited")

        await editor.select(path: "b.md")

        #expect(editor.selectedPath == "a.md")
        #expect(editor.currentText == "a edited")
        #expect(editor.isDirty)
        #expect(editor.saveError != nil)
        #expect(editor.loadError == nil)

        #expect(await editor.flushPendingSave())
        await editor.select(path: "b.md")
        #expect(editor.selectedPath == "b.md")
        #expect(editor.currentText == "b")
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
        let editor = NoteEditorController(repository: repository, autosaveDelay: .seconds(60))
        await editor.select(path: "note.md")
        editor.textDidChange("unsaved text")

        #expect(!(await editor.flushPendingSave()))

        #expect(editor.currentText == "unsaved text")
        #expect(editor.isDirty)
        #expect(editor.saveError != nil)
        #expect(editor.loadError == nil)
    }

    // MARK: - External reconciliation

    @Test func externalChangeReloadsWhenTheEditorIsClean() async throws {
        let (repository, vault, vaultRoot) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: vaultRoot) }
        _ = try await vault.write(relativePath: "note.md", content: "original", expectedHash: nil)

        let editor = NoteEditorController(repository: repository)
        await editor.select(path: "note.md")

        // Simulate an external editor changing the file on disk.
        _ = try await vault.write(relativePath: "note.md", content: "changed externally", expectedHash: try await vault.read(relativePath: "note.md").sha256)

        await editor.handleExternalChange()

        #expect(editor.currentText == "changed externally")
        #expect(!editor.isDirty)
        #expect(editor.externalChangeChoice == nil)
    }

    @Test func externalChangeWhileDirtyPresentsAChoiceInsteadOfReloadingOrIgnoring() async throws {
        let (repository, vault, vaultRoot) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: vaultRoot) }
        _ = try await vault.write(relativePath: "note.md", content: "original", expectedHash: nil)

        let editor = NoteEditorController(repository: repository, autosaveDelay: .seconds(60))
        await editor.select(path: "note.md")
        editor.textDidChange("my in-progress edit")

        _ = try await vault.write(relativePath: "note.md", content: "changed externally", expectedHash: try await vault.read(relativePath: "note.md").sha256)
        await editor.handleExternalChange()

        #expect(editor.currentText == "my in-progress edit")
        #expect(editor.isDirty)
        #expect(editor.externalChangeChoice != nil)

        // Idle autosave must not fire while the choice is pending, or it
        // would silently mint a conflict copy behind the user's back.
        editor.textDidChange("my in-progress edit further")
        try await Task.sleep(for: .milliseconds(50))
        let onDisk = try await vault.read(relativePath: "note.md")
        #expect(onDisk.content == "changed externally")
    }

    @Test func handleExternalChangeDefersToAnInFlightSaveInsteadOfPresentingAFalseChoice() async throws {
        let vaultRoot = try makeTempDirectory()
        let revisionsDirectory = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: vaultRoot)
            try? FileManager.default.removeItem(at: revisionsDirectory)
        }
        let setupVault = NotesVault(root: vaultRoot)
        _ = try await setupVault.write(relativePath: "note.md", content: "original", expectedHash: nil)

        // Call #1 is the initial select's read. The blur/idle-triggered
        // normal flush's revision-snapshot read is call #2, held so a
        // reconcile delta can arrive while that save is still in flight —
        // exactly the race where the watcher/rescan reports the editor's own
        // pending write as if it were an external edit.
        let gate = ScopeGate(blockedCall: 2)
        let repository = NotesRepository(
            vault: NotesVault(root: vaultRoot, scopeAccessor: { await gate.access(); return nil }),
            revisionStore: NoteRevisionStore(directory: revisionsDirectory)
        )
        let editor = NoteEditorController(repository: repository, autosaveDelay: .seconds(60))
        await editor.select(path: "note.md")
        editor.textDidChange("in-flight buffer")

        let flush = Task { @MainActor in await editor.flushPendingSave() }
        await gate.waitUntilBlocked()

        // The reconciler observes a delta for this note — really just its
        // own save landing — while the save is still suspended and the
        // buffer is still (necessarily) dirty.
        let reconcile = Task { @MainActor in await editor.handleExternalChange() }
        await Task.yield()
        // Deferred, not presented: the choice must not appear while the
        // save this delta actually describes is still settling.
        #expect(editor.externalChangeChoice == nil)

        await gate.unblock()
        #expect(await flush.value)
        await reconcile.value

        // The save the delta was racing has now landed cleanly, and nothing
        // else changed the file afterward, so no external-change choice is
        // left behind — the bug this regresses left a stale, false Keep
        // Mine/Take Theirs prompt over an already-saved buffer.
        #expect(editor.externalChangeChoice == nil)
        #expect(!editor.isDirty)
        #expect(editor.currentText == "in-flight buffer")
        let onDisk = try await setupVault.read(relativePath: "note.md")
        #expect(onDisk.content == "in-flight buffer")
    }

    @Test func externalReloadRaceKeepsTypedEditsAndPresentsAChoiceInsteadOfClobberingThem() async throws {
        let vaultRoot = try makeTempDirectory()
        let revisionsDirectory = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: vaultRoot)
            try? FileManager.default.removeItem(at: revisionsDirectory)
        }
        let setupVault = NotesVault(root: vaultRoot)
        _ = try await setupVault.write(relativePath: "note.md", content: "original", expectedHash: nil)

        // Blocks the *second* vault operation: the initial select's read is
        // call #1 (unblocked), the reconcile-triggered reload's read is #2.
        let gate = ScopeGate(blockedCall: 2)
        let repository = NotesRepository(
            vault: NotesVault(root: vaultRoot, scopeAccessor: { await gate.access(); return nil }),
            revisionStore: NoteRevisionStore(directory: revisionsDirectory)
        )
        let editor = NoteEditorController(repository: repository, autosaveDelay: .seconds(60))
        await editor.select(path: "note.md")
        #expect(!editor.isDirty)

        // An external editor changes the file while this editor is clean —
        // handleExternalChange() takes the "clean note, reload" branch and
        // suspends mid-`repository.read`.
        _ = try await setupVault.write(relativePath: "note.md", content: "changed externally", expectedHash: try await setupVault.read(relativePath: "note.md").sha256)
        let reload = Task { @MainActor in await editor.handleExternalChange() }
        await gate.waitUntilBlocked()

        // The user types while that read is still suspended.
        editor.textDidChange("typed during the reload race")

        await gate.unblock()
        _ = await reload.value

        // The typed edit must survive — the external snapshot must not have
        // silently replaced it — and the choice bar must be shown instead of
        // either a silent reload or a silent no-op.
        #expect(editor.currentText == "typed during the reload race")
        #expect(editor.isDirty)
        #expect(editor.externalChangeChoice != nil)
    }

    @Test func keepMineGuardsAgainstAConcurrentKeepMineOrTakeTheirsUntilItSettles() async throws {
        let vaultRoot = try makeTempDirectory()
        let revisionsDirectory = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: vaultRoot)
            try? FileManager.default.removeItem(at: revisionsDirectory)
        }
        let setupVault = NotesVault(root: vaultRoot)
        _ = try await setupVault.write(relativePath: "note.md", content: "original", expectedHash: nil)

        // Call #1 is the initial select's read; call #2 is the first
        // keepMine() save's revision-snapshot read, where this test suspends
        // the save mid-flight.
        let gate = ScopeGate(blockedCall: 2)
        let repository = NotesRepository(
            vault: NotesVault(root: vaultRoot, scopeAccessor: { await gate.access(); return nil }),
            revisionStore: NoteRevisionStore(directory: revisionsDirectory)
        )
        let editor = NoteEditorController(repository: repository, autosaveDelay: .seconds(60))
        await editor.select(path: "note.md")
        editor.textDidChange("buffer to keep")

        // Presents the choice via handleExternalChange's dirty branch, which
        // makes no repository call, so it doesn't disturb the gate's call
        // count.
        _ = try await setupVault.write(relativePath: "note.md", content: "changed externally", expectedHash: try await setupVault.read(relativePath: "note.md").sha256)
        await editor.handleExternalChange()
        #expect(editor.externalChangeChoice != nil)

        let firstKeepMine = Task { @MainActor in await editor.keepMine() }
        await gate.waitUntilBlocked()
        #expect(editor.isResolvingExternalChange)

        // Both a second Keep Mine and a Take Theirs while the first
        // resolution is still suspended must be no-ops: neither should touch
        // the vault (the gate's call count would move past 2 if they did)
        // or disturb the in-flight resolution's state.
        await editor.keepMine()
        await editor.takeTheirs()
        #expect(editor.isResolvingExternalChange)
        #expect(editor.externalChangeChoice != nil)
        #expect(editor.currentText == "buffer to keep")
        #expect(editor.isDirty)

        await gate.unblock()
        await firstKeepMine.value

        #expect(!editor.isResolvingExternalChange)
        #expect(editor.externalChangeChoice == nil)
        #expect(!editor.isDirty)
        #expect(editor.currentText == "changed externally")

        // Only the first Keep Mine's operation produced a conflict copy —
        // the guarded-out second attempt never wrote one — and that copy
        // holds exactly the buffer the first, original call chose to keep.
        let entries = try await setupVault.enumerate()
        let conflictPaths = entries.filter { $0.contains("conflict") }
        #expect(conflictPaths.count == 1)
        if let copyPath = conflictPaths.first {
            let copy = try await setupVault.read(relativePath: copyPath)
            #expect(copy.content == "buffer to keep")
        }
        let original = try await setupVault.read(relativePath: "note.md")
        #expect(original.content == "changed externally")
    }

    @Test func selectionAndFlushAreRejectedWhileKeepMineResolutionIsBlockedThenWorkAfterward() async throws {
        let vaultRoot = try makeTempDirectory()
        let revisionsDirectory = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: vaultRoot)
            try? FileManager.default.removeItem(at: revisionsDirectory)
        }
        let setupVault = NotesVault(root: vaultRoot)
        _ = try await setupVault.write(relativePath: "a.md", content: "original", expectedHash: nil)
        _ = try await setupVault.write(relativePath: "b.md", content: "other", expectedHash: nil)

        // Call #1 is the initial load. Call #2 is Keep Mine's repository
        // snapshot read; its guarded write would be call #3 after release.
        let gate = ScopeGate(blockedCall: 2)
        let repository = NotesRepository(
            vault: NotesVault(root: vaultRoot, scopeAccessor: { await gate.access(); return nil }),
            revisionStore: NoteRevisionStore(directory: revisionsDirectory)
        )
        let editor = NoteEditorController(repository: repository, autosaveDelay: .seconds(60))
        await editor.select(path: "a.md")
        editor.textDidChange("buffer to keep")
        _ = try await setupVault.write(relativePath: "a.md", content: "changed externally", expectedHash: try await setupVault.read(relativePath: "a.md").sha256)
        await editor.handleExternalChange()

        let keepMine = Task { @MainActor in await editor.keepMine() }
        await gate.waitUntilBlocked()
        #expect(editor.isResolvingExternalChange)

        // A list selection and the explicit flush used by blur/onDisappear
        // must both reject immediately. In particular, neither may join the
        // busy resolution and navigate after it finishes.
        #expect(!(await editor.select(path: "b.md")))
        #expect(!(await editor.flushPendingSave()))
        #expect(editor.selectedPath == "a.md")
        #expect(editor.currentText == "buffer to keep")
        #expect(editor.externalChangeChoice != nil)
        #expect(await gate.calls() == 2)
        #expect(try await setupVault.enumerate().filter { $0.contains("conflict") }.isEmpty)

        await gate.unblock()
        await keepMine.value

        // Only the resolution's original guarded write can create a copy.
        #expect(try await setupVault.enumerate().filter { $0.contains("conflict") }.count == 1)
        #expect(await gate.calls() == 4) // #3 write, #4 post-conflict reload

        // Once the resolution leaves its critical section, normal selection
        // and flushing resume their existing behavior.
        #expect(await editor.select(path: "b.md"))
        #expect(editor.selectedPath == "b.md")
        #expect(editor.currentText == "other")
    }

    @Test func takeTheirsDefersForABlockedNormalSaveThenUsesItsConflictCopyWithoutCreatingAnother() async throws {
        let vaultRoot = try makeTempDirectory()
        let revisionsDirectory = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: vaultRoot)
            try? FileManager.default.removeItem(at: revisionsDirectory)
        }
        let setupVault = NotesVault(root: vaultRoot)
        _ = try await setupVault.write(relativePath: "note.md", content: "original", expectedHash: nil)

        // Call #1 is the initial load. The normal flush suspends at its
        // repository snapshot read (#2), then performs its guarded write
        // (#3). Reconciliation waits for that local save before showing the
        // true external-change choice. Take Theirs then adds only the
        // replacement read (#4), never a second snapshot/write pair.
        let gate = ScopeGate(blockedCall: 2)
        let repository = NotesRepository(
            vault: NotesVault(root: vaultRoot, scopeAccessor: { await gate.access(); return nil }),
            revisionStore: NoteRevisionStore(directory: revisionsDirectory)
        )
        let editor = NoteEditorController(repository: repository, autosaveDelay: .seconds(60))
        await editor.select(path: "note.md")
        editor.textDidChange("normal save buffer")
        _ = try await setupVault.write(relativePath: "note.md", content: "changed externally", expectedHash: try await setupVault.read(relativePath: "note.md").sha256)

        let normalFlush = Task { @MainActor in await editor.flushPendingSave() }
        await gate.waitUntilBlocked()
        let reconcile = Task { @MainActor in await editor.handleExternalChange() }
        await Task.yield()
        // The reconciliation event might just be this app's own save, so no
        // choice can be shown until that save has actually settled.
        #expect(editor.externalChangeChoice == nil)

        await gate.unblock()
        #expect(!(await normalFlush.value))
        await reconcile.value
        #expect(editor.externalChangeChoice != nil)

        let takeTheirs = Task { @MainActor in await editor.takeTheirs() }
        await takeTheirs.value

        #expect(!editor.isResolvingExternalChange)
        #expect(editor.externalChangeChoice == nil)
        #expect(!editor.isDirty)
        #expect(editor.currentText == "changed externally")
        #expect(try await setupVault.enumerate().filter { $0.contains("conflict") }.count == 1)
        #expect(await gate.calls() == 4)
    }

    @Test func keepMineReusesABlockedNormalSavesConflictCopyWithoutDuplicatingIt() async throws {
        let vaultRoot = try makeTempDirectory()
        let revisionsDirectory = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: vaultRoot)
            try? FileManager.default.removeItem(at: revisionsDirectory)
        }
        let setupVault = NotesVault(root: vaultRoot)
        _ = try await setupVault.write(relativePath: "note.md", content: "original", expectedHash: nil)

        // Call #1 is the initial load. The already-running normal flush owns
        // snapshot read #2 and guarded write #3. Reconciliation waits for
        // it, then Keep Mine must reuse the resulting conflict copy rather
        // than issuing the same stale-hash save again. Its reload is #4.
        let gate = ScopeGate(blockedCall: 2)
        let repository = NotesRepository(
            vault: NotesVault(root: vaultRoot, scopeAccessor: { await gate.access(); return nil }),
            revisionStore: NoteRevisionStore(directory: revisionsDirectory)
        )
        let editor = NoteEditorController(repository: repository, autosaveDelay: .seconds(60))
        await editor.select(path: "note.md")
        editor.textDidChange("normal save buffer")
        _ = try await setupVault.write(relativePath: "note.md", content: "changed externally", expectedHash: try await setupVault.read(relativePath: "note.md").sha256)

        let normalFlush = Task { @MainActor in await editor.flushPendingSave() }
        await gate.waitUntilBlocked()
        let reconcile = Task { @MainActor in await editor.handleExternalChange() }
        await Task.yield()
        #expect(editor.externalChangeChoice == nil)

        await gate.unblock()
        #expect(!(await normalFlush.value))
        await reconcile.value
        #expect(editor.externalChangeChoice != nil)

        await editor.keepMine()

        #expect(!editor.isResolvingExternalChange)
        #expect(editor.currentText == "changed externally")
        #expect(!editor.isDirty)
        #expect(editor.externalChangeChoice == nil)
        guard let copyPath = editor.conflictBanner?.copyPath else {
            Issue.record("Expected the normal save's conflict copy")
            return
        }
        #expect((try await setupVault.read(relativePath: copyPath)).content == "normal save buffer")
        #expect((try await setupVault.read(relativePath: "note.md")).content == "changed externally")
        #expect(try await setupVault.enumerate().filter { $0.contains("conflict") }.count == 1)
        #expect(await gate.calls() == 4)
    }

    @Test func keepMineReusesAConflictCopyFromASaveThatFullyCompletedBeforeReconciliationObservedIt() async throws {
        let vaultRoot = try makeTempDirectory()
        let revisionsDirectory = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: vaultRoot)
            try? FileManager.default.removeItem(at: revisionsDirectory)
        }
        let setupVault = NotesVault(root: vaultRoot)
        _ = try await setupVault.write(relativePath: "note.md", content: "original", expectedHash: nil)

        let repository = NotesRepository(
            vault: NotesVault(root: vaultRoot),
            revisionStore: NoteRevisionStore(directory: revisionsDirectory)
        )
        let editor = NoteEditorController(repository: repository, autosaveDelay: .seconds(60))
        await editor.select(path: "note.md")
        editor.textDidChange("normal save buffer")

        // The external edit lands, then a normal flush (standing in for an
        // idle autosave) runs to completion and conflicts *before* the
        // reconciler's notification arrives — `inFlightSave` is already nil
        // and `pendingExternalChangeSaveOutcome` was never populated by the
        // time `handleExternalChange()` runs. Only `conflictBanner` still
        // records what happened.
        _ = try await setupVault.write(relativePath: "note.md", content: "changed externally", expectedHash: try await setupVault.read(relativePath: "note.md").sha256)
        #expect(!(await editor.flushPendingSave()))
        guard let earlyCopyPath = editor.conflictBanner?.copyPath else {
            Issue.record("Expected the normal flush's conflict copy")
            return
        }

        await editor.handleExternalChange()
        #expect(editor.externalChangeChoice != nil)

        await editor.keepMine()

        #expect(!editor.isResolvingExternalChange)
        #expect(editor.currentText == "changed externally")
        #expect(!editor.isDirty)
        #expect(editor.externalChangeChoice == nil)
        #expect(editor.conflictBanner?.copyPath == earlyCopyPath)
        #expect((try await setupVault.read(relativePath: earlyCopyPath)).content == "normal save buffer")
        #expect((try await setupVault.read(relativePath: "note.md")).content == "changed externally")
        // Exactly one conflict copy: Keep Mine must reuse the one the
        // already-completed flush created rather than minting a duplicate.
        #expect(try await setupVault.enumerate().filter { $0.contains("conflict") }.count == 1)
    }

    @Test func keepMineNonConflictSaveErrorKeepsTheBufferAndLeavesTheChoiceRetryable() async throws {
        let vaultRoot = try makeTempDirectory()
        let revisionsDirectory = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: vaultRoot)
            try? FileManager.default.removeItem(at: revisionsDirectory)
        }
        let setupVault = NotesVault(root: vaultRoot)
        _ = try await setupVault.write(relativePath: "note.md", content: "original", expectedHash: nil)

        // Call #1 is the initial select's read; call #2 is keepMine() save's
        // revision-snapshot read, which fails with a non-conflict I/O error
        // before a guarded write is attempted.
        let scope = FailOnceScope(failedCall: 2)
        let repository = NotesRepository(
            vault: NotesVault(root: vaultRoot, scopeAccessor: { try await scope.access() }),
            revisionStore: NoteRevisionStore(directory: revisionsDirectory)
        )
        let editor = NoteEditorController(repository: repository, autosaveDelay: .seconds(60))
        await editor.select(path: "note.md")
        editor.textDidChange("my in-progress edit")
        await editor.handleExternalChange()
        #expect(editor.externalChangeChoice != nil)

        await editor.keepMine()

        // Nothing was preserved anywhere by the failed save, so nothing here
        // may look like the save succeeded or like the content was ever at
        // risk: the buffer, dirty state, and the choice must all remain
        // exactly as they were, with the failure surfaced for a retry.
        #expect(editor.currentText == "my in-progress edit")
        #expect(editor.isDirty)
        #expect(editor.saveError != nil)
        #expect(editor.conflictBanner == nil)
        #expect(editor.externalChangeChoice != nil)

        let onDisk = try await setupVault.read(relativePath: "note.md")
        #expect(onDisk.content == "original")
        let entries = try await setupVault.enumerate()
        #expect(!entries.contains { $0.contains("conflict") })

        // The guard must not be left stuck by the non-conflict failure — a
        // retry is expected to actually run (and here, succeed outright,
        // since nothing external actually changed on disk in this test).
        #expect(!editor.isResolvingExternalChange)

        await editor.keepMine()

        #expect(editor.saveError == nil)
        #expect(editor.externalChangeChoice == nil)
        #expect(!editor.isDirty)
        #expect(!editor.isResolvingExternalChange)
    }

    @Test func takeTheirsKeepsTheChoiceBusyAndRetryableUntilItsReloadSettles() async throws {
        let vaultRoot = try makeTempDirectory()
        let revisionsDirectory = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: vaultRoot)
            try? FileManager.default.removeItem(at: revisionsDirectory)
        }
        let setupVault = NotesVault(root: vaultRoot)
        _ = try await setupVault.write(relativePath: "note.md", content: "original", expectedHash: nil)

        // Call #1 is the initial selection read. Call #2 is Take Theirs'
        // replacement read, held long enough to assert that the resolution
        // remains visibly busy and that a second choice cannot enter.
        let gate = ScopeGate(blockedCall: 2)
        let repository = NotesRepository(
            vault: NotesVault(root: vaultRoot, scopeAccessor: { await gate.access(); return nil }),
            revisionStore: NoteRevisionStore(directory: revisionsDirectory)
        )
        let editor = NoteEditorController(repository: repository, autosaveDelay: .seconds(60))
        await editor.select(path: "note.md")
        editor.textDidChange("buffer to discard")
        _ = try await setupVault.write(relativePath: "note.md", content: "changed externally", expectedHash: try await setupVault.read(relativePath: "note.md").sha256)
        await editor.handleExternalChange()
        #expect(editor.externalChangeChoice != nil)

        let takeTheirs = Task { @MainActor in await editor.takeTheirs() }
        await gate.waitUntilBlocked()

        #expect(editor.isResolvingExternalChange)
        #expect(editor.externalChangeChoice != nil)
        #expect(editor.isLoading)

        // A concurrent resolution must remain guarded while the first one
        // owns the choice.
        await editor.keepMine()
        #expect(editor.isResolvingExternalChange)
        #expect(editor.externalChangeChoice != nil)

        await gate.unblock()
        await takeTheirs.value

        #expect(!editor.isResolvingExternalChange)
        #expect(editor.externalChangeChoice == nil)
        #expect(!editor.isLoading)
        #expect(!editor.isDirty)
        #expect(editor.currentText == "changed externally")
        #expect(try await setupVault.enumerate() == ["note.md"])
    }

    @Test func keepMineSaveRaceKeepsNewerTypingDirtyAndPreservesOnlyThePreAwaitBufferInTheConflictCopy() async throws {
        let vaultRoot = try makeTempDirectory()
        let revisionsDirectory = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: vaultRoot)
            try? FileManager.default.removeItem(at: revisionsDirectory)
        }
        let setupVault = NotesVault(root: vaultRoot)
        _ = try await setupVault.write(relativePath: "note.md", content: "original", expectedHash: nil)

        // Call #1 is the initial select's read; call #2 is keepMine() save's
        // revision-snapshot read, which this test suspends mid-flight.
        let gate = ScopeGate(blockedCall: 2)
        let repository = NotesRepository(
            vault: NotesVault(root: vaultRoot, scopeAccessor: { await gate.access(); return nil }),
            revisionStore: NoteRevisionStore(directory: revisionsDirectory)
        )
        let editor = NoteEditorController(repository: repository, autosaveDelay: .seconds(60))
        await editor.select(path: "note.md")
        editor.textDidChange("pre-await buffer")

        _ = try await setupVault.write(relativePath: "note.md", content: "changed externally", expectedHash: try await setupVault.read(relativePath: "note.md").sha256)
        await editor.handleExternalChange()
        #expect(editor.externalChangeChoice != nil)

        let keepMineTask = Task { @MainActor in await editor.keepMine() }
        await gate.waitUntilBlocked()

        // The user types a newer buffer while Keep Mine's save (of the
        // pre-await buffer) is still suspended.
        editor.textDidChange("newer buffer typed during the keep mine save")

        await gate.unblock()
        await keepMineTask.value

        // The newest buffer must survive byte-identically and stay dirty —
        // the conflict copy the save produced only ever held the older,
        // pre-await content, so reloading it here would silently erase the
        // newer typing.
        #expect(editor.currentText == "newer buffer typed during the keep mine save")
        #expect(editor.isDirty)
        #expect(editor.saveError == nil)
        // The choice must remain actionable so the newer buffer can still be
        // resolved (Keep Mine again, or Take Theirs) instead of being
        // silently dropped.
        #expect(editor.externalChangeChoice != nil)

        guard let copyPath = editor.conflictBanner?.copyPath else {
            Issue.record("Expected a conflict banner with a copy path")
            return
        }
        let copy = try await setupVault.read(relativePath: copyPath)
        #expect(copy.content == "pre-await buffer")
        let original = try await setupVault.read(relativePath: "note.md")
        #expect(original.content == "changed externally")
    }

    @Test func keepMineSavesAsAConflictCopyThenReloadsTheExternalVersionCoherently() async throws {
        let (repository, vault, vaultRoot) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: vaultRoot) }
        _ = try await vault.write(relativePath: "note.md", content: "original", expectedHash: nil)

        let editor = NoteEditorController(repository: repository, autosaveDelay: .seconds(60))
        await editor.select(path: "note.md")
        editor.textDidChange("my in-progress edit")
        _ = try await vault.write(relativePath: "note.md", content: "changed externally", expectedHash: try await vault.read(relativePath: "note.md").sha256)
        await editor.handleExternalChange()
        #expect(editor.externalChangeChoice != nil)

        await editor.keepMine()

        #expect(editor.externalChangeChoice == nil)
        #expect(!editor.isDirty)
        #expect(editor.currentText == "changed externally")
        guard let copyPath = editor.conflictBanner?.copyPath else {
            Issue.record("Expected a conflict banner with a copy path")
            return
        }
        let copy = try await vault.read(relativePath: copyPath)
        #expect(copy.content == "my in-progress edit")
        let original = try await vault.read(relativePath: "note.md")
        #expect(original.content == "changed externally")

        // Coherent afterwards: no further autosave mints another copy.
        editor.textDidChange("changed externally") // no-op edit, still clean
        #expect(!editor.isDirty)
        #expect(try await vault.enumerate().filter { $0.contains("conflict") }.count == 1)
    }

    @Test func keepMinePostConflictReloadRaceKeepsTheNewestTypingAndLeavesTheChoiceActionable() async throws {
        let vaultRoot = try makeTempDirectory()
        let revisionsDirectory = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: vaultRoot)
            try? FileManager.default.removeItem(at: revisionsDirectory)
        }
        let setupVault = NotesVault(root: vaultRoot)
        _ = try await setupVault.write(relativePath: "note.md", content: "original", expectedHash: nil)

        // Call #1 is the initial select's read. keepMine() then snapshots the
        // current revision with read #2 and attempts its guarded write at #3;
        // both proceed to produce the conflict copy. Call #4 is the
        // post-conflict `repository.read`, which this test suspends mid-flight.
        let gate = ScopeGate(blockedCall: 4)
        let repository = NotesRepository(
            vault: NotesVault(root: vaultRoot, scopeAccessor: { await gate.access(); return nil }),
            revisionStore: NoteRevisionStore(directory: revisionsDirectory)
        )
        let editor = NoteEditorController(repository: repository, autosaveDelay: .seconds(60))
        await editor.select(path: "note.md")
        editor.textDidChange("pre-conflict buffer")

        _ = try await setupVault.write(relativePath: "note.md", content: "changed externally", expectedHash: try await setupVault.read(relativePath: "note.md").sha256)
        await editor.handleExternalChange()
        #expect(editor.externalChangeChoice != nil)

        let keepMineTask = Task { @MainActor in await editor.keepMine() }
        await gate.waitUntilBlocked()

        // The save has already completed as a conflict (the copy holds
        // "pre-conflict buffer") and the post-conflict reload's read is now
        // suspended. The user types a newer buffer while that read is in
        // flight.
        editor.textDidChange("newest buffer typed during the reload")

        await gate.unblock()
        await keepMineTask.value

        #expect(editor.currentText == "newest buffer typed during the reload")
        #expect(editor.isDirty)
        #expect(editor.externalChangeChoice != nil)
        guard let copyPath = editor.conflictBanner?.copyPath else {
            Issue.record("Expected a conflict banner with a copy path")
            return
        }
        #expect(editor.conflictBanner?.copyPath == copyPath)

        let original = try await setupVault.read(relativePath: "note.md")
        #expect(original.content == "changed externally")
        let copy = try await setupVault.read(relativePath: copyPath)
        #expect(copy.content == "pre-conflict buffer")
    }

    @Test func keepMineUnexpectedSuccessWithInFlightTypingRestartsAutosaveForTheNewerBuffer() async throws {
        let vaultRoot = try makeTempDirectory()
        let revisionsDirectory = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: vaultRoot)
            try? FileManager.default.removeItem(at: revisionsDirectory)
        }
        let setupVault = NotesVault(root: vaultRoot)
        _ = try await setupVault.write(relativePath: "note.md", content: "original", expectedHash: nil)

        // Call #1 is the initial select's read; call #2 is keepMine() save's
        // revision-snapshot read, which this test suspends mid-flight. The
        // file's hash is never changed underneath the editor, so the
        // suspended save will unexpectedly succeed against `expectedHash`
        // once released.
        let gate = ScopeGate(blockedCall: 2)
        let repository = NotesRepository(
            vault: NotesVault(root: vaultRoot, scopeAccessor: { await gate.access(); return nil }),
            revisionStore: NoteRevisionStore(directory: revisionsDirectory)
        )
        let editor = NoteEditorController(repository: repository, autosaveDelay: .milliseconds(50))
        await editor.select(path: "note.md")
        editor.textDidChange("older content")

        // The editor is already dirty, so this hits `handleExternalChange`'s
        // dirty branch, which presents the choice directly with no
        // `repository.read` — the on-disk hash is never touched, so Keep
        // Mine's save below still matches `expectedHash` and succeeds.
        await editor.handleExternalChange()
        #expect(editor.externalChangeChoice != nil)

        let keepMineTask = Task { @MainActor in await editor.keepMine() }
        await gate.waitUntilBlocked()

        // The user types newer content while the "older content" save is
        // still suspended.
        editor.textDidChange("newer content typed during keep mine")

        await gate.unblock()
        await keepMineTask.value

        #expect(editor.currentText == "newer content typed during keep mine")
        #expect(editor.isDirty)
        #expect(editor.externalChangeChoice == nil)
        #expect(editor.conflictBanner == nil)

        // The idle autosave that Keep Mine's success must have restarted
        // eventually flushes the newer buffer with no conflict copy.
        try await Task.sleep(for: .milliseconds(400))
        #expect(!editor.isDirty)
        let onDisk = try await setupVault.read(relativePath: "note.md")
        #expect(onDisk.content == "newer content typed during keep mine")
        #expect(try await setupVault.enumerate() == ["note.md"])
    }

    @Test func takeTheirsDiscardsTheBufferAndReloadsTheExternalVersion() async throws {
        let (repository, vault, vaultRoot) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: vaultRoot) }
        _ = try await vault.write(relativePath: "note.md", content: "original", expectedHash: nil)

        let editor = NoteEditorController(repository: repository, autosaveDelay: .seconds(60))
        await editor.select(path: "note.md")
        editor.textDidChange("my in-progress edit")
        _ = try await vault.write(relativePath: "note.md", content: "changed externally", expectedHash: try await vault.read(relativePath: "note.md").sha256)
        await editor.handleExternalChange()
        #expect(editor.externalChangeChoice != nil)

        await editor.takeTheirs()

        #expect(editor.externalChangeChoice == nil)
        #expect(!editor.isDirty)
        #expect(editor.currentText == "changed externally")
        // Never saved: no conflict copy exists anywhere in the vault.
        #expect(try await vault.enumerate() == ["note.md"])
    }

    // MARK: - Ordinary autosave conflict (unchanged from Phase 1)

    @Test func conflictedSaveKeepsEditorTextAndSurfacesTheCopyPathWithoutLosingData() async throws {
        let (repository, vault, vaultRoot) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: vaultRoot) }
        _ = try await vault.write(relativePath: "note.md", content: "original", expectedHash: nil)

        let editor = NoteEditorController(repository: repository, autosaveDelay: .seconds(60))
        await editor.select(path: "note.md")
        editor.textDidChange("my in-progress edit")

        // External editor races ahead while this editor is still holding the
        // original expected hash, and no reconcile delta arrives yet.
        _ = try await vault.write(relativePath: "note.md", content: "changed externally", expectedHash: try await vault.read(relativePath: "note.md").sha256)

        let saved = await editor.flushPendingSave()

        #expect(!saved)
        #expect(editor.currentText == "my in-progress edit")
        #expect(editor.conflictBanner != nil)

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

        let editor = NoteEditorController(repository: repository, autosaveDelay: .seconds(60))
        await editor.select(path: "note.md")
        editor.textDidChange("my edit")
        _ = try await vault.write(relativePath: "note.md", content: "changed externally", expectedHash: try await vault.read(relativePath: "note.md").sha256)
        _ = await editor.flushPendingSave()
        #expect(editor.conflictBanner != nil)

        editor.dismissConflictBanner()

        #expect(editor.conflictBanner == nil)
        #expect(editor.currentText == "my edit")
    }

    @Test func clearingSelectionResetsEditorState() async throws {
        let (repository, vault, vaultRoot) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: vaultRoot) }
        _ = try await vault.write(relativePath: "note.md", content: "hello", expectedHash: nil)

        let editor = NoteEditorController(repository: repository)
        await editor.select(path: "note.md")
        await editor.select(path: nil)

        #expect(editor.currentText == "")
        #expect(!editor.isDirty)
        #expect(editor.selectedPath == nil)
    }

    // MARK: - Wikilink autocomplete

    /// Regression for the reported bug: accepting a wikilink completion left
    /// the link unclosed (`[[Autocomplete Candidate` with no `]]`) and the
    /// suggestion popup open, because `applyReplacement`'s resulting
    /// `textDidChange`/selection-change notification re-triggered
    /// `updateWikilinkCompletion` against text that still looked like an
    /// unclosed `[[`. Exercises the full round trip through the controller
    /// (not just `WikilinkCompletion` in isolation) the way
    /// `NoteEditorView.Coordinator`/`WikilinkCompletionOverlay` actually
    /// drive it: type up to the trigger, accept, apply the replacement,
    /// then re-run the same completion update the view's `textDidChange`
    /// callback issues after every edit.
    @Test func acceptingAWikilinkCompletionClosesTheLinkAndStaysDismissed() async throws {
        let (repository, _, vaultRoot) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: vaultRoot) }

        let editor = NoteEditorController(repository: repository)
        editor.candidateNotes = [
            NoteSummary(relativePath: "Autocomplete Candidate.md", title: "Autocomplete Candidate", sha256: "a", modifiedAt: .now)
        ]

        let typed = "See [[Auto"
        editor.updateWikilinkCompletion(text: typed, cursorLocation: (typed as NSString).length)
        #expect(editor.wikilinkTrigger?.query == "Auto")
        #expect(!editor.wikilinkCandidates.isEmpty)

        let candidate = try #require(editor.wikilinkCandidates.first)
        let (range, replacement, _) = try #require(editor.acceptWikilinkCompletion(candidate))

        // Acceptance itself must clear the popup immediately.
        #expect(editor.wikilinkTrigger == nil)
        #expect(editor.wikilinkCandidates.isEmpty)

        let finalText = (typed as NSString).replacingCharacters(in: range, with: replacement)
        #expect(finalText == "See [[Autocomplete Candidate]]")

        // Mirrors what `NoteEditorView.Coordinator.textDidChange`/
        // `textViewDidChangeSelection` do after `insertText` lands: re-run
        // completion detection at the cursor position right after the
        // inserted text. It must not reopen the popup.
        let cursorAfterInsert = range.location + (replacement as NSString).length
        editor.updateWikilinkCompletion(text: finalText, cursorLocation: cursorAfterInsert)
        #expect(editor.wikilinkTrigger == nil)
        #expect(editor.wikilinkCandidates.isEmpty)
    }

    /// Regression for completing a partial query immediately before a closing
    /// pair the user already typed. The controller must pass the trigger's
    /// `hasTrailingClosingBrackets` flag through to the pure replacement
    /// helper, so only that existing pair remains after replacement.
    @Test func acceptingAWikilinkCompletionReusesAnExistingClosingPair() async throws {
        let (repository, _, vaultRoot) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: vaultRoot) }

        let editor = NoteEditorController(repository: repository)
        editor.candidateNotes = [
            NoteSummary(relativePath: "Autocomplete Candidate.md", title: "Autocomplete Candidate", sha256: "a", modifiedAt: .now)
        ]

        let typed = "See [[Auto]]"
        let cursorLocation = ("See [[Auto" as NSString).length
        editor.updateWikilinkCompletion(text: typed, cursorLocation: cursorLocation)
        #expect(editor.wikilinkTrigger?.hasTrailingClosingBrackets == true)

        let candidate = try #require(editor.wikilinkCandidates.first)
        let (range, replacement, reusesTrailingClosingBrackets) = try #require(editor.acceptWikilinkCompletion(candidate))
        let finalText = (typed as NSString).replacingCharacters(in: range, with: replacement)

        #expect(replacement == "Autocomplete Candidate")
        #expect(finalText == "See [[Autocomplete Candidate]]")
        #expect(!finalText.contains("]]]]"))
        #expect(reusesTrailingClosingBrackets)

        // The view advances the cursor past the reused closing pair. Keeping
        // it before that pair would make completion detect the same link
        // again on its next selection update.
        let cursorAfterInsert = range.location + (replacement as NSString).length + 2
        #expect(WikilinkCompletion.trigger(in: finalText, cursorLocation: cursorAfterInsert) == nil)
    }

    /// Escape's `doCommandBy` handler in `NoteEditorView.Coordinator` only
    /// intercepts `cancelOperation` when `wikilinkTrigger != nil`, then calls
    /// this directly — so this is the unit covering that "Escape dismisses
    /// without insertion" outcome without needing a live `NSTextView`.
    @Test func dismissWikilinkCompletionClearsTheTriggerWithoutModifyingText() async throws {
        let (repository, _, vaultRoot) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: vaultRoot) }
        let editor = NoteEditorController(repository: repository)
        editor.candidateNotes = [
            NoteSummary(relativePath: "Page.md", title: "Page", sha256: "a", modifiedAt: .now)
        ]
        let typed = "[[Pa"
        editor.updateWikilinkCompletion(text: typed, cursorLocation: (typed as NSString).length)
        #expect(editor.wikilinkTrigger != nil)

        editor.dismissWikilinkCompletion()

        #expect(editor.wikilinkTrigger == nil)
        #expect(editor.wikilinkCandidates.isEmpty)
    }
}
