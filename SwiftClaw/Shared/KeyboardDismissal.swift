import SwiftUI
#if os(iOS)
import UIKit
#endif

extension Notification.Name {
    static let chatComposerShouldResignFocus = Notification.Name("chatComposerShouldResignFocus")
}

extension View {
    @ViewBuilder
    func chatComposerDismissKeyboardOnTap() -> some View {
        #if os(iOS)
        self
            .contentShape(Rectangle())
            .simultaneousGesture(
                TapGesture().onEnded {
                    NotificationCenter.default.post(name: .chatComposerShouldResignFocus, object: nil)
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder),
                        to: nil,
                        from: nil,
                        for: nil
                    )
                }
            )
        #else
        self
        #endif
    }

    @ViewBuilder
    func chatComposerScrollDismissesKeyboard() -> some View {
        #if os(iOS)
        self.scrollDismissesKeyboard(.interactively)
        #else
        self
        #endif
    }
}
