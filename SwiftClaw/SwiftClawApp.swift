//
//  SwiftClawApp.swift
//  SwiftClaw
//
//  Created by Fenn on 6/12/26.
//

import SwiftUI
import SwiftData
import os

@main
struct SwiftClawApp: App {
    @AppStorage(SettingsKeys.theme) private var theme = AppTheme.system.rawValue
    @AppStorage(SettingsKeys.accentHue) private var accentHue = AccentColor.defaultHue
    @AppStorage(SettingsKeys.accentLightness) private var accentLightness = AccentColor.defaultLightness

    private var accent: Color {
        AccentColor.color(hue: accentHue, lightness: accentLightness)
    }

    private let modelContainerResult = SwiftClawModelContainerFactory.make()

    var body: some Scene {
        WindowGroup {
            switch modelContainerResult {
            case .success(let modelContainer):
                ContentView()
                    .modelContainer(modelContainer)
                    .preferredColorScheme(AppTheme(rawValue: theme)?.colorScheme)
                    .tint(accent)
                    .task {
                        await AppBootstrap.shared.run(modelContainer: modelContainer)
                    }
            case .failure(let error):
                AppStartupFailureView(error: error)
                    .preferredColorScheme(AppTheme(rawValue: theme)?.colorScheme)
                    .tint(accent)
            }
        }

        Settings {
            SettingsView()
                .preferredColorScheme(AppTheme(rawValue: theme)?.colorScheme)
                .tint(accent)
        }
    }

    private enum SwiftClawModelContainerFactory {
        private static let logger = AppLog.make("app.startup")

        static func make() -> Result<ModelContainer, AppStartupError> {
            let schema = Schema([
                Item.self,
                Chat.self,
                ChatMessage.self,
                Email.self,
                EmailThread.self,
                EmailNote.self,
                EmailAttachment.self,
            ])
            let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

            do {
                return .success(try ModelContainer(for: schema, configurations: [modelConfiguration]))
            } catch {
                logger.error("Could not create ModelContainer: \(String(describing: error), privacy: .public)")
                return .failure(.modelContainerCreationFailed(String(describing: error)))
            }
        }
    }

    enum AppStartupError: LocalizedError, Identifiable {
        case modelContainerCreationFailed(String)

        var id: String {
            errorDescription ?? "startup-error"
        }

        var errorDescription: String? {
            switch self {
            case .modelContainerCreationFailed:
                "SwiftClaw couldn't open its local data store."
            }
        }

        var recoverySuggestion: String? {
            switch self {
            case .modelContainerCreationFailed(let details):
                "Quit and reopen SwiftClaw. If the problem continues, preserve this error for diagnosis: \(details)"
            }
        }
    }

    private struct AppStartupFailureView: View {
        let error: AppStartupError
        @State private var isShowingAlert = true

        var body: some View {
            ContentUnavailableView(
                "SwiftClaw couldn't start",
                systemImage: "exclamationmark.triangle",
                description: Text(error.recoverySuggestion ?? error.localizedDescription)
            )
            .frame(minWidth: 480, minHeight: 320)
            .alert(
                "SwiftClaw couldn't start",
                isPresented: $isShowingAlert,
                presenting: error
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { error in
                Text(error.recoverySuggestion ?? error.localizedDescription)
            }
        }
    }
}
