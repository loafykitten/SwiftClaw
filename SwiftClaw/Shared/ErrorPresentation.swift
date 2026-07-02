import SwiftUI

struct PresentedAppError: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String

    init(_ error: any Error, title fallbackTitle: String) {
        if let localized = error as? LocalizedError {
            title = localized.errorDescription ?? fallbackTitle
            message = localized.recoverySuggestion
                ?? localized.failureReason
                ?? error.localizedDescription
        } else {
            title = fallbackTitle
            message = error.localizedDescription
        }
    }
}

extension View {
    func appErrorAlert(_ error: Binding<PresentedAppError?>) -> some View {
        alert(item: error) { error in
            Alert(
                title: Text(error.title),
                message: Text(error.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }
}
