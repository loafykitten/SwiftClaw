import Foundation
import Testing
@testable import SwiftClaw

struct NotesSettingsStorageTests {
    @Test func notesDefaultsToOff() throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }

        #expect(!SettingsStorage.isNotesEnabled(userDefaults: fixture.defaults))
    }

    @Test func enablingNotesPersists() throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }

        fixture.defaults.set(true, forKey: SettingsKeys.notesEnabled)

        #expect(SettingsStorage.isNotesEnabled(userDefaults: fixture.defaults))
    }

    // MARK: - Vault location

    @Test func vaultLocationDefaultsToAppManaged() throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }

        #expect(SettingsStorage.loadNotesVaultLocation(userDefaults: fixture.defaults) == .appManaged)
    }

    @Test func savingAnExternalVaultLocationRoundTrips() throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }

        SettingsStorage.saveNotesVaultLocation(.external(bookmarkKey: "vault.bookmark.1"), userDefaults: fixture.defaults)

        #expect(
            SettingsStorage.loadNotesVaultLocation(userDefaults: fixture.defaults)
                == .external(bookmarkKey: "vault.bookmark.1")
        )
    }

    @Test func switchingBackToAppManagedClearsTheStaleBookmarkKey() throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }

        SettingsStorage.saveNotesVaultLocation(.external(bookmarkKey: "vault.bookmark.1"), userDefaults: fixture.defaults)
        SettingsStorage.saveNotesVaultLocation(.appManaged, userDefaults: fixture.defaults)

        #expect(SettingsStorage.loadNotesVaultLocation(userDefaults: fixture.defaults) == .appManaged)
        #expect(fixture.defaults.string(forKey: SettingsKeys.notesVaultBookmarkKey) == nil)
    }

    @Test func externalTypeWithoutASavedBookmarkKeyFallsBackToAppManaged() throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }

        fixture.defaults.set("external", forKey: SettingsKeys.notesVaultLocationType)

        #expect(SettingsStorage.loadNotesVaultLocation(userDefaults: fixture.defaults) == .appManaged)
    }

    // MARK: - Folders

    @Test func dailyNoteFolderDefaultsToDailyNotes() throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }

        #expect(
            SettingsStorage.loadNotesDailyNoteFolder(userDefaults: fixture.defaults)
                == SettingsStorage.defaultNotesDailyNoteFolder
        )
    }

    @Test func defaultNewNoteFolderDefaultsToVaultRoot() throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }

        #expect(SettingsStorage.loadNotesDefaultNewNoteFolder(userDefaults: fixture.defaults) == nil)
    }

    @Test func savingAnEmptyDefaultNewNoteFolderClearsIt() throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }

        SettingsStorage.saveNotesDefaultNewNoteFolder("Inbox", userDefaults: fixture.defaults)
        #expect(SettingsStorage.loadNotesDefaultNewNoteFolder(userDefaults: fixture.defaults) == "Inbox")

        SettingsStorage.saveNotesDefaultNewNoteFolder(nil, userDefaults: fixture.defaults)
        #expect(SettingsStorage.loadNotesDefaultNewNoteFolder(userDefaults: fixture.defaults) == nil)
    }

    // MARK: - Review interval

    @Test func reviewIntervalDefaultsTo24Hours() throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }

        #expect(
            SettingsStorage.loadNotesReviewInterval(userDefaults: fixture.defaults)
                == SettingsStorage.defaultNotesReviewIntervalSeconds
        )
    }

    @Test func reviewIntervalOfZeroMeansManualOnlyAndIsPreserved() throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }

        SettingsStorage.saveNotesReviewInterval(0, userDefaults: fixture.defaults)

        #expect(SettingsStorage.loadNotesReviewInterval(userDefaults: fixture.defaults) == 0)
    }

    @Test func lastReviewCompletedAtRoundTrips() throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }

        #expect(SettingsStorage.loadNotesLastReviewCompletedAt(userDefaults: fixture.defaults) == nil)

        let date = Date(timeIntervalSince1970: 1_700_000_000)
        SettingsStorage.saveNotesLastReviewCompletedAt(date, userDefaults: fixture.defaults)

        #expect(SettingsStorage.loadNotesLastReviewCompletedAt(userDefaults: fixture.defaults) == date)
    }

    // MARK: - Embeddings

    @Test func embeddingsDefaultToEnabled() throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }

        #expect(SettingsStorage.isNotesEmbeddingsEnabled(userDefaults: fixture.defaults))
    }

    @Test func disablingEmbeddingsPersists() throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }

        fixture.defaults.set(false, forKey: SettingsKeys.notesEmbeddingsEnabled)

        #expect(!SettingsStorage.isNotesEmbeddingsEnabled(userDefaults: fixture.defaults))
    }

    // MARK: - Vault ID (VaultConfigurationStore integration)

    @Test @MainActor func vaultConfigurationStoreVaultIDUsesTheSharedSettingsKey() throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }

        let store = VaultConfigurationStore(userDefaults: fixture.defaults, hasUbiquityEntitlement: { false })
        let generated = store.vaultID

        #expect(fixture.defaults.string(forKey: SettingsKeys.notesVaultID) == generated)
    }
}
