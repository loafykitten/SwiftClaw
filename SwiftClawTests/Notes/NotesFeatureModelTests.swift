import Foundation
import Testing
@testable import SwiftClaw

/// Redirects `.applicationSupportDirectory` to an isolated temp root so
/// `VaultConfigurationStore`'s app-managed vault/revisions paths never touch
/// the real `~/Library/Application Support` during tests.
private nonisolated final class TempApplicationSupportFileManager: FileManager, @unchecked Sendable {
    let tempRoot: URL

    init(tempRoot: URL) {
        self.tempRoot = tempRoot
        super.init()
    }

    override func urls(for directory: FileManager.SearchPathDirectory, in domainMask: FileManager.SearchPathDomainMask) -> [URL] {
        directory == .applicationSupportDirectory ? [tempRoot] : super.urls(for: directory, in: domainMask)
    }
}

/// Focused non-UI coverage for `NotesFeatureModel`'s configuration-state
/// transitions: onboarding gating, app-managed/external vault setup,
/// vault-change `vaultID` regeneration, and reset never touching note files.
///
/// Serialized because several tests exercise the shared feature lifecycle
/// and timing-sensitive configuration generation guards.
@Suite(.serialized)
@MainActor
struct NotesFeatureModelTests {
    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeModel(
        defaults: UserDefaults,
        vaultOperationLeases: VaultOperationLeaseCoordinator? = nil
    ) throws -> NotesFeatureModel {
        try makeModel(
            defaults: defaults,
            appSupportRoot: makeTempDirectory(),
            vaultOperationLeases: vaultOperationLeases
        )
    }

    /// Shares `appSupportRoot` across two model instances — simulating a
    /// second `NotesFeatureModel` (a cold-relaunch stand-in) resolving the
    /// same already-onboarded app-managed vault the first one created.
    private func makeModel(
        defaults: UserDefaults,
        appSupportRoot: URL,
        vaultOperationLeases: VaultOperationLeaseCoordinator? = nil
    ) throws -> NotesFeatureModel {
        let fileManager = TempApplicationSupportFileManager(tempRoot: appSupportRoot)
        let configurationStore = VaultConfigurationStore(
            userDefaults: defaults,
            fileManager: fileManager,
            hasUbiquityEntitlement: { false }
        )
        let bookmarkStore = SecurityScopedBookmarkStore(userDefaults: defaults)
        return NotesFeatureModel(
            configurationStore: configurationStore,
            bookmarkStore: bookmarkStore,
            userDefaults: defaults,
            fileManager: fileManager,
            vaultOperationLeases: vaultOperationLeases
        )
    }

    @Test func activatingWithNoPriorOnboardingNeedsOnboardingAndTouchesNoVault() async throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        let model = try makeModel(defaults: fixture.defaults)

        await model.activate()

        #expect(model.configurationState == .needsOnboarding)
        #expect(model.repository == nil)
    }

    @Test func choosingAnAppManagedVaultConfiguresAnEmptyRepositoryAndPersistsOnboarding() async throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        let model = try makeModel(defaults: fixture.defaults)

        await model.chooseAppManagedVault()

        #expect(model.configurationState == .configured)
        #expect(model.repository?.notes.isEmpty == true)
        #expect(fixture.defaults.bool(forKey: SettingsKeys.notesHasCompletedOnboarding))
        #expect(SettingsStorage.loadNotesVaultLocation(userDefaults: fixture.defaults) == .appManaged)
    }

    @Test func revisionRestoreUpdatesTheVisibleCatalogWithoutReplacingTheLiveNote() async throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        let model = try makeModel(defaults: fixture.defaults)
        await model.chooseAppManagedVault()
        let repository = try #require(model.repository)
        let created = try await repository.createExactPath(relativePath: "note.md", content: "original")
        _ = try await repository.save(relativePath: "note.md", content: "current", expectedHash: created.sha256)
        let revision = try #require(try await model.revisions(forRelativePath: "note.md").first)

        let restored = try await model.restoreRevisionAsConflictCopy(
            relativePath: "note.md",
            revisionID: revision.id
        )

        #expect(model.notes.contains { $0.relativePath == restored.relativePath })
        #expect(try await repository.read(relativePath: restored.relativePath).content == "original")
        #expect(try await repository.read(relativePath: "note.md").content == "current")
    }

    @Test func choosingAnExternalFolderSavesABookmarkAndConfigures() async throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        let model = try makeModel(defaults: fixture.defaults)
        let externalFolder = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: externalFolder) }

        await model.chooseExternalVault(url: externalFolder)

        #expect(model.configurationState == .configured)
        guard case .external(let bookmarkKey) = SettingsStorage.loadNotesVaultLocation(userDefaults: fixture.defaults) else {
            Issue.record("Expected an external vault location")
            return
        }
        #expect(fixture.defaults.data(forKey: bookmarkKey) != nil)
        // Compare by last path component, not the full resolved path: a
        // bookmark resolves through `/private/var/...` while
        // `resolvingSymlinksInPath()` on the un-bookmarked URL stops at
        // `/var/...` — the same `/var` vs `/private/var` temp-dir symlink
        // gotcha `FSEventStreamMonitorTests` already works around.
        #expect(model.stats.resolvedPath?.hasSuffix(externalFolder.lastPathComponent) == true)
    }

    @Test func changingFromAppManagedToExternalRegeneratesTheVaultID() async throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        let model = try makeModel(defaults: fixture.defaults)
        let externalFolder = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: externalFolder) }

        await model.chooseAppManagedVault()
        let firstVaultID = model.configurationStore.vaultID

        await model.chooseExternalVault(url: externalFolder)
        let secondVaultID = model.configurationStore.vaultID

        #expect(firstVaultID != secondVaultID)
    }

    @Test func replacingAnExternalVaultThatCouldNotBeReopenedCleansItsStaleBookmark() async throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        let model = try makeModel(defaults: fixture.defaults)
        let staleBookmarkKey = "notes.vault.bookmark.stale"
        fixture.defaults.set(Data([0x00]), forKey: staleBookmarkKey)
        SettingsStorage.saveNotesVaultLocation(.external(bookmarkKey: staleBookmarkKey), userDefaults: fixture.defaults)
        fixture.defaults.set(true, forKey: SettingsKeys.notesHasCompletedOnboarding)

        await model.activate()
        await model.chooseAppManagedVault()

        #expect(model.configurationState == .configured)
        #expect(fixture.defaults.data(forKey: staleBookmarkKey) == nil)
    }

    @Test func creatingANoteThenResettingLeavesTheFileOnDiskButDisconnectsConfiguration() async throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        let model = try makeModel(defaults: fixture.defaults)

        await model.chooseAppManagedVault()
        await model.createNote()
        let resolvedPath = try #require(model.stats.resolvedPath)
        let originalVaultID = model.configurationStore.vaultID
        #expect(model.stats.noteCount == 1)

        await model.resetVaultConfiguration()

        #expect(model.configurationState == .needsOnboarding)
        #expect(model.repository == nil)
        #expect(model.configurationStore.vaultID != originalVaultID)
        #expect(!fixture.defaults.bool(forKey: SettingsKeys.notesHasCompletedOnboarding))
        // The note file itself is never deleted by a reset.
        let entries = try FileManager.default.contentsOfDirectory(atPath: resolvedPath)
        #expect(entries.contains { $0.hasSuffix(".md") })
    }

    @Test func resetKeepsTheExternalBookmarkUntilAnActiveVaultLeaseDrains() async throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        let leaseCoordinator = VaultOperationLeaseCoordinator()
        let model = try makeModel(defaults: fixture.defaults, vaultOperationLeases: leaseCoordinator)
        let externalFolder = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: externalFolder) }
        fixture.defaults.set(true, forKey: SettingsKeys.notesEnabled)

        await model.chooseExternalVault(url: externalFolder)
        guard case .external(let bookmarkKey) = SettingsStorage.loadNotesVaultLocation(userDefaults: fixture.defaults) else {
            Issue.record("Expected an external vault location")
            return
        }
        let lease = try #require(model.acquireVaultOperationLease(expectedVaultID: model.configurationStore.vaultID))

        let resetTask = Task {
            await model.resetVaultConfiguration()
        }
        await leaseCoordinator.waitUntilTeardownStarted()

        // The reset has begun but is waiting for the held operation lease, so
        // the bookmark the old vault resolves per operation must remain valid.
        #expect(fixture.defaults.data(forKey: bookmarkKey) != nil)

        lease.release()
        _ = await resetTask.value

        #expect(fixture.defaults.data(forKey: bookmarkKey) == nil)
    }

    @Test func configuredModelCannotGrantAVaultOperationLeaseAfterNotesIsDisabled() async throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        fixture.defaults.set(true, forKey: SettingsKeys.notesEnabled)
        let model = try makeModel(defaults: fixture.defaults)

        await model.chooseAppManagedVault()
        let configuredVaultID = model.configurationStore.vaultID
        fixture.defaults.set(false, forKey: SettingsKeys.notesEnabled)

        #expect(model.acquireVaultOperationLease(expectedVaultID: configuredVaultID) == nil)
    }

    @Test func createNoteFailureSurfacesAsAListErrorRatherThanSilently() async throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        let model = try makeModel(defaults: fixture.defaults)

        await model.chooseAppManagedVault()
        let resolvedPath = try #require(model.stats.resolvedPath)
        // Make the vault root unwritable so every create attempt fails —
        // `lastConfigurationError` (vault setup) must stay untouched, and the
        // failure must land somewhere the `.configured` UI actually shows it.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: resolvedPath)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: resolvedPath) }

        await model.createNote()

        #expect(model.notes.isEmpty)
        #expect(model.lastListError != nil)
        #expect(model.lastConfigurationError == nil)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: resolvedPath)
        await model.createNote()

        #expect(model.notes.count == 1)
        #expect(model.lastListError == nil)
    }

    @Test func switchingVaultsClearsAStaleListErrorFromThePreviousVault() async throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        let model = try makeModel(defaults: fixture.defaults)
        let externalFolder = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: externalFolder) }

        await model.chooseAppManagedVault()
        let resolvedPath = try #require(model.stats.resolvedPath)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: resolvedPath)
        await model.createNote()
        #expect(model.lastListError != nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: resolvedPath)

        await model.chooseExternalVault(url: externalFolder)

        #expect(model.lastListError == nil)
    }

    @Test func resettingVaultConfigurationClearsAStaleListError() async throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        let model = try makeModel(defaults: fixture.defaults)

        await model.chooseAppManagedVault()
        let resolvedPath = try #require(model.stats.resolvedPath)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: resolvedPath)
        await model.createNote()
        #expect(model.lastListError != nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: resolvedPath)

        await model.resetVaultConfiguration()

        #expect(model.lastListError == nil)
    }

    @Test func staleReconcilerDeltaCannotMutateANewVaultRepository() async throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        let model = try makeModel(defaults: fixture.defaults)
        let externalFolder = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: externalFolder) }
        try Data("new vault note".utf8).write(to: externalFolder.appendingPathComponent("new.md"))

        await model.chooseAppManagedVault()
        await model.chooseExternalVault(url: externalFolder)
        #expect(model.repository?.summary(forRelativePath: "new.md") != nil)

        // A callback retained by the old reconciler must be ignored after the
        // vault switch, even if it resumes after the new repository is ready.
        await model.handle(
            delta: .init(added: [], modified: [], removed: ["new.md"], renamedPairs: []),
            fromConfigurationGeneration: .max
        )

        #expect(model.repository?.summary(forRelativePath: "new.md") != nil)
    }

    @Test func activationReferenceCountingBalancesRepeatedViewLifecycleCalls() async throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        let model = try makeModel(defaults: fixture.defaults)

        await model.activate()
        await model.activate()
        #expect(model.activeCount == 2)

        model.deactivate()
        #expect(model.activeCount == 1)
        model.deactivate()
        model.deactivate()
        #expect(model.activeCount == 0)
    }

    @Test func selectingANoteThroughTheModelDrivesItsEditor() async throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        let model = try makeModel(defaults: fixture.defaults)

        await model.chooseAppManagedVault()
        await model.createNote()
        let path = try #require(model.selectedPath)

        #expect(model.editor?.selectedPath == path)
        #expect(model.editor?.currentText == "")
    }

    @Test func rebuildingIndexLeavesTheOpenDirtyEditorUntouched() async throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        let model = try makeModel(defaults: fixture.defaults)

        await model.chooseAppManagedVault()
        await model.createNote()
        let selectedPath = try #require(model.selectedPath)
        let editor = try #require(model.editor)
        editor.textDidChange("in-progress edit")

        await model.rebuildIndex()

        #expect(model.selectedPath == selectedPath)
        #expect(model.editor === editor)
        #expect(editor.selectedPath == selectedPath)
        #expect(editor.currentText == "in-progress edit")
        #expect(editor.isDirty)
    }

    @Test func externallyRemovedSelectedNoteRetainsDirtyEditsWithoutRecreatingIt() async throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        let model = try makeModel(defaults: fixture.defaults)

        await model.chooseAppManagedVault()
        await model.createNote()
        let selectedPath = try #require(model.selectedPath)
        let vaultRoot = URL(fileURLWithPath: try #require(model.stats.resolvedPath))
        model.editor?.textDidChange("unsaved edit")
        try FileManager.default.removeItem(at: vaultRoot.appendingPathComponent(selectedPath))

        await model.handle(delta: .init(added: [], modified: [], removed: [selectedPath], renamedPairs: []))

        #expect(model.selectedPath == selectedPath)
        #expect(model.editor?.selectedPath == selectedPath)
        #expect(model.editor?.currentText == "unsaved edit")
        #expect(model.editor?.isDirty == true)
        #expect(model.editor?.externalRemovalBanner?.formerPath == selectedPath)
        #expect(!(await model.editor?.flushPendingSave() ?? true))
        #expect(model.repository?.summary(forRelativePath: selectedPath) == nil)
        #expect(!FileManager.default.fileExists(atPath: vaultRoot.appendingPathComponent(selectedPath).path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: vaultRoot.path).filter { $0.hasSuffix(".md") }.isEmpty)
    }

    @Test func externallyRemovedCleanSelectedNoteClearsSelectionWithoutRecreatingIt() async throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        let model = try makeModel(defaults: fixture.defaults)

        await model.chooseAppManagedVault()
        await model.createNote()
        let selectedPath = try #require(model.selectedPath)
        let vaultRoot = URL(fileURLWithPath: try #require(model.stats.resolvedPath))
        try FileManager.default.removeItem(at: vaultRoot.appendingPathComponent(selectedPath))

        await model.handle(delta: .init(added: [], modified: [], removed: [selectedPath], renamedPairs: []))

        #expect(model.selectedPath == nil)
        #expect(model.editor?.selectedPath == nil)
        #expect(model.editor?.currentText == "")
        #expect(model.repository?.summary(forRelativePath: selectedPath) == nil)
        #expect(!FileManager.default.fileExists(atPath: vaultRoot.appendingPathComponent(selectedPath).path))
    }

    @Test func externalNonSelectedCatalogChangesPublishToTheFeatureModel() async throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        let model = try makeModel(defaults: fixture.defaults)

        await model.chooseAppManagedVault()
        await model.createNote()
        let selectedPath = try #require(model.selectedPath)
        let vaultRoot = URL(fileURLWithPath: try #require(model.stats.resolvedPath))

        try Data("added externally".utf8).write(to: vaultRoot.appendingPathComponent("other.md"))
        await model.handle(delta: .init(added: ["other.md"], modified: [], removed: [], renamedPairs: []))
        #expect(model.notes.map(\.relativePath) == [selectedPath, "other.md"].sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        })
        #expect(model.stats.noteCount == 2)

        try FileManager.default.moveItem(
            at: vaultRoot.appendingPathComponent("other.md"),
            to: vaultRoot.appendingPathComponent("renamed.md")
        )
        await model.handle(delta: .init(
            added: [],
            modified: [],
            removed: [],
            renamedPairs: [.init(from: "other.md", to: "renamed.md")]
        ))
        #expect(model.notes.map(\.relativePath) == [selectedPath, "renamed.md"].sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        })
        #expect(model.stats.noteCount == 2)

        try FileManager.default.removeItem(at: vaultRoot.appendingPathComponent("renamed.md"))
        await model.handle(delta: .init(added: [], modified: [], removed: ["renamed.md"], renamedPairs: []))
        #expect(model.notes.map(\.relativePath) == [selectedPath])
        #expect(model.stats.noteCount == 1)
    }

    /// Regression: `NotesSettingsView`'s stats (`stats.locationDescription`,
    /// `stats.noteCount`) must not depend on the 300s periodic rescan or an
    /// FSEvents hint ever arriving. Files added directly on disk (mirroring
    /// externally seeded fixtures) are invisible to the model until
    /// `refreshCatalog()` runs — proving the count genuinely comes from a
    /// fresh scan, not a stale in-memory value — and afterward both the
    /// note count and the external/app-managed label reflect current state.
    @Test func refreshCatalogPicksUpExternallyAddedNotesAndKeepsTheExternalLabelCorrect() async throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        let model = try makeModel(defaults: fixture.defaults)
        let externalFolder = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: externalFolder) }
        try Data("first".utf8).write(to: externalFolder.appendingPathComponent("First.md"))

        await model.chooseExternalVault(url: externalFolder)
        #expect(model.stats.noteCount == 1)
        #expect(model.stats.locationDescription == "External folder")

        for name in ["Second.md", "Third.md", "Fourth.md", "Fifth.md", "Sixth.md", "Seventh.md"] {
            try Data("seeded externally".utf8).write(to: externalFolder.appendingPathComponent(name))
        }
        // No `handle(delta:)`/rescan happened yet — the catalog must still
        // reflect only the note present at configure time.
        #expect(model.stats.noteCount == 1)

        await model.refreshCatalog()

        #expect(model.stats.noteCount == 7)
        #expect(model.stats.locationDescription == "External folder")
    }

    @Test func existingNotesAreSearchableImmediatelyAfterInitialVaultConfiguration() async throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        let model = try makeModel(defaults: fixture.defaults)
        let externalFolder = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: externalFolder) }
        try Data("A note about narwhals.".utf8).write(to: externalFolder.appendingPathComponent("Note.md"))

        // The external vault already has a note on disk before it's ever
        // configured — `configure(location:)` must populate the index from
        // the initial catalog, not only from later reconcile deltas.
        await model.chooseExternalVault(url: externalFolder)

        model.setSearchQuery("narwhals")
        try? await Task.sleep(for: .milliseconds(400))

        #expect(model.searchResults.map(\.document.sourceID) == ["Note.md"])
    }

    @Test func settingSearchQueryToEmptyClearsResultsImmediately() async throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        let model = try makeModel(defaults: fixture.defaults)
        await model.chooseAppManagedVault()

        model.setSearchQuery("anything")
        model.setSearchQuery("")

        #expect(model.searchResults.isEmpty)
        #expect(model.isSearching == false)
        #expect(model.searchQuery == "")
    }

    @Test func staleSearchFromAPreviousVaultCannotPopulateResultsAfterAVaultSwitch() async throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        let model = try makeModel(defaults: fixture.defaults)
        let externalFolder = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: externalFolder) }

        await model.chooseAppManagedVault()
        let vaultRoot = URL(fileURLWithPath: try #require(model.stats.resolvedPath))
        try Data("alpha content".utf8).write(to: vaultRoot.appendingPathComponent("Note.md"))
        await model.handle(delta: .init(added: ["Note.md"], modified: [], removed: [], renamedPairs: []))

        model.setSearchQuery("alpha")
        // The vault switch tears down and reconfigures before the debounced
        // search below ever resumes — its result must be discarded rather
        // than landing in the new (empty) vault's `searchResults`.
        await model.chooseExternalVault(url: externalFolder)
        try? await Task.sleep(for: .milliseconds(400))

        #expect(model.searchResults.isEmpty)
    }

    @Test func selectingANoteRefreshesBacklinksFromLinkingNotes() async throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        let model = try makeModel(defaults: fixture.defaults)

        await model.chooseAppManagedVault()
        let vaultRoot = URL(fileURLWithPath: try #require(model.stats.resolvedPath))
        try Data("Target note".utf8).write(to: vaultRoot.appendingPathComponent("Target.md"))
        try Data("Links to [[Target]].".utf8).write(to: vaultRoot.appendingPathComponent("Source.md"))
        await model.handle(delta: .init(added: ["Target.md", "Source.md"], modified: [], removed: [], renamedPairs: []))

        await model.select(path: "Target.md")

        #expect(model.backlinks.map(\.sourcePath) == ["Source.md"])
    }

    /// `ChatCompletionService`/`ToolsView` call this before a Notes UI has
    /// ever been opened this launch — it must bootstrap an already-onboarded
    /// vault so `search_notes`/`read_note` are available without requiring
    /// the user to open Notes first, and must never bump `activeCount` (that
    /// stays tied to `activate()`/`deactivate()`).
    @Test func prepareReadToolsBootstrapsAnOnboardedVaultWithoutIncrementingActiveCount() async throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        let appSupportRoot = try makeTempDirectory()
        let bootstrapModel = try makeModel(defaults: fixture.defaults, appSupportRoot: appSupportRoot)
        await bootstrapModel.chooseAppManagedVault()
        fixture.defaults.set(true, forKey: SettingsKeys.notesEnabled)

        // A separate model instance stands in for a fresh launch: same
        // persisted settings/on-disk vault, but its own in-memory state that
        // has never called `activate()`.
        let model = try makeModel(defaults: fixture.defaults, appSupportRoot: appSupportRoot)
        #expect(model.isAvailableForReadTools == false)

        await model.prepareReadToolsIfNeeded()

        #expect(model.configurationState == .configured)
        #expect(model.isAvailableForReadTools == true)
        #expect(model.activeCount == 0)
    }

    /// Disabled Notes must never appear configured, even after preparation —
    /// `prepareReadToolsIfNeeded` skips the bootstrap entirely rather than
    /// configuring a vault the user has turned off.
    @Test func prepareReadToolsLeavesDisabledNotesUnconfigured() async throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        let appSupportRoot = try makeTempDirectory()
        let bootstrapModel = try makeModel(defaults: fixture.defaults, appSupportRoot: appSupportRoot)
        await bootstrapModel.chooseAppManagedVault()
        fixture.defaults.set(false, forKey: SettingsKeys.notesEnabled)

        let model = try makeModel(defaults: fixture.defaults, appSupportRoot: appSupportRoot)
        await model.prepareReadToolsIfNeeded()

        #expect(model.configurationState == .unknown)
        #expect(model.isAvailableForReadTools == false)
    }

    /// Un-onboarded Notes (never completed setup) must resolve to
    /// `.needsOnboarding`, not silently stay `.unknown` or read as available.
    @Test func prepareReadToolsLeavesUnOnboardedNotesNeedingOnboarding() async throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        fixture.defaults.set(true, forKey: SettingsKeys.notesEnabled)
        let model = try makeModel(defaults: fixture.defaults)

        await model.prepareReadToolsIfNeeded()

        #expect(model.configurationState == .needsOnboarding)
        #expect(model.isAvailableForReadTools == false)
    }

    /// Concurrent callers (e.g. `ChatCompletionService` and `ToolsView`
    /// racing on the same cold launch) must coalesce onto one bootstrap
    /// rather than each configuring the vault independently.
    @Test func concurrentPrepareReadToolsCallsCoalesceIntoOneBootstrap() async throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        let appSupportRoot = try makeTempDirectory()
        let bootstrapModel = try makeModel(defaults: fixture.defaults, appSupportRoot: appSupportRoot)
        await bootstrapModel.chooseAppManagedVault()
        fixture.defaults.set(true, forKey: SettingsKeys.notesEnabled)

        let model = try makeModel(defaults: fixture.defaults, appSupportRoot: appSupportRoot)
        async let first: Void = model.prepareReadToolsIfNeeded()
        async let second: Void = model.prepareReadToolsIfNeeded()
        _ = await (first, second)

        #expect(model.isAvailableForReadTools == true)
    }

    /// The reverse race: `NotesView.activate()` (e.g. the user opens Notes)
    /// and `prepareReadToolsIfNeeded()` (e.g. a chat cold-launching the read
    /// tools) landing on the same launch must also coalesce onto one
    /// bootstrap — `activate()` still owns `activeCount`/the periodic rescan
    /// regardless of which call actually started the shared bootstrap task.
    @Test func concurrentActivateAndPrepareReadToolsCallsCoalesceIntoOneBootstrap() async throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        let appSupportRoot = try makeTempDirectory()
        let bootstrapModel = try makeModel(defaults: fixture.defaults, appSupportRoot: appSupportRoot)
        await bootstrapModel.chooseAppManagedVault()
        fixture.defaults.set(true, forKey: SettingsKeys.notesEnabled)

        let model = try makeModel(defaults: fixture.defaults, appSupportRoot: appSupportRoot)
        async let activation: Void = model.activate()
        async let preparation: Void = model.prepareReadToolsIfNeeded()
        _ = await (activation, preparation)

        #expect(model.isAvailableForReadTools == true)
        #expect(model.repository != nil)
        // Exactly the one `activate()` call bumped `activeCount` — `prepare`
        // must never bump it, even when it's the call that happens to win
        // the race to start the shared bootstrap task.
        #expect(model.activeCount == 1)
    }

    /// `searchNotesForTool` captures the indexer and `configurationGeneration`
    /// before awaiting the search. If a vault reset completes while that
    /// search is still in flight, the awaited hits belong to a vault that's
    /// no longer configured — they must be discarded as
    /// `ToolError.notConfigured`, never returned to the caller.
    @Test func searchNotesForToolDiscardsAResultThatOutlivesAConcurrentVaultReset() async throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        let model = try makeModel(defaults: fixture.defaults)
        await model.chooseAppManagedVault()
        // `isAvailableForReadTools` requires Notes enabled; without this the
        // tool call fails before reaching `toolOperationGate` and
        // `waitUntilEntered` below hangs forever.
        fixture.defaults.set(true, forKey: SettingsKeys.notesEnabled)
        let vaultRoot = URL(fileURLWithPath: try #require(model.stats.resolvedPath))
        try Data("alpha content".utf8).write(to: vaultRoot.appendingPathComponent("Note.md"))
        await model.handle(delta: .init(added: ["Note.md"], modified: [], removed: [], renamedPairs: []))

        // `toolOperationGate` forces `searchNotesForTool` to hold the result
        // it already got back from `NotesIndexer.search` (not merely "have
        // started" it) before the reset runs, so this proves the
        // post-operation generation recheck actually discards a real old
        // -vault result rather than only the initial availability guard.
        let gate = ToolOperationGate()
        model.toolOperationGate = gate
        async let searchOutcome = model.searchNotesForTool(query: "alpha", limit: 5)
        await gate.waitUntilEntered()
        await model.resetVaultConfiguration()
        gate.release()

        do {
            _ = try await searchOutcome
            Issue.record("expected ToolError.notConfigured")
        } catch ToolError.notConfigured(let toolName, let reason) {
            #expect(toolName == "Search Notes")
            #expect(reason.contains("Notes"))
        } catch {
            Issue.record("expected ToolError.notConfigured, got \(error)")
        }
    }

    /// Same stale-result guard as `searchNotesForTool`, for `readNoteForTool`:
    /// a read that's still in flight when a vault reset completes must fail
    /// as `ToolError.notConfigured` rather than returning the old vault's
    /// content.
    @Test func readNoteForToolDiscardsAResultThatOutlivesAConcurrentVaultReset() async throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        let model = try makeModel(defaults: fixture.defaults)
        await model.chooseAppManagedVault()
        // See the search test above: Notes must be enabled or
        // `isAvailableForReadTools` fails before the gate is entered.
        fixture.defaults.set(true, forKey: SettingsKeys.notesEnabled)
        let vaultRoot = URL(fileURLWithPath: try #require(model.stats.resolvedPath))
        try Data("alpha content".utf8).write(to: vaultRoot.appendingPathComponent("Note.md"))
        await model.handle(delta: .init(added: ["Note.md"], modified: [], removed: [], renamedPairs: []))

        // Same rationale as the search test above: force the result already
        // returned by `NotesRepository.read` to be held before the reset runs.
        let gate = ToolOperationGate()
        model.toolOperationGate = gate
        async let readOutcome = model.readNoteForTool(relativePath: "Note.md")
        await gate.waitUntilEntered()
        await model.resetVaultConfiguration()
        gate.release()

        do {
            _ = try await readOutcome
            Issue.record("expected ToolError.notConfigured")
        } catch ToolError.notConfigured(let toolName, let reason) {
            #expect(toolName == "Read Note")
            #expect(reason.contains("Notes"))
        } catch {
            Issue.record("expected ToolError.notConfigured, got \(error)")
        }
    }

    /// A reconcile delta from the old vault that resumes after a switch
    /// completes must not publish the old catalog or apply its removal to
    /// the new vault's index.
    @Test func reconcileDeltaSuspendedAcrossAVaultSwitchCannotTouchTheNewVault() async throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        let model = try makeModel(defaults: fixture.defaults)
        let externalFolder = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: externalFolder) }
        try Data("A note about narwhals.".utf8).write(to: externalFolder.appendingPathComponent("Shared.md"))

        await model.chooseAppManagedVault()
        let oldRoot = URL(fileURLWithPath: try #require(model.stats.resolvedPath))
        try Data("old vault copy".utf8).write(to: oldRoot.appendingPathComponent("Shared.md"))
        await model.handle(delta: .init(added: ["Shared.md"], modified: [], removed: [], renamedPairs: []))
        try FileManager.default.removeItem(at: oldRoot.appendingPathComponent("Shared.md"))

        let gate = ToolOperationGate()
        model.reconcileOperationGate = gate
        async let staleDelta: Void = model.handle(
            delta: .init(added: [], modified: [], removed: ["Shared.md"], renamedPairs: [])
        )
        await gate.waitUntilEntered()
        model.reconcileOperationGate = nil
        await model.chooseExternalVault(url: externalFolder)
        gate.release()
        await staleDelta

        #expect(model.notes.map(\.relativePath) == ["Shared.md"])
        model.setSearchQuery("narwhals")
        try? await Task.sleep(for: .milliseconds(400))
        #expect(model.searchResults.map(\.document.sourceID) == ["Shared.md"])
    }

    /// The same race one suspension later: a removal delta from the old
    /// vault held after its backlinks refresh must not clear or retarget the
    /// new vault's selection on a matching path.
    @Test func reconcileDeltaSuspendedAfterBacklinksCannotTouchTheNewVaultsSelection() async throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        let model = try makeModel(defaults: fixture.defaults)
        let externalFolder = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: externalFolder) }
        try Data("A note about narwhals.".utf8).write(to: externalFolder.appendingPathComponent("Shared.md"))

        await model.chooseAppManagedVault()
        let oldRoot = URL(fileURLWithPath: try #require(model.stats.resolvedPath))
        try Data("old vault copy".utf8).write(to: oldRoot.appendingPathComponent("Shared.md"))
        await model.handle(delta: .init(added: ["Shared.md"], modified: [], removed: [], renamedPairs: []))
        await model.select(path: "Shared.md")
        try FileManager.default.removeItem(at: oldRoot.appendingPathComponent("Shared.md"))

        let gate = ToolOperationGate()
        model.reconcileBacklinksGate = gate
        async let staleDelta: Void = model.handle(
            delta: .init(added: [], modified: [], removed: ["Shared.md"], renamedPairs: [])
        )
        await gate.waitUntilEntered()
        model.reconcileBacklinksGate = nil
        await model.chooseExternalVault(url: externalFolder)
        await model.select(path: "Shared.md")
        gate.release()
        await staleDelta

        #expect(model.selectedPath == "Shared.md")
        #expect(model.editor?.selectedPath == "Shared.md")
        #expect(model.editor?.currentText == "A note about narwhals.")
        #expect(model.editor?.externalRemovalBanner == nil)
    }

    /// Teardown's last suspension, stopping the old reconciler, comes after
    /// the editor is discarded: nothing typed there can land in a buffer
    /// that teardown then drops unsaved.
    @Test func typingDuringReconcilerShutdownCannotReachADiscardedBuffer() async throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        let model = try makeModel(defaults: fixture.defaults)

        await model.chooseAppManagedVault()
        await model.createNote()
        let selectedPath = try #require(model.selectedPath)
        let vaultRoot = URL(fileURLWithPath: try #require(model.stats.resolvedPath))
        model.editor?.textDidChange("typed before reset")

        let gate = ToolOperationGate()
        model.teardownOperationGate = gate
        async let reset = model.resetVaultConfiguration()
        await gate.waitUntilEntered()
        // The UI can only type into the editor the model still exposes.
        #expect(model.editor == nil)
        #expect(model.selectedPath == nil)
        model.editor?.textDidChange("typed during reconciler shutdown")
        gate.release()

        #expect(await reset)
        let onDisk = try String(contentsOf: vaultRoot.appendingPathComponent(selectedPath), encoding: .utf8)
        #expect(onDisk == "typed before reset")
    }

    /// Teardown must not discard the only copy of the open note's edits:
    /// a reset first saves a dirty buffer, and refuses (keeping the vault
    /// and editor) when that save fails.
    @Test func resetSavesADirtyEditorBufferBeforeTearingDown() async throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        let model = try makeModel(defaults: fixture.defaults)

        await model.chooseAppManagedVault()
        await model.createNote()
        let selectedPath = try #require(model.selectedPath)
        let vaultRoot = URL(fileURLWithPath: try #require(model.stats.resolvedPath))
        model.editor?.textDidChange("typed just before reset")

        #expect(await model.resetVaultConfiguration())

        #expect(model.configurationState == .needsOnboarding)
        let onDisk = try String(contentsOf: vaultRoot.appendingPathComponent(selectedPath), encoding: .utf8)
        #expect(onDisk == "typed just before reset")
    }

    @Test func resetAndVaultSwitchRefuseToDiscardAnUnsavableEditorBuffer() async throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        let model = try makeModel(defaults: fixture.defaults)
        let externalFolder = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: externalFolder) }

        await model.chooseAppManagedVault()
        await model.createNote()
        let selectedPath = try #require(model.selectedPath)
        let resolvedPath = try #require(model.stats.resolvedPath)
        let editor = try #require(model.editor)
        editor.textDidChange("unsaved, and unsavable")
        // An unwritable vault root makes every atomic save fail.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: resolvedPath)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: resolvedPath) }

        #expect(await model.resetVaultConfiguration() == false)
        #expect(await model.chooseExternalVault(url: externalFolder) == false)

        #expect(model.configurationState == .configured)
        #expect(model.lastConfigurationError == .unsavedEditorChanges)
        #expect(model.editor === editor)
        #expect(model.selectedPath == selectedPath)
        #expect(editor.currentText == "unsaved, and unsavable")
        #expect(editor.isDirty)
        #expect(model.stats.resolvedPath == resolvedPath)

        // Once the save can land, the same reset proceeds and keeps the text.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: resolvedPath)
        #expect(await model.resetVaultConfiguration())
        let onDisk = try String(contentsOf: URL(fileURLWithPath: resolvedPath).appendingPathComponent(selectedPath), encoding: .utf8)
        #expect(onDisk == "unsaved, and unsavable")
    }

    @Test func resettingVaultConfigurationClearsSearchAndHealthState() async throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        let model = try makeModel(defaults: fixture.defaults)

        await model.chooseAppManagedVault()
        model.setSearchQuery("something")

        await model.resetVaultConfiguration()

        #expect(model.searchQuery == "")
        #expect(model.searchResults.isEmpty)
        #expect(model.healthSummary == nil)
        #expect(model.backlinks.isEmpty)
    }
}
