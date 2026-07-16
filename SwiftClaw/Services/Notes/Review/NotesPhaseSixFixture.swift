#if DEBUG
    import Foundation

    /// Credential-free inference seam for Phase 6 Computer Use. It is accepted
    /// only inside the existing hardened temporary Notes fixture product; normal
    /// DEBUG builds cannot enable it accidentally.
    enum NotesPhaseSixFixture {
        static let launchArgument = "-SwiftClawEnableNotesPhaseSixFixture"

        static func isEnabled(
            arguments: [String] = ProcessInfo.processInfo.arguments,
            bundleIdentifier: String? = Bundle.main.bundleIdentifier
        ) -> Bool {
            bundleIdentifier == NoteProposalFixtureLaunch.fixtureBundleIdentifier
                && arguments.contains(NoteProposalFixtureSeeder.launchArgument)
                && arguments.contains(launchArgument)
        }

        @MainActor
        static func run(
            fetchTool: NotesReviewFetchTool,
            notifyTool: NotesReviewNotifyTool
        ) async throws {
            let digest = try await fetchTool.execute(arguments: ["limit_per_section": .number(6)])
            let ids = digest
                .split(whereSeparator: \.isNewline)
                .compactMap { line -> UUID? in
                    guard let marker = line.range(of: "finding_id: ") else { return nil }
                    let suffix = line[marker.upperBound...]
                    let raw = suffix.split(separator: "|").first.map(String.init)?
                        .trimmingCharacters(in: .whitespaces)
                    return raw.flatMap(UUID.init(uuidString:))
                }
            guard !ids.isEmpty else { return }

            let findings: [JSONValue] = ids.map { id in
                .object([
                    "finding_id": .string(id.uuidString),
                    "summary": .string("Fixture finding from the isolated Notes vault."),
                ])
            }
            _ = try await notifyTool.execute(arguments: [
                "findings": .array(findings),
                "message": .string("Here is the latest read-only Notes hygiene review."),
                "notification_summary": .string("Notes hygiene review ready."),
            ])
        }
    }
#endif
