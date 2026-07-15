import Foundation
import Testing
import SwiftData
@testable import SwiftClaw

/// Deterministic mutable box for simulating a vault switch that completes
/// *during* a proposal tool's suspended read/existence-check — a plain
/// `var` can't be captured across the `@Sendable` `Dependencies` closures.
private final class MutableBox<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}

/// Exercises `ProposeNoteEditTool`/`ProposeNoteCreateTool` against injected
/// `Dependencies` stubs plus a real temp-vault-backed check that no vault
/// file is ever written — proposing must only ever insert a
/// `NoteEditProposal` record and queue it, never touch note content.
@MainActor
struct ProposeNoteEditToolTests {
    private static let unsafeOrInvisibleNotePaths = [
        ".hidden.md",
        ".obsidian/Config.md",
        "notes/../outside.md",
        "/absolute.md",
        "note.txt",
        "note.md.tmp",
        "folder//note.md",
        "folder/./note.md",
    ]

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Chat.self, ChatMessage.self, NoteEditProposal.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    private func fetchProposals(in container: ModelContainer) -> [NoteEditProposal] {
        let context = ModelContext(container)
        return (try? context.fetch(FetchDescriptor<NoteEditProposal>())) ?? []
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Edit tool

    @Test func editToolInsertsAPendingProposalAndQueuesItWithoutWritingTheVault() async throws {
        let container = try makeContainer()
        let chatID = UUID()
        let coordinator = NotesProposalCoordinator()
        let vaultRoot = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: vaultRoot) }
        let vault = NotesVault(root: vaultRoot)
        guard case .wrote(let snapshot) = try await vault.write(relativePath: "note.md", content: "original", expectedHash: nil) else {
            Issue.record("expected a successful create")
            return
        }

        let tool = ProposeNoteEditTool(
            modelContainer: container,
            chatID: chatID,
            coordinator: coordinator,
            dependencies: .init(
                isAvailable: { true },
                readCurrentSnapshot: { path in
                    try? await vault.read(relativePath: path)
                }
            )
        )

        let result = try await tool.execute(arguments: [
            "path": .string("note.md"),
            "content": .string("proposed new content"),
            "summary": .string("Rewrite the intro"),
        ])

        #expect(result.contains("awaiting user approval"))

        let proposals = fetchProposals(in: container)
        #expect(proposals.count == 1)
        let proposal = try #require(proposals.first)
        #expect(proposal.kind == .edit)
        #expect(proposal.notePath == "note.md")
        #expect(proposal.baseContentHash == snapshot.sha256)
        #expect(proposal.proposedContent == "proposed new content")
        #expect(proposal.status == .pending)
        #expect(proposal.chatID == chatID)

        #expect(coordinator.hasQueuedProposals(forChatID: chatID))

        // The vault file itself must be untouched by proposing.
        let onDisk = try await vault.read(relativePath: "note.md")
        #expect(onDisk.content == "original")
    }

    @Test func editToolCapturesTheCurrentVaultIdentityOnTheProposal() async throws {
        let container = try makeContainer()
        let chatID = UUID()
        let coordinator = NotesProposalCoordinator()

        let tool = ProposeNoteEditTool(
            modelContainer: container,
            chatID: chatID,
            coordinator: coordinator,
            dependencies: .init(
                isAvailable: { true },
                readCurrentSnapshot: { path in
                    NoteFileSnapshot(relativePath: path, content: "original", sha256: "hash", modifiedAt: Date(timeIntervalSince1970: 0))
                },
                currentVaultID: { "vault-A" }
            )
        )

        _ = try await tool.execute(arguments: [
            "path": .string("note.md"),
            "content": .string("proposed new content"),
            "summary": .string("Rewrite the intro"),
        ])

        let proposal = try #require(fetchProposals(in: container).first)
        #expect(proposal.originatingVaultID == "vault-A")
    }

    @Test func editToolAllowsAnEmptyContentProposalToClearANote() async throws {
        let container = try makeContainer()
        let tool = ProposeNoteEditTool(
            modelContainer: container,
            chatID: UUID(),
            coordinator: NotesProposalCoordinator(),
            dependencies: .init(
                isAvailable: { true },
                readCurrentSnapshot: { path in
                    NoteFileSnapshot(relativePath: path, content: "original", sha256: "hash", modifiedAt: .now)
                },
                currentVaultID: { "vault-A" }
            )
        )

        _ = try await tool.execute(arguments: [
            "path": .string("note.md"),
            "content": .string(""),
            "summary": .string("Clear the note"),
        ])

        #expect(fetchProposals(in: container).first?.proposedContent == "")
    }

    @Test func editToolRejectsUnsafeOrInvisibleProposalPathsBeforeReading() async {
        let container = try! makeContainer()
        let readCount = MutableBox(0)
        let tool = ProposeNoteEditTool(
            modelContainer: container,
            chatID: UUID(),
            coordinator: NotesProposalCoordinator(),
            dependencies: .init(
                isAvailable: { true },
                readCurrentSnapshot: { _ in
                    readCount.value += 1
                    return nil
                },
                currentVaultID: { "vault-A" }
            )
        )

        for path in Self.unsafeOrInvisibleNotePaths {
            await #expect(throws: ToolError.self) {
                _ = try await tool.execute(arguments: [
                    "path": .string(path),
                    "content": .string("content"),
                    "summary": .string("summary"),
                ])
            }
        }

        #expect(readCount.value == 0)
        #expect(fetchProposals(in: container).isEmpty)
    }

    /// The P1 proposal-time vault binding race: a vault switch that lands
    /// entirely inside the suspended `readCurrentSnapshot` call must never
    /// let the resulting proposal bind vault A's content/hash to vault B's
    /// id. The stub reports "vault-A" up front, then flips to "vault-B" the
    /// moment the read resolves (simulating the switch completing mid-await)
    /// — the before/after capture in `execute` must catch the mismatch and
    /// refuse to persist anything.
    @Test func editToolRefusesWhenTheVaultIdentityChangesDuringTheSuspendedRead() async {
        let container = try! makeContainer()
        let chatID = UUID()
        let coordinator = NotesProposalCoordinator()
        let reportedVaultID = MutableBox("vault-A")

        let tool = ProposeNoteEditTool(
            modelContainer: container,
            chatID: chatID,
            coordinator: coordinator,
            dependencies: .init(
                isAvailable: { true },
                readCurrentSnapshot: { path in
                    reportedVaultID.value = "vault-B"
                    return NoteFileSnapshot(relativePath: path, content: "original", sha256: "hash", modifiedAt: Date(timeIntervalSince1970: 0))
                },
                currentVaultID: { reportedVaultID.value }
            )
        )

        await #expect(throws: ToolError.self) {
            _ = try await tool.execute(arguments: [
                "path": .string("note.md"),
                "content": .string("proposed new content"),
                "summary": .string("Rewrite the intro"),
            ])
        }

        #expect(fetchProposals(in: container).isEmpty)
        #expect(!coordinator.hasQueuedProposals(forChatID: chatID))
    }

    @Test func editToolThrowsWhenTheVaultIsNotConfiguredBeforeReading() async {
        let container = try! makeContainer()
        let tool = ProposeNoteEditTool(
            modelContainer: container,
            chatID: UUID(),
            dependencies: .init(
                isAvailable: { true },
                readCurrentSnapshot: { path in
                    NoteFileSnapshot(relativePath: path, content: "original", sha256: "hash", modifiedAt: Date(timeIntervalSince1970: 0))
                },
                currentVaultID: { nil }
            )
        )

        await #expect(throws: ToolError.self) {
            _ = try await tool.execute(arguments: [
                "path": .string("note.md"),
                "content": .string("content"),
                "summary": .string("summary"),
            ])
        }

        #expect(fetchProposals(in: container).isEmpty)
    }

    @Test func editToolThrowsWhenTheTargetNoteDoesNotExist() async {
        let container = try! makeContainer()
        let tool = ProposeNoteEditTool(
            modelContainer: container,
            chatID: UUID(),
            dependencies: .init(
                isAvailable: { true },
                readCurrentSnapshot: { _ in nil }
            )
        )

        await #expect(throws: ToolError.self) {
            _ = try await tool.execute(arguments: [
                "path": .string("missing.md"),
                "content": .string("content"),
                "summary": .string("summary"),
            ])
        }

        #expect(fetchProposals(in: container).isEmpty)
    }

    @Test func editToolThrowsNotConfiguredWhenUnavailable() async {
        let container = try! makeContainer()
        let tool = ProposeNoteEditTool(
            modelContainer: container,
            chatID: UUID(),
            dependencies: .init(isAvailable: { false }, readCurrentSnapshot: { _ in nil })
        )

        await #expect(throws: ToolError.self) {
            _ = try await tool.execute(arguments: [
                "path": .string("note.md"),
                "content": .string("content"),
                "summary": .string("summary"),
            ])
        }
    }

    // MARK: - Create tool

    @Test func createToolInsertsACreateOnlyPendingProposalWithNoBaseHash() async throws {
        let container = try makeContainer()
        let chatID = UUID()
        let coordinator = NotesProposalCoordinator()

        let tool = ProposeNoteCreateTool(
            modelContainer: container,
            chatID: chatID,
            coordinator: coordinator,
            dependencies: .init(isAvailable: { true }, readCurrentSnapshot: { _ in nil })
        )

        let result = try await tool.execute(arguments: [
            "path": .string("New Note.md"),
            "content": .string("brand new content"),
            "summary": .string("Create a note about X"),
        ])

        #expect(result.contains("awaiting user approval"))

        let proposal = try #require(fetchProposals(in: container).first)
        #expect(proposal.kind == .create)
        #expect(proposal.baseContentHash == nil)
        #expect(proposal.proposedContent == "brand new content")
        #expect(proposal.status == .pending)
        #expect(coordinator.hasQueuedProposals(forChatID: chatID))
    }

    @Test func createToolCapturesTheCurrentVaultIdentityOnTheProposal() async throws {
        let container = try makeContainer()
        let chatID = UUID()
        let coordinator = NotesProposalCoordinator()

        let tool = ProposeNoteCreateTool(
            modelContainer: container,
            chatID: chatID,
            coordinator: coordinator,
            dependencies: .init(
                isAvailable: { true },
                readCurrentSnapshot: { _ in nil },
                currentVaultID: { "vault-A" }
            )
        )

        _ = try await tool.execute(arguments: [
            "path": .string("New Note.md"),
            "content": .string("brand new content"),
            "summary": .string("Create a note about X"),
        ])

        let proposal = try #require(fetchProposals(in: container).first)
        #expect(proposal.originatingVaultID == "vault-A")
    }

    @Test func createToolAllowsAnEmptyContentProposal() async throws {
        let container = try makeContainer()
        let tool = ProposeNoteCreateTool(
            modelContainer: container,
            chatID: UUID(),
            coordinator: NotesProposalCoordinator(),
            dependencies: .init(
                isAvailable: { true },
                readCurrentSnapshot: { _ in nil },
                currentVaultID: { "vault-A" }
            )
        )

        _ = try await tool.execute(arguments: [
            "path": .string("Blank.md"),
            "content": .string(""),
            "summary": .string("Create a blank note"),
        ])

        #expect(fetchProposals(in: container).first?.proposedContent == "")
    }

    @Test func createToolRejectsUnsafeOrInvisibleProposalPathsBeforeCheckingExistence() async {
        let container = try! makeContainer()
        let readCount = MutableBox(0)
        let tool = ProposeNoteCreateTool(
            modelContainer: container,
            chatID: UUID(),
            coordinator: NotesProposalCoordinator(),
            dependencies: .init(
                isAvailable: { true },
                readCurrentSnapshot: { _ in
                    readCount.value += 1
                    return nil
                },
                currentVaultID: { "vault-A" }
            )
        )

        for path in Self.unsafeOrInvisibleNotePaths {
            await #expect(throws: ToolError.self) {
                _ = try await tool.execute(arguments: [
                    "path": .string(path),
                    "content": .string("content"),
                    "summary": .string("summary"),
                ])
            }
        }

        #expect(readCount.value == 0)
        #expect(fetchProposals(in: container).isEmpty)
    }

    /// Same P1 vault-binding race as `editToolRefusesWhenTheVaultIdentityChangesDuringTheSuspendedRead`,
    /// but for the create tool's existence check.
    @Test func createToolRefusesWhenTheVaultIdentityChangesDuringTheSuspendedExistenceCheck() async {
        let container = try! makeContainer()
        let chatID = UUID()
        let coordinator = NotesProposalCoordinator()
        let reportedVaultID = MutableBox("vault-A")

        let tool = ProposeNoteCreateTool(
            modelContainer: container,
            chatID: chatID,
            coordinator: coordinator,
            dependencies: .init(
                isAvailable: { true },
                readCurrentSnapshot: { _ in
                    reportedVaultID.value = "vault-B"
                    return nil
                },
                currentVaultID: { reportedVaultID.value }
            )
        )

        await #expect(throws: ToolError.self) {
            _ = try await tool.execute(arguments: [
                "path": .string("New Note.md"),
                "content": .string("brand new content"),
                "summary": .string("Create a note about X"),
            ])
        }

        #expect(fetchProposals(in: container).isEmpty)
        #expect(!coordinator.hasQueuedProposals(forChatID: chatID))
    }

    @Test func createToolThrowsWhenTheVaultIsNotConfiguredBeforeChecking() async {
        let container = try! makeContainer()
        let tool = ProposeNoteCreateTool(
            modelContainer: container,
            chatID: UUID(),
            dependencies: .init(
                isAvailable: { true },
                readCurrentSnapshot: { _ in nil },
                currentVaultID: { nil }
            )
        )

        await #expect(throws: ToolError.self) {
            _ = try await tool.execute(arguments: [
                "path": .string("New Note.md"),
                "content": .string("content"),
                "summary": .string("summary"),
            ])
        }

        #expect(fetchProposals(in: container).isEmpty)
    }

    @Test func createToolRefusesToProposeOverAnExistingPath() async {
        let container = try! makeContainer()
        let tool = ProposeNoteCreateTool(
            modelContainer: container,
            chatID: UUID(),
            dependencies: .init(
                isAvailable: { true },
                readCurrentSnapshot: { path in
                    NoteFileSnapshot(relativePath: path, content: "existing", sha256: "hash", modifiedAt: Date(timeIntervalSince1970: 0))
                }
            )
        )

        await #expect(throws: ToolError.self) {
            _ = try await tool.execute(arguments: [
                "path": .string("note.md"),
                "content": .string("content"),
                "summary": .string("summary"),
            ])
        }

        #expect(fetchProposals(in: container).isEmpty)
    }
}
