import SwiftUI

struct APIKeyField: View {
    let title: String
    @Binding var text: String
    @State private var isRevealed = false

    var body: some View {
        HStack(spacing: 8) {
            if isRevealed {
                TextField("", text: $text, prompt: Text(title))
                    .autocorrectionDisabled()
            } else {
                SecureField("", text: $text, prompt: Text(title))
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

/// An API-key row backed by `@KeychainStorage`. A rejected Keychain write is
/// called out inline, since inference keeps using the old (or no) credential
/// while the field shows the new one.
struct SecretKeyRow: View {
    let title: String
    let secret: KeychainStorage.Projection
    var helpText: String?

    var body: some View {
        LabeledContent(title) {
            APIKeyField(title: title, text: secret.text)
                .frame(maxWidth: 360)
        }

        if let failure = secret.entry.saveFailureMessage {
            Label(failure, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }

        if let helpText {
            Text(helpText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
