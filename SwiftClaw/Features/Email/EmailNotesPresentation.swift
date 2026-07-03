import SwiftUI

struct EmailNotesPresentationModifier: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @Binding var isPresented: Bool
    let emails: [Email]

    func body(content: Content) -> some View {
        if horizontalSizeClass == .compact {
            content.sheet(isPresented: $isPresented) {
                NavigationStack {
                    EmailNotesPopover(emails: emails)
                        .padding()
                        .navigationTitle("Notes")
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") {
                                    isPresented = false
                                }
                            }
                        }
                }
            }
        } else {
            content.popover(isPresented: $isPresented) {
                EmailNotesPopover(emails: emails)
            }
        }
    }
}

extension View {
    func emailNotesPresentation(
        isPresented: Binding<Bool>,
        emails: [Email]
    ) -> some View {
        modifier(EmailNotesPresentationModifier(isPresented: isPresented, emails: emails))
    }
}
