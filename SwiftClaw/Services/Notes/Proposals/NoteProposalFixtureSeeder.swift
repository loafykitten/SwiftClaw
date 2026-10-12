#if DEBUG
import Foundation
import SwiftData
import os
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The fixture accepts only a known product identity and a dedicated child of
/// the process's own temporary directory. `@temporary/...` is important on
/// iOS: the simulator's temporary container path is random before launch.
nonisolated struct NoteProposalFixtureLaunch: Sendable {
    static let fixtureBundleIdentifier = "com.caffeineplz.SwiftClaw.NoteProposalFixture"
    static let appDataRootArgument = "-SwiftClawNoteProposalFixtureAppDataRoot"
    static let temporaryTokenPrefix = "@temporary/"
    static let dedicatedRootPrefix = "SwiftClawNoteProposalFixture"

    let fixtureRoot: FixtureRoot

    static func configurationIfRequested(
        arguments: [String],
        bundleIdentifier: String?,
        fileManager: FileManager = .default
    ) -> Result<Self?, NoteProposalFixtureSeeder.ValidationError> {
        guard arguments.contains("-SwiftClawSeedNoteProposalFixture") else {
            return .success(nil)
        }
        guard bundleIdentifier == fixtureBundleIdentifier else {
            return .failure(.unexpectedBundleIdentifier)
        }

        let indices = arguments.indices.filter { arguments[$0] == appDataRootArgument }
        guard indices.count == 1 else {
            return .failure(indices.isEmpty ? .missingAppDataRootArgument : .duplicateAppDataRootArgument)
        }
        guard let index = indices.first, index + 1 < arguments.endIndex else {
            return .failure(.missingAppDataRootArgument)
        }

        let temporaryDirectory = resolved(fileManager.temporaryDirectory)
        let allowsLegacyMacOSTemporaryRoots: Bool
        #if os(macOS)
        allowsLegacyMacOSTemporaryRoots = true
        #else
        allowsLegacyMacOSTemporaryRoots = false
        #endif

        switch fixtureRootURL(
            for: arguments[index + 1],
            temporaryDirectory: temporaryDirectory,
            includesMacOSLegacyRoots: allowsLegacyMacOSTemporaryRoots
        ) {
        case .success(let rootURL):
            return .success(Self(fixtureRoot: FixtureRoot(rootURL: rootURL)))
        case .failure(let error):
            return .failure(error)
        }
    }

    /// Kept internal for focused tests. Production launch validation supplies
    /// `FileManager.default.temporaryDirectory`, which is the app container's
    /// temporary directory on iOS.
    static func fixtureRootURL(
        for argument: String,
        temporaryDirectory: URL,
        includesMacOSLegacyRoots: Bool
    ) -> Result<URL, NoteProposalFixtureSeeder.ValidationError> {
        let resolvedTemporaryDirectory = resolved(temporaryDirectory)
        let allowedRoots = temporaryRoots(
            temporaryDirectory: resolvedTemporaryDirectory,
            includesMacOSLegacyRoots: includesMacOSLegacyRoots
        )

        if argument.hasPrefix(temporaryTokenPrefix) {
            let name = String(argument.dropFirst(temporaryTokenPrefix.count))
            guard isDedicatedRootName(name) else { return .failure(.invalidAppDataRoot) }
            return .success(resolvedTemporaryDirectory.appendingPathComponent(name, isDirectory: true))
        }

        guard argument.hasPrefix("/") else { return .failure(.relativeAppDataRoot) }
        let suppliedPath = URL(fileURLWithPath: argument, isDirectory: true).standardizedFileURL
        guard isDedicatedRootName(suppliedPath.lastPathComponent) else {
            return .failure(.invalidAppDataRoot)
        }
        let suppliedURL = resolved(suppliedPath)
        guard allowedRoots.contains(where: { suppliedURL.deletingLastPathComponent().path == $0.path }) else {
            return .failure(.outsideTemporaryDirectory)
        }
        return .success(suppliedURL)
    }

    static func temporaryRoots(
        temporaryDirectory: URL,
        includesMacOSLegacyRoots: Bool
    ) -> [URL] {
        let candidates = [temporaryDirectory] + (includesMacOSLegacyRoots ? [
            URL(fileURLWithPath: "/tmp", isDirectory: true),
            URL(fileURLWithPath: "/private/tmp", isDirectory: true),
        ] : [])
        return candidates.map(resolved).reduce(into: []) { roots, candidate in
            if !roots.contains(where: { $0.path == candidate.path }) {
                roots.append(candidate)
            }
        }
    }

    private static func isDedicatedRootName(_ name: String) -> Bool {
        name == dedicatedRootPrefix || name.hasPrefix(dedicatedRootPrefix + "-")
    }

    private static func resolved(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
    }

    /// A root is captured by directory identity, not only its path. Every
    /// fixture side effect rechecks that identity so replacing the supplied
    /// directory with a symlink or another directory fails closed.
    struct FixtureRoot: Sendable {
        private static let ownershipMarkerName = ".swiftclaw-note-proposal-fixture-owner-v2"
        private static let ownershipMarkerContents = "SwiftClaw DEBUG note proposal fixture owner v2\n"
        private static let completionMarkerName = ".swiftclaw-note-proposal-fixture-v1"
        private static let completionMarkerContents = "SwiftClaw DEBUG note proposal fixture v1\n"
        private static let mainStoreName = "SwiftClawNoteProposalFixture.sqlite"
        private static let calendarStoreName = "SwiftClawNoteProposalFixtureCalendar.sqlite"

        let url: URL
        private let fileSystemNumber: UInt64

        fileprivate init(rootURL: URL) {
            self.url = rootURL
            self.fileSystemNumber = 0
        }

        private init(url: URL, fileSystemNumber: UInt64) {
            self.url = url
            self.fileSystemNumber = fileSystemNumber
        }

        var mainStoreURL: URL {
            url.appendingPathComponent(Self.mainStoreName)
        }

        var calendarStoreURL: URL {
            url.appendingPathComponent(Self.calendarStoreName)
        }

        static var completionMarkerFilename: String { completionMarkerName }
        static var completionMarkerText: String { completionMarkerContents }

        func establish(fileManager: FileManager = .default) throws -> Self {
            var created = false
            if !fileManager.fileExists(atPath: url.path) {
                do {
                    try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
                    created = true
                } catch {
                    guard fileManager.fileExists(atPath: url.path) else {
                        throw NoteProposalFixtureSeeder.ValidationError.couldNotCreateFixtureRoot
                    }
                }
            }

            let captured = try Self.capture(url: url, fileManager: fileManager)
            if fileManager.fileExists(atPath: captured.ownershipMarkerURL.path) {
                try captured.requireOwnershipMarker()
            } else {
                guard created else { throw NoteProposalFixtureSeeder.ValidationError.unownedFixtureRoot }
                try captured.createOwnershipMarker()
            }

            if try captured.isFixtureComplete() == false {
                try captured.removeIncompleteArtifacts()
            }
            try captured.revalidate()
            return captured
        }

        func revalidate() throws {
            let fresh = try Self.capture(url: url, fileManager: .default)
            guard fresh.fileSystemNumber == fileSystemNumber else {
                throw NoteProposalFixtureSeeder.ValidationError.fixtureRootIdentityChanged
            }
            try requireOwnershipMarker()
        }

        func isFixtureComplete() throws -> Bool {
            try revalidate()
            guard FileManager.default.fileExists(atPath: completionMarkerURL.path) else { return false }
            guard !Self.isSymbolicLink(completionMarkerURL),
                  try String(contentsOf: completionMarkerURL, encoding: .utf8) == Self.completionMarkerContents
            else {
                throw NoteProposalFixtureSeeder.ValidationError.unrecognizedCompletionMarker
            }
            return true
        }

        /// Removes only exact filenames that this fixture creates. The root is
        /// held by a directory descriptor, so a later path replacement cannot
        /// redirect cleanup outside the temporary fixture directory.
        func removeIncompleteArtifacts() throws {
            try revalidate()
            try withDirectoryDescriptor { descriptor in
                for name in Self.retryCleanupFilenames {
                    let result = name.withCString { unlinkat(descriptor, $0, 0) }
                    guard result == 0 || errno == ENOENT else {
                        throw NoteProposalFixtureSeeder.ValidationError.couldNotCleanIncompleteFixture
                    }
                }
            }
            try revalidate()
        }

        private static func capture(url: URL, fileManager: FileManager) throws -> Self {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue,
                  !Self.isSymbolicLink(url),
                  resolved(url).path == url.path,
                  let fileNumber = try fileManager.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber
            else {
                throw NoteProposalFixtureSeeder.ValidationError.fixtureRootIsUnsafe
            }
            return Self(url: url, fileSystemNumber: fileNumber.uint64Value)
        }

        private var ownershipMarkerURL: URL {
            url.appendingPathComponent(Self.ownershipMarkerName)
        }

        private var completionMarkerURL: URL {
            url.appendingPathComponent(Self.completionMarkerName)
        }

        private static var retryCleanupFilenames: [String] {
            [
                completionMarkerName,
                "01-Clean-Approve.md",
                "02-Reject-Keeps-Original.md",
                "03-Stale-Conflict-Keeps-External-Change.md",
                "04-Clean-Create.md",
                "05-Wrong-Vault-Expires-Without-Write.md",
                mainStoreName,
                mainStoreName + "-wal",
                mainStoreName + "-shm",
                mainStoreName + "-journal",
                calendarStoreName,
                calendarStoreName + "-wal",
                calendarStoreName + "-shm",
                calendarStoreName + "-journal",
            ]
        }

        private func requireOwnershipMarker() throws {
            guard FileManager.default.fileExists(atPath: ownershipMarkerURL.path),
                  !Self.isSymbolicLink(ownershipMarkerURL),
                  try String(contentsOf: ownershipMarkerURL, encoding: .utf8) == Self.ownershipMarkerContents
            else {
                throw NoteProposalFixtureSeeder.ValidationError.unownedFixtureRoot
            }
        }

        private func createOwnershipMarker() throws {
            try verifyIdentity()
            try withDirectoryDescriptor { directoryDescriptor in
                let markerDescriptor = Self.ownershipMarkerName.withCString { markerName in
                    openat(
                        directoryDescriptor,
                        markerName,
                        O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW,
                        0o600
                    )
                }
                guard markerDescriptor >= 0 else {
                    throw NoteProposalFixtureSeeder.ValidationError.couldNotCreateOwnershipMarker
                }
                defer { close(markerDescriptor) }
                try Self.writeAll(Data(Self.ownershipMarkerContents.utf8), to: markerDescriptor)
                guard fsync(markerDescriptor) == 0 else {
                    throw NoteProposalFixtureSeeder.ValidationError.couldNotCreateOwnershipMarker
                }
            }
            try revalidate()
        }

        private func verifyIdentity() throws {
            let fresh = try Self.capture(url: url, fileManager: .default)
            guard fresh.fileSystemNumber == fileSystemNumber else {
                throw NoteProposalFixtureSeeder.ValidationError.fixtureRootIdentityChanged
            }
        }

        private func withDirectoryDescriptor<T>(_ body: (Int32) throws -> T) throws -> T {
            let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
                guard let path else { return -1 }
                return open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            }
            guard descriptor >= 0 else { throw NoteProposalFixtureSeeder.ValidationError.fixtureRootIsUnsafe }
            defer { close(descriptor) }

            var information = stat()
            guard fstat(descriptor, &information) == 0,
                  UInt64(information.st_ino) == fileSystemNumber
            else {
                throw NoteProposalFixtureSeeder.ValidationError.fixtureRootIdentityChanged
            }
            return try body(descriptor)
        }

        private static func writeAll(_ data: Data, to descriptor: Int32) throws {
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let result = write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if result > 0 {
                        offset += result
                    } else if result < 0, errno == EINTR {
                        continue
                    } else {
                        throw NoteProposalFixtureSeeder.ValidationError.couldNotCreateOwnershipMarker
                    }
                }
            }
        }

        private static func resolved(_ url: URL) -> URL {
            url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        }

        private static func isSymbolicLink(_ url: URL) -> Bool {
            (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
        }
    }
}

/// DEBUG-only, opt-in data for exercising note-proposal cards without model
/// credentials or a real vault. Its factory-validated root is a dedicated
/// temporary directory and is never a production container or default store.
@MainActor
enum NoteProposalFixtureSeeder {
    nonisolated static let launchArgument = "-SwiftClawSeedNoteProposalFixture"

    private static let logger = AppLog.make("notes.fixture")
    private static let chatTitle = "Notes proposal fixture — safe temporary vault"
    private static let fixtureModelSelection = "debug-note-proposal-fixture"
    private struct ExistingFixture {
        let chat: Chat
        let proposals: [NoteEditProposal]

        var isComplete: Bool {
            proposals.count == NoteProposalFixtureSeeder.expectedProposalCount
                && proposals.allSatisfy { $0.cardPostedAt != nil && $0.chatID == chat.id }
        }
    }

    nonisolated enum ValidationError: LocalizedError, Equatable {
        case unexpectedBundleIdentifier
        case missingAppDataRootArgument
        case duplicateAppDataRootArgument
        case relativeAppDataRoot
        case invalidAppDataRoot
        case outsideTemporaryDirectory
        case couldNotCreateFixtureRoot
        case fixtureRootIsUnsafe
        case fixtureRootIdentityChanged
        case unownedFixtureRoot
        case couldNotCreateOwnershipMarker
        case couldNotCleanIncompleteFixture
        case unrecognizedCompletionMarker

        nonisolated var errorDescription: String? {
            switch self {
            case .unexpectedBundleIdentifier:
                "The note proposal fixture requires PRODUCT_BUNDLE_IDENTIFIER com.caffeineplz.SwiftClaw.NoteProposalFixture."
            case .missingAppDataRootArgument:
                "Missing -SwiftClawNoteProposalFixtureAppDataRoot @temporary/<dedicated-name>."
            case .duplicateAppDataRootArgument:
                "Provide -SwiftClawNoteProposalFixtureAppDataRoot exactly once."
            case .relativeAppDataRoot:
                "The fixture app-data root must be absolute or use @temporary/<dedicated-name>."
            case .invalidAppDataRoot:
                "Use a dedicated SwiftClawNoteProposalFixture directory name."
            case .outsideTemporaryDirectory:
                "The fixture app-data root must be a direct child of the allowed temporary directory."
            case .couldNotCreateFixtureRoot:
                "Couldn't create the dedicated temporary fixture directory."
            case .fixtureRootIsUnsafe:
                "The fixture directory is missing, is not a directory, or is a symbolic link."
            case .fixtureRootIdentityChanged:
                "The fixture directory changed while setup was running."
            case .unownedFixtureRoot:
                "The fixture directory is not marked as fixture-owned."
            case .couldNotCreateOwnershipMarker:
                "Couldn't establish fixture directory ownership."
            case .couldNotCleanIncompleteFixture:
                "Couldn't clean a known incomplete fixture file."
            case .unrecognizedCompletionMarker:
                "The temporary fixture directory contains an unrecognized completion marker."
            }
        }
    }

    enum FilePreparation: Equatable {
        case created
        case alreadyPrepared
    }

    struct BaseHashes {
        let cleanApprove: String
        let reject: String
        let stale: String
        let wrongVault: String
    }

    private struct FixtureFile {
        let relativePath: String
        let initialContent: String
    }

    private static let cleanApprovePath = "01-Clean-Approve.md"
    private static let rejectPath = "02-Reject-Keeps-Original.md"
    private static let stalePath = "03-Stale-Conflict-Keeps-External-Change.md"
    private static let createPath = "04-Clean-Create.md"
    private static let wrongVaultPath = "05-Wrong-Vault-Expires-Without-Write.md"

    private static let cleanApproveInitialContent = """
    # Clean approval fixture

    Outcome: this line starts as ORIGINAL.
    """

    private static let cleanApproveProposedContent = """
    # Clean approval fixture

    Outcome: APPROVED clean edit — this line changed through the proposal card.
    """

    private static let rejectInitialContent = """
    # Reject fixture

    Outcome: this ORIGINAL text must stay unchanged after Reject.
    """

    private static let rejectProposedContent = """
    # Reject fixture

    Outcome: this proposed text must NOT be written when you choose Reject.
    """

    private static let staleInitialContent = """
    # Stale conflict fixture

    Outcome: ORIGINAL content captured when this proposal was created.
    """

    private static let staleCurrentContent = """
    # Stale conflict fixture

    Outcome: EXTERNALLY CHANGED after the proposal was created. Approval must conflict and leave this text untouched.
    """

    private static let staleProposedContent = """
    # Stale conflict fixture

    Outcome: this proposed text must NOT overwrite the external change.
    """

    private static let createProposedContent = """
    # Clean create fixture

    Outcome: this file is created only after approving its proposal card.
    """

    private static let wrongVaultInitialContent = """
    # Wrong vault fixture

    Outcome: this ORIGINAL text must remain untouched because the proposal belongs to another vault identity.
    """

    private static let wrongVaultProposedContent = """
    # Wrong vault fixture

    Outcome: this proposed text must NOT be written; approval should expire before reading the vault.
    """

    private static var initialFiles: [FixtureFile] {
        [
            FixtureFile(relativePath: cleanApprovePath, initialContent: cleanApproveInitialContent),
            FixtureFile(relativePath: rejectPath, initialContent: rejectInitialContent),
            FixtureFile(relativePath: stalePath, initialContent: staleInitialContent),
            FixtureFile(relativePath: wrongVaultPath, initialContent: wrongVaultInitialContent),
        ]
    }

    nonisolated private static let expectedProposalCount = 5

    /// The factory has already validated the launch contract and opened only
    /// explicit fixture stores. Revalidation deliberately happens again inside
    /// this task, immediately before the first fixture side effect, so there
    /// is no validation-to-seed path handoff to trust.
    static func seedIfRequested(
        into container: ModelContainer,
        fixtureRoot: NoteProposalFixtureLaunch.FixtureRoot?
    ) {
        guard let fixtureRoot else { return }
        Task { @MainActor in
            await seed(into: container, fixtureRoot: fixtureRoot)
        }
    }

    private static func seed(
        into container: ModelContainer,
        fixtureRoot: NoteProposalFixtureLaunch.FixtureRoot
    ) async {
        do {
            try fixtureRoot.revalidate()
        } catch {
            logger.error("Note proposal fixture was not started: \(error.localizedDescription)")
            return
        }

        let vaultURL = fixtureRoot.url
        let context = container.mainContext
        if let existing = existingFixture(in: context) {
            guard existing.isComplete else {
                logger.error("Note proposal fixture state is incomplete; leaving it untouched rather than duplicating cards.")
                return
            }
            await reactivateExistingFixture(at: fixtureRoot)
            return
        }

        let preparation: FilePreparation
        do {
            preparation = try await prepareInitialFiles(in: fixtureRoot)
        } catch {
            logger.error("Note proposal fixture file setup failed: \(String(describing: error))")
            await rollbackIncompleteFixture(at: fixtureRoot)
            return
        }
        guard preparation == .created else {
            logger.error("A completed note proposal fixture marker exists without matching SwiftData cards; leaving the temporary vault untouched.")
            return
        }

        // This is deliberately after validation and initial-file setup. The
        // supported external-vault API writes the bookmark/settings and gives
        // the production dispatcher a real NotesFeatureModel/repository.
        UserDefaults.standard.set(true, forKey: SettingsKeys.notesEnabled)
        await NotesFeatureModel.shared.chooseExternalVault(url: vaultURL)
        guard NotesFeatureModel.shared.configurationState == .configured,
              let repository = NotesFeatureModel.shared.repository
        else {
            logger.error("Note proposal fixture could not configure its temporary external vault: \(NotesFeatureModel.shared.lastConfigurationError?.localizedDescription ?? "unknown error")")
            await rollbackIncompleteFixture(at: fixtureRoot)
            return
        }

        do {
            try fixtureRoot.revalidate()
            let cleanApprove = try await repository.read(relativePath: cleanApprovePath)
            try fixtureRoot.revalidate()
            let reject = try await repository.read(relativePath: rejectPath)
            try fixtureRoot.revalidate()
            let stale = try await repository.read(relativePath: stalePath)
            try fixtureRoot.revalidate()
            let wrongVault = try await repository.read(relativePath: wrongVaultPath)

            try await applyStaleExternalChange(in: fixtureRoot, expectedHash: stale.sha256)

            let hashes = BaseHashes(
                cleanApprove: cleanApprove.sha256,
                reject: reject.sha256,
                stale: stale.sha256,
                wrongVault: wrongVault.sha256
            )
            guard insertFixtureState(into: context, vaultID: NotesFeatureModel.shared.configurationStore.vaultID, baseHashes: hashes) else {
                throw FixtureFileError.fixtureStateCouldNotBeSaved
            }
            try await markFixtureComplete(in: fixtureRoot)
            logger.notice("Seeded five credential-free note proposal cards against temporary vault \(vaultURL.path)")
        } catch {
            logger.error("Note proposal fixture setup failed before completion: \(String(describing: error))")
            await rollbackIncompleteFixture(at: fixtureRoot)
        }
    }

    private static func reactivateExistingFixture(at fixtureRoot: NoteProposalFixtureLaunch.FixtureRoot) async {
        do {
            try fixtureRoot.revalidate()
        } catch {
            logger.error("Existing note proposal fixture root is no longer safe: \(error.localizedDescription)")
            return
        }
        let vaultURL = fixtureRoot.url
        guard storedExternalVaultMatches(vaultURL) else {
            logger.error("Existing note proposal fixture does not match the requested temporary vault; refusing to reconfigure Notes.")
            return
        }

        UserDefaults.standard.set(true, forKey: SettingsKeys.notesEnabled)
        await NotesFeatureModel.shared.activate()
        guard NotesFeatureModel.shared.configurationState == .configured else {
            logger.error("Existing note proposal fixture could not reactivate its temporary vault: \(NotesFeatureModel.shared.lastConfigurationError?.localizedDescription ?? "unknown error")")
            return
        }
        logger.notice("Reused existing credential-free note proposal fixture at \(vaultURL.path)")
    }

    /// Clears the isolated Notes bookmark/settings after a failed seed, then
    /// removes only known fixture files. The ownership marker remains, so the
    /// next launch can identify this exact root and reset its explicit stores
    /// before creating another fixture.
    private static func rollbackIncompleteFixture(at fixtureRoot: NoteProposalFixtureLaunch.FixtureRoot) async {
        await NotesFeatureModel.shared.resetVaultConfiguration()
        UserDefaults.standard.removeObject(forKey: SettingsKeys.notesEnabled)
        do {
            try fixtureRoot.removeIncompleteArtifacts()
        } catch {
            logger.error("Note proposal fixture rollback could not clean its owned files: \(String(describing: error))")
        }
    }

    /// Resolves only the previously stored external bookmark to prove it still
    /// targets this validated temporary folder before `activate()` can read a
    /// vault. A changed setting is a hard stop, never a fallback to whatever
    /// vault the user configured later.
    private static func storedExternalVaultMatches(_ vaultURL: URL) -> Bool {
        guard case .external(let bookmarkKey) = SettingsStorage.loadNotesVaultLocation() else {
            return false
        }
        guard let scopedURL = try? SecurityScopedBookmarkStore().resolve(forKey: bookmarkKey) else {
            return false
        }
        let storedURL = scopedURL.url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        return storedURL.path == vaultURL.path
    }

    /// Creates only the four notes that must exist before a proposal is made.
    /// A completion marker means this fixture owns the root and a repeat run
    /// must not rewrite a tester's approved/rejected outcomes. Any unmarked
    /// collision is refused rather than overwritten.
    static func prepareInitialFiles(in fixtureRoot: NoteProposalFixtureLaunch.FixtureRoot) async throws -> FilePreparation {
        try fixtureRoot.revalidate()
        if try fixtureRoot.isFixtureComplete() {
            return .alreadyPrepared
        }

        let vault = NotesVault(root: fixtureRoot.url)
        for file in initialFiles {
            try fixtureRoot.revalidate()
            guard try await vault.exists(relativePath: file.relativePath) == false else {
                throw FixtureFileError.pathAlreadyExists(file.relativePath)
            }
            try fixtureRoot.revalidate()
        }

        for file in initialFiles {
            try fixtureRoot.revalidate()
            guard case .created = try await vault.createExclusive(
                relativePath: file.relativePath,
                content: file.initialContent
            ) else {
                throw FixtureFileError.pathAlreadyExists(file.relativePath)
            }
            try fixtureRoot.revalidate()
        }
        return .created
    }

    static func applyStaleExternalChange(
        in fixtureRoot: NoteProposalFixtureLaunch.FixtureRoot,
        expectedHash: String
    ) async throws {
        try fixtureRoot.revalidate()
        let vault = NotesVault(root: fixtureRoot.url)
        guard case .wrote = try await vault.write(
            relativePath: stalePath,
            content: staleCurrentContent,
            expectedHash: expectedHash
        ) else {
            throw FixtureFileError.staleChangeDidNotApply
        }
        try fixtureRoot.revalidate()
    }

    static func markFixtureComplete(in fixtureRoot: NoteProposalFixtureLaunch.FixtureRoot) async throws {
        try fixtureRoot.revalidate()
        let vault = NotesVault(root: fixtureRoot.url)
        guard case .created = try await vault.createExclusive(
            relativePath: NoteProposalFixtureLaunch.FixtureRoot.completionMarkerFilename,
            content: NoteProposalFixtureLaunch.FixtureRoot.completionMarkerText
        ) else {
            throw FixtureFileError.unrecognizedMarker
        }
        try fixtureRoot.revalidate()
    }

    /// Inserts actual SwiftData proposals and one card message per proposal.
    /// The renderer fetches each proposal by this card's `itemID`, exactly as
    /// cards posted by `NotesProposalCoordinator` do in normal operation.
    @discardableResult
    static func insertFixtureState(
        into context: ModelContext,
        vaultID: String,
        baseHashes: BaseHashes
    ) -> Bool {
        guard existingFixture(in: context) == nil else { return false }

        let chat = Chat(title: chatTitle, modelSelection: fixtureModelSelection)
        context.insert(chat)
        chat.appendMessage(
            role: .assistant,
            content: "DEBUG fixture: five safe proposal cards below. All files live in the explicit temporary vault passed at launch; no inference or credentials were used."
        )

        let postedAt = Date()
        let proposals = [
            NoteEditProposal(
                kind: .edit,
                notePath: cleanApprovePath,
                baseContentHash: baseHashes.cleanApprove,
                proposedContent: cleanApproveProposedContent,
                summary: "Approve: replace ORIGINAL with APPROVED in 01-Clean-Approve.md.",
                chatID: chat.id,
                originatingVaultID: vaultID,
                cardPostedAt: postedAt
            ),
            NoteEditProposal(
                kind: .edit,
                notePath: rejectPath,
                baseContentHash: baseHashes.reject,
                proposedContent: rejectProposedContent,
                summary: "Reject: 02-Reject-Keeps-Original.md must remain ORIGINAL.",
                chatID: chat.id,
                originatingVaultID: vaultID,
                cardPostedAt: postedAt
            ),
            NoteEditProposal(
                kind: .edit,
                notePath: stalePath,
                baseContentHash: baseHashes.stale,
                proposedContent: staleProposedContent,
                summary: "Approve: this deliberately stale edit must conflict; EXTERNALLY CHANGED text stays untouched.",
                chatID: chat.id,
                originatingVaultID: vaultID,
                cardPostedAt: postedAt
            ),
            NoteEditProposal(
                kind: .create,
                notePath: createPath,
                proposedContent: createProposedContent,
                summary: "Approve: create 04-Clean-Create.md with the clearly marked fixture content.",
                chatID: chat.id,
                originatingVaultID: vaultID,
                cardPostedAt: postedAt
            ),
            NoteEditProposal(
                kind: .edit,
                notePath: wrongVaultPath,
                baseContentHash: baseHashes.wrongVault,
                proposedContent: wrongVaultProposedContent,
                summary: "Approve: this different-vault proposal must expire without reading or writing 05-Wrong-Vault-Expires-Without-Write.md.",
                chatID: chat.id,
                originatingVaultID: "DEBUG-FIXTURE-DIFFERENT-VAULT",
                cardPostedAt: postedAt
            ),
        ]

        for proposal in proposals {
            context.insert(proposal)
            chat.appendMessage(
                role: .assistant,
                content: proposal.summary,
                reviewCard: ReviewCardPayload(
                    reviewType: .noteProposal,
                    items: [
                        ReviewItem(
                            itemID: proposal.id,
                            actionToken: .approve,
                            actionLabel: "Approve",
                            summary: proposal.summary,
                            subject: proposal.notePath
                        ),
                    ]
                )
            )
        }

        do {
            try context.save()
            return true
        } catch {
            context.rollback()
            logger.error("Note proposal fixture SwiftData save failed: \(String(describing: error))")
            return false
        }
    }

    private static func existingFixture(in context: ModelContext) -> ExistingFixture? {
        let chats = (try? context.fetch(FetchDescriptor<Chat>())) ?? []
        guard let chat = chats.first(where: {
            $0.title == chatTitle && $0.modelSelection == fixtureModelSelection
        }) else {
            return nil
        }
        let proposals = (try? context.fetch(FetchDescriptor<NoteEditProposal>())) ?? []
        return ExistingFixture(chat: chat, proposals: proposals.filter { $0.chatID == chat.id })
    }

    private enum FixtureFileError: LocalizedError {
        case unrecognizedMarker
        case pathAlreadyExists(String)
        case staleChangeDidNotApply
        case fixtureStateCouldNotBeSaved

        var errorDescription: String? {
            switch self {
            case .unrecognizedMarker:
                "The temporary vault contains an unrecognized fixture marker."
            case .pathAlreadyExists(let path):
                "Refusing to overwrite existing fixture path \(path)."
            case .staleChangeDidNotApply:
                "The controlled stale-file change did not apply."
            case .fixtureStateCouldNotBeSaved:
                "The fixture SwiftData cards could not be saved."
            }
        }
    }
}
#endif
