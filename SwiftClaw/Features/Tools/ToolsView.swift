import SwiftUI

struct ToolsView: View {
    @State private var tools: [ToolListing] = []

    var body: some View {
        Group {
            if tools.isEmpty {
                emptyState
            } else {
                List(tools) { listing in
                    HStack(spacing: 12) {
                        Image(systemName: listing.systemImage)
                            .font(.title3)
                            .frame(width: 28)
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(listing.displayName)
                                .font(.headline)
                            Text(listing.description)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }

                        Spacer()

                        Text(listing.isConfigured ? "Ready" : "Needs setup")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                (listing.isConfigured ? Color.green : Color.orange).opacity(0.15),
                                in: Capsule()
                            )
                            .foregroundStyle(listing.isConfigured ? .green : .orange)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .onAppear(perform: refresh)
    }

    private var emptyState: some View {
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

    private func refresh() {
        tools = ToolRegistry.shared.tools.map(ToolListing.init)
    }
}

private struct ToolListing: Identifiable {
    let id: String
    let displayName: String
    let description: String
    let systemImage: String
    let isConfigured: Bool

    init(tool: any Tool) {
        id = tool.name
        displayName = tool.displayName
        description = tool.description
        systemImage = tool.systemImage
        isConfigured = tool.isConfigured
    }
}
