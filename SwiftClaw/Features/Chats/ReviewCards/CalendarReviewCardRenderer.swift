import SwiftUI

/// Calendar review-card renderer. Simpler than the email card: every row's
/// action is "View" (routes to the calendar), so there's no dispatcher, no
/// destructive confirmations, and no swipe actions.
struct CalendarReviewCardRenderer: View {
    let payload: ReviewCardPayload
    /// Invoked with the acted-upon `ReviewItem.id` so the host drops the row
    /// from the persisted card.
    let onItemActioned: (UUID) -> Void
    /// Invoked with `ReviewItem.itemID` (the `CalendarEvent.id`).
    let onItemView: (UUID) -> Void
    let onRefreshAnalysis: () async -> Void

    @State private var isRefreshingAnalysis = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "calendar.badge.exclamationmark")
                    .foregroundStyle(.tint)
                Text("Calendar review")
                    .font(.headline)
                Spacer()
                Button {
                    refreshAnalysis()
                } label: {
                    if isRefreshingAnalysis {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "sparkles")
                            .frame(width: 16, height: 16)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(isRefreshingAnalysis)
                .help("Run updated calendar analysis")
                .accessibilityLabel("Run updated calendar analysis")
            }

            if payload.items.isEmpty {
                Text("All clear — nothing left on this review.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(payload.items) { item in
                        row(item)
                        if item.id != payload.items.last?.id {
                            Divider()
                        }
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
    }

    private func row(_ item: ReviewItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.subject ?? "Event")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                Spacer()
                Button {
                    view(item)
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
            let metadata = [item.date, item.accountLabel]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
            if !metadata.isEmpty {
                Text(metadata)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(.rect)
        .onTapGesture { view(item) }
    }

    private func view(_ item: ReviewItem) {
        onItemView(item.itemID)
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
