import Foundation
import Observation

/// Owns the interim plain-text editor's state for exactly one selected note
/// at a time: the loaded baseline (content + hash), the live edited text,
/// dirty tracking, idle-debounced autosave, and the external-conflict
/// banner. A view-facing `@Observable` (not an actor) because it's driven
/// directly by `TextEditor`'s `Binding` on the main actor.
///
/// The critical invariant: `expectedHash` is only ever written by `load` (on
/// select or a reconcile-triggered reload of a *clean* note) and `save` (on
/// a successful write). Nothing else — in particular, no external-change
/// notification — is allowed to overwrite it while `isDirty` is true, or an
/// autosave could silently clobber content the editor never saw.
@MainActor
@Observable
final class NoteEditorModel {
    struct ConflictBanner: Equatable {
        let copyPath: String
    }

    struct ExternalRemovalBanner: Equatable {
        let formerPath: String
    }

    private static let logger = AppLog.make("notes.editor")

    private(set) var selectedPath: String?
    private(set) var editedText: String = ""
    private(set) var isDirty = false
    private(set) var isLoading = false
    private(set) var loadError: NotesError?
    /// Unlike `loadError`, this leaves the editor usable: the current buffer
    /// remains available to copy, edit, and retry after a write failure.
    private(set) var saveError: NotesError?
    private(set) var conflictBanner: ConflictBanner?
    private(set) var externalRemovalBanner: ExternalRemovalBanner?

    private var loadedContent: String = ""
    private var expectedHash: String?
    /// Increments for every selection request so a slow read started for an
    /// older selection cannot overwrite the currently selected note.
    private var selectionGeneration = 0
    /// Set once a save hits a conflict; suppresses further *idle-debounced*
    /// autosaves (which would otherwise mint a fresh conflict copy on every
    /// debounce cycle while the banner sits unread) without blocking an
    /// explicit flush (selection change, disappear) — those still fire so a
    /// last edit is never silently dropped, just possibly conflicted again.
    private var isAutosaveFrozen = false
    private var autosaveTask: Task<Void, Never>?
    /// A write suspends while it crosses the repository/vault actors. Keep
    /// every concurrent flush attached to that one task so a second
    /// disappearance callback cannot save the same stale hash as a conflict.
    private var inFlightSave: (id: UUID, task: Task<Bool, Never>)?

    private let repository: NotesRepository
    private let autosaveDelay: Duration

    init(repository: NotesRepository, autosaveDelay: Duration = .milliseconds(1500)) {
        self.repository = repository
        self.autosaveDelay = autosaveDelay
    }

    // MARK: - Selection

    /// Switches the editor to `path` (or clears it for `nil`), flushing any
    /// pending save for the previously selected note first so a selection
    /// change never drops an edit.
    @discardableResult
    func select(path: String?) async -> Bool {
        // The file was removed outside the app, so this buffer can no longer
        // be saved to its original path. A new explicit selection is the
        // user's choice to leave that recovery buffer; never flush it here.
        if externalRemovalBanner != nil {
            resetEditorState()
            selectedPath = path
            guard let path else { return true }
            selectionGeneration &+= 1
            await load(path: path, selectionGeneration: selectionGeneration)
            return true
        }

        selectionGeneration &+= 1
        let generation = selectionGeneration
        let didFlush = await flushPendingSave()
        guard generation == selectionGeneration else { return false }
        // A conflict already preserved the user's text in a distinct vault
        // file, so navigation can proceed. Any other failure leaves the
        // original note and its in-memory buffer selected for retry.
        guard didFlush || conflictBanner != nil else { return false }
        selectedPath = path
        conflictBanner = nil
        isAutosaveFrozen = false
        loadError = nil
        saveError = nil
        guard let path else {
            resetEditorState()
            return true
        }
        await load(path: path, selectionGeneration: generation)
        return true
    }

    private func load(path: String, selectionGeneration: Int) async {
        isLoading = true
        do {
            let snapshot = try await repository.read(relativePath: path)
            guard selectedPath == path, selectionGeneration == self.selectionGeneration else { return }
            loadedContent = snapshot.content
            expectedHash = snapshot.sha256
            editedText = snapshot.content
            isDirty = false
            loadError = nil
            isLoading = false
        } catch {
            guard selectedPath == path, selectionGeneration == self.selectionGeneration else { return }
            loadError = NotesError.from(error)
            isLoading = false
        }
    }

    /// Called by the feature coordinator when a reconcile delta touched the
    /// currently selected note. A no-op while dirty — see the type doc.
    func handleExternalChange() async {
        guard let selectedPath, !isDirty else { return }
        await load(path: selectedPath, selectionGeneration: selectionGeneration)
    }

    /// Retargets the editor to a new identity for the same open note (e.g.
    /// it was renamed externally) without discarding in-progress edits.
    func retarget(to newPath: String) {
        selectionGeneration &+= 1
        selectedPath = newPath
    }

    /// Retains a dirty buffer after its source file was removed externally.
    /// Autosave is stopped and future flushes become no-ops, so the deleted
    /// path is never silently recreated. The user can still copy the text or
    /// explicitly select another note.
    func handleExternalRemoval() {
        guard isDirty, let selectedPath else {
            clearSelectionAfterExternalRemoval()
            return
        }
        selectionGeneration &+= 1
        autosaveTask?.cancel()
        autosaveTask = nil
        inFlightSave?.task.cancel()
        inFlightSave = nil
        externalRemovalBanner = ExternalRemovalBanner(formerPath: selectedPath)
        saveError = nil
        conflictBanner = nil
        isAutosaveFrozen = false
    }

    /// Clears an externally removed clean selection without flushing it first.
    /// `select(path: nil)` deliberately flushes normal selection changes, but
    /// doing that after the file was removed would recreate it (or produce a
    /// conflict copy) with an obsolete baseline.
    private func clearSelectionAfterExternalRemoval() {
        selectionGeneration &+= 1
        autosaveTask?.cancel()
        autosaveTask = nil
        inFlightSave?.task.cancel()
        inFlightSave = nil
        selectedPath = nil
        resetEditorState()
    }

    private func resetEditorState() {
        editedText = ""
        loadedContent = ""
        expectedHash = nil
        isDirty = false
        isLoading = false
        loadError = nil
        saveError = nil
        conflictBanner = nil
        externalRemovalBanner = nil
        isAutosaveFrozen = false
    }

    // MARK: - Editing

    func textDidChange(_ newText: String) {
        editedText = newText
        isDirty = newText != loadedContent
        autosaveTask?.cancel()
        guard isDirty, !isAutosaveFrozen, externalRemovalBanner == nil else { return }
        scheduleAutosave()
    }

    private func scheduleAutosave() {
        autosaveTask = Task { [weak self, autosaveDelay] in
            try? await Task.sleep(for: autosaveDelay)
            guard !Task.isCancelled else { return }
            await self?.flushPendingSave()
        }
    }

    func dismissConflictBanner() {
        conflictBanner = nil
    }

    // MARK: - Save

    /// Saves unconditionally if dirty — used for the idle-debounce timer,
    /// selection changes, and view disappear/blur alike.
    @discardableResult
    func flushPendingSave() async -> Bool {
        autosaveTask?.cancel()
        autosaveTask = nil
        guard externalRemovalBanner == nil else { return false }
        guard isDirty, let selectedPath else { return true }
        return await save(path: selectedPath)
    }

    private func save(path: String) async -> Bool {
        if let inFlightSave {
            return await inFlightSave.task.value
        }

        let id = UUID()
        let task = Task { [weak self] in
            guard let self else { return false }
            return await self.performSave(path: path)
        }
        inFlightSave = (id, task)
        let result = await task.value
        if inFlightSave?.id == id {
            inFlightSave = nil
        }
        return result
    }

    private func performSave(path: String) async -> Bool {
        guard !Task.isCancelled else { return false }
        let contentToSave = editedText
        do {
            let summary = try await repository.save(
                relativePath: path,
                content: contentToSave,
                expectedHash: expectedHash
            )
            guard !Task.isCancelled, selectedPath == path else { return false }
            loadedContent = contentToSave
            expectedHash = summary.sha256
            isDirty = editedText != loadedContent
            conflictBanner = nil
            saveError = nil
            isAutosaveFrozen = false
            scheduleAutosaveIfNeeded()
            return true
        } catch let error as NotesError {
            guard !Task.isCancelled, selectedPath == path else { return false }
            if case .externalConflict(let copyPath) = error {
                // Content is intentionally left exactly as the user typed it
                // — the attempted save landed at `copyPath` instead, so
                // nothing here was lost. `expectedHash` is deliberately left
                // stale too: it still names the content this editor actually
                // loaded, not whatever's now on disk.
                conflictBanner = ConflictBanner(copyPath: copyPath)
                isAutosaveFrozen = true
            } else {
                saveError = error
            }
            Self.logger.error("save failed for \(path): \(String(describing: error))")
            return false
        } catch {
            guard !Task.isCancelled, selectedPath == path else { return false }
            saveError = NotesError.from(error)
            return false
        }
    }

    private func scheduleAutosaveIfNeeded() {
        guard isDirty, !isAutosaveFrozen, externalRemovalBanner == nil, autosaveTask == nil else { return }
        scheduleAutosave()
    }
}
