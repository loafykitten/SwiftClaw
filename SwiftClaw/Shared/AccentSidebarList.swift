import SwiftUI

struct AccentSidebarList<Item: Identifiable & Hashable>: View {
    let items: [Item]
    @Binding var selection: Item?
    let accent: Color
    var topContentInset: CGFloat = 0
    let title: (Item) -> String
    let systemImage: (Item) -> String
    var showsBadge: (Item) -> Bool = { _ in false }

    var body: some View {
        List {
            ForEach(items) { item in
                AccentSidebarRow(
                    title: title(item),
                    systemImage: systemImage(item),
                    accent: accent,
                    isSelected: selection == item,
                    showsBadge: showsBadge(item)
                ) {
                    selection = item
                }
                .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.sidebar)
        .contentMargins(.top, topContentInset, for: .scrollContent)
    }
}

private struct AccentSidebarRow: View {
    let title: String
    let systemImage: String
    let accent: Color
    let isSelected: Bool
    let showsBadge: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var selectionOpacity: Double {
        colorScheme == .dark ? 0.28 : 0.18
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? AnyShapeStyle(accent) : AnyShapeStyle(.secondary))

                Text(title)
                    .foregroundStyle(.primary)

                Spacer(minLength: 0)

                if showsBadge {
                    Circle()
                        .fill(accent)
                        .frame(width: 7, height: 7)
                        .accessibilityLabel("New item")
                }
            }
            .frame(minHeight: 28)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? accent.opacity(selectionOpacity) : .clear)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
