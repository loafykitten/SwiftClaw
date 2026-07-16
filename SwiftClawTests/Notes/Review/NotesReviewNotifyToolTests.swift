import Foundation
@testable import SwiftClaw
import SwiftData
import Testing

@MainActor
struct NotesReviewNotifyToolTests {
    private func container() throws -> ModelContainer {
        let schema = Schema([Chat.self, ChatMessage.self])
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    private func collector() -> (NotesReviewFindingCollector, UUID) {
        let collector = NotesReviewFindingCollector(); let id = UUID()
        collector.replace(with: [.init(id: id, kind: .brokenLink, subject: "Missing target", detail: "Broken from Home.md", location: "Home.md", date: nil)])
        return (collector, id)
    }

    private func arguments(id: UUID, stringified: Bool = false) -> [String: JSONValue] {
        let json = "[{\"finding_id\":\"\(id.uuidString)\",\"summary\":\"Needs repair\"}]"
        return ["findings": stringified ? .string(json) : .array([.object(["finding_id": .string(id.uuidString), "summary": .string("Needs repair")])]), "message": .string("One Notes issue.")]
    }

    @Test func createsNotesCardFromValidatedSummaryAndIsIdempotent() async throws {
        let container = try container(); let (collector, id) = collector()
        let tool = NotesReviewNotifyTool(modelContainer: container, collector: collector)
        _ = try await tool.execute(arguments: arguments(id: id))
        #expect(try await tool.execute(arguments: arguments(id: id)).contains("ignored"))
        let chat = try #require(try container.mainContext.fetch(FetchDescriptor<Chat>()).first)
        let card = try #require(chat.messages.compactMap(\.reviewCard).first)
        #expect(card.reviewType == .notes); #expect(card.items.first?.itemID == id)
        #expect(card.items.first?.accountLabel == "Home.md")
        #expect(try container.mainContext.fetchCount(FetchDescriptor<Chat>()) == 1)
    }

    @Test func acceptsJSONStringAndRejectsUnknownOrMalformedIDs() async throws {
        let container = try container(); let (collector, id) = collector()
        _ = try await NotesReviewNotifyTool(modelContainer: container, collector: collector).execute(arguments: arguments(id: id, stringified: true))
        for bad in [UUID().uuidString, "not-a-uuid"] {
            await #expect(throws: ToolError.self) {
                _ = try await NotesReviewNotifyTool(modelContainer: container, collector: collector).execute(arguments: ["findings": .array([.object(["finding_id": .string(bad)])]), "message": .string("x")])
            }
        }
    }

    @Test func appendsToTargetChatAndRetiresOldNotesCard() async throws {
        let container = try container(); let context = container.mainContext
        let chat = Chat(title: "Existing", modelSelection: "test"); context.insert(chat)
        let old = ChatMessage(role: .assistant, content: "", sortIndex: 0, reviewCard: .init(reviewType: .notes, items: [])); old.chat = chat; context.insert(old); try context.save()
        let (collector, id) = collector()
        _ = try await NotesReviewNotifyTool(modelContainer: container, collector: collector, targetChatID: chat.id).execute(arguments: arguments(id: id))
        #expect(old.reviewCard == nil)
        #expect(chat.messages.compactMap(\.reviewCard).count == 1)
    }

    @Test func persistenceFailureIsReportedAndDoesNotLatchIdempotency() async throws {
        let container = try container(); let (collector, id) = collector()
        struct Failure: Error {}
        let tool = NotesReviewNotifyTool(modelContainer: container, collector: collector, dependencies: .init(save: { _ in throw Failure() }))
        await #expect(throws: ToolError.self) { _ = try await tool.execute(arguments: arguments(id: id)) }
        await #expect(throws: ToolError.self) { _ = try await tool.execute(arguments: arguments(id: id)) }
        #expect(try container.mainContext.fetchCount(FetchDescriptor<Chat>()) == 0)
    }
}
