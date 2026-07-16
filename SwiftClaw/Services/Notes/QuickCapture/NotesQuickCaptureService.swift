import Foundation

@MainActor
final class NotesQuickCaptureService {
    enum Destination: Equatable, Sendable {
        case dailyNote
        case standaloneNote
    }

    struct CaptureResult: Equatable, Sendable {
        let path: String
        let destination: Destination
    }

    enum CaptureError: LocalizedError, Equatable {
        case emptyText
        case captureInProgress

        var errorDescription: String? {
            switch self {
            case .emptyText: "Enter something to capture."
            case .captureInProgress: "Another quick capture is still saving."
            }
        }
    }

    private let repository: NotesRepository
    private let statsStore: NotesCaptureStatsStore
    private let dailyNoteResolver: DailyNoteResolver
    private let now: () -> Date
    private var isCapturing = false

    init(
        repository: NotesRepository,
        statsStore: NotesCaptureStatsStore = NotesCaptureStatsStore(),
        calendar: Calendar = .current,
        now: @escaping () -> Date = { .now }
    ) {
        self.repository = repository
        self.statsStore = statsStore
        dailyNoteResolver = DailyNoteResolver(calendar: calendar)
        self.now = now
    }

    func captureDaily(_ text: String, folder: String?) async throws -> CaptureResult {
        let text = try normalized(text)
        try beginCapture()
        defer { isCapturing = false }
        let operationNow = now()
        let resolution = dailyNoteResolver.resolve(now: operationNow, folder: folder)

        if repository.summary(forRelativePath: resolution.relativePath) != nil {
            try await append(text, resolution: resolution)
        } else {
            do {
                _ = try await repository.createExactPath(
                    relativePath: resolution.relativePath,
                    content: resolution.newNoteContent(text: text)
                )
            } catch NotesError.pathAlreadyExists(_) {
                // The catalog was stale or an external writer won the atomic
                // create race. Re-read and append against that exact hash.
                try await append(text, resolution: resolution)
            }
        }

        statsStore.recordSuccessfulCapture(on: operationNow)
        return CaptureResult(path: resolution.relativePath, destination: .dailyNote)
    }

    func captureStandalone(_ text: String, folder: String? = nil) async throws -> CaptureResult {
        let text = try normalized(text)
        try beginCapture()
        defer { isCapturing = false }
        let operationNow = now()
        let firstLine = text.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? text
        let created = try await repository.create(title: firstLine, folder: folder)
        let saved = try await repository.save(
            relativePath: created.relativePath,
            content: text,
            expectedHash: created.sha256
        )

        statsStore.recordSuccessfulCapture(on: operationNow)
        return CaptureResult(path: saved.relativePath, destination: .standaloneNote)
    }

    func capturedTodayCount(now: Date = .now) -> Int {
        statsStore.capturedCount(on: now)
    }

    private func append(_ text: String, resolution: DailyNoteResolver.Resolution) async throws {
        let snapshot = try await repository.read(relativePath: resolution.relativePath)
        _ = try await repository.save(
            relativePath: resolution.relativePath,
            content: resolution.appending(text: text, to: snapshot.content),
            expectedHash: snapshot.sha256
        )
    }

    private func normalized(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CaptureError.emptyText }
        return trimmed
    }

    private func beginCapture() throws {
        guard !isCapturing else { throw CaptureError.captureInProgress }
        isCapturing = true
    }
}
