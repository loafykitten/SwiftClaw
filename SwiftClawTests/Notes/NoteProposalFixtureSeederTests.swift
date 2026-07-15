#if DEBUG
import Foundation
import SwiftData
import Testing
@testable import SwiftClaw

/// Keeps the DEBUG fixture's launch contract, directory ownership boundary,
/// and persisted card shape covered without constructing NotesFeatureModel or
/// touching the test process's user defaults.
@Suite(.serialized)
@MainActor
struct NoteProposalFixtureSeederTests {
    private let fixtureBundleIdentifier = NoteProposalFixtureLaunch.fixtureBundleIdentifier

    private func makeFixtureRoot() throws -> NoteProposalFixtureLaunch.FixtureRoot {
        let token = "@temporary/SwiftClawNoteProposalFixture-Tests-\(UUID().uuidString)"
        let result = NoteProposalFixtureLaunch.configurationIfRequested(
            arguments: [
                NoteProposalFixtureSeeder.launchArgument,
                NoteProposalFixtureLaunch.appDataRootArgument,
                token,
            ],
            bundleIdentifier: fixtureBundleIdentifier
        )
        guard case .success(.some(let configuration)) = result else {
            Issue.record("Expected a valid isolated fixture launch contract")
            throw FixtureTestError.invalidLaunchContract
        }
        return try configuration.fixtureRoot.establish()
    }

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Chat.self, ChatMessage.self, NoteEditProposal.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    @Test func fixtureRefusesTheProductionBundleIdentifierBeforeAnyRootIsCreated() {
        let result = NoteProposalFixtureLaunch.configurationIfRequested(
            arguments: [
                NoteProposalFixtureSeeder.launchArgument,
                NoteProposalFixtureLaunch.appDataRootArgument,
                "@temporary/SwiftClawNoteProposalFixture-ProductionIdentity",
            ],
            bundleIdentifier: "com.caffeineplz.SwiftClaw"
        )

        guard case .failure(.unexpectedBundleIdentifier) = result else {
            Issue.record("Expected the production bundle identifier to be refused")
            return
        }
    }

    @Test func temporaryTokenResolvesInsideAnIOSStyleAppTemporaryDirectory() {
        let simulatedAppTemporaryDirectory = URL(
            fileURLWithPath: "/private/var/mobile/Containers/Data/Application/TEST/tmp",
            isDirectory: true
        )
        let result = NoteProposalFixtureLaunch.fixtureRootURL(
            for: "@temporary/SwiftClawNoteProposalFixture-iOS",
            temporaryDirectory: simulatedAppTemporaryDirectory,
            includesMacOSLegacyRoots: false
        )

        guard case .success(let rootURL) = result else {
            Issue.record("Expected the iOS temporary token to validate without a simulator")
            return
        }
        #expect(rootURL.path == simulatedAppTemporaryDirectory.appendingPathComponent("SwiftClawNoteProposalFixture-iOS").path)
    }

    @Test func macOSLegacyTemporaryRootsStillAcceptDedicatedDirectChildren() {
        let result = NoteProposalFixtureLaunch.fixtureRootURL(
            for: "/tmp/SwiftClawNoteProposalFixture-macOS",
            temporaryDirectory: URL(fileURLWithPath: "/var/folders/example/T", isDirectory: true),
            includesMacOSLegacyRoots: true
        )

        guard case .success(let rootURL) = result else {
            Issue.record("Expected a dedicated /tmp fixture directory to validate on macOS")
            return
        }
        #expect(rootURL.lastPathComponent == "SwiftClawNoteProposalFixture-macOS")
    }

    @Test func temporarySymlinkEscapingToHomeIsRefused() throws {
        let name = "SwiftClawNoteProposalFixture-Escape-\(UUID().uuidString)"
        let link = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent(name)
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: FileManager.default.homeDirectoryForCurrentUser.path
        )
        defer { try? FileManager.default.removeItem(at: link) }

        let result = NoteProposalFixtureLaunch.fixtureRootURL(
            for: link.path,
            temporaryDirectory: FileManager.default.temporaryDirectory,
            includesMacOSLegacyRoots: true
        )

        guard case .failure(.outsideTemporaryDirectory) = result else {
            Issue.record("Expected a temporary symlink escaping its root to be refused")
            return
        }
    }

    @Test func replacingTheCapturedRootCannotWriteOutsideTheTemporaryFixture() async throws {
        let fixtureRoot = try makeFixtureRoot()
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoteProposalFixtureOutside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: fixtureRoot.url)
            try? FileManager.default.removeItem(at: outside)
        }

        try FileManager.default.removeItem(at: fixtureRoot.url)
        try FileManager.default.createSymbolicLink(atPath: fixtureRoot.url.path, withDestinationPath: outside.path)

        do {
            _ = try await NoteProposalFixtureSeeder.prepareInitialFiles(in: fixtureRoot)
            Issue.record("Expected a replaced fixture root to fail closed")
        } catch {
            // The captured directory identity is gone; no fixture write may run.
        }

        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("01-Clean-Approve.md").path))
    }

    @Test func incompleteOwnedFixtureCleansOnlyKnownFilesAndCanRetry() async throws {
        let fixtureRoot = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: fixtureRoot.url) }

        #expect(try await NoteProposalFixtureSeeder.prepareInitialFiles(in: fixtureRoot) == .created)
        try Data("fixture store".utf8).write(to: fixtureRoot.mainStoreURL)
        let unrelated = fixtureRoot.url.appendingPathComponent("leave-me-alone.txt")
        try Data("unrelated".utf8).write(to: unrelated)

        try fixtureRoot.removeIncompleteArtifacts()

        #expect(!FileManager.default.fileExists(atPath: fixtureRoot.url.appendingPathComponent("01-Clean-Approve.md").path))
        #expect(!FileManager.default.fileExists(atPath: fixtureRoot.mainStoreURL.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        #expect(try await NoteProposalFixtureSeeder.prepareInitialFiles(in: fixtureRoot) == .created)
    }

    @Test func fixtureFilesAndProposalCardsAreCreatedOnce() async throws {
        let fixtureRoot = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: fixtureRoot.url) }

        #expect(try await NoteProposalFixtureSeeder.prepareInitialFiles(in: fixtureRoot) == .created)
        let vault = NotesVault(root: fixtureRoot.url)
        let clean = try await vault.read(relativePath: "01-Clean-Approve.md")
        let reject = try await vault.read(relativePath: "02-Reject-Keeps-Original.md")
        let stale = try await vault.read(relativePath: "03-Stale-Conflict-Keeps-External-Change.md")
        let wrongVault = try await vault.read(relativePath: "05-Wrong-Vault-Expires-Without-Write.md")
        #expect(clean.content.contains("ORIGINAL"))
        #expect(reject.content.contains("ORIGINAL"))
        #expect(stale.content.contains("ORIGINAL"))
        #expect(wrongVault.content.contains("ORIGINAL"))
        try await NoteProposalFixtureSeeder.applyStaleExternalChange(in: fixtureRoot, expectedHash: stale.sha256)
        try await NoteProposalFixtureSeeder.markFixtureComplete(in: fixtureRoot)
        #expect(try await NoteProposalFixtureSeeder.prepareInitialFiles(in: fixtureRoot) == .alreadyPrepared)

        let container = try makeContainer()
        let context = container.mainContext
        let hashes = NoteProposalFixtureSeeder.BaseHashes(
            cleanApprove: clean.sha256,
            reject: reject.sha256,
            stale: stale.sha256,
            wrongVault: wrongVault.sha256
        )
        #expect(NoteProposalFixtureSeeder.insertFixtureState(into: context, vaultID: "fixture-vault", baseHashes: hashes))
        #expect(!NoteProposalFixtureSeeder.insertFixtureState(into: context, vaultID: "fixture-vault", baseHashes: hashes))

        let proposals = try context.fetch(FetchDescriptor<NoteEditProposal>())
        #expect(proposals.count == 5)
        #expect(proposals.allSatisfy { $0.chatID != nil && $0.cardPostedAt != nil })
        #expect(proposals.filter { $0.originatingVaultID == "fixture-vault" }.count == 4)
        #expect(proposals.contains { $0.originatingVaultID == "DEBUG-FIXTURE-DIFFERENT-VAULT" })

        let chat = try #require(context.fetch(FetchDescriptor<Chat>()).first)
        let cardItemIDs = Set(chat.messages.compactMap { message in
            message.reviewCard?.items.first?.itemID
        })
        #expect(cardItemIDs == Set(proposals.map(\.id)))
        #expect(chat.messages.compactMap(\.reviewCard).allSatisfy {
            $0.reviewType == .noteProposal && $0.items.count == 1
        })

        let staleCurrent = try await vault.read(relativePath: "03-Stale-Conflict-Keeps-External-Change.md")
        #expect(staleCurrent.sha256 != stale.sha256)
        #expect(staleCurrent.content.contains("EXTERNALLY CHANGED"))
        #expect(try await vault.exists(relativePath: "04-Clean-Create.md") == false)
    }

    private enum FixtureTestError: Error {
        case invalidLaunchContract
    }
}
#endif
