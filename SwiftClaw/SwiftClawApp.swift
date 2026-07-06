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
    #if os(macOS)
    static let settingsWindowID = "settings"
    #endif

    @AppStorage(SettingsKeys.theme) private var theme = AppTheme.system.rawValue

    private let modelContainerResult = SwiftClawModelContainerFactory.make()

    init() {
        // Install the notification delegate before launch completes so a
        // notification tap that cold-launches the app is routed, not dropped.
        guard !ProcessInfo.processInfo.isRunningInPreview else { return }
        AppNotificationService.shared.activate()
    }

    #if os(macOS)
    var body: some Scene {
        appWindow
            .commands {
                CommandGroup(replacing: .appSettings) {
                    OpenSettingsButton(windowID: Self.settingsWindowID)
                }
            }

        Window("SwiftClaw Settings", id: Self.settingsWindowID) {
            SettingsView()
                .environment(AppRouter.shared)
                .preferredColorScheme(AppTheme(rawValue: theme)?.colorScheme)
        }
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
    }
    #else
    var body: some Scene {
        appWindow
    }
    #endif

    private var appWindow: some Scene {
        WindowGroup {
            switch modelContainerResult {
            case .success(let modelContainer):
                RootView(modelContainer: modelContainer)
                    .preferredColorScheme(AppTheme(rawValue: theme)?.colorScheme)
            case .failure(let error):
                AppStartupFailureView(error: error)
                    .preferredColorScheme(AppTheme(rawValue: theme)?.colorScheme)
            }
        }
    }

    /// Hosts the main UI and runs bootstrap, with the launch splash overlaid on
    /// top until the minimum display window elapses. Splash state lives here (not
    /// in the `App` body) so a single `@State` can drive the fade-out.
    private struct RootView: View {
        let modelContainer: ModelContainer

        @State private var isShowingSplash = !ProcessInfo.processInfo.isRunningInPreview
        @State private var isShowingNotificationsPrompt = false

        var body: some View {
            ContentView()
                .modelContainer(modelContainer)
                .task {
                    await AppBootstrap.shared.run(modelContainer: modelContainer)
                }
                .overlay {
                    if isShowingSplash {
                        SplashView()
                            .transition(.opacity)
                            .zIndex(1)
                    }
                }
                .task {
                    // Give the splash a beat to play its intro, then fade out.
                    try? await Task.sleep(for: .seconds(1.8))
                    withAnimation(.easeInOut(duration: 0.5)) {
                        isShowingSplash = false
                    }
                    // One-time offer to enable notifications, after the splash
                    // so the alert doesn't pop over the intro. Declining keeps
                    // the system status untouched — Settings can prompt later.
                    guard !ProcessInfo.processInfo.isRunningInPreview else { return }
                    try? await Task.sleep(for: .seconds(0.6))
                    if await AppNotificationService.shared.shouldOfferLaunchPrompt() {
                        isShowingNotificationsPrompt = true
                    }
                }
                .alert("Enable notifications?", isPresented: $isShowingNotificationsPrompt) {
                    Button("Enable") {
                        Task { await AppNotificationService.shared.acceptLaunchPrompt() }
                    }
                    Button("Not Now", role: .cancel) {
                        AppNotificationService.shared.declineLaunchPrompt()
                    }
                } message: {
                    Text("SwiftClaw can notify you about new mail, inbox review results, and chat replies that arrive while you're away. If you decline, you can enable notifications anytime in Settings › Notifications.")
                }
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
                let container = try ModelContainer(for: schema, configurations: [modelConfiguration])
                #if DEBUG
                MainActor.assumeIsolated {
                    SampleChatSeeder.seedIfRequested(into: container)
                    SampleEmailSeeder.seedIfRequested(into: container)
                }
                #endif
                return .success(container)
            } catch {
                logger.error("Could not create ModelContainer: \(String(describing: error), privacy: .public)")
                return .failure(.modelContainerCreationFailed(String(describing: error)))
            }
        }
    }

    #if DEBUG
    /// Inserts a couple of chats when launched with
    /// `-SwiftClawSeedSampleChats`, so simulator/UI runs can exercise the
    /// transcript, composer, and unread indicators without live inference.
    @MainActor
    private enum SampleChatSeeder {
        static func seedIfRequested(into container: ModelContainer) {
            guard ProcessInfo.processInfo.arguments.contains("-SwiftClawSeedSampleChats") else { return }
            let context = container.mainContext
            guard ((try? context.fetchCount(FetchDescriptor<Chat>())) ?? 0) == 0 else { return }

            let kyoto = Chat(title: "Weekend in Kyoto", modelSelection: "claude-sonnet-5")
            context.insert(kyoto)
            kyoto.appendMessage(
                role: .user,
                content: "Can you sketch a two-day Kyoto plan? Quiet temples and good coffee, please."
            )
            kyoto.appendMessage(
                role: .assistant,
                content: """
                Here's a relaxed split:

                ## Day 1 — East side
                1. **Fushimi Inari** at dawn, before the crowds
                2. Coffee at a *kissaten* in Gion
                3. `Philosopher's Path` toward Nanzen-ji

                ## Day 2 — Arashiyama
                - Bamboo grove early, then Ōkōchi Sansō garden
                - Finish with hōjicha and a river walk
                """
            )

            let recipes = Chat(title: "Dinner ideas", modelSelection: "claude-sonnet-5")
            context.insert(recipes)
            recipes.appendMessage(role: .user, content: "Three weeknight dinners with pantry staples?")
            recipes.appendMessage(
                role: .assistant,
                content: "1. Cacio e pepe\n2. Chickpea curry\n3. Fried-rice night — clean out the crisper drawer."
            )

            try? context.save()
            // Kyoto is the older chat, so it won't be auto-selected in the
            // regular layout — its unread indicator stays visible.
            AppRouter.shared.noteNewChatMessages(in: kyoto.id)
        }
    }
    #endif

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
            #if os(macOS)
            .frame(minWidth: 480, minHeight: 320)
            #endif
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
#if os(macOS)
private struct OpenSettingsButton: View {
    let windowID: String
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Settings…") {
            AppRouter.shared.openSettings()
            openWindow(id: windowID)
        }
        .keyboardShortcut(",", modifiers: .command)
    }
}
#endif
