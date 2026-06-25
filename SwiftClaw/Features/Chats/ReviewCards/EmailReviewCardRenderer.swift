import SwiftUI
import SwiftData
import os

/// Emails review-card renderer. Used by `ReviewCardRendererRegistry` when a
/// `ChatMessage` carries a `ReviewCardPayload` of type `.email`. Tap a row's
/// body → navigates to the email in EmailView. Tap the action-label badge →
/// confirmation dialog → dispatcher performs the action. Long-press → context
/// menu of View / Archive / Flag / Add Notes / Delete.
struct EmailReviewCardRenderer: View {
    let payload: ReviewCardPayload
    let dispatcher: AnyHashableReviewActionDispatcher
    /// Invoked with the acted-upon `ReviewItem.id` (the payload-local id, not
    /// `itemID`) once an action is dispatched. The host drops that item from
    /// the persisted card so the row vanishes on the next render and stays
    /// gone across relaunches. Optimistic — fires regardless of server
    /// outcome, matching the "local mutation always applies; server failures
    /// surface via MailSyncMonitor" contract the dispatcher + detail view use.
    let onItemActioned: (UUID) -> Void
    /// Invoked with `ReviewItem.itemID` (the email's UUID) when the user taps
    /// the row body (not the action badge) — the host navigates to EmailView
    /// with that email's thread selected.
    let onItemView: (UUID) -> Void

    @State private var pendingItem: ReviewItem?
    @State private var pendingAction: ReviewActionToken?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "envelope.badge")
                    .foregroundStyle(.tint)
                Text("Inbox review")
                    .font(.headline)
                Spacer()
            }

            if payload.items.isEmpty {
                // The last actionable item was just removed — surface a
                // compact "all caught up" line instead of a bare header. The
                // sibling summary `ChatMessage` (next row in the chat) still
                // carries the point-in-time pass summary.
                Text("All caught up — nothing left to action.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(payload.items) { item in
                    row(for: item)
                    if item.id != payload.items.last?.id {
                        Divider()
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.10))
        }
        .confirmationDialog(
            pendingAction.map { $0.displayName } ?? "Confirm",
            isPresented: Binding(
                get: { pendingItem != nil },
                set: { if !$0 { pendingItem = nil; pendingAction = nil } }
            ),
            presenting: pendingItem
        ) { item in
            if let action = pendingAction {
                Button(action.displayName, role: action.role) {
                    let actedItemID = item.id
                    pendingItem = nil
                    pendingAction = nil
                    Task {
                        await dispatcher.dispatcher.perform(action: action, itemID: item.itemID)
                    }
                    // Optimistically remove from the card — server failures
                    // surface via `MailSyncMonitor` rather than keeping the
                    // row stuck (matches the dispatcher's "local mutation
                    // always applies" contract).
                    onItemActioned(actedItemID)
                }
            }
            Button("Cancel", role: .cancel) {
                pendingItem = nil
                pendingAction = nil
            }
        } message: { _ in
            Text("Apply this action to the selected email?")
        }
    }

    @ViewBuilder
    private func row(for item: ReviewItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.subject ?? "Email")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                Spacer()
                Button {
                    pendingItem = item
                    pendingAction = item.action ?? .review
                } label: {
                    Text(item.actionLabel)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.tint.opacity(0.15), in: Capsule())
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.borderless)
            }
            if let summary = item.summary, !summary.isEmpty {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            if let sender = item.sender, !sender.isEmpty {
                Text(sender)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onItemView(item.itemID)
        }
        .contextMenu {
            ForEach(ReviewActionToken.allCases.filter { $0 != .reply }) { action in
                Button(action.displayName) {
                    pendingItem = item
                    pendingAction = action
                }
            }
        }
    }
}
