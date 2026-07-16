import Foundation

/// One pass's allow-list of ephemeral finding IDs. IDs deliberately identify
/// the fetched finding, not a note or vault path, and are never reusable as a
/// stable Notes identity.
@MainActor
final class NotesReviewFindingCollector {
    nonisolated struct Finding: Sendable, Equatable {
        nonisolated enum Kind: String, Sendable {
            case uncheckedTask = "Unchecked task"
            case conflictCopy = "Conflict copy"
            case brokenLink = "Broken link"
            case recentNote = "Recent note"
            case indexHealth = "Index health"
        }

        let id: UUID
        let kind: Kind
        let subject: String
        let detail: String
        let location: String?
        let date: Date?
    }

    private(set) var findings: [UUID: Finding] = [:]

    func replace(with newFindings: [Finding]) {
        findings = Dictionary(uniqueKeysWithValues: newFindings.map { ($0.id, $0) })
    }

    func finding(id: UUID) -> Finding? {
        findings[id]
    }
}

nonisolated protocol NotesReviewDataSource: Sendable {
    @MainActor func prepare() async
    @MainActor var isAvailable: Bool { get }
    @MainActor func notes() -> [NoteSummary]
    @MainActor func read(relativePath: String) async throws -> NoteFileSnapshot
    @MainActor func brokenLinks() async -> [ResolvedLink]
    @MainActor func healthSummary() async -> NotesHealthSummary?
}

/// Production boundary for review reads. It intentionally goes through the
/// Notes feature facade/repository and never owns or opens a vault/database.
nonisolated struct NotesFeatureReviewDataSource: NotesReviewDataSource {
    @MainActor func prepare() async {
        await NotesFeatureModel.shared.prepareReadToolsIfNeeded()
    }

    @MainActor var isAvailable: Bool {
        NotesFeatureModel.shared.isAvailableForReadTools
    }

    @MainActor func notes() -> [NoteSummary] {
        NotesFeatureModel.shared.repository?.notes ?? []
    }

    @MainActor func read(relativePath: String) async throws -> NoteFileSnapshot {
        try await NotesFeatureModel.shared.readNoteForTool(relativePath: relativePath)
    }

    @MainActor func brokenLinks() async -> [ResolvedLink] {
        await NotesFeatureModel.shared.refreshBrokenLinks()
        return NotesFeatureModel.shared.brokenLinks
    }

    @MainActor func healthSummary() async -> NotesHealthSummary? {
        await NotesFeatureModel.shared.refreshHealth()
        return NotesFeatureModel.shared.healthSummary
    }
}

/// System-only, read-only vault-hygiene digest. Every dimension is bounded so
/// a large vault cannot turn a scheduled review into an unbounded prompt.
final class NotesReviewFetchTool: Tool, @unchecked Sendable {
    static let maximumPerDimension = 25
    static let taskExcerptLimit = 180

    let name = "fetch_notes_review_digest"
    let displayName = "Fetch Notes Review Digest"
    let description = "Fetches a bounded read-only Notes hygiene digest. limit_per_section defaults to 10 and is capped at 25."
    let systemImage = "note.text"
    let parameters = [
        ToolParameter(name: "limit_per_section", type: .integer, description: "Maximum findings in each digest section (default 10, max 25)."),
    ]
    var isConfigured: Bool {
        true
    }

    var isEnabled: Bool {
        true
    }

    private let dataSource: any NotesReviewDataSource
    private let collector: NotesReviewFindingCollector
    private let userDefaults: UserDefaults
    private let now: @Sendable () -> Date

    init(
        dataSource: any NotesReviewDataSource = NotesFeatureReviewDataSource(),
        collector: NotesReviewFindingCollector,
        userDefaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.dataSource = dataSource
        self.collector = collector
        self.userDefaults = userDefaults
        self.now = now
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        let limit = min(Self.maximumPerDimension, max(1, arguments["limit_per_section"]?.intValue ?? 10))
        await dataSource.prepare()
        guard await dataSource.isAvailable else {
            throw ToolError.notConfigured(toolName: displayName, reason: "Notes is disabled, or no vault/index is configured.")
        }

        let allNotes = await dataSource.notes()
        let configuredDailyFolder = await MainActor.run {
            SettingsStorage.loadNotesDailyNoteFolder(userDefaults: userDefaults)
        }
        let dailyFolder = NotesFilenameSanitizer.sanitizeFolder(configuredDailyFolder)
        let dailyNotes = allNotes.filter {
            Self.isDailyNotePath($0.relativePath, folder: dailyFolder)
        }
        .sorted { $0.modifiedAt > $1.modifiedAt }

        var findings: [NotesReviewFindingCollector.Finding] = []
        var dailyReadFailureCount = 0
        var taskFindings: [NotesReviewFindingCollector.Finding] = []
        for note in dailyNotes.prefix(limit * 3) where taskFindings.count < limit {
            let snapshot: NoteFileSnapshot
            do {
                snapshot = try await dataSource.read(relativePath: note.relativePath)
            } catch {
                dailyReadFailureCount += 1
                continue
            }
            for line in snapshot.content.split(whereSeparator: \.isNewline) where taskFindings.count < limit {
                let text = line.trimmingCharacters(in: .whitespaces)
                guard text.hasPrefix("- [ ]") || text.hasPrefix("* [ ]") else { continue }
                taskFindings.append(Self.finding(.uncheckedTask, subject: String(text.dropFirst(5)).trimmingCharacters(in: .whitespaces), detail: "Unchecked daily-note task", location: note.relativePath, date: note.modifiedAt))
            }
        }
        findings += taskFindings

        let conflicts = allNotes.filter { NotesHealthSummary.isConflictCopy($0.relativePath) }
            .sorted { $0.modifiedAt > $1.modifiedAt }.prefix(limit)
        findings += conflicts.map { Self.finding(.conflictCopy, subject: $0.title, detail: "Conflict copy needs triage", location: $0.relativePath, date: $0.modifiedAt) }

        let broken = await dataSource.brokenLinks()
        findings += broken.prefix(limit).map {
            Self.finding(.brokenLink, subject: $0.pagePath.isEmpty ? "Unresolved heading link" : $0.pagePath, detail: "Broken link from \($0.sourcePath)", location: $0.sourcePath, date: nil)
        }

        let operationNow = now()
        let recentCutoff = operationNow.addingTimeInterval(-7 * 24 * 3600)
        let recent = allNotes.filter { $0.modifiedAt >= recentCutoff && !NotesHealthSummary.isConflictCopy($0.relativePath) }
            .sorted { $0.modifiedAt > $1.modifiedAt }.prefix(limit)
        findings += recent.map { Self.finding(.recentNote, subject: $0.title, detail: "Recently modified", location: $0.relativePath, date: $0.modifiedAt) }

        if let health = await dataSource.healthSummary() {
            var status = [
                health.ftsAvailable ? "full-text search available" : "full-text search unavailable",
                health.embeddingAvailable ? "embeddings available" : "embeddings unavailable",
                "\(health.lastIndexFailedPaths.count) indexing failure(s)",
            ]
            if let error = health.indexError {
                status.append("index error: \(error.prefix(Self.taskExcerptLimit))")
            }
            if health.lastIndexSuccessAt == nil {
                status.append("index has no successful completion")
            }
            if dailyReadFailureCount > 0 {
                status.append("\(dailyReadFailureCount) daily note read failure(s)")
            }
            findings.append(Self.finding(.indexHealth, subject: "Notes index", detail: status.joined(separator: "; "), location: nil, date: health.lastIndexSuccessAt))
        } else {
            let detail = dailyReadFailureCount > 0
                ? "Index health unavailable; \(dailyReadFailureCount) daily note read failure(s)"
                : "Index health unavailable"
            findings.append(Self.finding(.indexHealth, subject: "Notes index", detail: detail, location: nil, date: nil))
        }

        await collector.replace(with: findings)
        guard !findings.isEmpty else { return "Notes review digest is empty." }
        let grouped = Dictionary(grouping: findings, by: \NotesReviewFindingCollector.Finding.kind)
        return NotesReviewFindingCollector.Finding.Kind.allCasesForDigest.compactMap { kind in
            guard let values = grouped[kind], !values.isEmpty else { return nil }
            let lines = values.map { finding in
                var fields = ["finding_id: \(finding.id.uuidString)", "subject: \(Self.clean(finding.subject))", "detail: \(Self.clean(finding.detail))"]
                if let location = finding.location {
                    fields.append("location: \(Self.clean(location))")
                }
                return "- " + fields.joined(separator: " | ")
            }
            return "\(kind.rawValue) (\(values.count)):\n" + lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    private static func finding(_ kind: NotesReviewFindingCollector.Finding.Kind, subject: String, detail: String, location: String?, date: Date?) -> NotesReviewFindingCollector.Finding {
        .init(id: UUID(), kind: kind, subject: String(clean(subject).prefix(taskExcerptLimit)), detail: String(clean(detail).prefix(taskExcerptLimit)), location: location.map { String(clean($0).prefix(taskExcerptLimit)) }, date: date)
    }

    private static func clean(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }

    /// Daily review is deliberately narrower than "anything in this
    /// folder": only the exact files produced by `DailyNoteResolver` count.
    /// In particular, a vault-root daily-note setting must not make an empty
    /// prefix match every note in the vault.
    private static func isDailyNotePath(_ relativePath: String, folder: String?) -> Bool {
        let filename: String
        if let folder {
            let prefix = folder + "/"
            guard relativePath.hasPrefix(prefix) else { return false }
            filename = String(relativePath.dropFirst(prefix.count))
            guard !filename.contains("/") else { return false }
        } else {
            guard !relativePath.contains("/") else { return false }
            filename = relativePath
        }

        guard filename.hasSuffix(".md") else { return false }
        let date = filename.dropLast(3)
        let parts = date.split(separator: "-", omittingEmptySubsequences: false)
        return parts.count == 3
            && parts[0].count == 4
            && parts[1].count == 2
            && parts[2].count == 2
            && parts.allSatisfy { $0.allSatisfy(\.isNumber) }
    }
}

private extension NotesReviewFindingCollector.Finding.Kind {
    nonisolated static let allCasesForDigest: [Self] = [.uncheckedTask, .conflictCopy, .brokenLink, .recentNote, .indexHealth]
}
