import Foundation
import SwiftData

/// Shared seam for the request-bound memory write tools (`add_memory`,
/// `supersede_memory`, `create_memory_collection`) so tests can stub the
/// repository and gating instead of the live `MemoryFeatureModel` singleton.
///
/// The tool surface is identical for both access levels — the *collection's*
/// access level (never the caller) decides how a write lands: writes-freely
/// targets apply immediately through `MemoryRepository` and queue a
/// disclosure chip; asks-first targets persist a `MemoryProposal` and queue
/// an inline proposal card. The tools themselves never choose.
nonisolated struct MemoryWriteToolDependencies: Sendable {
    var isAvailable: @MainActor @Sendable () -> Bool
    var repository: @MainActor @Sendable () -> MemoryRepository?

    static let live = MemoryWriteToolDependencies(
        isAvailable: { MemoryFeatureModel.shared.isAvailable },
        repository: { MemoryFeatureModel.shared.repository }
    )
}

private nonisolated let memoryToolsScopeOptions: [WorkspaceFeature] = [.email, .calendar, .reminders, .notes]

/// Saves one new memory entry. Routed by the target collection's access
/// level; an omitted or unresolvable target goes to the Inbox rather than
/// force-filing into a wrong home.
struct AddMemoryTool: Tool {
    let name = "add_memory"
    let displayName = "Add Memory"
    let description = """
        Save one short fact (target 15-40 tokens) to persistent memory. \
        Prefer an existing collection (pass its title or 8-character \
        handle); omit "collection" when unsure where it belongs — it goes \
        to the Inbox for the user to file, never guess a wrong home. \
        Writes to "AI asks first" collections become proposals the user \
        must approve. To update an existing fact use supersede_memory \
        instead of adding a duplicate.
        """
    let systemImage = "brain.head.profile"

    let parameters = [
        ToolParameter(
            name: "content",
            type: .string,
            description: "The fact to remember — one atomic statement.",
            isRequired: true
        ),
        ToolParameter(
            name: "collection",
            type: .string,
            description: "Target collection title or 8-character handle. Omit when uncertain (files to Inbox)."
        ),
        ToolParameter(
            name: "tags",
            type: .array,
            description: "Optional cross-cutting tags."
        ),
    ]

    private let modelContainer: ModelContainer
    private let chatID: UUID
    private let coordinator: MemoryCardCoordinator
    private let dependencies: MemoryWriteToolDependencies

    @MainActor
    init(
        modelContainer: ModelContainer,
        chatID: UUID,
        coordinator: MemoryCardCoordinator? = nil,
        dependencies: MemoryWriteToolDependencies = .live
    ) {
        self.modelContainer = modelContainer
        self.chatID = chatID
        self.coordinator = coordinator ?? MemoryCardCoordinator.shared
        self.dependencies = dependencies
    }

    var isConfigured: Bool {
        MainActor.assumeIsolated { dependencies.isAvailable() }
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        guard let content = arguments["content"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else {
            throw ToolError.missingArgument("content")
        }
        let collectionReference = arguments["collection"]?.stringValue
        let tags = MemoryToolArguments.tags(from: arguments)

        return try await MainActor.run {
            guard dependencies.isAvailable(), let repository = dependencies.repository() else {
                throw ToolError.notConfigured(toolName: displayName, reason: SearchMemoryTool.unavailableReason)
            }
            let target = try MemoryToolArguments.resolveTarget(
                reference: collectionReference,
                repository: repository
            )

            switch target.accessLevel {
            case .writesFreely:
                let entry = try repository.addEntry(
                    body: content,
                    tags: tags,
                    to: target,
                    createdBy: .ai,
                    sourceChatID: chatID
                )
                coordinator.enqueueWrite(entryID: entry.id, chatID: chatID)
                return "Saved to \"\(target.title)\" (handle \(entry.handle))."
            case .asksFirst:
                let proposal = MemoryProposal(
                    entryText: content,
                    targetCollectionID: target.id,
                    tags: tags,
                    summary: "Remember in \"\(target.title)\"",
                    source: .chat,
                    chatID: chatID
                )
                let context = ModelContext(modelContainer)
                context.insert(proposal)
                try context.save()
                coordinator.enqueueProposal(proposalID: proposal.id, chatID: chatID)
                return "\"\(target.title)\" requires approval — proposed, awaiting the user's decision."
            }
        }
    }
}

/// Replaces an established fact: adds the new entry and stamps the old one
/// superseded — never an in-place rewrite, so contradictions stay visible.
struct SupersedeMemoryTool: Tool {
    let name = "supersede_memory"
    let displayName = "Supersede Memory"
    let description = """
        Update an existing memory: saves replacement text and marks the old \
        entry (identified by its 8-character handle) superseded. Use when a \
        stored fact changed; use add_memory for genuinely new facts. Targets \
        in "AI asks first" collections become proposals the user must approve.
        """
    let systemImage = "arrow.triangle.2.circlepath"

    let parameters = [
        ToolParameter(
            name: "handle",
            type: .string,
            description: "The 8-character handle of the entry being replaced.",
            isRequired: true
        ),
        ToolParameter(
            name: "content",
            type: .string,
            description: "The replacement fact.",
            isRequired: true
        ),
        ToolParameter(
            name: "tags",
            type: .array,
            description: "Optional tags for the replacement (defaults to the old entry's tags)."
        ),
    ]

    private let modelContainer: ModelContainer
    private let chatID: UUID
    private let coordinator: MemoryCardCoordinator
    private let dependencies: MemoryWriteToolDependencies

    @MainActor
    init(
        modelContainer: ModelContainer,
        chatID: UUID,
        coordinator: MemoryCardCoordinator? = nil,
        dependencies: MemoryWriteToolDependencies = .live
    ) {
        self.modelContainer = modelContainer
        self.chatID = chatID
        self.coordinator = coordinator ?? MemoryCardCoordinator.shared
        self.dependencies = dependencies
    }

    var isConfigured: Bool {
        MainActor.assumeIsolated { dependencies.isAvailable() }
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        guard let handle = arguments["handle"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines), !handle.isEmpty else {
            throw ToolError.missingArgument("handle")
        }
        guard let content = arguments["content"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else {
            throw ToolError.missingArgument("content")
        }
        let tags = MemoryToolArguments.tags(from: arguments)

        return try await MainActor.run {
            guard dependencies.isAvailable(), let repository = dependencies.repository() else {
                throw ToolError.notConfigured(toolName: displayName, reason: SearchMemoryTool.unavailableReason)
            }
            let old: MemoryEntry
            do {
                old = try repository.resolveEntry(handle: handle)
            } catch let memoryError as MemoryError {
                throw ToolError.executionFailed(memoryError.errorDescription ?? String(describing: memoryError))
            }
            let target = try old.collection ?? repository.ensureInbox()

            switch target.accessLevel {
            case .writesFreely:
                let replacement: MemoryEntry
                do {
                    replacement = try repository.supersedeEntry(
                        old,
                        withBody: content,
                        tags: tags.isEmpty ? nil : tags,
                        createdBy: .ai,
                        sourceChatID: chatID
                    )
                } catch let memoryError as MemoryError {
                    throw ToolError.executionFailed(memoryError.errorDescription ?? String(describing: memoryError))
                }
                coordinator.enqueueWrite(entryID: replacement.id, chatID: chatID)
                return "Superseded (\(handle)) in \"\(target.title)\" — new handle \(replacement.handle)."
            case .asksFirst:
                let proposal = MemoryProposal(
                    entryText: content,
                    targetCollectionID: target.id,
                    supersedesEntryID: old.id,
                    tags: tags,
                    summary: "Update a memory in \"\(target.title)\"",
                    source: .chat,
                    chatID: chatID
                )
                let context = ModelContext(modelContainer)
                context.insert(proposal)
                try context.save()
                coordinator.enqueueProposal(proposalID: proposal.id, chatID: chatID)
                return "\"\(target.title)\" requires approval — proposed, awaiting the user's decision."
            }
        }
    }
}

/// Creates a new collection, optionally seeded with initial entries. New
/// collections default to "AI writes freely" (the frictionless-capture
/// path); requesting "asks first" turns the whole creation — collection plus
/// seed entries — into one proposal granted in a single approval.
struct CreateMemoryCollectionTool: Tool {
    let name = "create_memory_collection"
    let displayName = "Create Memory Collection"
    let description = """
        Create a new memory collection for a theme that doesn't fit any \
        existing collection. The title should be a short descriptive \
        sentence saying what belongs inside. Check the memory index first — \
        prefer filing into an existing collection or the Inbox over \
        creating near-duplicates.
        """
    let systemImage = "folder.badge.plus"

    let parameters = [
        ToolParameter(
            name: "title",
            type: .string,
            description: "Short descriptive sentence naming what the collection holds.",
            isRequired: true
        ),
        ToolParameter(
            name: "details",
            type: .string,
            description: "Optional longer description of what belongs here."
        ),
        ToolParameter(
            name: "tags",
            type: .array,
            description: "Optional cross-cutting tags."
        ),
        ToolParameter(
            name: "access_level",
            type: .string,
            description: "\"writes_freely\" (default) or \"asks_first\" (every AI write needs user approval)."
        ),
        ToolParameter(
            name: "scope",
            type: .string,
            description: "Optional feature scope: email, calendar, reminders, or notes. Omit for global."
        ),
        ToolParameter(
            name: "initial_entries",
            type: .array,
            description: "Optional first facts to save into the new collection."
        ),
    ]

    private let modelContainer: ModelContainer
    private let chatID: UUID
    private let coordinator: MemoryCardCoordinator
    private let dependencies: MemoryWriteToolDependencies

    @MainActor
    init(
        modelContainer: ModelContainer,
        chatID: UUID,
        coordinator: MemoryCardCoordinator? = nil,
        dependencies: MemoryWriteToolDependencies = .live
    ) {
        self.modelContainer = modelContainer
        self.chatID = chatID
        self.coordinator = coordinator ?? MemoryCardCoordinator.shared
        self.dependencies = dependencies
    }

    var isConfigured: Bool {
        MainActor.assumeIsolated { dependencies.isAvailable() }
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        guard let title = arguments["title"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            throw ToolError.missingArgument("title")
        }
        let details = arguments["details"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let tags = MemoryToolArguments.tags(from: arguments)
        let accessLevel: MemoryCollection.AccessLevel
        switch arguments["access_level"]?.stringValue {
        case nil, "writes_freely": accessLevel = .writesFreely
        case "asks_first": accessLevel = .asksFirst
        case .some(let other):
            throw ToolError.invalidArguments("access_level must be \"writes_freely\" or \"asks_first\", got \"\(other)\"")
        }
        let scope: WorkspaceFeature?
        if let scopeRaw = arguments["scope"]?.stringValue, !scopeRaw.isEmpty {
            guard let feature = memoryToolsScopeOptions.first(where: { $0.rawValue == scopeRaw }) else {
                throw ToolError.invalidArguments(
                    "scope must be one of \(memoryToolsScopeOptions.map(\.rawValue).joined(separator: ", "))"
                )
            }
            scope = feature
        } else {
            scope = nil
        }
        let initialEntries = MemoryToolArguments.strings(from: arguments["initial_entries"])

        return try await MainActor.run {
            guard dependencies.isAvailable(), let repository = dependencies.repository() else {
                throw ToolError.notConfigured(toolName: displayName, reason: SearchMemoryTool.unavailableReason)
            }
            if let existing = repository.collections().first(where: {
                $0.title.compare(title, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }) {
                throw ToolError.invalidArguments(
                    "A collection titled \"\(existing.title)\" already exists (handle \(existing.handle)) — use add_memory instead."
                )
            }

            switch accessLevel {
            case .writesFreely:
                // One save for the collection and its seeds: a failure must
                // not leave a half-seeded collection behind, and nothing is
                // disclosed until the whole creation persisted.
                let (collection, entries) = try repository.performBatch {
                    let collection = try repository.createCollection(
                        title: title,
                        details: details?.isEmpty == true ? nil : details,
                        tags: tags,
                        accessLevel: .writesFreely,
                        scope: scope,
                        createdBy: .ai,
                        chatID: chatID
                    )
                    let entries = try initialEntries.map { body in
                        try repository.addEntry(
                            body: body,
                            to: collection,
                            createdBy: .ai,
                            sourceChatID: chatID
                        )
                    }
                    return (collection, entries)
                }
                coordinator.enqueueCollectionCreation(collectionID: collection.id, chatID: chatID)
                for entry in entries {
                    coordinator.enqueueWrite(entryID: entry.id, chatID: chatID)
                }
                let seeded = initialEntries.isEmpty ? "" : " with \(initialEntries.count) entries"
                return "Created \"\(title)\"\(seeded) (handle \(collection.handle))."
            case .asksFirst:
                // The whole creation — collection and seed entries — is one
                // proposal, granted in a single approval. Seed entries ride
                // in `entryText` newline-separated; the dispatcher splits.
                let proposal = MemoryProposal(
                    entryText: initialEntries.joined(separator: "\n"),
                    newCollectionTitle: title,
                    newCollectionDetails: details?.isEmpty == true ? nil : details,
                    newCollectionAccessLevel: .asksFirst,
                    scope: scope,
                    tags: tags,
                    summary: "Create the asks-first collection \"\(title)\"",
                    source: .chat,
                    chatID: chatID
                )
                let context = ModelContext(modelContainer)
                context.insert(proposal)
                try context.save()
                coordinator.enqueueProposal(proposalID: proposal.id, chatID: chatID)
                return "An asks-first collection requires approval — proposed, awaiting the user's decision."
            }
        }
    }
}

/// Argument helpers shared by the write tools.
nonisolated enum MemoryToolArguments {
    static func tags(from arguments: [String: JSONValue]) -> [String] {
        strings(from: arguments["tags"])
    }

    static func strings(from value: JSONValue?) -> [String] {
        guard case .array(let values) = value else { return [] }
        return values.compactMap {
            $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .filter { !$0.isEmpty }
    }

    /// Resolves the target collection for a write: a provided reference must
    /// resolve (handle first, then exact title — an unresolvable reference
    /// errors so the model can search rather than misfile); no reference
    /// means the Inbox, the design's never-force-file pressure valve.
    @MainActor
    static func resolveTarget(
        reference: String?,
        repository: MemoryRepository
    ) throws -> MemoryCollection {
        guard let reference = reference?.trimmingCharacters(in: .whitespacesAndNewlines),
              !reference.isEmpty else {
            return try repository.ensureInbox()
        }
        do {
            return try OpenMemoryCollectionTool.Dependencies.resolveCollection(
                reference: reference,
                repository: repository
            )
        } catch {
            throw ToolError.invalidArguments("""
                No collection matches "\(reference)". Use a handle or exact \
                title from the memory index, create_memory_collection for a \
                new theme, or omit "collection" to file into the Inbox.
                """)
        }
    }
}
