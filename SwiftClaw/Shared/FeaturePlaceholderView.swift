import SwiftUI

/// A centered icon, title, and message used as the empty/placeholder state for
/// feature screens that have no content to show yet.
struct FeaturePlaceholderView: View {
    let systemImage: String
    let title: String
    let message: String
    var badge: String? = nil

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: systemImage)
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text(title)
                .font(.title2)
                .fontWeight(.semibold)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.tertiary)

            if let badge {
                Text(badge)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static func comingSoon(
        systemImage: String,
        title: String,
        message: String = "This feature is planned for a future SwiftClaw update."
    ) -> FeaturePlaceholderView {
        FeaturePlaceholderView(
            systemImage: systemImage,
            title: title,
            message: message,
            badge: "Coming Soon"
        )
    }
}

#Preview {
    FeaturePlaceholderView(
        systemImage: "wrench.and.screwdriver",
        title: "Tools",
        message: "No tools configured"
    )
}
