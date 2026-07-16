import Foundation
import Observation

/// Owns the styled-source editor's state for exactly one selected note at a
/// time: the loaded baseline (content + hash), dirty tracking, idle-
/// debounced autosave, and the external-conflict/removal/reconcile banners.
///
/// This is the Phase 2 replacement for the Phase 1 `NoteEditorModel`. The
/// key architectural change: `currentText` is no longer bound through a
/// SwiftUI `Binding` — `NoteEditorView`'s `NSTextView` is the visual source
/// of truth for what's on screen, and only ever calls into
/// `textDidChange(_:)` (one-way, from its delegate). Whenever *this*
/// controller needs to push content into the view instead — initial load, a
/// clean reconcile reload, Take Theirs — it calls `applyText`, a closure the
/// view layer wires up in `makeNSView`. SwiftUI itself never round-trips the
/// full document.
///
/// The critical invariant carried over from Phase 1: `expectedHash` is only
/// ever written by `load` (on select, or a reload of a *clean* note) and
/// `save` (on a successful write). Nothing else — in particular, no external
/// -change notification — is allowed to overwrite it while `isDirty` is
/// true, or an autosave could silently clobber content the editor never saw.
@MainActor
@Observable
final class NoteEditorController {
    struct ConflictBanner: Equatable {
        let copyPath: String
    }

    struct ExternalRemovalBanner: Equatable {
        let formerPath: String
    }

    /// Surfaced when a reconcile delta touches the selected note while it's
    /// dirty. Presented as a non-modal choice bar — see `keepMine()`/
    /// `takeTheirs()`.
    struct ExternalChangeChoice: Equatable {}

    /// The result of one serialized repository save. Keeping the attempted
    /// content with the result lets a later Keep Mine action tell whether a
    /// normal save that was already in progress preserved *its* buffer or an
    /// older one that must not be mistaken for the user's current choice.
    private enum SaveOutcome {
        case succeeded(content: String)
        case externalConflict(content: String, copyPath: String)
        case failed(content: String)

        /// A failed attempt did not preserve anything. A save or conflict
        /// copy only satisfies Keep Mine when it used the buffer captured for
        /// that action; an older in-flight autosave still needs one later
        /// attempt.
        func preserved(content: String) -> Bool {
            switch self {
            case .succeeded(let savedContent), .externalConflict(let savedContent, _):
                return savedContent == content
            case .failed:
                return false
            }
        }

        var didSucceed: Bool {
            if case .succeeded = self { return true }
            return false
        }
    }

    private static let logger = AppLog.make("notes.editor")

    private(set) var selectedPath: String?
    private(set) var currentText: String = ""
    private(set) var isDirty = false
    private(set) var isLoading = false
    private(set) var loadError: NotesError?
    /// Unlike `loadError`, this leaves the editor usable: the current buffer
    /// remains available to copy, edit, and retry after a write failure.
    private(set) var saveError: NotesError?
    private(set) var conflictBanner: ConflictBanner?
    /// The buffer held by `conflictBanner`. A banner only makes it safe to
    /// leave the editor when it preserved the exact text currently on screen.
    private var conflictBannerContent: String?
    private(set) var externalRemovalBanner: ExternalRemovalBanner?
    private(set) var externalChangeChoice: ExternalChangeChoice?
    /// True for the full duration of a `keepMine()`/`takeTheirs()` call.
    /// Guards both methods so only one resolution of `externalChangeChoice`
    /// can run at a time — without this, a second Keep Mine tap while the
    /// first is still suspended on its save/reload could mint a second
    /// conflict copy, and a Take Theirs tap could race the in-flight Keep
    /// Mine into a contradictory final state. Always cleared before the
    /// method returns, including on early guard failures and non-conflict
    /// errors that leave the choice retryable.
    private(set) var isResolvingExternalChange = false
    /// Advances when Keep Mine or Take Theirs takes ownership of an external
    /// change. A normal flush records this before it suspends; if a resolver
    /// ran while it waited, it must stop even after that resolver clears
    /// `isResolvingExternalChange`.
    private var externalChangeResolutionGeneration = 0

    /// Wired up by the view layer (`NoteEditorView`'s `makeNSView`/non-macOS
    /// fallback) so the controller can push freshly loaded content into the
    /// live editor without SwiftUI ever owning the string. `nil` before the
    /// view exists — `load` still updates `currentText` in that case, and
    /// the view reads it once when it's created.
    var applyText: ((String) -> Void)?

    /// Pushed in by `NotesFeatureModel` whenever its catalog changes — the
    /// candidate set for wikilink autocomplete. Kept here (not a reference to
    /// the model itself) so this controller and `NoteEditorView` never import
    /// or depend on `NotesFeatureModel`.
    var candidateNotes: [NoteSummary] = []

    private(set) var wikilinkTrigger: WikilinkCompletion.Trigger?
    private(set) var wikilinkCandidates: [WikilinkCompletion.Candidate] = []
    private(set) var selectedWikilinkCandidateIndex: Int?
    private(set) var wikilinkAnchorRect: CGRect?

    var selectedWikilinkCandidate: WikilinkCompletion.Candidate? {
        guard let selectedWikilinkCandidateIndex,
              wikilinkCandidates.indices.contains(selectedWikilinkCandidateIndex)
        else { return nil }
        return wikilinkCandidates[selectedWikilinkCandidateIndex]
    }

    /// Wired up by the view layer to perform the actual text replacement a
    /// chosen completion needs — on macOS, `NSTextView.insertText(_:
    /// replacementRange:)` (routes through the normal editing/undo pipeline,
    /// so `textDidChange(_:)` fires exactly as it would for typed input); on
    /// the non-macOS `TextEditor` fallback, a plain string replace followed
    /// by an explicit `textDidChange(_:)` call, since there's no live text
    /// view to drive.
    var applyReplacement: ((NSRange, String, Bool) -> Void)?

    private var loadedContent: String = ""
    private var expectedHash: String?
    /// Increments for every selection request so a slow read started for an
    /// older selection cannot overwrite the currently selected note.
    private var selectionGeneration = 0
    /// Increments on every `textDidChange(_:)` call. A clean-note external
    /// reload captures this before its `repository.read` suspends; if the
    /// user types while that read is in flight, the generation no longer
    /// matches on return and the snapshot is discarded instead of clobbering
    /// the edit the read never saw.
    private var editGeneration = 0
    /// Identifies whichever `load` call most recently started. Each `load`
    /// captures its own id and only clears `isLoading` (and this field) if
    /// it still matches when the call finishes — a retarget/reselect that
    /// starts a newer load in the meantime bumps this to a new id, so the
    /// older, now-stale call's completion can never clear the newer load's
    /// spinner.
    private var activeLoadID: UUID?
    /// Set once a save hits a conflict, or an external-change choice is
    /// pending; suppresses further *idle-debounced* autosaves (which would
    /// otherwise mint a fresh conflict copy on every debounce cycle) without
    /// blocking an explicit flush (selection change, disappear) — those
    /// still fire so a last edit is never silently dropped, just possibly
    /// conflicted again.
    private var isAutosaveFrozen = false
    private var autosaveTask: Task<Void, Never>?
    /// A write suspends while it crosses the repository/vault actors. Keep
    /// every concurrent flush attached to that one task so a second
    /// disappearance callback cannot save the same stale hash as a conflict.
    /// A resolver captures this value before it marks itself active, then
    /// awaits that exact task. This gives Keep Mine/Take Theirs stable
    /// ownership of a normal save that began before the external-choice
    /// action, even if another waiter clears the shared slot as it completes.
    private struct InFlightSave {
        let id: UUID
        let task: Task<SaveOutcome, Never>
    }

    private var inFlightSave: InFlightSave?
    /// When reconciliation waits for this app's own save and that save finds
    /// a real external conflict, retain its result for the next choice
    /// action. `keepMine()` can then reuse the copy already made for the
    /// current buffer instead of issuing the same stale-hash save again.
    /// This is set only while `externalChangeChoice` is visible.
    private var pendingExternalChangeSaveOutcome: SaveOutcome?

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
        // Keep Mine / Take Theirs owns this buffer until its save or reload
        // settles. Returning false leaves NotesView's list binding reading
        // the controller/model's existing selection, so the attempted list
        // change naturally reverts without flushing or retargeting the note.
        guard !isResolvingExternalChange else { return false }

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
        // An external removal or active choice resolution may have begun
        // while the flush was suspended. Neither state may be bypassed by a
        // stale conflict banner from an older save attempt.
        guard externalRemovalBanner == nil, !isResolvingExternalChange else { return false }
        // A conflict already preserved the user's text in a distinct vault
        // file, so navigation can proceed. Any other failure leaves the
        // original note and its in-memory buffer selected for retry.
        guard didFlush || hasConflictCopyForCurrentText else { return false }
        selectedPath = path
        clearConflictBanner()
        externalChangeChoice = nil
        pendingExternalChangeSaveOutcome = nil
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

    /// `requireEditGeneration`, when set, is captured by the caller
    /// immediately before this `await`s `repository.read`. If the user types
    /// during that suspension, `editGeneration` no longer matches on return:
    /// the external snapshot is discarded (never applied over the newer
    /// buffer) and an external-change choice is surfaced instead, exactly as
    /// if the edit had arrived a moment earlier. Ordinary loads (selection,
    /// Keep Mine, Take Theirs) pass `nil` and always apply — those are
    /// user-initiated replacements of the buffer, not a race with it.
    /// Returns whether the external snapshot was actually applied, so a
    /// caller holding state open across the read (`keepMine`'s post-conflict
    /// reload) knows whether it's safe to close that state out or must leave
    /// it actionable because a race discarded the snapshot.
    @discardableResult
    private func load(path: String, selectionGeneration: Int, requireEditGeneration: Int? = nil) async -> Bool {
        let loadID = UUID()
        activeLoadID = loadID
        isLoading = true
        do {
            let snapshot = try await repository.read(relativePath: path)
            guard selectedPath == path, selectionGeneration == self.selectionGeneration else {
                finishLoad(loadID)
                return false
            }
            if let requireEditGeneration, requireEditGeneration != editGeneration {
                finishLoad(loadID)
                presentExternalChangeChoiceIfNeeded()
                return false
            }
            loadedContent = snapshot.content
            expectedHash = snapshot.sha256
            currentText = snapshot.content
            isDirty = false
            loadError = nil
            finishLoad(loadID)
            dismissWikilinkCompletion()
            applyText?(snapshot.content)
            return true
        } catch {
            guard selectedPath == path, selectionGeneration == self.selectionGeneration else {
                finishLoad(loadID)
                return false
            }
            if let requireEditGeneration, requireEditGeneration != editGeneration {
                finishLoad(loadID)
                presentExternalChangeChoiceIfNeeded()
                return false
            }
            loadError = NotesError.from(error)
            finishLoad(loadID)
            return false
        }
    }

    /// Clears `isLoading` only if `loadID` still owns it — i.e. no newer
    /// `load` call has started since. A stale call that lost the race must
    /// leave a newer call's spinner alone.
    private func finishLoad(_ loadID: UUID) {
        guard activeLoadID == loadID else { return }
        activeLoadID = nil
        isLoading = false
    }

    private func presentExternalChangeChoiceIfNeeded() {
        guard externalChangeChoice == nil else { return }
        externalChangeChoice = ExternalChangeChoice()
        isAutosaveFrozen = true
        autosaveTask?.cancel()
        autosaveTask = nil
    }

    /// Called by the feature coordinator when a reconcile delta touched the
    /// currently selected note: a clean note reloads immediately; a dirty
    /// note surfaces `externalChangeChoice` instead of silently reloading or
    /// silently ignoring the change, and freezes idle autosave until the
    /// user picks `keepMine()` or `takeTheirs()`.
    func handleExternalChange() async {
        guard let selectedPath else { return }
        // A reconcile delta can be reporting the very write a normal save (or
        // Keep Mine/Take Theirs) already has in flight — the watcher/rescan
        // that produced this delta races that save's own disk write. Join it
        // first so this never mistakes our own in-progress save for a
        // genuine external edit and presents a false Keep Mine/Take Theirs
        // choice on top of a buffer that is (or is about to be) already
        // saved. A successful joined save is its own local change regardless
        // of any newer typing; a conflict still proves a real external edit.
        if let saveAtObservation = inFlightSave {
            let selectionGenerationAtObservation = selectionGeneration
            let outcome = await waitForInFlightSave(saveAtObservation)
            guard self.selectedPath == selectedPath, self.selectionGeneration == selectionGenerationAtObservation else { return }
            // A successful local save is exactly the event this reconcile
            // notification observed. Even if newer typing kept the editor
            // dirty, that is local state that the normal save path will
            // preserve; it is not evidence of an external change.
            if case .succeeded? = outcome { return }
            // A conflict proves there really was an external change. Keep
            // the completed outcome so Keep Mine can reuse its conflict
            // copy instead of creating a duplicate for the same buffer.
            pendingExternalChangeSaveOutcome = outcome
        }
        guard isDirty else {
            // The buffer is clean *right now*, but `repository.read` below
            // suspends — capture the edit generation first so a keystroke
            // that lands during that suspension is never silently clobbered.
            let startEditGeneration = editGeneration
            await load(path: selectedPath, selectionGeneration: selectionGeneration, requireEditGeneration: startEditGeneration)
            return
        }
        presentExternalChangeChoiceIfNeeded()
    }

    /// Resolves a pending `externalChangeChoice` by attempting to save the
    /// in-editor buffer anyway. Since the external content changed, this
    /// save is expected to lose the hash-guard race: the attempted text
    /// lands at a conflict-copy path (never overwriting the external
    /// version), and the editor then reloads the current external content so
    /// it ends up coherent rather than sitting on a stale buffer that would
    /// mint another conflict copy on the next autosave. The rare case where
    /// the save actually succeeds (the external change was reverted before
    /// this ran) is treated as an ordinary successful save.
    ///
    /// Only a confirmed `.externalConflict` means the attempted content was
    /// actually preserved (as the conflict copy) and it's safe to reload —
    /// but only if nothing newer was typed while the save was suspended.
    /// `contentToSave`/`editGenerationAtSave` are captured together right
    /// before the `await`; if `editGeneration` has since moved on, the
    /// conflict copy holds only that older, pre-await buffer, while
    /// `currentText` now holds edits the copy never saw. Reloading in that
    /// case would silently replace the newer buffer with the older conflict
    /// content, so the reload is skipped, the choice is left actionable (the
    /// newer buffer still needs to be resolved separately), and autosave
    /// stays frozen so an idle debounce can't mint a second copy behind it.
    ///
    /// Any other failure — a revoked security scope, disk I/O, etc. — means
    /// nothing was written anywhere: the buffer, dirty state, and the choice
    /// itself are all left in place so the user can retry Keep Mine or fall
    /// back to Take Theirs instead of losing the edit.
    func keepMine() async {
        guard let selectedPath, externalChangeChoice != nil, !isResolvingExternalChange else { return }
        // Capture before exposing the resolving state. The normal flush is
        // already blocked when this action can race it; this exact task is the
        // one Keep Mine is permitted to consume, never a later save.
        let saveAtResolution = inFlightSave
        let observedSaveOutcome = pendingExternalChangeSaveOutcome
        pendingExternalChangeSaveOutcome = nil
        externalChangeResolutionGeneration &+= 1
        isResolvingExternalChange = true
        defer { isResolvingExternalChange = false }
        autosaveTask?.cancel()
        autosaveTask = nil
        let contentToSave = currentText
        let editGenerationAtSave = editGeneration
        let selectionGenerationAtSave = selectionGeneration

        // A normal flush may have begun just before the reconciler presented
        // the choice. Join it first: another stale-hash save here could mint
        // a duplicate conflict copy. If it saved this exact buffer, its
        // result already fulfils Keep Mine. If it saved an older buffer (or
        // simply failed), make one serialized Keep Mine attempt afterward.
        let priorOutcome = await waitForInFlightSave(saveAtResolution) ?? observedSaveOutcome
        guard self.selectedPath == selectedPath, self.selectionGeneration == selectionGenerationAtSave else { return }

        let outcome: SaveOutcome
        if let priorOutcome, priorOutcome.preserved(content: contentToSave) {
            outcome = priorOutcome
        } else if let conflictBanner, conflictBannerContent == contentToSave {
            // An autosave (or another normal flush) can conflict and fully
            // complete — clearing `inFlightSave` and leaving no
            // `pendingExternalChangeSaveOutcome` behind — before the
            // reconciler's notification even reaches `handleExternalChange()`.
            // That earlier attempt already preserved this exact buffer at
            // `conflictBanner.copyPath`; reuse it instead of writing a second,
            // redundant copy of identical content.
            outcome = .externalConflict(content: contentToSave, copyPath: conflictBanner.copyPath)
        } else {
            outcome = await save(
                path: selectedPath,
                content: contentToSave,
                expectedHashOverride: expectedHash
            )
        }

        guard self.selectedPath == selectedPath, self.selectionGeneration == selectionGenerationAtSave else { return }
        switch outcome {
        case .succeeded:
            // The external edit was reverted before the save completed, or
            // the joined normal save already wrote this exact buffer. If the
            // user typed newer text while that was suspended, performSave()
            // left it dirty and this restarts its normal idle autosave.
            saveError = nil
            externalChangeChoice = nil
            isAutosaveFrozen = false
            scheduleAutosaveIfNeeded()

        case .externalConflict(_, let copyPath):
            conflictBanner = ConflictBanner(copyPath: copyPath)
            conflictBannerContent = contentToSave
            guard editGeneration == editGenerationAtSave else {
                // The copy preserved the captured older buffer. Keep the
                // newer typing and leave the choice actionable for it.
                isAutosaveFrozen = true
                return
            }
            // The choice and autosave freeze stay active across this read: if
            // the user types while it is suspended, load() discards the stale
            // snapshot instead of erasing the newer buffer.
            let requireEditGeneration = editGeneration
            let applied = await load(
                path: selectedPath,
                selectionGeneration: self.selectionGeneration,
                requireEditGeneration: requireEditGeneration
            )
            if applied {
                externalChangeChoice = nil
                isAutosaveFrozen = false
            }

        case .failed:
            // performSave() has already retained the error and left the
            // buffer/choice retryable. Do not reload or unfreeze here.
            break
        }
    }

    /// Resolves a pending `externalChangeChoice` by discarding the in-editor
    /// buffer entirely and reloading the external version — never saved.
    func takeTheirs() async {
        guard let selectedPath, externalChangeChoice != nil, !isResolvingExternalChange else { return }
        // See `keepMine()`: retain the normal save that predates this choice
        // before other waiters can clean up the shared slot.
        let saveAtResolution = inFlightSave
        pendingExternalChangeSaveOutcome = nil
        externalChangeResolutionGeneration &+= 1
        isResolvingExternalChange = true
        defer { isResolvingExternalChange = false }
        autosaveTask?.cancel()
        autosaveTask = nil
        let editGenerationAtResolution = editGeneration
        let selectionGenerationAtResolution = selectionGeneration
        // Do not race a normal save that was already suspended when the
        // choice appeared. Its conflict copy (if any) is the only write Take
        // Theirs permits; after it settles this action only performs a
        // guarded replacement read.
        _ = await waitForInFlightSave(saveAtResolution)
        guard self.selectedPath == selectedPath, self.selectionGeneration == selectionGenerationAtResolution else { return }
        // Keep the choice visible and frozen until the replacement actually
        // lands. Besides preserving a useful busy state for the disabled
        // buttons, this makes a failed or stale reload retryable instead of
        // leaving the user with no way to resolve the conflict.
        let applied = await load(
            path: selectedPath,
            selectionGeneration: selectionGeneration,
            requireEditGeneration: editGenerationAtResolution
        )
        guard applied else { return }
        externalChangeChoice = nil
        isAutosaveFrozen = false
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
        clearConflictBanner()
        externalChangeChoice = nil
        pendingExternalChangeSaveOutcome = nil
        isAutosaveFrozen = false
    }

    /// Clears an externally removed clean selection without flushing it
    /// first. `select(path: nil)` deliberately flushes normal selection
    /// changes, but doing that after the file was removed would recreate it
    /// (or produce a conflict copy) with an obsolete baseline.
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
        currentText = ""
        loadedContent = ""
        expectedHash = nil
        isDirty = false
        activeLoadID = nil
        isLoading = false
        loadError = nil
        saveError = nil
        clearConflictBanner()
        externalRemovalBanner = nil
        externalChangeChoice = nil
        pendingExternalChangeSaveOutcome = nil
        isAutosaveFrozen = false
        dismissWikilinkCompletion()
        applyText?("")
    }

    // MARK: - Editing

    /// Called one-way from the live editor (the `NSTextView` delegate on
    /// macOS, or the non-macOS fallback's `Binding` setter) whenever the
    /// user's text changes. Never called by this controller itself when
    /// pushing content the other direction — see `applyText`.
    func textDidChange(_ newText: String) {
        editGeneration &+= 1
        currentText = newText
        isDirty = newText != loadedContent
        autosaveTask?.cancel()
        guard isDirty, !isAutosaveFrozen, externalRemovalBanner == nil, externalChangeChoice == nil else { return }
        scheduleAutosave()
    }

    // MARK: - Wikilink autocomplete

    /// Called by the view layer after every text change (and cursor move, on
    /// platforms that report one) with the live text and cursor location.
    /// Pure detection lives in `WikilinkCompletion`; this just recomputes the
    /// observable state from it, excluding the currently open note from the
    /// candidate list.
    func updateWikilinkCompletion(text: String, cursorLocation: Int) {
        guard let trigger = WikilinkCompletion.trigger(in: text, cursorLocation: cursorLocation) else {
            dismissWikilinkCompletion()
            return
        }
        wikilinkTrigger = trigger
        let candidates = WikilinkCompletion.rankedCandidates(
            query: trigger.query, notes: candidateNotes, excluding: selectedPath
        )
        if candidates != wikilinkCandidates {
            selectedWikilinkCandidateIndex = WikilinkCompletionSelection.reset(candidateCount: candidates.count)
        }
        wikilinkCandidates = candidates
    }

    func dismissWikilinkCompletion() {
        wikilinkTrigger = nil
        wikilinkCandidates = []
        selectedWikilinkCandidateIndex = nil
        wikilinkAnchorRect = nil
    }

    func moveWikilinkCompletionSelection(_ direction: WikilinkCompletionSelection.Direction) {
        selectedWikilinkCandidateIndex = WikilinkCompletionSelection.move(
            direction,
            from: selectedWikilinkCandidateIndex,
            candidateCount: wikilinkCandidates.count
        )
    }

    func updateWikilinkAnchorRect(_ rect: CGRect?) {
        wikilinkAnchorRect = rect
    }

    /// Resolves the pending trigger against a chosen candidate, returning the
    /// exact replacement and final cursor placement the view should apply to
    /// the live text view. The replacement closes an unclosed link, but may
    /// reuse a closing pair already immediately after the cursor; in that
    /// case the view must move the cursor past the existing pair so completion
    /// does not immediately reopen. Returns `nil` if there's no longer a
    /// pending trigger (e.g. the view raced a dismiss).
    func acceptWikilinkCompletion(_ candidate: WikilinkCompletion.Candidate) -> (range: NSRange, replacement: String, reusesTrailingClosingBrackets: Bool)? {
        guard let trigger = wikilinkTrigger else { return nil }
        dismissWikilinkCompletion()
        let replacement = WikilinkCompletion.completionText(
            for: candidate.note,
            closingBracketsAlreadyPresent: trigger.hasTrailingClosingBrackets
        )
        return (trigger.queryRange, replacement, trigger.hasTrailingClosingBrackets)
    }

    private func scheduleAutosave() {
        autosaveTask = Task { [weak self, autosaveDelay] in
            try? await Task.sleep(for: autosaveDelay)
            guard !Task.isCancelled else { return }
            await self?.flushPendingSave()
        }
    }

    func dismissConflictBanner() {
        clearConflictBanner()
    }

    // MARK: - Save

    /// Saves unconditionally if dirty — used for the idle-debounce timer,
    /// selection changes, and view disappear/blur alike.
    @discardableResult
    func flushPendingSave() async -> Bool {
        // A resolution owns the pending choice's buffer. Selection and view
        // disappearance both call this method, so this one guard prevents
        // either lifecycle path from creating a parallel stale-hash write.
        guard !isResolvingExternalChange else { return false }
        autosaveTask?.cancel()
        autosaveTask = nil
        guard externalRemovalBanner == nil else { return false }
        guard isDirty, let selectedPath else { return true }
        if conflictBanner != nil {
            // An earlier conflict may have preserved a buffer the user has
            // since changed. It cannot authorize a later ordinary failure;
            // only an exact-text copy satisfies this explicit flush.
            if !hasConflictCopyForCurrentText {
                clearConflictBanner()
                isAutosaveFrozen = false
            }
            if hasConflictCopyForCurrentText { return false }
        }
        let selectionGenerationAtFlush = selectionGeneration
        let resolutionGenerationAtFlush = externalChangeResolutionGeneration

        // A joined save can be for an older buffer. For an explicit flush we
        // must not let that outcome authorize navigation until the buffer
        // currently on screen has itself reached disk (or its own conflict
        // copy). Each pass captures both pieces of write state before its
        // suspension; if typing advances while the save is in flight, the
        // next pass serially saves the newer buffer with the then-current
        // expected hash.
        while true {
            guard !isResolvingExternalChange,
                  externalChangeResolutionGeneration == resolutionGenerationAtFlush,
                  externalRemovalBanner == nil,
                  self.selectedPath == selectedPath,
                  self.selectionGeneration == selectionGenerationAtFlush,
                  isDirty
            else { return false }

            let contentToPreserve = currentText
            let expectedHashAtSave = expectedHash
            let outcome = await save(
                path: selectedPath,
                content: contentToPreserve,
                expectedHashOverride: expectedHashAtSave
            )

            guard !isResolvingExternalChange,
                  externalChangeResolutionGeneration == resolutionGenerationAtFlush,
                  externalRemovalBanner == nil,
                  self.selectedPath == selectedPath,
                  self.selectionGeneration == selectionGenerationAtFlush
            else { return false }

            let preservedCapturedContent = outcome.preserved(content: contentToPreserve)
            let failedCapturedContent: Bool
            if case .failed(let failedContent) = outcome {
                failedCapturedContent = failedContent == contentToPreserve
            } else {
                failedCapturedContent = false
            }

            // A joined save can return an older outcome even when the current
            // text still matches this pass's capture. Only an ordinary failure
            // for this exact capture is final without preserving it.
            guard (preservedCapturedContent || failedCapturedContent),
                  currentText == contentToPreserve
            else {
                // Do not leave a copy for an older outcome actionable: a
                // conflict banner may authorize selection only for its exact
                // preserved buffer.
                if case .externalConflict(let conflictContent, _) = outcome,
                   conflictBannerContent == conflictContent {
                    clearConflictBanner()
                    isAutosaveFrozen = false
                }
                // The preceding `await save` serializes every retry. This
                // loop never busy-spins; each pass awaits a save/join before
                // deciding whether another newer buffer needs preservation.
                continue
            }

            switch outcome {
            case .succeeded:
                // `currentText` is exactly `contentToPreserve`, so this
                // success wrote the current buffer rather than an older one.
                return true
            case .externalConflict:
                // The exact current buffer is safely in the copy. Return
                // false so `select` uses its existing banner-based path.
                return false
            case .failed:
                // Nothing preserved this exact buffer; retain the selection
                // and editable text for an explicit retry.
                return false
            }
        }
    }

    /// Waits for the single in-flight normal save and clears its slot only if
    /// it still owns it. Any caller may perform this cleanup, which avoids a
    /// completed task lingering long enough for a subsequent Keep Mine retry
    /// to accidentally join the old result again.
    private func waitForInFlightSave(_ capturedSave: InFlightSave? = nil) async -> SaveOutcome? {
        if let save = capturedSave ?? inFlightSave {
            let outcome = await save.task.value
            if self.inFlightSave?.id == save.id {
                self.inFlightSave = nil
            }
            return outcome
        }
        return nil
    }

    /// Starts one repository save, or joins an already-running save. Callers
    /// that need a particular captured buffer must wait first, then call this
    /// with that buffer once the earlier task has settled.
    private func save(path: String, content: String? = nil, expectedHashOverride: String? = nil) async -> SaveOutcome {
        if let outcome = await waitForInFlightSave() {
            return outcome
        }

        let contentToSave = content ?? currentText
        let expectedHashAtSave = expectedHashOverride ?? self.expectedHash
        let id = UUID()
        let task: Task<SaveOutcome, Never> = Task { [weak self] in
            guard let self else { return SaveOutcome.failed(content: contentToSave) }
            return await self.performSave(
                path: path,
                content: contentToSave,
                expectedHashAtSave: expectedHashAtSave
            )
        }
        inFlightSave = InFlightSave(id: id, task: task)
        let outcome = await task.value
        if inFlightSave?.id == id {
            inFlightSave = nil
        }
        return outcome
    }

    private func performSave(path: String, content: String, expectedHashAtSave: String?) async -> SaveOutcome {
        guard !Task.isCancelled else { return .failed(content: content) }
        do {
            let summary = try await repository.save(
                relativePath: path,
                content: content,
                expectedHash: expectedHashAtSave
            )
            guard !Task.isCancelled, selectedPath == path else { return .failed(content: content) }
            loadedContent = content
            self.expectedHash = summary.sha256
            isDirty = currentText != loadedContent
            clearConflictBanner()
            saveError = nil
            if externalChangeChoice == nil {
                isAutosaveFrozen = false
            }
            scheduleAutosaveIfNeeded()
            return .succeeded(content: content)
        } catch let error as NotesError {
            guard !Task.isCancelled, selectedPath == path else { return .failed(content: content) }
            if case .externalConflict(let copyPath) = error {
                // Content is intentionally left exactly as the user typed it
                // — the attempted save landed at `copyPath` instead, so
                // nothing here was lost. `expectedHash` is deliberately left
                // stale too: it still names the content this editor actually
                // loaded, not whatever's now on disk.
                conflictBanner = ConflictBanner(copyPath: copyPath)
                conflictBannerContent = content
                isAutosaveFrozen = true
                Self.logger.error("save failed for \(path): \(String(describing: error))")
                return .externalConflict(content: content, copyPath: copyPath)
            } else {
                saveError = error
            }
            Self.logger.error("save failed for \(path): \(String(describing: error))")
            return .failed(content: content)
        } catch {
            guard !Task.isCancelled, selectedPath == path else { return .failed(content: content) }
            saveError = NotesError.from(error)
            return .failed(content: content)
        }
    }

    private func scheduleAutosaveIfNeeded() {
        guard isDirty, !isAutosaveFrozen, externalRemovalBanner == nil, externalChangeChoice == nil, autosaveTask == nil else { return }
        scheduleAutosave()
    }

    private var hasConflictCopyForCurrentText: Bool {
        conflictBanner != nil && conflictBannerContent == currentText
    }

    private func clearConflictBanner() {
        conflictBanner = nil
        conflictBannerContent = nil
    }
}

/// Pure, bounded selection policy for wikilink completion keyboard handling.
/// Keeping indices out of the view makes result changes and empty lists safe.
enum WikilinkCompletionSelection {
    enum Direction {
        case up
        case down
    }

    static func reset(candidateCount: Int) -> Int? {
        candidateCount > 0 ? 0 : nil
    }

    static func move(_ direction: Direction, from selectedIndex: Int?, candidateCount: Int) -> Int? {
        guard candidateCount > 0 else { return nil }
        guard let selectedIndex, (0..<candidateCount).contains(selectedIndex) else { return 0 }

        switch direction {
        case .up:
            return max(0, selectedIndex - 1)
        case .down:
            return min(candidateCount - 1, selectedIndex + 1)
        }
    }
}
