import SwiftUI

struct ProviderListEditor<Item: Identifiable, ItemContent: View>: View {
    @Binding private var items: [Item]

    private let title: String
    private let emptyMessage: String
    private let addButtonTitle: String
    private let makeItem: () -> Item
    private let itemContent: (Binding<Item>, Binding<Bool>, @escaping () -> Void) -> ItemContent

    @State private var expandedItemIDs: Set<Item.ID> = []

    init(
        title: String,
        emptyMessage: String,
        addButtonTitle: String,
        items: Binding<[Item]>,
        makeItem: @escaping () -> Item,
        @ViewBuilder itemContent: @escaping (
            Binding<Item>,
            Binding<Bool>,
            @escaping () -> Void
        ) -> ItemContent
    ) {
        self.title = title
        self.emptyMessage = emptyMessage
        self.addButtonTitle = addButtonTitle
        _items = items
        self.makeItem = makeItem
        self.itemContent = itemContent
    }

    var body: some View {
        Group {
            Text(title)
                .font(.headline)

            if items.isEmpty {
                Text(emptyMessage)
                    .foregroundStyle(.secondary)
            }

            ForEach($items) { $item in
                let id = item.id
                itemContent($item, isExpandedBinding(for: id)) {
                    withAnimation {
                        items.removeAll { $0.id == id }
                    }
                    expandedItemIDs.remove(id)
                }
            }

            Button(addButtonTitle, systemImage: "plus") {
                let item = makeItem()
                withAnimation {
                    items.append(item)
                }
                expandedItemIDs.insert(item.id)
            }
            .buttonStyle(.borderless)
        }
    }

    private func isExpandedBinding(for id: Item.ID) -> Binding<Bool> {
        Binding(
            get: { expandedItemIDs.contains(id) },
            set: { isExpanded in
                if isExpanded {
                    expandedItemIDs.insert(id)
                } else {
                    expandedItemIDs.remove(id)
                }
            }
        )
    }
}

/// Disclosure-row label showing an item's name with a secondary capability summary,
/// so collapsed rows still communicate their configuration.
struct ProviderItemLabel: View {
    let title: String
    let capabilities: Set<ModelCapability>

    private var capabilitySummary: String {
        let names = ModelCapability.allCases
            .filter { capabilities.contains($0) }
            .map(\.displayName)
        return names.isEmpty ? "No capabilities" : names.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(capabilitySummary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
