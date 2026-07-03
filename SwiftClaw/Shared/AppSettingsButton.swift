import SwiftUI

struct AppSettingsButton<LabelContent: View>: View {
    var section: SettingsSection? = nil
    @ViewBuilder var label: () -> LabelContent

    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    var body: some View {
        #if os(macOS)
        Button {
            AppRouter.shared.openSettings(section: section)
            openWindow(id: SwiftClawApp.settingsWindowID)
        } label: {
            label()
        }
        #else
        Button {
            AppRouter.shared.openSettings(section: section)
        } label: {
            label()
        }
        #endif
    }
}
