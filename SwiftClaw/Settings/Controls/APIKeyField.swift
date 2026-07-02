import SwiftUI

struct APIKeyField: View {
    let title: String
    @Binding var text: String
    @State private var isRevealed = false

    var body: some View {
        HStack(spacing: 8) {
            if isRevealed {
                TextField(title, text: $text)
                    .autocorrectionDisabled()
            } else {
                SecureField(title, text: $text)
            }
            Button {
                isRevealed.toggle()
            } label: {
                Image(systemName: isRevealed ? "eye.slash" : "eye")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(isRevealed ? "Hide API key" : "Show API key")
            .accessibilityLabel(isRevealed ? "Hide API key" : "Show API key")
        }
    }
}

struct SecretKeyRow: View {
    let title: String
    @Binding var text: String
    var helpText: String?

    var body: some View {
        LabeledContent(title) {
            APIKeyField(title: title, text: $text)
                .frame(maxWidth: 360)
        }

        if let helpText {
            Text(helpText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
