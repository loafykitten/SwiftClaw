import Foundation
import Testing
@testable import SwiftClaw

/// Redirects `.applicationSupportDirectory` to an isolated temp root so
/// `VaultConfigurationStore`'s app-managed vault/revisions paths never touch
/// the real `~/Library/Application Support` during tests.
private final class TempApplicationSupportFileManager: FileManager, @unchecked Sendable {
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
/// Serialized: several tests here drive `NotesRepository.create`, which
/// posts the shared/unscoped `.notesStoreDidChange` to
/// `NotificationCenter.default` — the same global signal
/// `NotesRepositoryTests` asserts is *not* posted in its reload tests. See
/// that suite's own `.serialized` comment for the underlying reason.
@Suite(.serialized)
@MainActor
struct NotesFeatureModelTests {
    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeModel(defaults: UserDefaults) throws -> NotesFeatureModel {
        let appSupportRoot = try makeTempDirectory()
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
            fileManager: fileManager
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
        #expect(model.notes.map(\.relativePath) == [selectedPath, "other.md"].sorted())
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
        #expect(model.notes.map(\.relativePath) == [selectedPath, "renamed.md"].sorted())
        #expect(model.stats.noteCount == 2)

        try FileManager.default.removeItem(at: vaultRoot.appendingPathComponent("renamed.md"))
        await model.handle(delta: .init(added: [], modified: [], removed: ["renamed.md"], renamedPairs: []))
        #expect(model.notes.map(\.relativePath) == [selectedPath])
        #expect(model.stats.noteCount == 1)
    }
}
