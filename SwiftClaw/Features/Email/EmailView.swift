import SwiftUI

struct EmailView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "envelope")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Email")
                .font(.title2)
                .fontWeight(.semibold)
            Text("No messages")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
