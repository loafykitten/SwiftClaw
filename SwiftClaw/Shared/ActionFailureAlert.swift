import SwiftUI

/// A user action (complete, delete, drag, …) that failed, ready for
/// `actionFailureAlert`.
struct ActionFailure: Identifiable {
    let id = UUID()
    let title: String
    let message: String

    init(title: String, error: any Error) {
        self.title = title
        message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

extension View {
    /// Presents `failure` as a one-button alert. Screens whose rows, context
    /// menus, and drags trigger repository mutations keep one of these at
    /// their root instead of an alert per row.
    func actionFailureAlert(_ failure: Binding<ActionFailure?>) -> some View {
        alert(
            failure.wrappedValue?.title ?? "",
            isPresented: Binding(
                get: { failure.wrappedValue != nil },
                set: { if !$0 { failure.wrappedValue = nil } }
            ),
            presenting: failure.wrappedValue
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { failure in
            Text(failure.message)
        }
    }
}
