import Foundation
import SwiftUI

/// Renders a `ReviewCardPayload` to a SwiftUI view. Each review type registers
/// a renderer. Looked up from the chat UI when a `ChatMessage` carries
/// `reviewCardData`. Future review types add a `ReviewType` case + renderer —
/// no SwiftData model change required.
@MainActor
struct ReviewCardRendererRegistry {
    static let shared = ReviewCardRendererRegistry()

    /// Dispatches payload rendering to the renderer for `payload.reviewType`.
    /// `onItemActioned` is invoked with the acted-upon `ReviewItem.id` so the
    /// host (which owns the `ChatMessage`) can drop that item from the card —
    /// see `ChatMessageRow`. Kept as a UUID-typed callback rather than passing
    /// the `ChatMessage` itself so the renderer stays free of SwiftData and
    /// future `.calendar` / `.reminders` cards reuse it cleanly.
    @ViewBuilder
    func makeView(
        for payload: ReviewCardPayload,
        dispatcherProvider: @escaping (ReviewType) -> AnyHashableReviewActionDispatcher?,
        onItemActioned: @escaping (UUID) -> Void,
        onItemView: @escaping (UUID) -> Void,
        onRefreshAnalysis: @escaping () async -> Void
    ) -> some View {
        switch payload.reviewType {
        case .email:
            EmailReviewCardRenderer(
                payload: payload,
                dispatcher: dispatcherProvider(.email) ?? AnyHashableReviewActionDispatcher(NoOpReviewActionDispatcher()),
                onItemActioned: onItemActioned,
                onItemView: onItemView,
                onRefreshAnalysis: onRefreshAnalysis
            )
        case .calendar:
            CalendarReviewCardRenderer(
                payload: payload,
                onItemActioned: onItemActioned,
                onItemView: onItemView,
                onRefreshAnalysis: onRefreshAnalysis
            )
        case .reminders:
            Text("Reviewer for \(payload.reviewType.rawValue) not yet implemented.")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .unknown:
            Text("This review card is from a newer version and can't be displayed.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

/// No-op dispatcher used when no real dispatcher is wired in (preview, etc).
@MainActor
final class NoOpReviewActionDispatcher: ReviewActionDispatcher {
    let reviewType: ReviewType = .email
    func perform(action: ReviewActionToken, itemID: UUID) async {}
}
