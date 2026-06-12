import SwiftUI

struct ToolsView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Tools")
                .font(.title2)
                .fontWeight(.semibold)
            Text("No tools configured")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
