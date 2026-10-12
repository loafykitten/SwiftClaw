import Foundation
import Observation
#if os(macOS)
import AppKit
#endif

/// The Notes feature coordinator: owns vault configuration/onboarding state,
/// wires `NotesVault`/`NotesRepository`/`VaultReconciler`/
/// `FSEventStreamMonitor` together for whichever `VaultLocation` is
/// configured, and exposes the single `NoteEditorController` for the current
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
    private(set) var editor: NoteEditorController?
    private(set) var selectedPath: String?
    /// The observation-safe catalog consumed by Notes UI. `NotesRepository`
    /// is intentionally not observable, so external reconcile changes must be
    /// copied here to refresh the list and settings stats.
    private(set) var notes: [NoteSummary] = []
    private(set) var lastConfigurationError: NotesError?
    /// Distinct from `lastConfigurationError` (vault setup/onboarding
    /// failures, surfaced only outside `.configured` — see
    /// `NotesSettingsView`/`needsOnboardingView`): this covers catalog
    /// mutations like `createNote()` that can fail once a vault is already
    /// configured, so the `.configured` UI has somewhere to actually show
    /// them instead of failing silently.
    private(set) var lastListError: NotesError?

    private(set) var searchQuery: String = ""
    private(set) var searchResults: [SearchHit] = []
    private(set) var isSearching = false
    private(set) var searchError: NotesError?

    private(set) var backlinks: [ResolvedLink] = []
    private(set) var isLoadingBacklinks = false
    private(set) var backlinksError: NotesError?

    private(set) var brokenLinks: [ResolvedLink] = []
    private(set) var isLoadingBrokenLinks = false
    private(set) var brokenLinksError: NotesError?

    private(set) var healthSummary: NotesHealthSummary?
    private(set) var isRefreshingHealth = false
    private(set) var healthError: NotesError?

    private(set) var isRebuildingIndex = false
    private(set) var rebuildIndexError: NotesError?

    let configurationStore: VaultConfigurationStore
    private let bookmarkStore: SecurityScopedBookmarkStore
    private let userDefaults: UserDefaults
    private let fileManager: FileManager

    private var vault: NotesVault?
    private var indexer: NotesIndexer?
    private var reconciler: VaultReconciler?
    private var quickCaptureService: NotesQuickCaptureService?
    private var searchTask: Task<Void, Never>?
    /// Gates `NoteProposalDispatcher` approvals against a vault teardown/
    /// switch beginning mid-approval — see `acquireVaultOperationLease` and
    /// `teardownCurrentVault`.
    private let vaultOperationLeases: VaultOperationLeaseCoordinator
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
    /// In-flight settings-driven bootstrap (`bootstrapFromSettingsIfOnboarded`),
    /// shared by `activate()` and `prepareReadToolsIfNeeded()` so concurrent
    /// callers (e.g. `NotesView.activate()` and `ChatCompletionService`/
    /// `ToolsView` racing on a cold launch) coalesce onto one bootstrap
    /// instead of each starting their own `configure(location:)`. Cancelled
    /// by `teardownCurrentVault()` so a reset/vault switch that begins mid-
    /// bootstrap can't have its result clobbered by this task committing a
    /// stale configuration afterward — see `configure(location:)`'s
    /// `Task.checkCancellation()` just before it commits state.
    private var configurationBootstrapTask: Task<Void, Never>?
    /// Identifies which `ensureConfigurationBootstrapped` call currently owns
    /// `configurationBootstrapTask`. A completing waiter only clears the slot
    /// if its own `token` still matches this value — otherwise a newer call
    /// already installed a different task into the slot (e.g. after
    /// `teardownCurrentVault()` cancelled and cleared this waiter's task),
    /// and clearing it would erase that newer task instead of this stale
    /// one. See `invalidateConfigurationBootstrapSlot()`.
    private var configurationBootstrapTaskToken: UInt64 = 0
    private var nextConfigurationBootstrapToken: UInt64 = 0
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
        fileManager: FileManager = .default,
        vaultOperationLeases: VaultOperationLeaseCoordinator? = nil
    ) {
        self.configurationStore = configurationStore ?? VaultConfigurationStore()
        self.bookmarkStore = bookmarkStore ?? SecurityScopedBookmarkStore()
        self.userDefaults = userDefaults
        self.fileManager = fileManager
        self.vaultOperationLeases = vaultOperationLeases ?? VaultOperationLeaseCoordinator()
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

        let wasAlreadyConfigured = repository != nil
        await ensureConfigurationBootstrapped(skipIfDisabled: false)
        if wasAlreadyConfigured, repository != nil {
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

    /// Shared coalescing entry point for `activate()` and
    /// `prepareReadToolsIfNeeded()`: both routes must fold onto exactly one
    /// in-flight `bootstrapFromSettingsIfOnboarded()` pass rather than each
    /// starting its own `configure(location:)` — whichever call arrives
    /// first creates `configurationBootstrapTask`; the other awaits it.
    /// `configurationState == .unknown` keeps repeat calls (once already
    /// `.configured`/`.needsOnboarding`) cheap no-ops, matching the previous
    /// per-caller gating each route used on its own.
    private func ensureConfigurationBootstrapped(skipIfDisabled: Bool) async {
        guard !ProcessInfo.processInfo.isRunningInPreview else { return }

        if let configurationBootstrapTask {
            await configurationBootstrapTask.value
            return
        }
        guard configurationState == .unknown else { return }
        if skipIfDisabled {
            // `prepare` must not touch the filesystem/bookmark/index for a
            // feature the user has turned off; `activate` (a Notes view
            // actually on screen) has no such skip — see `activate()`.
            guard SettingsStorage.isNotesEnabled(userDefaults: userDefaults) else { return }
        }

        let token = nextConfigurationBootstrapToken
        nextConfigurationBootstrapToken &+= 1
        let task = Task { [weak self] in
            guard let self else { return }
            await self.bootstrapFromSettingsIfOnboarded()
        }
        configurationBootstrapTask = task
        configurationBootstrapTaskToken = token
        await task.value
        // Only clear the slot if it still holds *this* task — a concurrent
        // `teardownCurrentVault()` may have already cleared it (and bumped
        // the token via `invalidateConfigurationBootstrapSlot()`) and a newer
        // `ensureConfigurationBootstrapped` call may have installed a
        // different task by the time this one finishes.
        if configurationBootstrapTaskToken == token {
            configurationBootstrapTask = nil
        }
    }

    /// Cancels and clears the in-flight bootstrap task, if any, and
    /// invalidates `configurationBootstrapTaskToken` so that task's own
    /// completing waiter (in `ensureConfigurationBootstrapped`) can't later
    /// clear a newer task installed into the slot after this call returns.
    private func invalidateConfigurationBootstrapSlot() {
        configurationBootstrapTask?.cancel()
        configurationBootstrapTask = nil
        configurationBootstrapTaskToken = nextConfigurationBootstrapToken
        nextConfigurationBootstrapToken &+= 1
    }

    private func bootstrapFromSettingsIfOnboarded() async {
        guard userDefaults.bool(forKey: SettingsKeys.notesHasCompletedOnboarding) else {
            configurationState = .needsOnboarding
            return
        }
        let location = SettingsStorage.loadNotesVaultLocation(userDefaults: userDefaults)
        await configureAndActivate(location: location)
    }

    /// Onboarding action: create/open the app-managed vault. `false` when
    /// the switch was refused before anything changed (see
    /// `teardownCurrentVault()`); `lastConfigurationError` says why.
    @discardableResult
    func chooseAppManagedVault() async -> Bool {
        await applyNewVaultLocation(.appManaged)
    }

    /// Onboarding action: adopt a user-chosen external folder (already
    /// granted via `NSOpenPanel`), saving a fresh security-scoped bookmark
    /// under a stable generated key. `false` when the switch was refused
    /// before anything changed.
    @discardableResult
    func chooseExternalVault(url: URL) async -> Bool {
        let key = "notes.vault.bookmark.\(UUID().uuidString)"
        do {
            try bookmarkStore.save(url: url, forKey: key)
        } catch {
            lastConfigurationError = NotesError.from(error)
            return false
        }
        return await applyNewVaultLocation(.external(bookmarkKey: key))
    }

    private func applyNewVaultLocation(_ location: VaultLocation) async -> Bool {
        // `currentLocation` is nil when reopening the persisted external
        // bookmark failed during startup. Fall back to the stored location so
        // choosing another vault still cleans up that obsolete bookmark.
        let previousLocation = currentLocation ?? SettingsStorage.loadNotesVaultLocation(userDefaults: userDefaults)
        let previousBookmarkKey = bookmarkKey(for: previousLocation)
        guard await teardownCurrentVault() else {
            // The current vault stays; drop the bookmark minted for the
            // refused switch so it doesn't linger unused.
            if let newBookmarkKey = bookmarkKey(for: location), newBookmarkKey != previousBookmarkKey {
                bookmarkStore.remove(forKey: newBookmarkKey)
            }
            return false
        }

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
        return true
    }

    /// Settings action: disconnect the current vault configuration. Never
    /// touches the vault's file contents — only forgets where it is, so the
    /// next onboarding pass (or picking the same folder again) starts clean.
    /// `false` when refused because the open note couldn't be saved.
    @discardableResult
    func resetVaultConfiguration() async -> Bool {
        let persistedLocation = SettingsStorage.loadNotesVaultLocation(userDefaults: userDefaults)
        let bookmarkToRemove = bookmarkKey(for: currentLocation ?? persistedLocation)
        guard await teardownCurrentVault() else { return false }
        // An approval that acquired a lease can resolve this bookmark for each
        // vault operation. Keep it available until teardown has drained that
        // approval and cleared the old vault; removing it earlier can revoke
        // security-scoped access while the approval is still mid-operation.
        if let bookmarkToRemove {
            bookmarkStore.remove(forKey: bookmarkToRemove)
        }
        // Reset is a logical vault switch even though it leaves the note
        // files alone. Do not let a later setup reuse revisions or index
        // state belonging to the disconnected vault.
        configurationStore.regenerateVaultID()
        userDefaults.removeObject(forKey: SettingsKeys.notesVaultLocationType)
        userDefaults.removeObject(forKey: SettingsKeys.notesVaultBookmarkKey)
        userDefaults.removeObject(forKey: SettingsKeys.notesHasCompletedOnboarding)
        configurationState = .needsOnboarding
        lastConfigurationError = nil
        return true
    }

    private func bookmarkKey(for location: VaultLocation?) -> String? {
        guard case .external(let key) = location else { return nil }
        return key
    }

    // MARK: - Configuration

    private func configureAndActivate(location: VaultLocation) async {
        let generation = configurationGeneration
        do {
            try await configure(location: location)
            // Re-verified immediately before committing the terminal
            // `configurationState`/`lastConfigurationError` — `configure`
            // itself already guards every internal suspension against this
            // same `generation`, but this call boundary gets its own check
            // too so the two functions don't rely on each other's internals
            // staying in sync.
            guard !Task.isCancelled, generation == configurationGeneration else { return }
            configurationState = .configured
            lastConfigurationError = nil
        } catch is CancellationError {
            // `configure(location:)` was cancelled by a concurrent
            // `teardownCurrentVault()` (a reset or vault switch) just before
            // committing state — whichever operation triggered that
            // cancellation already owns `configurationState`/`repository`,
            // so this stale pass must not overwrite them.
            return
        } catch is ConfigurationSuperseded {
            // Same rationale as `CancellationError` above, but for the case
            // where `configurationGeneration` moved without the setup
            // `Task` itself ever being cancelled — e.g. a direct
            // `applyNewVaultLocation` isn't owned by
            // `configurationBootstrapTask`, so only the generation counter
            // (not `Task.checkCancellation()`) can catch it.
            return
        } catch {
            guard !Task.isCancelled, generation == configurationGeneration else { return }
            lastConfigurationError = NotesError.from(error)
            configurationState = .needsOnboarding
        }
    }

    /// Thrown internally (never surfaced to callers as a user-facing error)
    /// when a setup pass discovers, after resuming from a suspension, that
    /// `configurationGeneration` moved on without it — i.e. a concurrent
    /// `teardownCurrentVault()`/newer `configure` pass superseded this one.
    /// Distinct from `CancellationError`: `configurationBootstrapTask` being
    /// cancelled is one way a pass can become stale, but a direct
    /// `applyNewVaultLocation`/`resetVaultConfiguration` bumping
    /// `configurationGeneration` while this pass's own `Task` is never
    /// cancelled is another — this error covers both uniformly.
    private struct ConfigurationSuperseded: Error {}

    /// Re-verifies this setup pass is still current before any further side
    /// effect or state commit. Call after every `await`/actor suspension in
    /// `configure(location:)` (per the generation contract on
    /// `configurationGeneration`), and immediately before assigning any of
    /// `self.vault`/`repository`/`indexer`/`reconciler`/`currentLocation`/
    /// `currentRootURL`.
    private func checkConfigurationCurrent(generation: Int) throws {
        try Task.checkCancellation()
        guard generation == configurationGeneration else { throw ConfigurationSuperseded() }
    }

    private func configure(location: VaultLocation) async throws {
        let generation = configurationGeneration
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

        // Each filesystem actor owns its FileManager instead of sharing the
        // main actor's injected instance across isolation domains. The
        // resolved directories already carry any test-specific location mapping.
        let vault = NotesVault(root: root, fileManager: FileManager(), scopeAccessor: scopeAccessor)
        let revisionStore = NoteRevisionStore(
            directory: configurationStore.revisionsDirectory(),
            fileManager: FileManager()
        )
        let repository = NotesRepository(vault: vault, revisionStore: revisionStore)
        // Monitoring starts before catalog hydration. That makes the loaded
        // catalog safe to use as the reconciler baseline: edits during the
        // load are buffered as events instead of disappearing in a prime
        // window.
        let monitoring = watchStream(root: root, location: location)
        // The monitor started above is orphaned if this pass aborts before
        // `reconciler.start` takes ownership of the stream — a concurrent
        // teardown can't stop a monitor it never saw committed.
        func abortMonitoring() {
            #if os(macOS)
            monitor?.stop()
            monitor = nil
            #endif
            monitoringScope = nil
        }
        await repository.reload()
        if let error = repository.lastError {
            Self.logger.error("reload reported \(String(describing: error))")
        }

        // A concurrent `teardownCurrentVault()` (reset, vault switch, or a
        // second `applyNewVaultLocation`) — checked here, right before this
        // pass starts overwriting `self`'s vault/repository/indexer, so a
        // stale pass can never resurrect state a reset/switch already tore
        // down or is about to replace.
        do {
            try checkConfigurationCurrent(generation: generation)
        } catch {
            abortMonitoring()
            throw error
        }

        let reconciler = VaultReconciler(stateProvider: { [vault] in
            try await Self.vaultEntries(vault: vault)
        })

        let embeddingProvider: TextEmbeddingProvider? = SettingsStorage.isNotesEmbeddingsEnabled(userDefaults: userDefaults)
            ? NLSentenceEmbeddingProvider() : nil
        let indexer: NotesIndexer
        do {
            indexer = try NotesIndexer.makeAtVaultIndexDirectory(
                configurationStore.indexDirectory(),
                embeddingProvider: embeddingProvider,
                fileManager: fileManager,
                noteReader: { [weak self] path in
                    guard let self else { throw NotesError.underlying("The vault isn't configured.") }
                    return try await self.indexerNoteReader(path)
                },
                catalogProvider: { [weak self] in
                    await self?.indexerCatalogProvider() ?? []
                }
            )
        } catch {
            abortMonitoring()
            throw error
        }

        // Re-verified again immediately before committing — construction
        // above (reconciler/embeddingProvider/indexer) is synchronous, but
        // this keeps the guard directly adjacent to the assignments it
        // protects rather than relying on the check above still applying.
        do {
            try checkConfigurationCurrent(generation: generation)
        } catch {
            abortMonitoring()
            throw error
        }

        self.vault = vault
        self.repository = repository
        self.notes = repository.notes
        self.editor = NoteEditorController(repository: repository)
        self.editor?.candidateNotes = repository.notes
        self.quickCaptureService = NotesQuickCaptureService(
            repository: repository,
            statsStore: NotesCaptureStatsStore(userDefaults: userDefaults)
        )
        self.indexer = indexer
        self.reconciler = reconciler
        self.currentLocation = location
        self.currentRootURL = root

        await reconciler.start(events: monitoring.events) { [weak self] delta in
            await self?.handle(delta: delta, fromConfigurationGeneration: generation)
        }
        do {
            try checkConfigurationCurrent(generation: generation)
        } catch {
            // This pass's own local `reconciler` — not `self.reconciler`,
            // which a newer pass may already have replaced — must not keep
            // running past this point.
            await reconciler.stop()
            throw error
        }

        if monitoring.isActive {
            await reconciler.primeKnownState(
                with: repository.notes.map {
                    VaultReconciler.VaultEntry(relativePath: $0.relativePath, sha256: $0.sha256)
                }
            )
        } else {
            // iOS and a macOS external vault whose security scope could not
            // be monitored must scan rather than prime from an unwatched load.
            await reconciler.rescanNow()
        }
        do {
            try checkConfigurationCurrent(generation: generation)
        } catch {
            await reconciler.stop()
            throw error
        }

        startActivationObserver()

        // Existing notes must be searchable immediately. Exact catalog hashes
        // let the indexer skip even the note-file read for unchanged rows.
        _ = await indexer.syncCatalog(repository.notes)
        do {
            try checkConfigurationCurrent(generation: generation)
        } catch {
            await reconciler.stop()
            throw error
        }

        await refreshHealth()
        do {
            try checkConfigurationCurrent(generation: generation)
        } catch {
            await reconciler.stop()
            throw error
        }
    }

    private func indexerNoteReader(_ relativePath: String) async throws -> NoteFileSnapshot {
        guard let repository else { throw NotesError.underlying("The vault isn't configured.") }
        return try await repository.read(relativePath: relativePath)
    }

    private func indexerCatalogProvider() async -> [NoteSummary] {
        repository?.notes ?? []
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

    private func watchStream(root: URL, location: VaultLocation) -> (events: AsyncStream<Void>, isActive: Bool) {
        #if os(macOS)
        if case .external(let bookmarkKey) = location {
            monitoringScope = try? bookmarkStore.resolve(forKey: bookmarkKey)
            guard monitoringScope != nil else { return (AsyncStream { $0.finish() }, false) }
        }
        let fsMonitor = FSEventStreamMonitor(paths: [root.path])
        monitor = fsMonitor
        let events = fsMonitor.start()
        let forwarded = AsyncStream<Void> { continuation in
            let forwardTask = Task {
                for await _ in events {
                    continuation.yield(())
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in forwardTask.cancel() }
        }
        return (forwarded, true)
        #else
        return (AsyncStream { $0.finish() }, false)
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

    /// Acquires a lease for one in-flight `NoteProposalDispatcher` approval
    /// file operation against the vault identified by `expectedVaultID`.
    /// `nil` when that vault isn't the currently configured one, no vault is
    /// configured at all, or a teardown/switch is already underway — the
    /// caller must treat that exactly like "this vault is unavailable" (mark
    /// the proposal `.expired`), never retry-until-success. A held lease
    /// blocks `teardownCurrentVault()` from clearing/switching state until
    /// the caller releases it — see `VaultOperationLeaseCoordinator`.
    func acquireVaultOperationLease(expectedVaultID: String) -> VaultOperationLeaseCoordinator.Lease? {
        guard SettingsStorage.isNotesEnabled(userDefaults: userDefaults),
              configurationState == .configured,
              repository != nil,
              configurationStore.vaultID == expectedVaultID
        else { return nil }
        return vaultOperationLeases.acquireLease()
    }

    /// Saves the open editor's buffer before teardown discards the editor.
    /// `false` (with `lastConfigurationError` set) when the buffer couldn't
    /// be saved and isn't already preserved in a conflict copy — the editor
    /// holds the only copy, so the caller must abort the reset/switch.
    private func preserveEditorBufferForTeardown() async -> Bool {
        guard let editor else { return true }
        await editor.flushPendingSave()
        guard !editor.hasUnpreservedChanges else {
            lastConfigurationError = .unsavedEditorChanges
            return false
        }
        return true
    }

    /// `false` when teardown was refused because the open note's unsaved
    /// buffer couldn't be preserved; nothing was torn down in that case.
    @discardableResult
    private func teardownCurrentVault() async -> Bool {
        // Before anything is torn down: the editor's buffer must reach disk
        // (or already sit in a conflict copy). A late disappearance-triggered
        // flush can't be relied on — it may run after the bookmark is gone.
        guard await preserveEditorBufferForTeardown() else { return false }

        // Marks teardown as beginning (blocking new
        // `acquireVaultOperationLease` calls) and waits for any in-flight
        // approval that already holds a lease to finish, *before* any of the
        // state below is cleared — otherwise a settings switch could begin
        // tearing down `vault`/`repository` while a suspended approval file
        // operation is still using them.
        let teardown = await vaultOperationLeases.beginTeardownAndWaitForDrain()
        defer { vaultOperationLeases.endTeardown(teardown) }
        // Typing may have continued while the drain was suspended. From here
        // to `editor = nil` nothing may suspend, or a new edit could land in
        // a buffer that is about to be discarded.
        guard await preserveEditorBufferForTeardown() else { return false }

        configurationGeneration &+= 1
        // Cancel (rather than merely orphan) any in-flight settings bootstrap
        // — without this, a bootstrap that's already past the
        // `Task.checkCancellation()` guard in `configure(location:)` could
        // still commit a stale vault/repository/indexer after this teardown
        // finishes, undoing the reset/switch this call is performing.
        invalidateConfigurationBootstrapSlot()
        #if os(macOS)
        monitor?.stop()
        monitor = nil
        #endif
        monitoringScope = nil
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        let stoppingReconciler = reconciler
        reconciler = nil
        vault = nil
        indexer = nil
        repository = nil
        editor = nil
        quickCaptureService = nil
        notes = []
        currentLocation = nil
        currentRootURL = nil
        selectedPath = nil
        // A stale create-note failure from the previous vault must not leak
        // into whatever vault (or onboarding state) comes next.
        lastListError = nil

        searchTask?.cancel()
        searchTask = nil
        searchQuery = ""
        searchResults = []
        isSearching = false
        searchError = nil
        backlinks = []
        isLoadingBacklinks = false
        backlinksError = nil
        brokenLinks = []
        isLoadingBrokenLinks = false
        brokenLinksError = nil
        healthSummary = nil
        isRefreshingHealth = false
        healthError = nil
        isRebuildingIndex = false
        rebuildIndexError = nil

        // Stopped only now that the editor is discarded. Any delta still in
        // flight carries the old generation, so it can't touch the new state.
        if let teardownOperationGate {
            await teardownOperationGate.enterAndWaitForRelease()
        }
        await stoppingReconciler?.stop()
        return true
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
        // Captured with the repository so this delta can only ever reach the
        // indexer of the vault it came from.
        let indexer = self.indexer
        _ = await repository.apply(delta: delta)
        if let reconcileOperationGate {
            await reconcileOperationGate.enterAndWaitForRelease()
        }
        // A vault switch may have completed while `apply` was suspended:
        // the old catalog must not replace the new vault's, and an old
        // removal must not touch the new vault's index.
        guard generation == configurationGeneration else { return }
        notes = repository.notes
        editor?.candidateNotes = repository.notes

        _ = await indexer?.apply(delta: delta)
        guard generation == configurationGeneration else { return }
        await refreshHealth()
        guard generation == configurationGeneration else { return }
        if let selectedPath, delta.added.contains(selectedPath) || delta.modified.contains(selectedPath)
            || delta.removed.contains(selectedPath) || delta.renamedPairs.contains(where: { $0.from == selectedPath || $0.to == selectedPath }) {
            await refreshBacklinks()
            if let reconcileBacklinksGate {
                await reconcileBacklinksGate.enterAndWaitForRelease()
            }
            // The selection and editor below must still be this vault's.
            guard generation == configurationGeneration else { return }
        }

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
        await refreshBacklinks()
    }

    /// Lists snapshots for a note while holding the configured vault stable.
    /// A settings reset or vault switch waits for this read to finish instead
    /// of letting a stale sheet populate from the prior vault.
    func revisions(forRelativePath relativePath: String) async throws -> [NoteRevisionMetadata] {
        guard configurationState == .configured, let repository else {
            throw NotesError.underlying("The Notes vault is no longer available.")
        }
        guard let lease = vaultOperationLeases.acquireLease() else {
            throw NotesError.underlying("The Notes vault is changing. Close Revisions and try again.")
        }
        defer { lease.release() }
        return try await repository.revisions(forRelativePath: relativePath)
    }

    /// Restores historical content beside the selected live note, never over
    /// it. The lease keeps a concurrent vault reset/switch from tearing down
    /// the repository while the copy is being published.
    @discardableResult
    func restoreRevisionAsConflictCopy(
        relativePath: String,
        revisionID: String
    ) async throws -> NoteSummary {
        guard configurationState == .configured, let repository else {
            throw NotesError.underlying("The Notes vault is no longer available.")
        }
        guard let lease = vaultOperationLeases.acquireLease() else {
            throw NotesError.underlying("The Notes vault is changing. Close Revisions and try again.")
        }
        defer { lease.release() }

        let restored = try await repository.restoreRevisionAsConflictCopy(
            relativePath: relativePath,
            revisionID: revisionID
        )
        notes = repository.notes
        editor?.candidateNotes = repository.notes
        _ = await indexer?.apply(
            delta: VaultReconciler.ReconcileDelta(
                added: [restored.relativePath],
                modified: [],
                removed: [],
                renamedPairs: []
            )
        )
        await refreshHealth()
        return restored
    }

    /// Forces `currentLocation`/`notes` to catch up with their sources of
    /// truth instead of waiting on the next FSEvents hint or the 300s
    /// periodic rescan. `NotesSettingsView` calls this on every appearance:
    /// its own catalog/location-derived stats (`stats.locationDescription`,
    /// `stats.noteCount`) can otherwise sit stale for up to five minutes —
    /// or indefinitely, if the live vault's FSEvents watch never established
    /// (e.g. a security-scoped bookmark that resolves but whose monitoring
    /// scope silently fails) — after notes are added/removed outside the app
    /// while Settings, not the notes list, is what's on screen. Re-reading
    /// `currentLocation` from persisted settings (rather than trusting the
    /// in-memory value) is a deliberate self-heal: it costs nothing when
    /// already correct, and settings/UserDefaults remain the single source
    /// of truth for which vault is configured.
    func refreshCatalog() async {
        guard repository != nil else { return }
        if currentLocation != nil {
            currentLocation = SettingsStorage.loadNotesVaultLocation(userDefaults: userDefaults)
        }
        await reconciler?.rescanNow()
    }

    @discardableResult
    func createNote() async -> String? {
        guard let repository else { return nil }
        lastListError = nil
        do {
            let folder = SettingsStorage.loadNotesDefaultNewNoteFolder(userDefaults: userDefaults)
            let summary = try await repository.create(title: "Untitled", folder: folder)
            notes = repository.notes
            editor?.candidateNotes = repository.notes
            await select(path: summary.relativePath)
            return selectedPath == summary.relativePath ? summary.relativePath : nil
        } catch {
            lastListError = NotesError.from(error)
            return nil
        }
    }

    /// Shared mutation path for the Notes toolbar and Workspace capture
    /// action. One service instance per configured vault prevents two UI
    /// surfaces from racing the same read/append/save sequence.
    @discardableResult
    func quickCapture(
        _ text: String,
        destination: NotesQuickCaptureService.Destination
    ) async throws -> String {
        guard let repository, let quickCaptureService else {
            throw NotesError.underlying("Set up a Notes vault before using quick capture.")
        }

        let previousPaths = Set(repository.notes.map(\.relativePath))
        let result: NotesQuickCaptureService.CaptureResult
        switch destination {
        case .dailyNote:
            result = try await quickCaptureService.captureDaily(
                text,
                folder: SettingsStorage.loadNotesDailyNoteFolder(userDefaults: userDefaults)
            )
        case .standaloneNote:
            result = try await quickCaptureService.captureStandalone(
                text,
                folder: SettingsStorage.loadNotesDefaultNewNoteFolder(userDefaults: userDefaults)
            )
        }

        notes = repository.notes
        editor?.candidateNotes = repository.notes
        let delta = previousPaths.contains(result.path)
            ? VaultReconciler.ReconcileDelta(added: [], modified: [result.path], removed: [], renamedPairs: [])
            : VaultReconciler.ReconcileDelta(added: [result.path], modified: [], removed: [], renamedPairs: [])
        _ = await indexer?.apply(delta: delta)
        await refreshHealth()
        await select(path: result.path)
        NotificationCenter.default.post(name: .notesQuickCaptureDidChange, object: nil)
        return result.path
    }

    func capturedTodayCount(now: Date = .now) -> Int {
        quickCaptureService?.capturedTodayCount(now: now)
            ?? NotesCaptureStatsStore(userDefaults: userDefaults).capturedCount(on: now)
    }

    /// Dismisses a create-note (or other catalog-mutation) failure banner.
    func dismissListError() {
        lastListError = nil
    }

    // MARK: - Search

    /// Debounced hybrid search, driven by `NotesView`'s search field on every
    /// keystroke. An empty query cancels any in-flight search and clears
    /// results immediately rather than showing stale hits from the previous
    /// query. `configurationGeneration` is captured up front so a vault
    /// switch/reset mid-search discards the result instead of applying it to
    /// the new vault's state.
    func setSearchQuery(_ query: String) {
        searchTask?.cancel()
        searchTask = nil
        searchQuery = query
        guard !query.isEmpty else {
            searchResults = []
            searchError = nil
            isSearching = false
            return
        }
        guard let indexer else {
            searchResults = []
            return
        }
        isSearching = true
        searchError = nil
        let generation = configurationGeneration
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            do {
                let hits = try await indexer.search(query: query)
                guard !Task.isCancelled, self.configurationGeneration == generation, self.searchQuery == query else { return }
                self.searchResults = hits
                self.searchError = nil
                self.isSearching = false
            } catch {
                guard !Task.isCancelled, self.configurationGeneration == generation, self.searchQuery == query else { return }
                self.searchError = NotesError.from(error)
                self.isSearching = false
            }
        }
    }

    func dismissSearchError() {
        searchError = nil
    }

    // MARK: - Backlinks & broken links

    /// Refreshes `backlinks` for the current `selectedPath`. Called on
    /// selection change and whenever a reconcile delta touches the selected
    /// note or its incoming links.
    func refreshBacklinks() async {
        guard let selectedPath else {
            backlinks = []
            backlinksError = nil
            isLoadingBacklinks = false
            return
        }
        guard let indexer else {
            backlinks = []
            return
        }
        let generation = configurationGeneration
        isLoadingBacklinks = true
        do {
            let links = try await indexer.backlinks(to: selectedPath)
            guard generation == configurationGeneration, self.selectedPath == selectedPath else { return }
            backlinks = links
            backlinksError = nil
            isLoadingBacklinks = false
        } catch {
            guard generation == configurationGeneration, self.selectedPath == selectedPath else { return }
            backlinksError = NotesError.from(error)
            isLoadingBacklinks = false
        }
    }

    func dismissBacklinksError() {
        backlinksError = nil
    }

    func refreshBrokenLinks() async {
        guard let indexer else {
            brokenLinks = []
            return
        }
        let generation = configurationGeneration
        isLoadingBrokenLinks = true
        do {
            let links = try await indexer.brokenLinks()
            guard generation == configurationGeneration else { return }
            brokenLinks = links
            brokenLinksError = nil
            isLoadingBrokenLinks = false
        } catch {
            guard generation == configurationGeneration else { return }
            brokenLinksError = NotesError.from(error)
            isLoadingBrokenLinks = false
        }
    }

    func dismissBrokenLinksError() {
        brokenLinksError = nil
    }

    // MARK: - Vault health & index rebuild

    func refreshHealth() async {
        guard let indexer else {
            healthSummary = nil
            return
        }
        let generation = configurationGeneration
        isRefreshingHealth = true
        let summary = await indexer.healthSummary()
        guard generation == configurationGeneration else { return }
        healthSummary = summary
        healthError = nil
        isRefreshingHealth = false
    }

    /// Settings' "Rebuild Index" action: wipes and reindexes every note from
    /// scratch (the index is a rebuildable cache, never the source of
    /// truth), then refreshes health so the UI reflects the outcome.
    func rebuildIndex() async {
        guard let indexer else { return }
        isRebuildingIndex = true
        rebuildIndexError = nil
        do {
            _ = try await indexer.rebuildAll()
        } catch {
            rebuildIndexError = NotesError.from(error)
        }
        isRebuildingIndex = false
        await refreshHealth()
        await refreshBacklinks()
        await refreshBrokenLinks()
    }

    func dismissRebuildIndexError() {
        rebuildIndexError = nil
    }

    /// Settings' embeddings toggle: applies the change to the live indexer
    /// immediately (`NotesIndexer.setEmbeddingProvider` decides whether that
    /// needs a rebuild) rather than waiting for the next app launch, so
    /// disabling stops vector use right away and enabling produces usable
    /// embeddings without a stale mixed state.
    func updateEmbeddingsEnabled(_ enabled: Bool) async {
        guard let indexer else { return }
        let generation = configurationGeneration
        let provider: TextEmbeddingProvider? = enabled ? NLSentenceEmbeddingProvider() : nil
        _ = await indexer.setEmbeddingProvider(provider)
        guard generation == configurationGeneration else { return }
        await refreshHealth()
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

    // MARK: - AI read tools (Phase 4)

    /// Lazily bootstraps the vault/index from persisted settings so
    /// `search_notes`/`read_note` are available on a cold chat launch, not
    /// only after `NotesView`/`NotesSettingsView` has been opened once this
    /// launch. Call before reading `isAvailableForReadTools` (`Tool
    /// .isConfigured` itself must stay synchronous, so it cannot bootstrap on
    /// its own).
    ///
    /// Deliberately does not touch `activeCount`/`startPeriodicRescanIfNeeded()`
    /// — those stay tied exclusively to a Notes view's `activate()`/
    /// `deactivate()` lifecycle, so a chat that never opens Notes doesn't
    /// leave a periodic rescan loop running in the background. A no-op once
    /// `configurationState` has left `.unknown` (via this method, or via
    /// `activate()`), so repeat calls on every chat completion or `ToolsView`
    /// appearance are cheap. Concurrent callers — including `activate()`
    /// itself, e.g. `NotesView` opening while a chat is cold-launching the
    /// read tools — coalesce onto one in-flight bootstrap via
    /// `ensureConfigurationBootstrapped`/`configurationBootstrapTask` rather
    /// than racing two `configure(location:)` passes.
    func prepareReadToolsIfNeeded() async {
        await ensureConfigurationBootstrapped(skipIfDisabled: true)
    }

    /// Gate for `search_notes`/`read_note`: Notes enabled in Settings, a vault
    /// configured, and an index actually constructed. `Tool.isConfigured`
    /// reads this synchronously (see its `MainActor.assumeIsolated` use —
    /// safe because both call sites, `ChatCompletionService` and
    /// `ToolsView`, are themselves `@MainActor`, and only ever read state
    /// `prepareReadToolsIfNeeded()` already finished mutating before they run
    /// — see their call sites), and `execute` rechecks it so a tool invoked
    /// directly right after Notes is disabled still throws
    /// `ToolError.notConfigured` instead of running stale.
    var isAvailableForReadTools: Bool {
        SettingsStorage.isNotesEnabled(userDefaults: userDefaults)
            && configurationState == .configured
            && repository != nil
            && indexer != nil
    }

    private static let readToolsUnavailableReason = "Notes is disabled, or no vault/index is configured."

    /// Test-only synchronization seam for the stale-result guards below.
    /// `nil` in production, so it adds no behavior there. A test sets this,
    /// then `await`s `waitUntilEntered()` to know the real `NotesIndexer
    /// .search`/`NotesRepository.read` call has already returned its result
    /// — not merely started, which an unsynchronized `async let` can't
    /// guarantee — before racing a concurrent reset/switch and calling
    /// `release()` to let the held result reach the guard below. This proves
    /// the *post-operation* generation recheck actually discards a result
    /// produced by a now-stale vault, not just an initial availability check
    /// made before the operation ran.
    @ObservationIgnored
    var toolOperationGate: ToolOperationGate?

    /// Test-only, like `toolOperationGate`: holds a reconcile delta right
    /// after `NotesRepository.apply(delta:)` returns, so a test can complete
    /// a vault switch inside that real suspension window.
    @ObservationIgnored
    var reconcileOperationGate: ToolOperationGate?

    /// Test-only, like `reconcileOperationGate`: holds a reconcile delta
    /// right after its `refreshBacklinks()` returns.
    @ObservationIgnored
    var reconcileBacklinksGate: ToolOperationGate?

    /// Test-only: holds `teardownCurrentVault()` just before it stops the
    /// old reconciler, so a test can type into that suspension window.
    @ObservationIgnored
    var teardownOperationGate: ToolOperationGate?

    /// `search_notes`' sole search boundary — the indexer, never the raw
    /// index database. Captures `configurationGeneration` and the indexer
    /// itself before the `await`: if a vault reset/switch completes while
    /// the search is in flight, the awaited result belongs to a vault that's
    /// no longer configured, so it's discarded (as `ToolError.notConfigured`,
    /// not a stale success) rather than returned. `SearchNotesTool.execute`
    /// preserves this `ToolError` as-is instead of re-wrapping it.
    func searchNotesForTool(query: String, limit: Int) async throws -> [SearchHit] {
        let generation = configurationGeneration
        guard let indexer, isAvailableForReadTools else {
            throw ToolError.notConfigured(toolName: "Search Notes", reason: Self.readToolsUnavailableReason)
        }
        let hits = try await indexer.search(query: query, limit: limit)
        if let toolOperationGate {
            await toolOperationGate.enterAndWaitForRelease()
        }
        guard generation == configurationGeneration, isAvailableForReadTools else {
            throw ToolError.notConfigured(toolName: "Search Notes", reason: Self.readToolsUnavailableReason)
        }
        return hits
    }

    /// `read_note`'s sole read boundary — the repository, never `NotesVault`
    /// directly. Same stale-result guard as `searchNotesForTool`: the
    /// repository is captured before the `await`, and its result is
    /// discarded in favor of `ToolError.notConfigured` if the configuration
    /// generation or availability gate moved while the read was in flight.
    func readNoteForTool(relativePath: String) async throws -> NoteFileSnapshot {
        let generation = configurationGeneration
        guard let repository, isAvailableForReadTools else {
            throw ToolError.notConfigured(toolName: "Read Note", reason: Self.readToolsUnavailableReason)
        }
        // Model-facing reads see only what enumeration exposes — never
        // dotfiles, `.git/`, or non-Markdown files.
        guard VaultIgnoreRules.isVisibleMarkdownNotePath(relativePath) else {
            throw NotesError.invalidNotePath(relativePath)
        }
        let snapshot = try await repository.read(relativePath: relativePath)
        if let toolOperationGate {
            await toolOperationGate.enterAndWaitForRelease()
        }
        guard generation == configurationGeneration, isAvailableForReadTools else {
            throw ToolError.notConfigured(toolName: "Read Note", reason: Self.readToolsUnavailableReason)
        }
        return snapshot
    }
}

/// Deterministic two-phase rendezvous used only by tests (see
/// `NotesFeatureModel.toolOperationGate`) to pause a facade call exactly
/// where a real suspension already occurs, without sleeps or timing
/// assumptions. `enterAndWaitForRelease()` is called from inside the
/// production code path under test; `waitUntilEntered()`/`release()` are
/// called from the test to synchronize around it.
final class ToolOperationGate: @unchecked Sendable {
    private let enteredContinuation: AsyncStream<Void>.Continuation
    private let enteredStream: AsyncStream<Void>
    private let releaseContinuation: AsyncStream<Void>.Continuation
    private let releaseStream: AsyncStream<Void>

    init() {
        var enteredContinuation: AsyncStream<Void>.Continuation!
        enteredStream = AsyncStream { enteredContinuation = $0 }
        self.enteredContinuation = enteredContinuation
        var releaseContinuation: AsyncStream<Void>.Continuation!
        releaseStream = AsyncStream { releaseContinuation = $0 }
        self.releaseContinuation = releaseContinuation
    }

    func enterAndWaitForRelease() async {
        enteredContinuation.yield(())
        var iterator = releaseStream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func waitUntilEntered() async {
        var iterator = enteredStream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func release() {
        releaseContinuation.yield(())
    }
}
