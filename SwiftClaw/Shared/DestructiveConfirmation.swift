import SwiftUI

struct ConfirmationDialogCopy {
    let title: String
    let actionTitle: String
    let message: String
    var role: ButtonRole? = .destructive
}

extension View {
    func confirmingAction<Item>(
        item: Binding<Item?>,
        copy: ConfirmationDialogCopy,
        action: @escaping (Item) -> Void
    ) -> some View {
        confirmationDialog(
            copy.title,
            isPresented: Binding(
                get: { item.wrappedValue != nil },
                set: { isPresented in
                    if !isPresented {
                        item.wrappedValue = nil
                    }
                }
            ),
            presenting: item.wrappedValue
        ) { value in
            Button(copy.actionTitle, role: copy.role) {
                action(value)
                item.wrappedValue = nil
            }
            Button("Cancel", role: .cancel) {
                item.wrappedValue = nil
            }
        } message: { _ in
            Text(copy.message)
        }
    }
}
