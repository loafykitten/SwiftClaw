import Foundation
import os
import SwiftData

@MainActor
final class ResearchSessionCoordinator {
    typealias PlanHandler = @MainActor (
        ResearchEngine,
        String,
        [ResearchClarification]
    ) async throws -> ResearchPlanningResult
    typealias RunHandler = @MainActor (
        ResearchEngine,
        ResearchPlan,
        ResearchPlanContext,
        @escaping ResearchEngine.ProgressHandler
    ) async throws -> DeepResearchRunResult
    typealias NotificationHandler = @MainActor (UUID, String, Bool) -> Void

    static let shared = ResearchSessionCoordinator()

    private static let logger = AppLog.make("research.session")

    private let engineFactory: @MainActor () -> ResearchEngine
    private let planHandler: PlanHandler
    private let runHandler: RunHandler
    private let notificationHandler: NotificationHandler
    private let runBudget: Duration
    private var modelContainer: ModelContainer?
    private var modelContext: ModelContext?
    private var activeRunTask: Task<Void, Never>?
    private var activeSessionID: UUID?
    private var activeStage: ResearchStage?
    private var processedProgressEventCount = 0
    private var deletedSessionIDs = Set<UUID>()

    init(
        engineFactory: @escaping @MainActor () -> ResearchEngine = {
            ResearchEngine(configuration: .deepResearch())
        },
        planHandler: @escaping PlanHandler = { engine, topic, clarifications in
            try await engine.plan(
                topic: topic,
                focus: nil,
                clarifications: clarifications
            )
        },
        runHandler: @escaping RunHandler = { engine, plan, context, progress in
            await engine.run(plan: plan, context: context, progress: progress)
        },
        notificationHandler: @escaping NotificationHandler = { sessionID, title, isPartial in
            AppNotificationService.shared.notifyResearchComplete(
                sessionID: sessionID,
                title: title,
                isPartial: isPartial
            )
        },
        runBudget: Duration = .seconds(15 * 60)
    ) {
        self.engineFactory = engineFactory
        self.planHandler = planHandler
        self.runHandler = runHandler
        self.notificationHandler = notificationHandler
        self.runBudget = runBudget
    }

    /// Hands the singleton its store once at launch and converts any process-
    /// interrupted work into an honest terminal state. No work auto-restarts:
    /// Phase 5 decides whether to offer the resumable approved plan.
    func configure(modelContainer: ModelContainer) {
        guard self.modelContainer == nil else {
            Self.logger.error("ResearchSessionCoordinator was configured more than once")
            return
        }

        self.modelContainer = modelContainer
        // The coordinator is MainActor-bound, so it shares the container's
        // main context — the same one the UI's @Query sessions live in.
        // Mutating a view-fetched session and saving a private context here
        // would silently drop the change.
        let modelContext = modelContainer.mainContext
        self.modelContext = modelContext

        do {
            let sessions = try modelContext.fetch(FetchDescriptor<ResearchSession>())
            var changed = false
            for session in sessions where Self.isRunningFamily(session.status) {
                var checkpoint = session.progress ?? ResearchSessionCheckpoint()
                // A stored report can only come from an earlier partial run
                // that was resumed; a first run interrupted mid-flight has
                // nothing written yet.
                let storedReport = session.reportMarkdown?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )

                if !(storedReport?.isEmpty ?? true) {
                    session.status = .completedPartial
                    session.isUnviewed = true
                } else {
                    session.status = .cancelled
                }
                session.completedAt = .now
                session.errorMessage = "Research was interrupted when SwiftClaw stopped."
                checkpoint.canResume = session.planPayload != nil
                session.progress = checkpoint
                changed = true
            }
            if changed {
                try modelContext.save()
            }
        } catch {
            Self.logger.error("Could not reconcile interrupted research: \(String(describing: error))")
        }
    }

    func createSession(topic: String) -> ResearchSession {
        let session = ResearchSession(topic: topic)
        guard let modelContext else {
            Self.logger.error("Cannot create research session before configure(modelContainer:)")
            return session
        }
        modelContext.insert(session)
        save(modelContext)
        return session
    }

    func submitClarifications(
        session: ResearchSession,
        answers: [ResearchClarification]
    ) {
        session.clarifications = answers
        session.status = .planning
        session.errorMessage = nil
        saveModelContext()
    }

    func generatePlan(session: ResearchSession) async {
        session.status = .planning
        session.errorMessage = nil
        saveModelContext()

        do {
            let result = try await planHandler(
                engineFactory(),
                session.topic,
                session.clarifications
            )
            session.planPayload = ResearchSessionPlanPayload(
                plan: result.plan,
                context: result.context
            )
            session.progress = ResearchSessionCheckpoint(completedStage: .planning)
            session.status = .awaitingPlanApproval
            saveModelContext()
        } catch {
            session.status = .failed
            session.completedAt = .now
            session.errorMessage = error.localizedDescription
            session.isUnviewed = true
            saveModelContext()
        }
    }

    func startRun(session: ResearchSession, approvedPlan: ResearchPlan) {
        guard activeRunTask == nil else {
            Self.logger.error("Ignored research start while another session is active")
            return
        }
        guard var payload = session.planPayload else {
            session.status = .failed
            session.completedAt = .now
            session.errorMessage = "The approved research plan is missing its saved context."
            session.isUnviewed = true
            saveModelContext()
            return
        }

        payload.plan = approvedPlan
        session.planPayload = payload
        session.status = .running
        session.completedAt = nil
        session.errorMessage = nil
        session.isUnviewed = false
        var checkpoint = session.progress ?? ResearchSessionCheckpoint()
        checkpoint.canResume = true
        session.progress = checkpoint
        saveModelContext()

        let sessionID = session.id
        activeSessionID = sessionID
        activeStage = nil
        processedProgressEventCount = 0
        ResearchProgressMonitor.shared.begin(sessionID: sessionID, budget: runBudget)

        let progressBuffer = ResearchProgressEventBuffer()
        let progressHandler: ResearchEngine.ProgressHandler = { [weak self] event in
            progressBuffer.append(event)
            Task { @MainActor [weak self] in
                self?.drainProgress(progressBuffer, sessionID: sessionID)
            }
        }
        let engine = engineFactory()
        activeRunTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await runHandler(
                    engine,
                    payload.plan,
                    payload.context,
                    progressHandler
                )
                drainProgress(progressBuffer, sessionID: sessionID)
                guard !deletedSessionIDs.contains(sessionID) else {
                    finishRun(sessionID: sessionID)
                    deletedSessionIDs.remove(sessionID)
                    return
                }
                persist(result, to: session, wasCancelled: Task.isCancelled)
            } catch {
                drainProgress(progressBuffer, sessionID: sessionID)
                guard !deletedSessionIDs.contains(sessionID) else {
                    finishRun(sessionID: sessionID)
                    deletedSessionIDs.remove(sessionID)
                    return
                }
                persist(error, to: session, wasCancelled: Task.isCancelled)
            }
            finishRun(sessionID: sessionID)
        }
    }

    func cancel(session: ResearchSession) {
        guard activeSessionID == session.id, let activeRunTask else {
            if Self.isRunningFamily(session.status) {
                markCancelled(session)
            }
            return
        }
        activeRunTask.cancel()
    }

    func deleteSession(session: ResearchSession) {
        guard let modelContext else { return }
        if activeSessionID == session.id {
            deletedSessionIDs.insert(session.id)
            activeRunTask?.cancel()
            ResearchProgressMonitor.shared.finish()
        }
        modelContext.delete(session)
        save(modelContext)
    }

    func resumableSession() -> ResearchSession? {
        guard let modelContext else { return nil }
        do {
            return try modelContext.fetch(FetchDescriptor<ResearchSession>())
                .filter { session in
                    (session.status == .cancelled || session.status == .completedPartial)
                        && session.planPayload != nil
                        && session.progress?.canResume == true
                }
                .max { $0.createdAt < $1.createdAt }
        } catch {
            Self.logger.error("Could not fetch resumable research: \(String(describing: error))")
            return nil
        }
    }

    #if DEBUG
        func waitForIdleForTesting() async {
            if let activeRunTask {
                await activeRunTask.value
            }
        }
    #endif

    private func drainProgress(
        _ buffer: ResearchProgressEventBuffer,
        sessionID: UUID
    ) {
        guard activeSessionID == sessionID else { return }
        let events = buffer.snapshot()
        guard processedProgressEventCount < events.count else { return }
        for event in events.dropFirst(processedProgressEventCount) {
            handleProgress(event, sessionID: sessionID)
            processedProgressEventCount += 1
        }
    }

    private func handleProgress(_ event: ResearchProgressEvent, sessionID: UUID) {
        guard activeSessionID == sessionID,
              let session = fetchSession(id: sessionID) else { return }

        var checkpoint = session.progress ?? ResearchSessionCheckpoint()
        if case let .stageChanged(nextStage) = event,
           let activeStage,
           activeStage != nextStage
        {
            checkpoint.completedStage = activeStage
        }

        ResearchProgressMonitor.shared.apply(event)
        activeStage = ResearchProgressMonitor.shared.stage
        checkpoint.sourceCount = ResearchProgressMonitor.shared.sourceCount
        checkpoint.activityFeed = ResearchProgressMonitor.shared.activityFeed
        session.progress = checkpoint

        if case .stageChanged = event, checkpoint.completedStage != nil {
            saveModelContext()
        }
    }

    private func persist(
        _ result: DeepResearchRunResult,
        to session: ResearchSession,
        wasCancelled: Bool
    ) {
        session.reportMarkdown = result.reportMarkdown
        session.sources = result.sources
        session.evidence = result.evidence
        session.openQuestions = result.openQuestions
        session.unverifiedClaimCount = result.unverifiedClaimCount
        session.completedAt = .now
        session.errorMessage = nil

        var checkpoint = session.progress ?? ResearchSessionCheckpoint()
        checkpoint.completedStage = activeStage ?? checkpoint.completedStage
        checkpoint.sourceCount = result.sources.count
        checkpoint.activityFeed = ResearchProgressMonitor.shared.activityFeed
        checkpoint.degradationNotes = result.degradationNotes
        checkpoint.canResume = wasCancelled
        session.progress = checkpoint

        if wasCancelled {
            session.status = .cancelled
            session.isUnviewed = !result.reportMarkdown.isEmpty
            saveModelContext()
        } else {
            let isPartial = result.isPartial || !result.degradationNotes.isEmpty
            session.status = isPartial ? .completedPartial : .completed
            session.isUnviewed = true
            saveModelContext()
            notificationHandler(session.id, session.title, isPartial)
        }
    }

    private func persist(
        _ error: Error,
        to session: ResearchSession,
        wasCancelled: Bool
    ) {
        if wasCancelled {
            markCancelled(session)
            return
        }
        session.status = .failed
        session.completedAt = .now
        session.errorMessage = error.localizedDescription
        session.isUnviewed = true
        saveModelContext()
    }

    private func markCancelled(_ session: ResearchSession) {
        session.status = .cancelled
        session.completedAt = .now
        session.isUnviewed = !(session.reportMarkdown?.isEmpty ?? true)
        var checkpoint = session.progress ?? ResearchSessionCheckpoint()
        checkpoint.canResume = session.planPayload != nil
        session.progress = checkpoint
        saveModelContext()
    }

    private func fetchSession(id: UUID) -> ResearchSession? {
        guard let modelContext else { return nil }
        var descriptor = FetchDescriptor<ResearchSession>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    private func finishRun(sessionID: UUID) {
        guard activeSessionID == sessionID else { return }
        activeRunTask = nil
        activeSessionID = nil
        activeStage = nil
        processedProgressEventCount = 0
        ResearchProgressMonitor.shared.finish()
    }

    private func saveModelContext() {
        guard let modelContext else { return }
        save(modelContext)
    }

    private func save(_ modelContext: ModelContext) {
        do {
            try modelContext.save()
        } catch {
            Self.logger.error("Could not save research session: \(String(describing: error))")
        }
    }

    private static func isRunningFamily(_ status: ResearchSessionStatus) -> Bool {
        status == .running || status == .planning || status == .clarifying
    }
}

private final nonisolated class ResearchProgressEventBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var events = [ResearchProgressEvent]()

    func append(_ event: ResearchProgressEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func snapshot() -> [ResearchProgressEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}
