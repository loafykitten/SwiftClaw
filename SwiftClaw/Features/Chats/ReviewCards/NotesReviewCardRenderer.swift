import SwiftUI

/// Read-only Notes vault-hygiene card. Finding UUIDs are pass-local integrity
/// tokens, so rows deliberately do not pretend they can navigate to a stable
/// file identity. Paths remain visible as context.
struct NotesReviewCardRenderer: View {
    let payload: ReviewCardPayload
    let onRefreshAnalysis: () async -> Void

    @State private var isRefreshing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "note.text")
                    .foregroundStyle(.tint)
                Text("Notes review")
                    .font(.headline)
                Spacer()
                Button(action: refresh) {
                    if isRefreshing {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "sparkles")
                            .frame(width: 16, height: 16)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(isRefreshing)
                .help("Run updated Notes analysis")
                .accessibilityLabel("Run updated Notes analysis")
            }

            if payload.items.isEmpty {
                Text("All clear — nothing needs attention in this review.")
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
        .accessibilityIdentifier("notes.review.card")
    }

    private func row(_ item: ReviewItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.subject ?? "Notes finding")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                if let kind = item.sender, !kind.isEmpty {
                    Text(kind)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if let summary = item.summary, !summary.isEmpty {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let metadata = [item.date, item.accountLabel]
                .compactMap(\.self)
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
            if !metadata.isEmpty {
                Text(metadata)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            await onRefreshAnalysis()
            isRefreshing = false
        }
    }
}
