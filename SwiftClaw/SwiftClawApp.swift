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
        guard !ProcessInfo.processInfo.isRunningInPreview,
              !ProcessInfo.processInfo.isRunningAsTestHost else { return }
        AppNotificationService.shared.activate()
    }

    #if os(macOS)
    var body: some Scene {
        appWindow
            // Without this, a first launch opens at SwiftUI's 900×450
            // default, too short for the three-column Email and Notes layouts.
            .defaultSize(width: 1280, height: 820)
            .commands {
                CommandGroup(replacing: .appSettings) {
                    OpenSettingsButton(windowID: Self.settingsWindowID)
                }
            }

        Window("SwiftClaw Settings", id: Self.settingsWindowID) {
            // The Settings scene needs the same container as the main window —
            // without it, every `@Query` in Settings reads an empty implicit
            // store (seen live: Calendar settings listing no calendars).
            Group {
                if case .success(let modelContainer) = modelContainerResult {
                    SettingsView()
                        .modelContainer(modelContainer)
                } else {
                    SettingsView()
                }
            }
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
            if ProcessInfo.processInfo.isRunningAsTestHost {
                // Hosting SwiftClawTests: no bootstrap, sync, or live UI.
                EmptyView()
            } else {
                appContent
            }
        }
    }

    @ViewBuilder
    private var appContent: some View {
        switch modelContainerResult {
        case .success(let modelContainer):
            RootView(modelContainer: modelContainer)
                .preferredColorScheme(AppTheme(rawValue: theme)?.colorScheme)
        case .failure(let error):
            AppStartupFailureView(error: error)
                .preferredColorScheme(AppTheme(rawValue: theme)?.colorScheme)
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

    // SwiftClawModelContainerFactory, AppStartupError, and the DEBUG sample
    // seeders live in Shared/SwiftClawModelContainerFactory.swift — the
    // factory grew a second (calendar) configuration and was extracted so its
    // fallback logic is testable.

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
