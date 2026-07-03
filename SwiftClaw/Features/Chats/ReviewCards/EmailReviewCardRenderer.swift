import SwiftUI
import SwiftData
import os

/// Emails review-card renderer. Used by `ReviewCardRendererRegistry` when a
/// `ChatMessage` carries a `ReviewCardPayload` of type `.email`. Tap a row's
/// body → navigates to the email in EmailView. Tap the action-label badge →
/// dispatcher performs the action. Long-press → context menu of View /
/// Archive / Flag / Delete.
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
    let onRefreshAnalysis: () async -> Void

    @AppStorage(SettingsKeys.emailReviewSlideAction)
    private var slideActionRaw = SettingsStorage.defaultEmailReviewSlideAction.rawValue
    @State private var pendingItem: ReviewItem?
    @State private var pendingAction: ReviewActionToken?
    @State private var isRefreshingAnalysis = false

    private var slideAction: ReviewActionToken {
        EmailReviewSlideAction(rawValue: slideActionRaw)?.token
            ?? SettingsStorage.defaultEmailReviewSlideAction.token
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "envelope.badge")
                    .foregroundStyle(.tint)
                Text("Inbox review")
                    .font(.headline)
                Spacer()
                Button {
                    refreshAnalysis()
                } label: {
                    if isRefreshingAnalysis || MailSyncMonitor.shared.isReviewing {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "sparkles")
                            .frame(width: 16, height: 16)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(isRefreshingAnalysis || MailSyncMonitor.shared.isReviewing)
                .help("Run updated email analysis")
                .accessibilityLabel("Run updated email analysis")
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
                    EmailReviewCardRow(
                        item: item,
                        slideAction: slideAction,
                        selectAction: { action in selectAction(action, for: item) },
                        performAction: { action in perform(action: action, for: item) },
                        viewEmail: { onItemView(item.itemID) }
                    )
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
                    pendingItem = nil
                    pendingAction = nil
                    perform(action: action, for: item)
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

    /// Handles a deliberate action pick (action badge or context menu). `review`
    /// is non-destructive, so it performs immediately and opens the email —
    /// matching the swipe and badge-tap paths. Everything else routes through
    /// the confirmation dialog first.
    private func selectAction(_ action: ReviewActionToken, for item: ReviewItem) {
        if action == .review {
            perform(action: action, for: item)
            onItemView(item.itemID)
        } else {
            pendingItem = item
            pendingAction = action
        }
    }

    private func perform(action: ReviewActionToken, for item: ReviewItem) {
        Task {
            await dispatcher.dispatcher.perform(action: action, itemID: item.itemID)
        }
        // Optimistically remove from the card — server failures surface via
        // `MailSyncMonitor` rather than keeping the row stuck.
        onItemActioned(item.id)
    }

    private func refreshAnalysis() {
        guard !isRefreshingAnalysis else { return }
        isRefreshingAnalysis = true
        Task {
            await onRefreshAnalysis()
            isRefreshingAnalysis = false
        }
    }
}

private struct EmailReviewCardRow: View {
    let item: ReviewItem
    let slideAction: ReviewActionToken
    let selectAction: (ReviewActionToken) -> Void
    let performAction: (ReviewActionToken) -> Void
    let viewEmail: () -> Void

    private var recommendedAction: ReviewActionToken {
        item.action ?? .review
    }

    var body: some View {
        EmailQuickActionSwipe(
            action: slideAction,
            onPerform: { action in
                performAction(action)
                if action == .review {
                    viewEmail()
                }
            }
        ) {
            rowContent
        }
    }

    private var rowContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.subject ?? "Email")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                Spacer()
                Button {
                    selectAction(recommendedAction)
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
                    .fixedSize(horizontal: false, vertical: true)
            }
            let metadata = [item.sender, item.date]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
            if !metadata.isEmpty {
                Text(metadata)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            viewEmail()
        }
        .contextMenu {
            ForEach(ReviewActionToken.allCases.filter { $0 != .reply }) { action in
                Button(action.displayName) {
                    selectAction(action)
                }
            }
        }
    }
}
