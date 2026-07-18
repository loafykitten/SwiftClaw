import Foundation
import Observation
import SwiftData

/// The Memory feature coordinator: a thin `@MainActor` seam that owns the
/// single `MemoryRepository` and hands it to views, the Workspace tile, and
/// (in Phase 2) the shared-registry read tools. Far simpler than
/// `NotesFeatureModel` — Memory is pure SwiftData, so there is no vault,
/// watcher, or lease machinery to coordinate.
///
/// Construction does no I/O (per convention); `configure(modelContainer:)`
/// is called once from `AppBootstrap`. UI list reads still go through
/// `@Query` in views; `tileSummary` exists because the Workspace tile lives
/// outside the Memory view hierarchy and only needs counts, refreshed on
/// appearance via `refreshTileSummary()`.
@MainActor
@Observable
final class MemoryFeatureModel {
    static let shared = MemoryFeatureModel()

    private(set) var repository: MemoryRepository?
    /// Built alongside the repository; caches the serialized store keyed on
    /// `MemoryRepository.mutationGeneration` — see `MemoryPromptBuilder`.
    private(set) var promptBuilder: MemoryPromptBuilder?
    private(set) var tileSummary: MemoryRepository.Summary?

    init() {}

    func configure(modelContainer: ModelContainer) {
        guard repository == nil else { return }
        let repository = MemoryRepository(modelContext: modelContainer.mainContext)
        self.repository = repository
        promptBuilder = MemoryPromptBuilder(repository: repository)
    }

    /// Whether Memory is usable right now: enabled in Settings and
    /// configured with a container. The Phase-2 read tools' `isConfigured`
    /// gate reads this synchronously.
    var isAvailable: Bool {
        SettingsStorage.isMemoryEnabled() && repository != nil
    }

    func refreshTileSummary() {
        guard let repository else { return }
        // The Memory landing creates the Inbox lazily on first open; ensure
        // it here too so the tile's collection count never disagrees with
        // the list the user is about to see (the tile is only rendered when
        // the feature is enabled, so this never creates data for a disabled
        // feature).
        _ = repository.ensureInbox()
        tileSummary = repository.summary()
    }
}
