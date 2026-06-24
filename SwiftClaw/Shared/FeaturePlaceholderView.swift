import SwiftUI

/// A centered icon, title, and message used as the empty/placeholder state for
/// feature screens that have no content to show yet.
struct FeaturePlaceholderView: View {
    let systemImage: String
    let title: String
    let message: String

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
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    FeaturePlaceholderView(
        systemImage: "wrench.and.screwdriver",
        title: "Tools",
        message: "No tools configured"
    )
}
