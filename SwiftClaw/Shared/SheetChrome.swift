import SwiftUI

/// Shared header/footer chrome for the app's modal sheets. Extracted from the
/// three email sheets (reply composer, note editor, account editor) that all
/// repeated the same `title + Cancel + Divider` header and `Divider + trailing
/// prominent confirm button` footer. Keeping the padding/placement/styling in
/// one place stops the sheets from drifting apart visually.

/// Sheet header: a title on the leading edge, a trailing Cancel button, and a
/// divider below. `onCancel` lets callers do work before dismissing (e.g. the
/// account editor cancels its in-flight Test Connection task).
struct SheetHeader: View {
    let title: String
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Button("Cancel", action: onCancel)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider()
        }
    }
}

/// Sheet footer: a divider above a trailing borderedProminent confirm button.
struct SheetFooter: View {
    let confirmTitle: String
    var isDisabled: Bool = false
    let onConfirm: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            HStack {
                Spacer()
                Button(confirmTitle, action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .disabled(isDisabled)
            }
            .padding(20)
        }
    }
}
