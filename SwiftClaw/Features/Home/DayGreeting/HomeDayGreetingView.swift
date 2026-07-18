import SwiftUI

struct HomeDayGreetingView: View {
    @ObservedObject var viewModel: HomeDayGreetingViewModel

    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    @AppStorage(SettingsKeys.personaDisplayName) private var personaDisplayName = ""
    @AppStorage(SettingsKeys.quoteAccentHue) private var quoteAccentHue = QuoteAccent.defaultQuoteHue
    @AppStorage(SettingsKeys.quoteAccentLightness) private var quoteAccentLightness = QuoteAccent.defaultQuoteLightness

    private var quoteAccent: Color {
        QuoteAccent.color(hue: quoteAccentHue, lightness: quoteAccentLightness)
    }

    var body: some View {
        greetingContent
            .font(.title3)
            .contentTransition(.opacity)
            .animation(.easeInOut(duration: 0.4), value: viewModel.greeting)
    }

    @ViewBuilder
    private var greetingContent: some View {
        if let parts = HomeDayGreetingGenerator.userNameHighlightParts(
            in: viewModel.greeting,
            userName: PersonaProfile.displayName
        ) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(parts.prefix)
                    .foregroundStyle(.secondary)
                Button(action: openPersonaSettings) {
                    Text(parts.userName)
                        .foregroundStyle(quoteAccent)
                }
                .buttonStyle(.plain)
                .help("Open Persona settings")
                .accessibilityHint("Opens Persona settings")
                Text(parts.suffix)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text(viewModel.greeting)
                .foregroundStyle(.secondary)
        }
    }

    private func openPersonaSettings() {
        AppRouter.shared.openSettings(section: .persona)
        #if os(macOS)
        openWindow(id: SwiftClawApp.settingsWindowID)
        #endif
    }
}

#Preview {
    HomeDayGreetingView(viewModel: HomeDayGreetingViewModel())
        .frame(width: 300, height: 80)
}
