import SwiftUI

struct MemoryView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "brain")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Memory")
                .font(.title2)
                .fontWeight(.semibold)
            Text("No memories stored")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
