import Foundation
import SwiftData

/// Request-bound tool for follow-up chats spawned from a Deep Research
/// report (`Chat.researchSessionID`): reads the stored report so the model
/// can quote it without the whole document living in the system prompt.
/// Never registered on `ToolRegistry.shared`.
struct ResearchReportTool: Tool {
    /// Reports short enough to return whole; longer ones return the section
    /// list and require a `section` argument.
    private static let fullReportCharacterLimit = 8_000

    let name = "research_report"
    let displayName = "Research Report"
    let description = """
        Read the Deep Research report this chat follows up on. Call with no \
        arguments for the report (or its section list when long); pass \
        "section" with a section heading to read just that section. The \
        report's [n] citation numbers match the source list in this chat's \
        context.
        """
    let systemImage = "doc.text.magnifyingglass"

    let parameters = [
        ToolParameter(
            name: "section",
            type: .string,
            description: "A section heading from the report to read on its own."
        ),
    ]

    var isConfigured: Bool { true }
    var isEnabled: Bool { true }

    private let modelContainer: ModelContainer
    private let sessionID: UUID

    init(modelContainer: ModelContainer, sessionID: UUID) {
        self.modelContainer = modelContainer
        self.sessionID = sessionID
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        let requestedSection = arguments["section"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let report: String? = await MainActor.run { [sessionID] in
            let context = modelContainer.mainContext
            let id = sessionID
            var descriptor = FetchDescriptor<ResearchSession>(
                predicate: #Predicate { $0.id == id }
            )
            descriptor.fetchLimit = 1
            return try? context.fetch(descriptor).first?.reportMarkdown
        }

        guard let report, !report.isEmpty else {
            return "The research report is no longer available — its session was deleted."
        }

        let sections = Self.sections(of: report)

        if let requestedSection, !requestedSection.isEmpty {
            let normalizedRequest = requestedSection.lowercased()
            let match = sections.first {
                $0.heading.trimmingCharacters(in: .whitespaces).lowercased() == normalizedRequest
            } ?? sections.first {
                $0.heading.localizedCaseInsensitiveContains(requestedSection)
            }
            guard let match else {
                let headings = sections.map { "- \($0.heading)" }.joined(separator: "\n")
                return "No section matches \"\(requestedSection)\". Sections:\n\(headings)"
            }
            return Self.bounded(match.body)
        }

        if report.count <= Self.fullReportCharacterLimit {
            return report
        }

        let headings = sections.map { "- \($0.heading)" }.joined(separator: "\n")
        return """
            The report is long; request one section at a time via "section".
            Sections:
            \(headings)
            """
    }

    /// Every tool result honors the size promise, not just the no-argument
    /// path — one oversized section must not blow the context either.
    private static func bounded(_ text: String) -> String {
        guard text.count > fullReportCharacterLimit else { return text }
        return String(text.prefix(fullReportCharacterLimit))
            + "\n\n[Truncated — the section exceeds the tool's size limit.]"
    }

    /// Splits on `## ` headings, ignoring lines inside ``` fences so code
    /// samples can't fabricate sections. The preamble before the first
    /// heading rides with the first section.
    private static func sections(of report: String) -> [(heading: String, body: String)] {
        var sections = [(heading: String, body: String)]()
        var currentHeading = "Report"
        var currentLines = [String]()
        var isInFence = false

        for line in report.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                isInFence.toggle()
            }
            if !isInFence, line.hasPrefix("## ") {
                if !currentLines.isEmpty {
                    sections.append((currentHeading, currentLines.joined(separator: "\n")))
                }
                currentHeading = String(line.dropFirst(3))
                currentLines = [String(line)]
            } else {
                currentLines.append(String(line))
            }
        }
        if !currentLines.isEmpty {
            sections.append((currentHeading, currentLines.joined(separator: "\n")))
        }
        return sections
    }
}
