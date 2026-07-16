import Foundation
@testable import SwiftClaw
import SwiftData
import Testing

@MainActor
struct NotesReviewServiceTests {
    private struct Harness {
        let container: ModelContainer
        let defaults: UserDefaultsFixture
        let source: NotesReviewSourceStub
        let service: NotesReviewService
        init() throws {
            let schema = Schema([Chat.self, ChatMessage.self])
            container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
            defaults = try UserDefaultsFixture(); defaults.defaults.set("test-model", forKey: SettingsKeys.clawModel)
            source = NotesReviewSourceStub(now: .now)
            service = NotesReviewService(modelContainer: container, userDefaults: defaults.defaults, dataSource: source)
            service.unreadChatIDsProvider = { [] }
        }
    }

    @Test func offersExactToolsStandaloneAndUsesTriagePrompt() async throws {
        let harness = try Harness(); defer { harness.defaults.cleanup() }
        let probe = NotesReviewInvocationProbe()
        harness.service.completeProvider = { messages, _, receivedMode, tools in
            await probe.record(
                names: tools.map(\.name).sorted(),
                mode: receivedMode,
                prompt: String(describing: messages)
            )
            return ""
        }
        #expect(await harness.service.runOnce(force: true))
        let invocation = await probe.invocation
        #expect(invocation?.names == ["fetch_notes_review_digest", "notify_user_about_notes"])
        #expect(invocation?.mode == .standalone)
        #expect(invocation?.prompt.contains("read-only vault-hygiene") == true)
        #expect(invocation?.prompt.contains("Never edit notes") == true)
    }

    @Test func missingModelAndUnavailableVaultAreHardGuardsEvenWhenForced() async throws {
        let harness = try Harness(); defer { harness.defaults.cleanup() }
        harness.defaults.defaults.removeObject(forKey: SettingsKeys.clawModel)
        #expect(await !(harness.service.runOnce(force: true)))
        #expect(harness.service.lastStatusMessage == "Review needs a model in Settings")
        harness.defaults.defaults.set("test", forKey: SettingsKeys.clawModel); harness.source.available = false
        #expect(await !(harness.service.runOnce(force: true)))
        #expect(harness.service.lastStatusMessage == "Notes is unavailable")
    }

    @Test func scheduledUnreadGuardIsBypassedOnlyByForce() async throws {
        let harness = try Harness(); defer { harness.defaults.cleanup() }
        let chat = Chat(title: "\(Chat.notesReviewTitlePrefix) Jul 15", modelSelection: "test")
        harness.container.mainContext.insert(chat); try harness.container.mainContext.save()
        harness.service.unreadChatIDsProvider = { [chat.id] }
        #expect(await !(harness.service.runOnce()))
        harness.service.completeProvider = { _, _, _, _ in "" }
        #expect(await harness.service.runOnce(force: true))
    }

    @Test func completionStampChangesOnlyAfterSuccessfulInference() async throws {
        let harness = try Harness(); defer { harness.defaults.cleanup() }
        struct Failure: Error {}
        harness.service.completeProvider = { _, _, _, _ in throw Failure() }
        #expect(await !(harness.service.runOnce(force: true)))
        #expect(SettingsStorage.loadNotesLastReviewCompletedAt(userDefaults: harness.defaults.defaults) == nil)
        harness.service.completeProvider = { _, _, _, _ in "ok" }
        #expect(await harness.service.runOnce(force: true))
        #expect(SettingsStorage.loadNotesLastReviewCompletedAt(userDefaults: harness.defaults.defaults) != nil)
    }
}

private actor NotesReviewInvocationProbe {
    struct Invocation: Sendable {
        let names: [String]
        let mode: InferenceSystemPromptMode
        let prompt: String
    }

    private(set) var invocation: Invocation?

    func record(names: [String], mode: InferenceSystemPromptMode, prompt: String) {
        invocation = Invocation(names: names, mode: mode, prompt: prompt)
    }
}
