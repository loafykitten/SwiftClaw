import Foundation
import Security
import SwiftData
import os

/// Builds the app's single `ModelContainer` from two configurations:
///
/// - the default (unnamed) local store carrying every pre-calendar model, and
/// - a named "SwiftClawCalendar" store for calendar + reminders models.
///
/// The calendar store is separate because it is destined for CloudKit sync
/// (its models are CloudKit-shaped: no unique attributes, defaults/optionals
/// everywhere — see docs/conventions/MODELS.md) while the rest of the app
/// stays local. Keeping it in its own configuration lets the sync flip happen
/// without touching the main store.
enum SwiftClawModelContainerFactory {
    private static let logger = AppLog.make("app.startup")

    static func make() -> Result<ModelContainer, AppStartupError> {
        #if DEBUG
        let fixtureRoot: NoteProposalFixtureLaunch.FixtureRoot?
        switch NoteProposalFixtureLaunch.configurationIfRequested(
            arguments: ProcessInfo.processInfo.arguments,
            bundleIdentifier: Bundle.main.bundleIdentifier
        ) {
        case .success(nil):
            fixtureRoot = nil
        case .success(.some(let configuration)):
            do {
                // Establish the fixture-owned root before any ModelContainer
                // can choose a default store or contact CloudKit.
                fixtureRoot = try configuration.fixtureRoot.establish()
            } catch {
                return .failure(.fixtureConfigurationFailed(error.localizedDescription))
            }
        case .failure(let error):
            return .failure(.fixtureConfigurationFailed(error.localizedDescription))
        }
        #endif

        let mainSchema = Schema([
            Item.self,
            Chat.self,
            ChatMessage.self,
            Email.self,
            EmailThread.self,
            EmailNote.self,
            EmailAttachment.self,
            NoteEditProposal.self,
        ])
        let calendarSchema = Schema([
            CalendarEvent.self,
            UserCalendar.self,
            Reminder.self,
            ReminderList.self,
        ])
        let fullSchema = Schema([
            Item.self,
            Chat.self,
            ChatMessage.self,
            Email.self,
            EmailThread.self,
            EmailNote.self,
            EmailAttachment.self,
            NoteEditProposal.self,
            CalendarEvent.self,
            UserCalendar.self,
            Reminder.self,
            ReminderList.self,
        ])
        #if DEBUG
        let mainConfiguration: ModelConfiguration
        if let fixtureRoot {
            do {
                try fixtureRoot.revalidate()
            } catch {
                return .failure(.fixtureConfigurationFailed(error.localizedDescription))
            }
            mainConfiguration = ModelConfiguration(
                nil,
                schema: mainSchema,
                url: fixtureRoot.mainStoreURL
            )
        } else {
            mainConfiguration = ModelConfiguration(schema: mainSchema, isStoredInMemoryOnly: false)
        }
        let usesFixtureStores = fixtureRoot != nil
        #else
        let mainConfiguration = ModelConfiguration(schema: mainSchema, isStoredInMemoryOnly: false)
        let usesFixtureStores = false
        #endif

        // Preferred: calendar store synced through the private CloudKit
        // database. Only attempted when the process actually carries the
        // iCloud entitlement — CKContainer raises an uncatchable ObjC
        // exception (not a thrown error) without it, so the do/catch below
        // can't save us. Creation can still throw for softer reasons (signed
        // out, unprovisioned container); the local fallback opens the SAME
        // named store without sync, so nothing is lost and CloudKit exports
        // existing rows when it attaches later.
        if !usesFixtureStores,
           hasCloudKitEntitlement,
           !ProcessInfo.processInfo.arguments.contains("-SwiftClawDisableCloudKitSync") {
            let syncedCalendarConfiguration = ModelConfiguration(
                "SwiftClawCalendar",
                schema: calendarSchema,
                isStoredInMemoryOnly: false,
                cloudKitDatabase: .private("iCloud.com.caffeineplz.SwiftClaw")
            )
            do {
                let container = try ModelContainer(
                    for: fullSchema,
                    configurations: [mainConfiguration, syncedCalendarConfiguration]
                )
                #if DEBUG
                seedIfRequested(into: container, fixtureRoot: fixtureRoot)
                #else
                seedIfRequested(into: container)
                #endif
                return .success(container)
            } catch {
                logger.warning("""
                    CloudKit calendar store unavailable, falling back to local-only: \
                    \(String(describing: error), privacy: .public)
                    """)
            }
        }

        #if DEBUG
        let localCalendarConfiguration: ModelConfiguration
        if let fixtureRoot {
            do {
                try fixtureRoot.revalidate()
            } catch {
                return .failure(.fixtureConfigurationFailed(error.localizedDescription))
            }
            localCalendarConfiguration = ModelConfiguration(
                "SwiftClawCalendar",
                schema: calendarSchema,
                url: fixtureRoot.calendarStoreURL
            )
        } else {
            localCalendarConfiguration = ModelConfiguration(
                "SwiftClawCalendar",
                schema: calendarSchema,
                isStoredInMemoryOnly: false
            )
        }
        #else
        let localCalendarConfiguration = ModelConfiguration(
            "SwiftClawCalendar",
            schema: calendarSchema,
            isStoredInMemoryOnly: false
        )
        #endif
        do {
            let container = try ModelContainer(
                for: fullSchema,
                configurations: [mainConfiguration, localCalendarConfiguration]
            )
            #if DEBUG
            seedIfRequested(into: container, fixtureRoot: fixtureRoot)
            #else
            seedIfRequested(into: container)
            #endif
            return .success(container)
        } catch {
            logger.error("Could not create ModelContainer: \(String(describing: error), privacy: .public)")
            return .failure(.modelContainerCreationFailed(String(describing: error)))
        }
    }

    /// Whether this process is signed with `com.apple.developer.icloud-services`.
    /// False on personal development teams (they can't carry iCloud
    /// entitlements at all — see SwiftClaw.entitlements for the re-enable
    /// recipe on a paid team).
    ///
    /// `SecTaskCreateFromSelf`/`SecTaskCopyValueForEntitlement` aren't in the
    /// iOS SDK, so iOS can't prove the entitlement here; it conservatively
    /// reports false and falls through to the local-only store, same as an
    /// unprovisioned macOS process.
    private static var hasCloudKitEntitlement: Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(
            task,
            "com.apple.developer.icloud-services" as CFString,
            nil
        ) != nil
        #else
        return false
        #endif
    }

    #if DEBUG
    private static func seedIfRequested(
        into container: ModelContainer,
        fixtureRoot: NoteProposalFixtureLaunch.FixtureRoot?
    ) {
        MainActor.assumeIsolated {
            SampleChatSeeder.seedIfRequested(into: container)
            SampleEmailSeeder.seedIfRequested(into: container)
            NoteProposalFixtureSeeder.seedIfRequested(into: container, fixtureRoot: fixtureRoot)
        }
    }
    #else
    private static func seedIfRequested(into container: ModelContainer) {
    }
    #endif
}

enum AppStartupError: LocalizedError, Identifiable {
    case modelContainerCreationFailed(String)
    #if DEBUG
    case fixtureConfigurationFailed(String)
    #endif

    var id: String {
        errorDescription ?? "startup-error"
    }

    var errorDescription: String? {
        switch self {
        case .modelContainerCreationFailed:
            "SwiftClaw couldn't open its local data store."
        #if DEBUG
        case .fixtureConfigurationFailed:
            "SwiftClaw refused to start the DEBUG note proposal fixture."
        #endif
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .modelContainerCreationFailed(let details):
            "Quit and reopen SwiftClaw. If the problem continues, preserve this error for diagnosis: \(details)"
        #if DEBUG
        case .fixtureConfigurationFailed(let details):
            "Use the documented fixture-only bundle identifier and temporary-root launch argument. Details: \(details)"
        #endif
        }
    }
}

#if DEBUG
/// Inserts a couple of chats when launched with
/// `-SwiftClawSeedSampleChats`, so simulator/UI runs can exercise the
/// transcript, composer, and unread indicators without live inference.
@MainActor
enum SampleChatSeeder {
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
