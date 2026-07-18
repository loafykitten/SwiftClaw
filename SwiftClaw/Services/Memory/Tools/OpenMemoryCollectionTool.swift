import Foundation

/// Returns one memory collection in full — the expansion path the compact
/// index points at when the store outgrows full injection. Accepts a
/// collection handle (from the index) or an exact title. Shares
/// `MemoryPromptBuilder.serialize` so the model sees the same format as the
/// injected store.
struct OpenMemoryCollectionTool: Tool {
    struct Dependencies: Sendable {
        var isAvailable: @MainActor @Sendable () -> Bool
        var open: @MainActor @Sendable (_ reference: String) throws -> String?

        static let live = Dependencies(
            isAvailable: { MemoryFeatureModel.shared.isAvailable },
            open: { reference in
                guard let repository = MemoryFeatureModel.shared.repository else { return nil }
                let collection = try Self.resolveCollection(reference: reference, repository: repository)
                return MemoryPromptBuilder.serialize(collection: collection).joined(separator: "\n")
            }
        )

        /// Handle first (the index cites handles), then exact
        /// case-insensitive title.
        @MainActor
        static func resolveCollection(
            reference: String,
            repository: MemoryRepository
        ) throws -> MemoryCollection {
            if let byHandle = try? repository.resolveCollection(handle: reference) {
                return byHandle
            }
            let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let byTitle = repository.collections().first(where: {
                $0.title.compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }) else {
                throw MemoryError.collectionNotFound
            }
            return byTitle
        }
    }

    let dependencies: Dependencies

    init(dependencies: Dependencies = .live) {
        self.dependencies = dependencies
    }

    let name = "open_memory_collection"
    let displayName = "Open Memory Collection"
    let description = """
        Read one memory collection in full: header, description, and every \
        current entry with its handle. Pass a collection handle from the \
        memory index, or an exact collection title.
        """
    let systemImage = "folder"

    let parameters = [
        ToolParameter(
            name: "collection",
            type: .string,
            description: "The collection's 8-character handle, or its exact title.",
            isRequired: true
        ),
    ]

    /// `MainActor.assumeIsolated` — see `SearchMemoryTool.isConfigured`.
    var isConfigured: Bool {
        MainActor.assumeIsolated {
            dependencies.isAvailable()
        }
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        guard await dependencies.isAvailable() else {
            throw ToolError.notConfigured(toolName: displayName, reason: SearchMemoryTool.unavailableReason)
        }
        guard let reference = arguments["collection"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !reference.isEmpty else {
            throw ToolError.missingArgument("collection")
        }
        do {
            guard let block = try await dependencies.open(reference) else {
                throw ToolError.notConfigured(toolName: displayName, reason: SearchMemoryTool.unavailableReason)
            }
            return block
        } catch let memoryError as MemoryError {
            throw ToolError.executionFailed(memoryError.errorDescription ?? String(describing: memoryError))
        }
    }
}
