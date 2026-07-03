import SwiftUI

struct AppSettingsButton<LabelContent: View>: View {
    @ViewBuilder var label: () -> LabelContent

    var body: some View {
        #if os(macOS)
        SettingsLink(label: label)
        #else
        Button {
            AppRouter.shared.selectedNavigationItem = .settings
        } label: {
            label()
        }
        #endif
    }
}
