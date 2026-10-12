import Foundation
import SwiftData

/// Scripts the outcome of repository saves through their `persist` seam:
/// each queued outcome answers one save (`true` succeeds, `false` throws
/// `InjectedSaveFailure` without touching the store). Once the queue is
/// empty every save succeeds.
@MainActor
final class ScriptedSaves {
    struct InjectedSaveFailure: Error {}

    var outcomes: [Bool] = []

    func persist(_ context: ModelContext) throws {
        if !outcomes.isEmpty, !outcomes.removeFirst() {
            throw InjectedSaveFailure()
        }
        try context.save()
    }
}
