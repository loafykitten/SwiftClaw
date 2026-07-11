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
        let mainSchema = Schema([
            Item.self,
            Chat.self,
            ChatMessage.self,
            Email.self,
            EmailThread.self,
            EmailNote.self,
            EmailAttachment.self,
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
            CalendarEvent.self,
            UserCalendar.self,
            Reminder.self,
            ReminderList.self,
        ])
        let mainConfiguration = ModelConfiguration(schema: mainSchema, isStoredInMemoryOnly: false)

        // Preferred: calendar store synced through the private CloudKit
        // database. Only attempted when the process actually carries the
        // iCloud entitlement — CKContainer raises an uncatchable ObjC
        // exception (not a thrown error) without it, so the do/catch below
        // can't save us. Creation can still throw for softer reasons (signed
        // out, unprovisioned container); the local fallback opens the SAME
        // named store without sync, so nothing is lost and CloudKit exports
        // existing rows when it attaches later.
        if hasCloudKitEntitlement,
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
                seedIfRequested(into: container)
                return .success(container)
            } catch {
                logger.warning("""
                    CloudKit calendar store unavailable, falling back to local-only: \
                    \(String(describing: error), privacy: .public)
                    """)
            }
        }

        let localCalendarConfiguration = ModelConfiguration(
            "SwiftClawCalendar",
            schema: calendarSchema,
            isStoredInMemoryOnly: false
        )
        do {
            let container = try ModelContainer(
                for: fullSchema,
                configurations: [mainConfiguration, localCalendarConfiguration]
            )
            seedIfRequested(into: container)
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
    private static var hasCloudKitEntitlement: Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(
            task,
            "com.apple.developer.icloud-services" as CFString,
            nil
        ) != nil
    }

    private static func seedIfRequested(into container: ModelContainer) {
        #if DEBUG
        MainActor.assumeIsolated {
            SampleChatSeeder.seedIfRequested(into: container)
            SampleEmailSeeder.seedIfRequested(into: container)
        }
        #endif
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
