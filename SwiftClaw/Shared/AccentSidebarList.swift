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
        List(selection: $selection) {
            ForEach(items) { item in
                Label {
                    HStack(spacing: 6) {
                        Text(title(item))
                        Spacer(minLength: 0)
                        if showsBadge(item) {
                            Circle()
                                .fill(accent)
                                .frame(width: 7, height: 7)
                                .accessibilityLabel("New item")
                        }
                    }
                } icon: {
                    Image(systemName: systemImage(item))
                }
                .tag(item)
                .listItemTint(accent)
                .accessibilityAddTraits(selection == item ? .isSelected : [])
                .accessibilityElement(children: .combine)
            }
        }
        .listStyle(.sidebar)
        .contentMargins(.top, topContentInset, for: .scrollContent)
    }
}
