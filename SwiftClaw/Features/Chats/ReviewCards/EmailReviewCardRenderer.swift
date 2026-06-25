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

    @State private var pendingItem: ReviewItem?
    @State private var pendingAction: ReviewActionToken?
    @State private var isRefreshingAnalysis = false

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
    let selectAction: (ReviewActionToken) -> Void
    let performAction: (ReviewActionToken) -> Void
    let viewEmail: () -> Void

    @State private var horizontalOffset: CGFloat = 0

    private let actionWidth: CGFloat = 100
    private var triggerDistance: CGFloat {
        actionWidth + 18
    }
    private var maxDragDistance: CGFloat {
        max(actionWidth, triggerDistance)
    }

    private var recommendedAction: ReviewActionToken {
        item.action ?? .review
    }

    private var revealProgress: Double {
        min(Double(abs(horizontalOffset) / triggerDistance), 1)
    }

    var body: some View {
        ZStack {
            swipeBackground
            rowContent
                .offset(x: horizontalOffset)
                .gesture(dragGesture)
        }
        .clipShape(Rectangle())
        .animation(.easeOut(duration: 0.16), value: horizontalOffset)
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

    private var swipeBackground: some View {
        HStack {
            Spacer()
            HStack(spacing: 8) {
                Image(systemName: recommendedAction.swipeSystemImage)
                    .font(.headline)
                Text(recommendedAction.displayName)
                    .font(.caption)
                    .fontWeight(.semibold)
            }
            .frame(width: actionWidth)
            .frame(maxHeight: .infinity)
            .background(recommendedAction.swipeColor.opacity(0.25 + 0.65 * revealProgress))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(revealProgress == 0 ? 0 : 1)
        .accessibilityHidden(true)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                horizontalOffset = max(-maxDragDistance, min(0, value.translation.width))
            }
            .onEnded { value in
                let shouldPerform = value.translation.width <= -triggerDistance
                horizontalOffset = 0
                guard shouldPerform else { return }
                performAction(recommendedAction)
                if recommendedAction == .review {
                    viewEmail()
                }
            }
    }
}

private extension ReviewActionToken {
    var swipeSystemImage: String {
        switch self {
        case .review: "envelope.open"
        case .flag: "flag.fill"
        case .reply: "arrowshape.turn.up.left.fill"
        case .delete: "trash.fill"
        case .archive: "archivebox.fill"
        }
    }

    var swipeColor: Color {
        switch self {
        case .review: .blue
        case .flag: .orange
        case .reply: .green
        case .delete: .red
        case .archive: .gray
        }
    }
}
