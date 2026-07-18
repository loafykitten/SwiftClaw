#if DEBUG
import Foundation
import SwiftData

/// Seeds a chat carrying one `.memoryWrite` disclosure chip and one pending
/// `.memoryProposal` card (plus the backing collections/entries/proposal)
/// when launched with `-SwiftClawSeedMemoryCards`, so simulator/UI runs can
/// exercise both card types — View/Undo, Accept/Edit/Dismiss — without live
/// inference. Fixture identity only, never real data
/// (`docs/testing/SIMULATOR_UI_VERIFICATION.md`).
@MainActor
enum MemoryCardFixtureSeeder {
    static func seedIfRequested(into container: ModelContainer) {
        guard ProcessInfo.processInfo.arguments.contains("-SwiftClawSeedMemoryCards") else { return }
        let context = container.mainContext
        guard ((try? context.fetchCount(FetchDescriptor<MemoryProposal>())) ?? 0) == 0 else { return }

        let chat = Chat(title: "Trip planning", modelSelection: "claude-sonnet-5")
        context.insert(chat)
        chat.appendMessage(role: .user, content: "Remember that I always take window seats, and that I'm vegetarian.")
        chat.appendMessage(
            role: .assistant,
            content: "Saved your seating preference. Your diet lives in a collection that needs your approval first — card below."
        )

        let travel = MemoryCollection(title: "Travel preferences", tags: ["travel"], createdBy: .ai)
        context.insert(travel)
        let diet = MemoryCollection(title: "Health & diet", accessLevel: .asksFirst, createdBy: .user)
        context.insert(diet)

        let entry = MemoryEntry(
            body: "Prefers window seats on long-haul flights",
            createdBy: .ai,
            sourceChatID: chat.id,
            disclosedAt: .now
        )
        entry.collection = travel
        context.insert(entry)
        context.insert(MemoryActivityEvent(
            kind: .added,
            entryID: entry.id,
            collectionID: travel.id,
            snapshotText: entry.body,
            actor: .ai,
            chatID: chat.id
        ))
        chat.appendMessage(role: .assistant, content: "", reviewCard: ReviewCardPayload(
            reviewType: .memoryWrite,
            items: [
                ReviewItem(
                    itemID: entry.id,
                    actionToken: .undo,
                    actionLabel: "Undo",
                    summary: entry.body,
                    subject: travel.title
                ),
            ]
        ))

        let proposal = MemoryProposal(
            entryText: "Vegetarian — no meat or fish",
            targetCollectionID: diet.id,
            summary: "Remember in \"Health & diet\"",
            source: .chat,
            chatID: chat.id,
            cardPostedAt: .now
        )
        context.insert(proposal)
        chat.appendMessage(role: .assistant, content: "", reviewCard: ReviewCardPayload(
            reviewType: .memoryProposal,
            items: [
                ReviewItem(
                    itemID: proposal.id,
                    actionToken: .approve,
                    actionLabel: "Review",
                    summary: proposal.summary,
                    subject: diet.title
                ),
            ]
        ))

        // A second, new-collection proposal so a UI pass can exercise
        // Dismiss (or Edit) on one card and Accept on the other.
        let collectionProposal = MemoryProposal(
            entryText: "Runs on Tuesday mornings\nPrefers gym sessions under an hour",
            newCollectionTitle: "Workout schedule",
            newCollectionAccessLevel: .writesFreely,
            summary: "Create a collection for workout patterns",
            source: .chat,
            chatID: chat.id,
            cardPostedAt: .now
        )
        context.insert(collectionProposal)
        chat.appendMessage(role: .assistant, content: "", reviewCard: ReviewCardPayload(
            reviewType: .memoryProposal,
            items: [
                ReviewItem(
                    itemID: collectionProposal.id,
                    actionToken: .approve,
                    actionLabel: "Review",
                    summary: collectionProposal.summary,
                    subject: collectionProposal.newCollectionTitle
                ),
            ]
        ))

        try? context.save()
        AppRouter.shared.noteNewChatMessages(in: chat.id)
    }
}
#endif
