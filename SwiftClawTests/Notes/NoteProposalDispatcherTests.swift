import CryptoKit
import Foundation
import Testing
import SwiftData
@testable import SwiftClaw

/// Mutable main-actor state for synchronous dispatcher seams.
@MainActor
private final class MutableBox<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}

/// Sendable call counter for closures that run outside the main actor.
private actor AsyncCallCounter {
    private var value = 0

    func increment() {
        value += 1
    }

    func currentValue() -> Int {
        value
    }
}

/// Records concurrent completion order without sharing mutable state between
/// tasks.
private actor CompletionLog {
    private var entries: [String] = []

    func append(_ entry: String) {
        entries.append(entry)
    }

    func currentEntries() -> [String] {
        entries
    }
}

/// Gates only the first vault scope access. An edit approval performs several
/// scoped reads/writes; gating every one would require multiple releases and
/// would turn this lease-ordering test into a repository-operation deadlock.
@MainActor
private final class FirstOperationGate {
    private let gate = ToolOperationGate()
    private var hasEntered = false

    func enterFirstAndWaitForRelease() async {
        guard !hasEntered else { return }
        hasEntered = true
        await gate.enterAndWaitForRelease()
    }

    func waitUntilEntered() async {
        await gate.waitUntilEntered()
    }

    func release() {
        gate.release()
    }
}

private enum InjectedSaveFailure: Error {
    case selectedCall
}

private enum InjectedVaultFailure: Error, Sendable {
    case unavailable
}

/// The critical Phase 5 safety suite: approving a proposal must never
/// silently clobber a note that changed on disk after the proposal was made
/// (the hash guard re-checked immediately before mutation), a clean approve
/// must apply through `NotesRepository` (so the existing revision-snapshot
/// behavior runs), and repeated actions on an already-resolved proposal must
/// be no-ops.
@MainActor
struct NoteProposalDispatcherTests {
    /// Every test's proposals are captured against this id by default;
    /// `makeDispatcher` wires a matching `VaultOperationLeaseCoordinator` so
    /// approval succeeds unless a test deliberately wants a mismatch/denied
    /// lease.
    private let defaultVaultID = "vault-under-test"

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeRepository() throws -> (repository: NotesRepository, vault: NotesVault, vaultRoot: URL, revisionStore: NoteRevisionStore) {
        let vaultRoot = try makeTempDirectory()
        let revisionsDirectory = try makeTempDirectory()
        let vault = NotesVault(root: vaultRoot)
        let revisionStore = NoteRevisionStore(directory: revisionsDirectory)
        let repository = NotesRepository(vault: vault, revisionStore: revisionStore)
        return (repository, vault, vaultRoot, revisionStore)
    }

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Chat.self, ChatMessage.self, NoteEditProposal.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    /// Builds a dispatcher whose `acquireVaultOperationLease` seam grants a
    /// lease from `leaseCoordinator` only when the requested id matches
    /// `vaultID` — mirrors `NotesFeatureModel.acquireVaultOperationLease`'s
    /// identity check without needing real settings/a real feature model.
    private func makeDispatcher(
        container: ModelContainer,
        repository: NotesRepository?,
        vaultID: String,
        leaseCoordinator: VaultOperationLeaseCoordinator? = nil,
        saveProposalStatus: @escaping @MainActor (ModelContext) throws -> Void = { context in
            try context.save()
        }
    ) -> NoteProposalDispatcher {
        let leaseCoordinator = leaseCoordinator ?? VaultOperationLeaseCoordinator()
        return NoteProposalDispatcher(
            modelContainer: container,
            repositoryProvider: { repository },
            acquireVaultOperationLease: { requestedVaultID in
                requestedVaultID == vaultID ? leaseCoordinator.acquireLease() : nil
            },
            saveProposalStatus: saveProposalStatus
        )
    }

    @discardableResult
    private func insertChat(in container: ModelContainer) -> Chat {
        let context = ModelContext(container)
        let chat = Chat(title: "Notes", modelSelection: "test-model")
        context.insert(chat)
        try? context.save()
        return chat
    }

    private func insertProposal(_ proposal: NoteEditProposal, in container: ModelContainer) {
        let context = ModelContext(container)
        context.insert(proposal)
        try? context.save()
    }

    private func fetchProposal(id: UUID, in container: ModelContainer) -> NoteEditProposal? {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<NoteEditProposal>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func fetchChat(id: UUID, in container: ModelContainer) -> Chat? {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<Chat>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    // MARK: - Clean approve

    @Test func cleanApproveAppliesTheEditAndCreatesARevisionSnapshot() async throws {
        let (repository, vault, vaultRoot, revisionStore) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: vaultRoot) }
        let container = try makeContainer()
        let chat = insertChat(in: container)

        guard case .wrote(let original) = try await vault.write(relativePath: "note.md", content: "original content", expectedHash: nil) else {
            Issue.record("expected a successful create")
            return
        }

        let proposal = NoteEditProposal(
            kind: .edit,
            notePath: "note.md",
            baseContentHash: original.sha256,
            proposedContent: "new content",
            summary: "Rewrite the note",
            chatID: chat.id,
            originatingVaultID: defaultVaultID
        )
        insertProposal(proposal, in: container)

        let dispatcher = makeDispatcher(container: container, repository: repository, vaultID: defaultVaultID)
        await dispatcher.perform(action: .approve, itemID: proposal.id)

        let resolved = try #require(fetchProposal(id: proposal.id, in: container))
        #expect(resolved.status == .applied)
        #expect(resolved.resolvedAt != nil)

        let onDisk = try await vault.read(relativePath: "note.md")
        #expect(onDisk.content == "new content")

        let revisions = try await revisionStore.revisions(forKey: "note.md")
        #expect(revisions.contains { $0.content == "original content" })

        let updatedChat = try #require(fetchChat(id: chat.id, in: container))
        #expect(updatedChat.visibleMessages.contains { $0.content.contains("Applied") })
    }

    @Test func cleanApproveCanClearANote() async throws {
        let (repository, vault, vaultRoot, _) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: vaultRoot) }
        let container = try makeContainer()
        let chat = insertChat(in: container)

        guard case .wrote(let original) = try await vault.write(relativePath: "note.md", content: "original content", expectedHash: nil) else {
            Issue.record("expected a successful create")
            return
        }

        let proposal = NoteEditProposal(
            kind: .edit,
            notePath: "note.md",
            baseContentHash: original.sha256,
            proposedContent: "",
            summary: "Clear the note",
            chatID: chat.id,
            originatingVaultID: defaultVaultID
        )
        insertProposal(proposal, in: container)

        let dispatcher = makeDispatcher(container: container, repository: repository, vaultID: defaultVaultID)
        await dispatcher.perform(action: .approve, itemID: proposal.id)

        #expect(fetchProposal(id: proposal.id, in: container)?.status == .applied)
        #expect(try await vault.read(relativePath: "note.md").content.isEmpty)
    }

    // MARK: - Conflict

    @Test func approveAfterAnExternalEditMarksConflictedAndLeavesTheFileUntouched() async throws {
        let (repository, vault, vaultRoot, _) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: vaultRoot) }
        let container = try makeContainer()
        let chat = insertChat(in: container)

        guard case .wrote(let original) = try await vault.write(relativePath: "note.md", content: "original content", expectedHash: nil) else {
            Issue.record("expected a successful create")
            return
        }

        // Simulate an external editor changing the file after the proposal
        // captured its base hash.
        _ = try await vault.write(relativePath: "note.md", content: "changed externally", expectedHash: original.sha256)

        let proposal = NoteEditProposal(
            kind: .edit,
            notePath: "note.md",
            baseContentHash: original.sha256,
            proposedContent: "attempted overwrite",
            summary: "Rewrite the note",
            chatID: chat.id,
            originatingVaultID: defaultVaultID
        )
        insertProposal(proposal, in: container)

        let dispatcher = makeDispatcher(container: container, repository: repository, vaultID: defaultVaultID)
        await dispatcher.perform(action: .approve, itemID: proposal.id)

        let resolved = try #require(fetchProposal(id: proposal.id, in: container))
        #expect(resolved.status == .conflicted)
        #expect(resolved.resolvedAt != nil)

        let onDisk = try await vault.read(relativePath: "note.md")
        #expect(onDisk.content == "changed externally")

        let updatedChat = try #require(fetchChat(id: chat.id, in: container))
        #expect(updatedChat.visibleMessages.contains { $0.content.contains("not applied") })
    }

    @Test func approveOfACreateProposalOverAnExistingPathConflictsWithoutWritingAConflictCopy() async throws {
        let (repository, vault, vaultRoot, _) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: vaultRoot) }
        let container = try makeContainer()
        let chat = insertChat(in: container)

        _ = try await vault.write(relativePath: "note.md", content: "already here", expectedHash: nil)

        let proposal = NoteEditProposal(
            kind: .create,
            notePath: "note.md",
            baseContentHash: nil,
            proposedContent: "new note content",
            summary: "Create a note",
            chatID: chat.id,
            originatingVaultID: defaultVaultID
        )
        insertProposal(proposal, in: container)

        let dispatcher = makeDispatcher(container: container, repository: repository, vaultID: defaultVaultID)
        await dispatcher.perform(action: .approve, itemID: proposal.id)

        let resolved = try #require(fetchProposal(id: proposal.id, in: container))
        #expect(resolved.status == .conflicted)

        let onDisk = try await vault.read(relativePath: "note.md")
        #expect(onDisk.content == "already here")

        let entries = try await vault.enumerate()
        #expect(entries == ["note.md"])
    }

    @Test func approvalInfrastructureFailureRestoresPendingWithoutClaimingAConflict() async throws {
        let vaultRoot = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: vaultRoot) }
        try Data("original content".utf8).write(to: vaultRoot.appendingPathComponent("note.md"))
        let originalHash = SHA256.hash(data: Data("original content".utf8)).map { String(format: "%02x", $0) }.joined()
        let vault = NotesVault(root: vaultRoot, scopeAccessor: {
            throw InjectedVaultFailure.unavailable
        })
        let revisionsDirectory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: revisionsDirectory) }
        let repository = NotesRepository(vault: vault, revisionStore: NoteRevisionStore(directory: revisionsDirectory))
        let container = try makeContainer()
        let chat = insertChat(in: container)
        let proposal = NoteEditProposal(
            kind: .edit,
            notePath: "note.md",
            baseContentHash: originalHash,
            proposedContent: "new content",
            summary: "Rewrite the note",
            chatID: chat.id,
            originatingVaultID: defaultVaultID
        )
        insertProposal(proposal, in: container)

        let dispatcher = makeDispatcher(container: container, repository: repository, vaultID: defaultVaultID)
        await dispatcher.perform(action: .approve, itemID: proposal.id)

        let persisted = try #require(fetchProposal(id: proposal.id, in: container))
        #expect(persisted.status == .pending)
        #expect(persisted.resolvedAt == nil)
        #expect(try String(contentsOf: vaultRoot.appendingPathComponent("note.md"), encoding: .utf8) == "original content")

        let updatedChat = try #require(fetchChat(id: chat.id, in: container))
        #expect(updatedChat.visibleMessages.contains { $0.content.contains("couldn't confirm whether the note changed") })
        #expect(!updatedChat.visibleMessages.contains { $0.content.contains("Note changed since proposed") })
    }

    // MARK: - Reject

    @Test func rejectMarksRejectedAndPostsAnOutcome() async throws {
        let (repository, vault, vaultRoot, _) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: vaultRoot) }
        let container = try makeContainer()
        let chat = insertChat(in: container)

        guard case .wrote(let original) = try await vault.write(relativePath: "note.md", content: "original content", expectedHash: nil) else {
            Issue.record("expected a successful create")
            return
        }

        let proposal = NoteEditProposal(
            kind: .edit,
            notePath: "note.md",
            baseContentHash: original.sha256,
            proposedContent: "new content",
            summary: "Rewrite the note",
            chatID: chat.id,
            originatingVaultID: defaultVaultID
        )
        insertProposal(proposal, in: container)

        let dispatcher = makeDispatcher(container: container, repository: repository, vaultID: defaultVaultID)
        await dispatcher.perform(action: .reject, itemID: proposal.id)

        let resolved = try #require(fetchProposal(id: proposal.id, in: container))
        #expect(resolved.status == .rejected)
        #expect(resolved.resolvedAt != nil)

        let onDisk = try await vault.read(relativePath: "note.md")
        #expect(onDisk.content == "original content")

        let updatedChat = try #require(fetchChat(id: chat.id, in: container))
        #expect(updatedChat.visibleMessages.contains { $0.content.contains("Rejected") })
    }

    // MARK: - Vault switch (originating-vault identity)

    @Test func approveOfAnEditProposalAfterAVaultSwitchMarksExpiredAndWritesNothing() async throws {
        let (repository, vault, vaultRoot, _) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: vaultRoot) }
        let container = try makeContainer()
        let chat = insertChat(in: container)

        guard case .wrote(let original) = try await vault.write(relativePath: "note.md", content: "original content", expectedHash: nil) else {
            Issue.record("expected a successful create")
            return
        }

        let proposal = NoteEditProposal(
            kind: .edit,
            notePath: "note.md",
            baseContentHash: original.sha256,
            proposedContent: "new content",
            summary: "Rewrite the note",
            chatID: chat.id,
            originatingVaultID: "vault-A"
        )
        insertProposal(proposal, in: container)

        // The proposal was captured against "vault-A"; the user has since
        // switched to a different vault — approval must refuse to touch
        // this (unrelated) vault's `repository`/`vault` at all. A dispatcher
        // whose lease seam denies every request stands in for "vault-A" no
        // longer being the configured vault.
        let dispatcher = NoteProposalDispatcher(
            modelContainer: container,
            repositoryProvider: { repository },
            acquireVaultOperationLease: { _ in nil }
        )
        await dispatcher.perform(action: .approve, itemID: proposal.id)

        let resolved = try #require(fetchProposal(id: proposal.id, in: container))
        #expect(resolved.status == .expired)
        #expect(resolved.resolvedAt != nil)

        let onDisk = try await vault.read(relativePath: "note.md")
        #expect(onDisk.content == "original content")

        let updatedChat = try #require(fetchChat(id: chat.id, in: container))
        #expect(updatedChat.visibleMessages.contains { $0.content.contains("not applied") })
    }

    @Test func approveOfACreateProposalAfterAVaultSwitchMarksExpiredAndWritesNothing() async throws {
        let (repository, vault, vaultRoot, _) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: vaultRoot) }
        let container = try makeContainer()
        let chat = insertChat(in: container)

        let proposal = NoteEditProposal(
            kind: .create,
            notePath: "New Note.md",
            baseContentHash: nil,
            proposedContent: "brand new content",
            summary: "Create a note",
            chatID: chat.id,
            originatingVaultID: "vault-A"
        )
        insertProposal(proposal, in: container)

        let dispatcher = NoteProposalDispatcher(
            modelContainer: container,
            repositoryProvider: { repository },
            acquireVaultOperationLease: { _ in nil }
        )
        await dispatcher.perform(action: .approve, itemID: proposal.id)

        let resolved = try #require(fetchProposal(id: proposal.id, in: container))
        #expect(resolved.status == .expired)

        let entries = try await vault.enumerate()
        #expect(entries.isEmpty)
    }

    @Test func approveStillAppliesWhenTheVaultIdentityIsUnchanged() async throws {
        let (repository, vault, vaultRoot, _) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: vaultRoot) }
        let container = try makeContainer()
        let chat = insertChat(in: container)

        let proposal = NoteEditProposal(
            kind: .create,
            notePath: "New Note.md",
            baseContentHash: nil,
            proposedContent: "brand new content",
            summary: "Create a note",
            chatID: chat.id,
            originatingVaultID: "vault-A"
        )
        insertProposal(proposal, in: container)

        let dispatcher = makeDispatcher(container: container, repository: repository, vaultID: "vault-A")
        await dispatcher.perform(action: .approve, itemID: proposal.id)

        let resolved = try #require(fetchProposal(id: proposal.id, in: container))
        #expect(resolved.status == .applied)

        let onDisk = try await vault.read(relativePath: "New Note.md")
        #expect(onDisk.content == "brand new content")
    }

    // MARK: - Missing originating vault id (unbound proposal)

    /// A `nil` `originatingVaultID` (a proposal that predates the
    /// vault-binding check, or was otherwise never bound) is unbound and must
    /// expire without ever touching the repository — safety over the legacy
    /// convenience of treating a missing id as "assume it matches".
    @Test func approveOfAnEditProposalWithNoOriginatingVaultIDExpiresWithoutTouchingTheRepository() async throws {
        let (repository, vault, vaultRoot, _) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: vaultRoot) }
        let container = try makeContainer()
        let chat = insertChat(in: container)

        guard case .wrote(let original) = try await vault.write(relativePath: "note.md", content: "original content", expectedHash: nil) else {
            Issue.record("expected a successful create")
            return
        }

        let proposal = NoteEditProposal(
            kind: .edit,
            notePath: "note.md",
            baseContentHash: original.sha256,
            proposedContent: "new content",
            summary: "Rewrite the note",
            chatID: chat.id
            // originatingVaultID defaults to nil.
        )
        insertProposal(proposal, in: container)

        let repositoryProviderCallCount = MutableBox(0)
        let leaseRequestCount = MutableBox(0)
        let dispatcher = NoteProposalDispatcher(
            modelContainer: container,
            repositoryProvider: {
                repositoryProviderCallCount.value += 1
                return repository
            },
            acquireVaultOperationLease: { _ in
                leaseRequestCount.value += 1
                return nil
            }
        )
        await dispatcher.perform(action: .approve, itemID: proposal.id)

        let resolved = try #require(fetchProposal(id: proposal.id, in: container))
        #expect(resolved.status == .expired)
        #expect(repositoryProviderCallCount.value == 0)
        #expect(leaseRequestCount.value == 0)

        let onDisk = try await vault.read(relativePath: "note.md")
        #expect(onDisk.content == "original content")
    }

    @Test func approveOfACreateProposalWithNoOriginatingVaultIDExpiresWithoutTouchingTheRepository() async throws {
        let (repository, vault, vaultRoot, _) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: vaultRoot) }
        let container = try makeContainer()
        let chat = insertChat(in: container)

        let proposal = NoteEditProposal(
            kind: .create,
            notePath: "New Note.md",
            baseContentHash: nil,
            proposedContent: "brand new content",
            summary: "Create a note",
            chatID: chat.id
            // originatingVaultID defaults to nil.
        )
        insertProposal(proposal, in: container)

        let repositoryProviderCallCount = MutableBox(0)
        let dispatcher = NoteProposalDispatcher(
            modelContainer: container,
            repositoryProvider: {
                repositoryProviderCallCount.value += 1
                return repository
            },
            acquireVaultOperationLease: { _ in nil }
        )
        await dispatcher.perform(action: .approve, itemID: proposal.id)

        let resolved = try #require(fetchProposal(id: proposal.id, in: container))
        #expect(resolved.status == .expired)
        #expect(repositoryProviderCallCount.value == 0)

        let entries = try await vault.enumerate()
        #expect(entries.isEmpty)
    }

    // MARK: - Ordered status-persistence failures

    @Test func preflightApplyingSaveFailureDoesNotTouchTheVaultOrPostAnAppliedOutcome() async throws {
        let vaultRoot = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: vaultRoot) }
        try Data("original content".utf8).write(to: vaultRoot.appendingPathComponent("note.md"))

        let vaultOperationCount = AsyncCallCounter()
        let vault = NotesVault(root: vaultRoot, scopeAccessor: {
            await vaultOperationCount.increment()
            return nil
        })
        let revisionsDirectory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: revisionsDirectory) }
        let repository = NotesRepository(vault: vault, revisionStore: NoteRevisionStore(directory: revisionsDirectory))
        let container = try makeContainer()
        let chat = insertChat(in: container)
        let originalHash = SHA256.hash(data: Data("original content".utf8)).map { String(format: "%02x", $0) }.joined()
        let proposal = NoteEditProposal(
            kind: .edit,
            notePath: "note.md",
            baseContentHash: originalHash,
            proposedContent: "new content",
            summary: "Rewrite the note",
            chatID: chat.id,
            originatingVaultID: defaultVaultID
        )
        insertProposal(proposal, in: container)

        let saveCallCount = MutableBox(0)
        let dispatcher = makeDispatcher(
            container: container,
            repository: repository,
            vaultID: defaultVaultID,
            saveProposalStatus: { context in
                saveCallCount.value += 1
                if saveCallCount.value == 1 { throw InjectedSaveFailure.selectedCall }
                try context.save()
            }
        )

        await dispatcher.perform(action: .approve, itemID: proposal.id)

        // The first (preflight `.applying`) save failed, so rollback restored
        // the durable pending record before the dispatcher could touch the
        // repository/vault at all.
        let persisted = try #require(fetchProposal(id: proposal.id, in: container))
        #expect(persisted.status == .pending)
        #expect(persisted.resolvedAt == nil)
        #expect(await vaultOperationCount.currentValue() == 0)
        #expect(try Data(contentsOf: vaultRoot.appendingPathComponent("note.md")) == Data("original content".utf8))

        let updatedChat = try #require(fetchChat(id: chat.id, in: container))
        #expect(!updatedChat.visibleMessages.contains { $0.content.contains("Applied") })
    }

    @Test func finalAppliedSaveFailureStaysApplyingAndNeverReappliesTheFileChange() async throws {
        let (repository, vault, vaultRoot, revisionStore) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: vaultRoot) }
        let container = try makeContainer()
        let chat = insertChat(in: container)

        guard case .wrote(let original) = try await vault.write(relativePath: "note.md", content: "original content", expectedHash: nil) else {
            Issue.record("expected a successful create")
            return
        }

        let proposal = NoteEditProposal(
            kind: .edit,
            notePath: "note.md",
            baseContentHash: original.sha256,
            proposedContent: "new content",
            summary: "Rewrite the note",
            chatID: chat.id,
            originatingVaultID: defaultVaultID
        )
        insertProposal(proposal, in: container)

        let saveCallCount = MutableBox(0)
        let dispatcher = makeDispatcher(
            container: container,
            repository: repository,
            vaultID: defaultVaultID,
            saveProposalStatus: { context in
                saveCallCount.value += 1
                if saveCallCount.value == 2 { throw InjectedSaveFailure.selectedCall }
                try context.save()
            }
        )

        await dispatcher.perform(action: .approve, itemID: proposal.id)

        // The successful file mutation happened between the two ordered saves,
        // but rollback of the failed final save reveals the already-durable
        // intermediate state to a fresh context.
        let persistedAfterFailure = try #require(fetchProposal(id: proposal.id, in: container))
        #expect(persistedAfterFailure.status == .applying)
        #expect(persistedAfterFailure.resolvedAt == nil)
        #expect(try await vault.read(relativePath: "note.md").content == "new content")
        let revisionsAfterFirstAttempt = try await revisionStore.revisions(forKey: "note.md")
        #expect(revisionsAfterFirstAttempt.count == 1)
        #expect(revisionsAfterFirstAttempt.first?.content == "original content")

        let chatAfterFailure = try #require(fetchChat(id: chat.id, in: container))
        #expect(chatAfterFailure.visibleMessages.contains {
            $0.content.contains("Please verify the note directly, or ask me to re-propose.")
        })
        #expect(!chatAfterFailure.visibleMessages.contains { $0.content.hasPrefix("Applied the proposed") })

        await dispatcher.perform(action: .approve, itemID: proposal.id)

        let persistedAfterRetry = try #require(fetchProposal(id: proposal.id, in: container))
        #expect(persistedAfterRetry.status == .applying)
        #expect(saveCallCount.value == 2)
        #expect(try await vault.read(relativePath: "note.md").content == "new content")
        let revisionsAfterRetry = try await revisionStore.revisions(forKey: "note.md")
        #expect(revisionsAfterRetry.count == 1)
    }

    // MARK: - Vault-operation lease (teardown vs. in-flight approval)

    /// The P1 in-flight-approval-vs-vault-switch race: a settings switch
    /// must not begin clearing/reconfiguring vault state while a
    /// `NoteProposalDispatcher` approval already holds a lease and is
    /// suspended mid file-operation. `NotesVault`'s `scopeAccessor` is the
    /// vault's own real per-operation suspension point — wrapping it in a
    /// `ToolOperationGate` (the same deterministic two-phase rendezvous
    /// `NotesFeatureModelTests` already uses for the read-tool stale-result
    /// races) pauses `applyEdit`'s `repository.read` exactly there, with the
    /// lease already acquired, so `beginTeardownAndWaitForDrain()` is
    /// guaranteed to observe an active lease rather than racing to start
    /// before one exists.
    @Test func teardownWaitsForAnInFlightGatedApprovalToReleaseItsLeaseBeforeCompleting() async throws {
        let vaultRoot = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: vaultRoot) }
        // Written directly (not through the vault) so setup itself never
        // touches the gate below.
        try Data("original content".utf8).write(to: vaultRoot.appendingPathComponent("note.md"))

        let gate = FirstOperationGate()
        let vault = NotesVault(root: vaultRoot, scopeAccessor: {
            await gate.enterFirstAndWaitForRelease()
            return nil
        })
        let revisionsDirectory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: revisionsDirectory) }
        let repository = NotesRepository(vault: vault, revisionStore: NoteRevisionStore(directory: revisionsDirectory))

        let container = try makeContainer()
        let chat = insertChat(in: container)
        // The base hash is computed against the setup content above without
        // going through the gated vault.
        let originalHash = SHA256.hash(data: Data("original content".utf8)).map { String(format: "%02x", $0) }.joined()
        let proposal = NoteEditProposal(
            kind: .edit,
            notePath: "note.md",
            baseContentHash: originalHash,
            proposedContent: "new content",
            summary: "Rewrite the note",
            chatID: chat.id,
            originatingVaultID: defaultVaultID
        )
        insertProposal(proposal, in: container)

        let leaseCoordinator = VaultOperationLeaseCoordinator()
        let dispatcher = makeDispatcher(container: container, repository: repository, vaultID: defaultVaultID, leaseCoordinator: leaseCoordinator)

        let proposalID = proposal.id
        let completionOrder = CompletionLog()

        async let approveOutcome: Void = {
            await dispatcher.perform(action: .approve, itemID: proposalID)
            await completionOrder.append("approve")
        }()

        // The approval is now suspended inside `applyEdit`'s
        // `repository.read`, having already acquired its lease.
        await gate.waitUntilEntered()

        async let teardownOwner: VaultOperationLeaseCoordinator.Teardown = {
            await leaseCoordinator.beginTeardownAndWaitForDrain()
        }()

        // Synchronize with the coordinator's exact state transition instead
        // of hoping its newly-created task has run after scheduler yields.
        await leaseCoordinator.waitUntilTeardownStarted()
        #expect(leaseCoordinator.isTeardownInProgress)
        #expect(await completionOrder.currentEntries().isEmpty)
        // Once teardown has begun, a brand new lease request must be refused
        // even though the in-flight approval's own lease is still held.
        #expect(leaseCoordinator.acquireLease() == nil)

        gate.release()
        _ = await approveOutcome
        let teardown = await teardownOwner
        await completionOrder.append("teardown")
        leaseCoordinator.endTeardown(teardown)

        // The approval's own file operation — and its lease release — must
        // have completed strictly before teardown's wait returned.
        #expect(await completionOrder.currentEntries() == ["approve", "teardown"])

        let resolved = try #require(fetchProposal(id: proposal.id, in: container))
        #expect(resolved.status == .applied)
    }

    /// "A direct feature-model lease test is fine if safer than timing a
    /// whole settings flow" — this is that: fully deterministic, no timing
    /// assumptions. Once teardown has begun, no new lease can be acquired,
    /// full stop.
    @Test func newLeaseCannotBeAcquiredOnceTeardownHasBegun() async {
        let coordinator = VaultOperationLeaseCoordinator()
        // No lease held yet, so this returns immediately.
        let teardown = await coordinator.beginTeardownAndWaitForDrain()

        #expect(coordinator.acquireLease() == nil)
        coordinator.endTeardown(teardown)
    }

    @Test func overlappingTeardownsTransferOwnershipFIFOWithoutReopeningLeases() async throws {
        let coordinator = VaultOperationLeaseCoordinator()
        let firstOwner = await coordinator.beginTeardownAndWaitForDrain()

        let secondOwnerTask = Task {
            await coordinator.beginTeardownAndWaitForDrain()
        }
        await coordinator.waitUntilTeardownIsQueued()

        let thirdOwnerTask = Task {
            await coordinator.beginTeardownAndWaitForDrain()
        }
        await coordinator.waitUntilTeardownIsQueued(atLeast: 2)

        #expect(coordinator.isTeardownInProgress)
        #expect(coordinator.acquireLease() == nil)

        coordinator.endTeardown(firstOwner)
        let secondOwner = await secondOwnerTask.value
        // The second caller was first in the queue, and it owns the gate now.
        // A stale first-owner end cannot reopen acquisition underneath it.
        #expect(coordinator.acquireLease() == nil)
        coordinator.endTeardown(firstOwner)
        #expect(coordinator.isTeardownInProgress)
        #expect(coordinator.acquireLease() == nil)

        coordinator.endTeardown(secondOwner)
        let thirdOwner = await thirdOwnerTask.value
        #expect(coordinator.acquireLease() == nil)

        coordinator.endTeardown(thirdOwner)
        #expect(!coordinator.isTeardownInProgress)
        let lease = try #require(coordinator.acquireLease())
        lease.release()
    }

    // MARK: - Exact-path create collision (atomic, no vault writes)

    @Test func createCollisionWritesNeitherTheTargetNorAConflictCopy() async throws {
        let (repository, vault, vaultRoot, _) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: vaultRoot) }

        _ = try await vault.write(relativePath: "note.md", content: "already here", expectedHash: nil)

        await #expect(throws: NotesError.self) {
            _ = try await repository.createExactPath(relativePath: "note.md", content: "attempted create")
        }

        let onDisk = try await vault.read(relativePath: "note.md")
        #expect(onDisk.content == "already here")

        let entries = try await vault.enumerate()
        #expect(entries == ["note.md"])
    }

    @Test func vaultCreateExclusiveCollisionWritesNothing() async throws {
        let (_, vault, vaultRoot, _) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: vaultRoot) }

        _ = try await vault.write(relativePath: "note.md", content: "already here", expectedHash: nil)

        let outcome = try await vault.createExclusive(relativePath: "note.md", content: "attempted create")
        #expect(outcome == .collision)

        let onDisk = try await vault.read(relativePath: "note.md")
        #expect(onDisk.content == "already here")
        #expect(try await vault.enumerate() == ["note.md"])
    }

    // MARK: - Card ModelContext staleness

    @Test func cardsFetchLatestProposalStateAcrossASeparateContextWrite() async throws {
        let (repository, vault, vaultRoot, _) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: vaultRoot) }
        let container = try makeContainer()
        let chat = insertChat(in: container)

        guard case .wrote(let original) = try await vault.write(relativePath: "note.md", content: "original content", expectedHash: nil) else {
            Issue.record("expected a successful create")
            return
        }

        let proposal = NoteEditProposal(
            kind: .edit,
            notePath: "note.md",
            baseContentHash: original.sha256,
            proposedContent: "new content",
            summary: "Rewrite the note",
            chatID: chat.id,
            originatingVaultID: defaultVaultID
        )
        insertProposal(proposal, in: container)

        // Mimics the card's long-lived environment `ModelContext`: fetch
        // once up front so the proposal is registered before another
        // context (the dispatcher's) mutates and saves it.
        let cardContext = ModelContext(container)
        _ = NoteProposalCardRenderer.fetchLatestProposal(id: proposal.id, in: cardContext)

        let dispatcher = makeDispatcher(container: container, repository: repository, vaultID: defaultVaultID)
        await dispatcher.perform(action: .approve, itemID: proposal.id)

        let refetched = try #require(NoteProposalCardRenderer.fetchLatestProposal(id: proposal.id, in: cardContext))
        #expect(refetched.status == .applied)
    }

    @Test func cardOnlyReadsCurrentContentForItsOriginatingAvailableVault() {
        let proposal = NoteEditProposal(
            kind: .edit,
            notePath: "note.md",
            baseContentHash: "hash",
            proposedContent: "new content",
            summary: "Rewrite the note",
            chatID: UUID(),
            originatingVaultID: "vault-A"
        )

        #expect(NoteProposalCardRenderer.canReadCurrentContent(
            for: proposal,
            currentVaultID: "vault-A",
            isVaultAvailable: true
        ))
        #expect(!NoteProposalCardRenderer.canReadCurrentContent(
            for: proposal,
            currentVaultID: "vault-B",
            isVaultAvailable: true
        ))
        #expect(!NoteProposalCardRenderer.canReadCurrentContent(
            for: proposal,
            currentVaultID: "vault-A",
            isVaultAvailable: false
        ))
    }

    // MARK: - Idempotency

    @Test func doubleApproveIsIdempotent() async throws {
        let (repository, vault, vaultRoot, _) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: vaultRoot) }
        let container = try makeContainer()
        let chat = insertChat(in: container)

        guard case .wrote(let original) = try await vault.write(relativePath: "note.md", content: "original content", expectedHash: nil) else {
            Issue.record("expected a successful create")
            return
        }

        let proposal = NoteEditProposal(
            kind: .edit,
            notePath: "note.md",
            baseContentHash: original.sha256,
            proposedContent: "new content",
            summary: "Rewrite the note",
            chatID: chat.id,
            originatingVaultID: defaultVaultID
        )
        insertProposal(proposal, in: container)

        let dispatcher = makeDispatcher(container: container, repository: repository, vaultID: defaultVaultID)
        await dispatcher.perform(action: .approve, itemID: proposal.id)
        let firstResolvedAt = try #require(fetchProposal(id: proposal.id, in: container)?.resolvedAt)
        let messageCountAfterFirst = try #require(fetchChat(id: chat.id, in: container)).visibleMessages.count

        await dispatcher.perform(action: .approve, itemID: proposal.id)

        let resolved = try #require(fetchProposal(id: proposal.id, in: container))
        #expect(resolved.status == .applied)
        #expect(resolved.resolvedAt == firstResolvedAt)

        let onDisk = try await vault.read(relativePath: "note.md")
        #expect(onDisk.content == "new content")

        let messageCountAfterSecond = try #require(fetchChat(id: chat.id, in: container)).visibleMessages.count
        #expect(messageCountAfterSecond == messageCountAfterFirst)
    }
}
