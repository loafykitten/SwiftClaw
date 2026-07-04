import SwiftUI

struct AppSettingsButton<LabelContent: View>: View {
    var section: SettingsSection? = nil
    var highlightToolsFeature: WorkspaceFeature? = nil
    @ViewBuilder var label: () -> LabelContent

    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    var body: some View {
        #if os(macOS)
        Button {
            AppRouter.shared.openSettings(section: section, highlightingToolsFeature: highlightToolsFeature)
            openWindow(id: SwiftClawApp.settingsWindowID)
        } label: {
            label()
        }
        #else
        Button {
            AppRouter.shared.openSettings(section: section, highlightingToolsFeature: highlightToolsFeature)
        } label: {
            label()
        }
        #endif
    }
}
