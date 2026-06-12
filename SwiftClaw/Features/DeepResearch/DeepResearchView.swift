import SwiftUI

struct DeepResearchView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Deep Research")
                .font(.title2)
                .fontWeight(.semibold)
            Text("Start a deep research query")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
