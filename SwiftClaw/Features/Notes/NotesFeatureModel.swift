import Foundation
import Observation
#if os(macOS)
import AppKit
#endif

/// The Notes feature coordinator: owns vault configuration/onboarding state,
/// wires `NotesVault`/`NotesRepository`/`VaultReconciler`/
/// `FSEventStreamMonitor` together for whichever `VaultLocation` is
/// configured, and exposes the single `NoteEditorModel` for the current
/// selection. `NotesView` and `NotesSettingsView` both consume the shared
/// `NotesFeatureModel.shared` instance (per `MailSyncMonitor.shared` /
/// `EmailManualSyncCoordinator.shared`) so there is exactly one vault
/// watcher/reconciler per launch, not one per view instance.
///
/// Construction alone never touches the filesystem, Keychain, or a bookmark
/// — all of that is deferred to `activate()`, which itself no-ops under
/// `ProcessInfo.processInfo.isRunningInPreview` so SwiftUI previews stay
/// side-effect free.
@MainActor
@Observable
final class NotesFeatureModel {
    enum ConfigurationState: Equatable {
        case unknown
        case needsOnboarding
        case configured
    }

    struct Stats {
        let noteCount: Int
        let locationDescription: String
        let resolvedPath: String?
    }

    static let shared = NotesFeatureModel()

    private static let logger = AppLog.make("notes.feature")
    private static let periodicRescanInterval: Duration = .seconds(300)

    private(set) var configurationState: ConfigurationState = .unknown
    private(set) var repository: NotesRepository?
    private(set) var editor: NoteEditorModel?
    private(set) var selectedPath: String?
    /// The observation-safe catalog consumed by Notes UI. `NotesRepository`
    /// is intentionally not observable, so external reconcile changes must be
    /// copied here to refresh the list and settings stats.
    private(set) var notes: [NoteSummary] = []
    private(set) var lastConfigurationError: NotesError?

    let configurationStore: VaultConfigurationStore
    private let bookmarkStore: SecurityScopedBookmarkStore
    private let userDefaults: UserDefaults
    private let fileManager: FileManager

    private var vault: NotesVault?
    private var reconciler: VaultReconciler?
    #if os(macOS)
    private var monitor: FSEventStreamMonitor?
    #endif
    private var monitoringScope: ScopedURL?
    private var currentLocation: VaultLocation?
    private var currentRootURL: URL?

    private(set) var activeCount = 0
    /// Invalidates callbacks from a reconciler belonging to a vault that was
    /// just disconnected or replaced. Stopping a reconciler cancels future
    /// work, but a delta handler may already be waiting to resume on the main
    /// actor when a vault switch begins.
    private var configurationGeneration = 0
    private var periodicRescanTask: Task<Void, Never>?
    /// `nonisolated(unsafe)`: an `NSObjectProtocol` observer token is an
    /// opaque, thread-safe handle — safe to read from `deinit`, which for a
    /// `@MainActor` class runs in a nonisolated context.
    @ObservationIgnored
    private nonisolated(unsafe) var activationObserver: NSObjectProtocol?

    /// `configurationStore`/`bookmarkStore` default to `nil` (constructed in
    /// the body) rather than as default-argument expressions — a default
    /// argument's initializer expression evaluates outside this
    /// `@MainActor` init's isolation, so calling `VaultConfigurationStore()`
    /// (itself `@MainActor`) directly as a default value doesn't compile.
    init(
        configurationStore: VaultConfigurationStore? = nil,
        bookmarkStore: SecurityScopedBookmarkStore? = nil,
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) {
        self.configurationStore = configurationStore ?? VaultConfigurationStore()
        self.bookmarkStore = bookmarkStore ?? SecurityScopedBookmarkStore()
        self.userDefaults = userDefaults
        self.fileManager = fileManager
    }

    deinit {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
    }

    // MARK: - Lifecycle

    /// Call from a view's `.task`. Reference-counted so the shared instance
    /// stays "active" (periodic rescans running) as long as at least one of
    /// `NotesView`/`NotesSettingsView` is on screen, and idles the moment
    /// neither is.
    func activate() async {
        activeCount += 1
        guard !ProcessInfo.processInfo.isRunningInPreview else { return }

        if repository == nil {
            await bootstrapFromSettingsIfOnboarded()
        } else {
            await reconciler?.rescanNow()
        }
        startPeriodicRescanIfNeeded()
    }

    /// Call from a view's `.onDisappear`.
    func deactivate() {
        activeCount = max(0, activeCount - 1)
        guard activeCount == 0 else { return }
        periodicRescanTask?.cancel()
        periodicRescanTask = nil
    }

    private func startPeriodicRescanIfNeeded() {
        guard periodicRescanTask == nil, reconciler != nil else { return }
        periodicRescanTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.periodicRescanInterval)
                guard !Task.isCancelled else { return }
                await self?.reconciler?.rescanNow()
            }
        }
    }

    // MARK: - Bootstrap / onboarding completion

    private func bootstrapFromSettingsIfOnboarded() async {
        guard userDefaults.bool(forKey: SettingsKeys.notesHasCompletedOnboarding) else {
            configurationState = .needsOnboarding
            return
        }
        let location = SettingsStorage.loadNotesVaultLocation(userDefaults: userDefaults)
        await configureAndActivate(location: location)
    }

    /// Onboarding action: create/open the app-managed vault.
    func chooseAppManagedVault() async {
        await applyNewVaultLocation(.appManaged)
    }

    /// Onboarding action: adopt a user-chosen external folder (already
    /// granted via `NSOpenPanel`), saving a fresh security-scoped bookmark
    /// under a stable generated key.
    func chooseExternalVault(url: URL) async {
        let key = "notes.vault.bookmark.\(UUID().uuidString)"
        do {
            try bookmarkStore.save(url: url, forKey: key)
        } catch {
            lastConfigurationError = NotesError.from(error)
            return
        }
        await applyNewVaultLocation(.external(bookmarkKey: key))
    }

    private func applyNewVaultLocation(_ location: VaultLocation) async {
        // `currentLocation` is nil when reopening the persisted external
        // bookmark failed during startup. Fall back to the stored location so
        // choosing another vault still cleans up that obsolete bookmark.
        let previousLocation = currentLocation ?? SettingsStorage.loadNotesVaultLocation(userDefaults: userDefaults)
        let previousBookmarkKey = bookmarkKey(for: previousLocation)
        await teardownCurrentVault()

        // A genuinely new/different vault gets a fresh vaultID so its
        // revisions/index never collide with (or resurrect) a previous
        // vault's cached state.
        configurationStore.regenerateVaultID()
        SettingsStorage.saveNotesVaultLocation(location, userDefaults: userDefaults)
        userDefaults.set(true, forKey: SettingsKeys.notesHasCompletedOnboarding)

        if let previousBookmarkKey, previousBookmarkKey != bookmarkKey(for: location) {
            bookmarkStore.remove(forKey: previousBookmarkKey)
        }

        await configureAndActivate(location: location)
    }

    /// Settings action: disconnect the current vault configuration. Never
    /// touches the vault's file contents — only forgets where it is, so the
    /// next onboarding pass (or picking the same folder again) starts clean.
    func resetVaultConfiguration() async {
        let persistedLocation = SettingsStorage.loadNotesVaultLocation(userDefaults: userDefaults)
        if let key = bookmarkKey(for: currentLocation ?? persistedLocation) {
            bookmarkStore.remove(forKey: key)
        }
        await teardownCurrentVault()
        // Reset is a logical vault switch even though it leaves the note
        // files alone. Do not let a later setup reuse revisions or index
        // state belonging to the disconnected vault.
        configurationStore.regenerateVaultID()
        userDefaults.removeObject(forKey: SettingsKeys.notesVaultLocationType)
        userDefaults.removeObject(forKey: SettingsKeys.notesVaultBookmarkKey)
        userDefaults.removeObject(forKey: SettingsKeys.notesHasCompletedOnboarding)
        configurationState = .needsOnboarding
        lastConfigurationError = nil
    }

    private func bookmarkKey(for location: VaultLocation?) -> String? {
        guard case .external(let key) = location else { return nil }
        return key
    }

    // MARK: - Configuration

    private func configureAndActivate(location: VaultLocation) async {
        do {
            try await configure(location: location)
            configurationState = .configured
            lastConfigurationError = nil
        } catch {
            lastConfigurationError = NotesError.from(error)
            configurationState = .needsOnboarding
        }
    }

    private func configure(location: VaultLocation) async throws {
        let root: URL
        let scopeAccessor: NotesVault.ScopeAccessor

        switch location {
        case .appManaged:
            root = configurationStore.resolveAppManagedRoot()
            scopeAccessor = { nil }
        case .external(let bookmarkKey):
            let scoped = try bookmarkStore.resolve(forKey: bookmarkKey)
            root = scoped.url
            // `[weak self]` (not a captured `bookmarkStore` reference) is the
            // only way to reach back into MainActor-isolated state from this
            // `@Sendable` closure without making `SecurityScopedBookmarkStore`
            // itself `Sendable` — the codebase's established weak-self
            // exception (see `EmailManualSyncCoordinator`) covers this.
            scopeAccessor = { [weak self] in
                guard let self else { return nil }
                return try await self.resolveExternalScope(bookmarkKey: bookmarkKey)
            }
        }

        let vault = NotesVault(root: root, fileManager: fileManager, scopeAccessor: scopeAccessor)
        let revisionStore = NoteRevisionStore(
            directory: configurationStore.revisionsDirectory(),
            fileManager: fileManager
        )
        let repository = NotesRepository(vault: vault, revisionStore: revisionStore)
        await repository.reload()
        if let error = repository.lastError {
            Self.logger.error("reload reported \(String(describing: error))")
        }

        let reconciler = VaultReconciler(stateProvider: { [vault] in
            try await Self.vaultEntries(vault: vault)
        })

        self.vault = vault
        self.repository = repository
        self.notes = repository.notes
        self.editor = NoteEditorModel(repository: repository)
        self.reconciler = reconciler
        self.currentLocation = location
        self.currentRootURL = root

        let generation = configurationGeneration
        await reconciler.start(events: watchStream(root: root, location: location)) { [weak self] delta in
            await self?.handle(delta: delta, fromConfigurationGeneration: generation)
        }
        await reconciler.rescanNow()
        startActivationObserver()
    }

    private func resolveExternalScope(bookmarkKey: String) throws -> ScopedURL {
        try bookmarkStore.resolve(forKey: bookmarkKey)
    }

    /// Full reads for hashes: `NotesVault` has no lighter-weight hash-only
    /// enumeration, and adding one is out of scope for this interim wiring —
    /// acceptable at the personal-vault scale (10^3–10^4 notes) this feature
    /// targets. A note unreadable mid-scan is skipped rather than failing
    /// the whole rescan.
    private static func vaultEntries(vault: NotesVault) async throws -> [VaultReconciler.VaultEntry] {
        let paths = try await vault.enumerate()
        var entries: [VaultReconciler.VaultEntry] = []
        entries.reserveCapacity(paths.count)
        for path in paths {
            guard let snapshot = try? await vault.read(relativePath: path) else { continue }
            entries.append(VaultReconciler.VaultEntry(relativePath: snapshot.relativePath, sha256: snapshot.sha256))
        }
        return entries
    }

    private func watchStream(root: URL, location: VaultLocation) -> AsyncStream<Void> {
        #if os(macOS)
        if case .external(let bookmarkKey) = location {
            monitoringScope = try? bookmarkStore.resolve(forKey: bookmarkKey)
            guard monitoringScope != nil else { return AsyncStream { $0.finish() } }
        }
        let fsMonitor = FSEventStreamMonitor(paths: [root.path])
        monitor = fsMonitor
        let events = fsMonitor.start()
        return AsyncStream { continuation in
            let forwardTask = Task {
                for await _ in events {
                    continuation.yield(())
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in forwardTask.cancel() }
        }
        #else
        return AsyncStream { $0.finish() }
        #endif
    }

    private func startActivationObserver() {
        guard activationObserver == nil else { return }
        #if os(macOS)
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.reconciler?.rescanNow()
            }
        }
        #endif
    }

    private func teardownCurrentVault() async {
        configurationGeneration &+= 1
        #if os(macOS)
        monitor?.stop()
        monitor = nil
        #endif
        monitoringScope = nil
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        await reconciler?.stop()
        reconciler = nil
        vault = nil
        repository = nil
        editor = nil
        notes = []
        currentLocation = nil
        currentRootURL = nil
        selectedPath = nil
    }

    // MARK: - Reconciliation

    /// Internal for focused reconciliation tests. The reconciler remains the
    /// only production caller.
    func handle(delta: VaultReconciler.ReconcileDelta) async {
        await handle(delta: delta, fromConfigurationGeneration: configurationGeneration)
    }

    /// Internal for focused reconciliation tests. Production callbacks carry
    /// the generation captured when their reconciler was configured.
    func handle(delta: VaultReconciler.ReconcileDelta, fromConfigurationGeneration generation: Int) async {
        guard generation == configurationGeneration else { return }
        guard let repository else { return }
        _ = await repository.apply(delta: delta)
        notes = repository.notes

        if let selectedPath {
            if let pair = delta.renamedPairs.first(where: { $0.from == selectedPath }) {
                self.selectedPath = pair.to
                editor?.retarget(to: pair.to)
                await editor?.handleExternalChange()
            } else if delta.removed.contains(selectedPath) {
                // Do not use `select(path: nil)`: it flushes ordinary
                // selection changes and could recreate a file that was just
                // removed outside the app.
                editor?.handleExternalRemoval()
                self.selectedPath = editor?.selectedPath
            } else if delta.modified.contains(selectedPath) || delta.added.contains(selectedPath) {
                await editor?.handleExternalChange()
            }
        }
    }

    // MARK: - Selection & list actions

    func select(path: String?) async {
        guard let editor else {
            selectedPath = path
            return
        }
        guard await editor.select(path: path) else { return }
        selectedPath = editor.selectedPath
    }

    func createNote() async {
        guard let repository else { return }
        do {
            let folder = SettingsStorage.loadNotesDefaultNewNoteFolder(userDefaults: userDefaults)
            let summary = try await repository.create(title: "Untitled", folder: folder)
            notes = repository.notes
            await select(path: summary.relativePath)
        } catch {
            lastConfigurationError = NotesError.from(error)
        }
    }

    // MARK: - Settings actions

    func revealVaultInFinder() {
        #if os(macOS)
        guard let currentRootURL else { return }
        if case .external(let key) = currentLocation, let scope = try? bookmarkStore.resolve(forKey: key) {
            withExtendedLifetime(scope) {
                NSWorkspace.shared.activateFileViewerSelecting([scope.url])
            }
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([currentRootURL])
        }
        #endif
    }

    var stats: Stats {
        Stats(
            noteCount: notes.count,
            locationDescription: Self.describe(currentLocation),
            resolvedPath: currentRootURL?.path
        )
    }

    private static func describe(_ location: VaultLocation?) -> String {
        switch location {
        case .none:
            "Not configured"
        case .appManaged:
            "App-managed vault"
        case .external:
            "External folder"
        }
    }
}
