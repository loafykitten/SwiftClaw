import SwiftUI

struct ProviderListEditor<Item: Identifiable, ExistingContent: View, AddContent: View>: View where Item.ID: Equatable {
    @Binding private var items: [Item]

    private let title: String
    private let emptyMessage: String
    private let addButtonTitle: String
    private let canAdd: Bool
    private let addAction: () -> Void
    private let existingContent: (Binding<Item>, @escaping () -> Void) -> ExistingContent
    private let addContent: (@escaping () -> Void) -> AddContent

    init(
        title: String,
        emptyMessage: String,
        addButtonTitle: String,
        items: Binding<[Item]>,
        canAdd: Bool,
        addAction: @escaping () -> Void,
        @ViewBuilder existingContent: @escaping (Binding<Item>, @escaping () -> Void) -> ExistingContent,
        @ViewBuilder addContent: @escaping (@escaping () -> Void) -> AddContent
    ) {
        self.title = title
        self.emptyMessage = emptyMessage
        self.addButtonTitle = addButtonTitle
        _items = items
        self.canAdd = canAdd
        self.addAction = addAction
        self.existingContent = existingContent
        self.addContent = addContent
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
                existingContent($item) {
                    items.removeAll { $0.id == id }
                }
            }

            Divider()

            addContent(addAction)

            Button(addButtonTitle, systemImage: "plus") {
                addAction()
            }
            .disabled(!canAdd)
        }
    }
}
