import Foundation

/// Performs an action on a review item, resolved by `actionToken`. Conforming
/// types are referenced by their hashable boxing so SwiftUI can capture them in
/// views without losing value semantics.
@MainActor
protocol ReviewActionDispatcher: AnyObject {
    var reviewType: ReviewType { get }
    func perform(action: ReviewActionToken, itemID: UUID) async
}

/// Type-erased wrapper so the chat UI can hold any dispatcher uniformly.
@MainActor
final class AnyHashableReviewActionDispatcher: Hashable, @unchecked Sendable {
    let dispatcher: any ReviewActionDispatcher

    init(_ dispatcher: any ReviewActionDispatcher) {
        self.dispatcher = dispatcher
    }

    nonisolated static func == (lhs: AnyHashableReviewActionDispatcher, rhs: AnyHashableReviewActionDispatcher) -> Bool {
        ObjectIdentifier(lhs) == ObjectIdentifier(rhs)
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}
