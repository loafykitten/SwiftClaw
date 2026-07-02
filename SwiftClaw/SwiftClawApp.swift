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
    static let settingsWindowID = "settings"

    @AppStorage(SettingsKeys.theme) private var theme = AppTheme.system.rawValue

    private let modelContainerResult = SwiftClawModelContainerFactory.make()

    var body: some Scene {
        WindowGroup {
            switch modelContainerResult {
            case .success(let modelContainer):
                ContentView()
                    .modelContainer(modelContainer)
                    .preferredColorScheme(AppTheme(rawValue: theme)?.colorScheme)
                    .task {
                        await AppBootstrap.shared.run(modelContainer: modelContainer)
                    }
            case .failure(let error):
                AppStartupFailureView(error: error)
                    .preferredColorScheme(AppTheme(rawValue: theme)?.colorScheme)
            }
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                OpenSettingsButton(windowID: Self.settingsWindowID)
            }
        }

        Window("SwiftClaw Settings", id: Self.settingsWindowID) {
            SettingsView()
                .preferredColorScheme(AppTheme(rawValue: theme)?.colorScheme)
        }
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
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

/// Replaces the standard "Settings…" app-menu item so ⌘, opens our dedicated
/// `Window` scene instead of the SwiftUI `Settings` scene. The plain window
/// hosts a unified `NSToolbar`, which (unlike the Settings scene) leading-aligns
/// the back/forward controls and section title like Xcode's settings.
private struct OpenSettingsButton: View {
    let windowID: String
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Settings…") {
            openWindow(id: windowID)
        }
        .keyboardShortcut(",", modifiers: .command)
    }
}
