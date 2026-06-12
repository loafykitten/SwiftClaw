//
//  SwiftClawApp.swift
//  SwiftClaw
//
//  Created by Fenn on 6/12/26.
//

import SwiftUI
import SwiftData

@main
struct SwiftClawApp: App {
    @AppStorage(SettingsKeys.theme) private var theme = AppTheme.system.rawValue
    @AppStorage(SettingsKeys.accentHue) private var accentHue = AccentColor.defaultHue
    @AppStorage(SettingsKeys.accentBrightness) private var accentBrightness = AccentColor.defaultBrightness

    private var accent: Color {
        AccentColor.color(hue: accentHue, brightness: accentBrightness)
    }

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Item.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    init() {
        Keychain.migrateAPIKeysFromUserDefaults()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(AppTheme(rawValue: theme)?.colorScheme)
                .tint(accent)
        }
        .modelContainer(sharedModelContainer)

        Settings {
            SettingsView()
                .preferredColorScheme(AppTheme(rawValue: theme)?.colorScheme)
                .tint(accent)
        }
    }
}
