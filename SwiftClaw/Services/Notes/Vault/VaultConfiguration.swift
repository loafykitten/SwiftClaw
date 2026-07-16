import Foundation
import Security

/// Where the Notes vault lives on disk. `appManaged` is a folder this app
/// owns (App Support, or the iCloud ubiquity container when entitled — see
/// `VaultConfigurationStore.resolveAppManagedRoot()`); `external` is a
/// user-chosen folder (e.g. a live Obsidian vault) reached via a
/// security-scoped bookmark saved under `bookmarkKey`.
enum VaultLocation: Codable, Equatable, Sendable {
    case appManaged
    case external(bookmarkKey: String)
}

/// Resolves vault roots and the vault-scoped directories that live *outside*
/// the vault (index cache, revision snapshots). `@MainActor` because it only
/// touches `UserDefaults` and cheap path arithmetic in response to
/// settings/UI actions — no file I/O of its own, so no need for actor
/// isolation beyond the main actor.
@MainActor
final class VaultConfigurationStore {
    private let userDefaults: UserDefaults
    private let fileManager: FileManager
    private let hasUbiquityEntitlement: () -> Bool
    private let ubiquityContainerURL: () -> URL?

    /// All dependencies are injectable so tests never touch the real
    /// `UserDefaults.standard`, the real App Support directory, or the real
    /// iCloud entitlement/container.
    init(
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        hasUbiquityEntitlement: @escaping () -> Bool = VaultConfigurationStore.defaultHasUbiquityEntitlement,
        ubiquityContainerURL: @escaping () -> URL? = { FileManager.default.url(forUbiquityContainerIdentifier: nil) }
    ) {
        self.userDefaults = userDefaults
        self.fileManager = fileManager
        self.hasUbiquityEntitlement = hasUbiquityEntitlement
        self.ubiquityContainerURL = ubiquityContainerURL
    }

    /// Stable identifier for the current vault, generated once and persisted.
    /// Keys the on-disk index/revisions directories so a later switch to a
    /// different vault location never collides with a previous vault's
    /// cached state.
    var vaultID: String {
        if let existing = userDefaults.string(forKey: SettingsKeys.notesVaultID) {
            return existing
        }
        let generated = UUID().uuidString
        userDefaults.set(generated, forKey: SettingsKeys.notesVaultID)
        return generated
    }

    /// Resolves the app-managed vault root: the iCloud ubiquity container
    /// (the dormant sync seam — see `docs/features/NOTES.md` §Dormant sync) when
    /// the app is entitled for iCloud services *and* a container URL is
    /// actually available, else `Application Support/SwiftClaw/Notes/Vault`.
    /// Entitlement alone isn't enough to pick the ubiquity path — iCloud can
    /// be signed out, disabled, or the container not yet provisioned — so
    /// this never blocks on iCloud availability to produce a usable root.
    func resolveAppManagedRoot() -> URL {
        if hasUbiquityEntitlement(), let ubiquityURL = ubiquityContainerURL() {
            return ubiquityURL
                .appendingPathComponent("Documents", isDirectory: true)
                .appendingPathComponent("Vault", isDirectory: true)
        }
        return applicationSupportRoot()
            .appendingPathComponent("Notes", isDirectory: true)
            .appendingPathComponent("Vault", isDirectory: true)
    }

    /// Generates and persists a fresh `vaultID`, replacing whatever was
    /// there before. Callers must invoke this whenever the *vault location*
    /// actually changes (a different app-managed vault is recreated after a
    /// reset, or the user points at a different external folder) — reusing
    /// the old `vaultID` would let the new vault's revisions/index collide
    /// with, or resurrect, a previous vault's cached state.
    @discardableResult
    func regenerateVaultID() -> String {
        let generated = UUID().uuidString
        userDefaults.set(generated, forKey: SettingsKeys.notesVaultID)
        return generated
    }

    /// Where `NoteRevisionStore` persists this vault's snapshots — always
    /// outside the vault itself, keyed by `vaultID`.
    func revisionsDirectory() -> URL {
        applicationSupportRoot()
            .appendingPathComponent("Notes", isDirectory: true)
            .appendingPathComponent("Revisions", isDirectory: true)
            .appendingPathComponent(vaultID, isDirectory: true)
    }

    /// Where the (Phase 3) search index database lives for this vault —
    /// reserved here so `vaultID` stays the single source of truth for
    /// per-vault cache directories.
    func indexDirectory() -> URL {
        applicationSupportRoot()
            .appendingPathComponent("Notes", isDirectory: true)
            .appendingPathComponent("Index", isDirectory: true)
            .appendingPathComponent(vaultID, isDirectory: true)
    }

    private func applicationSupportRoot() -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("SwiftClaw", isDirectory: true)
    }

    /// `SecTaskCreateFromSelf`/`SecTaskCopyValueForEntitlement` aren't in the
    /// iOS SDK, so iOS can't prove the entitlement here; it conservatively
    /// reports false, same as an unprovisioned macOS process.
    nonisolated static func defaultHasUbiquityEntitlement() -> Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(
            task,
            "com.apple.developer.icloud-services" as CFString,
            nil
        ) != nil
        #else
        return false
        #endif
    }
}
