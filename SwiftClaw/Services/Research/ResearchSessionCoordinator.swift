import Foundation
import os
import SwiftData
#if os(macOS)
import AppKit
#else
import UIKit
#endif

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
    /// Test seam for failure injection; production always saves the context.
    typealias SaveHandler = @MainActor (ModelContext) throws -> Void

    static let shared = ResearchSessionCoordinator()

    private static let logger = AppLog.make("research.session")

    private let engineFactory: @MainActor () -> ResearchEngine
    private let planHandler: PlanHandler
    private let runHandler: RunHandler
    private let notificationHandler: NotificationHandler
    private let saveHandler: SaveHandler
    private let runBudget: Duration
    private var modelContainer: ModelContainer?
    private var modelContext: ModelContext?
    private var activeRunTask: Task<Void, Never>?
    private var activeSessionID: UUID?
    private var activeStage: ResearchStage?
    private var processedProgressEventCount = 0
    private var deletedSessionIDs = Set<UUID>()
    /// Coordinator-owned planning work, keyed by session id so deletion can
    /// cancel it — a view-owned Task would keep writing into a deleted model.
    private var planningTasks: [UUID: Task<Void, Never>] = [:]
    /// Finished runs whose save failed, keyed by session id. Held here rather
    /// than only as unsaved changes on the shared main context, because any
    /// other component whose own save fails rolls that context back — which
    /// would discard the report and revert the session to its persisted
    /// `running` state. Re-applied and retried until a save lands.
    private var unsavedResults: [UUID: CompletedRun] = [:]
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var pendingRetryTask: Task<Void, Never>?

    /// The session currently running deep research, if any. The UI disables
    /// start/resume/retry actions while another session holds the slot.
    var runningSessionID: UUID? {
        activeSessionID
    }

    /// Whether a *different* session holds the single active-run slot.
    func isAnotherRunActive(than session: ResearchSession) -> Bool {
        runningSessionID != nil && runningSessionID != session.id
    }

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
        saveHandler: @escaping SaveHandler = { try $0.save() },
        runBudget: Duration = .seconds(15 * 60)
    ) {
        self.engineFactory = engineFactory
        self.planHandler = planHandler
        self.runHandler = runHandler
        self.notificationHandler = notificationHandler
        self.saveHandler = saveHandler
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
        observeSaveOpportunities(for: modelContext)

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
        let sessionID = session.id
        if let existing = planningTasks[sessionID] {
            await existing.value
            return
        }

        session.status = .planning
        session.errorMessage = nil
        saveModelContext()

        let topic = session.topic
        let clarifications = session.clarifications
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { planningTasks[sessionID] = nil }

            let outcome: Result<ResearchPlanningResult, Error>
            do {
                outcome = try await .success(planHandler(engineFactory(), topic, clarifications))
            } catch {
                outcome = .failure(error)
            }

            // The session may have been deleted (or the run superseded) while
            // planning was in flight — refetch instead of writing through the
            // captured object.
            guard let session = fetchSession(id: sessionID),
                  session.status == .planning else {
                return
            }

            switch outcome {
            case .success(let result):
                session.planPayload = result
                session.progress = ResearchSessionCheckpoint(completedStage: .planning)
                session.status = .awaitingPlanApproval
            case .failure(let error):
                session.status = .failed
                session.completedAt = .now
                session.errorMessage = error.localizedDescription
                session.isUnviewed = true
            }
            saveModelContext()
        }
        planningTasks[sessionID] = task
        await task.value
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

        // A new run supersedes a previous result that never reached the store.
        unsavedResults[session.id] = nil
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
        planningTasks[session.id]?.cancel()
        planningTasks[session.id] = nil
        unsavedResults[session.id] = nil
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

    /// Whether a finished run's result for `sessionID` hasn't been saved yet.
    func hasUnsavedResult(for sessionID: UUID) -> Bool {
        unsavedResults[sessionID] != nil
    }

    /// Re-applies a finished run's unsaved result if a rollback of the shared
    /// context reverted it, so the report stays readable and exportable.
    func restoreUnsavedResult(for session: ResearchSession) {
        unsavedResults[session.id]?.noteViewedState(of: session)
        guard let unsaved = unsavedResults[session.id], !unsaved.isApplied(to: session) else {
            return
        }
        unsaved.apply(to: session)
    }

    /// Re-applies every unsaved result and tries to save them again. Runs on
    /// its own after any other successful save of the shared context (the
    /// store works again) and when the app resigns active or backgrounds; a
    /// failure keeps them, with their warning, for the next attempt.
    func retryUnsavedResults() {
        guard !unsavedResults.isEmpty, let modelContext else { return }
        var sessions: [UUID: ResearchSession] = [:]
        for id in unsavedResults.keys {
            guard let session = fetchSession(id: id) else { continue }
            unsavedResults[id]?.noteViewedState(of: session)
            guard var saved = unsavedResults[id] else { continue }
            saved.saveFailureMessage = nil
            saved.apply(to: session)
            sessions[id] = session
        }

        do {
            try saveHandler(modelContext)
        } catch {
            Self.logger.error("Could not save research result on retry: \(String(describing: error))")
            for (id, session) in sessions {
                unsavedResults[id]?.apply(to: session)
            }
            return
        }
        for id in sessions.keys {
            unsavedResults[id] = nil
        }
    }

    #if DEBUG
        func waitForIdleForTesting() async {
            if let activeRunTask {
                await activeRunTask.value
            }
            if let pendingRetryTask {
                await pendingRetryTask.value
            }
        }
    #endif

    /// Retries unsaved results when saving is likely to work or about to
    /// matter: after another successful save of the shared context (deferred
    /// a turn — saving from inside its notification would re-enter it), and
    /// when the app resigns active or moves to the background.
    private func observeSaveOpportunities(for modelContext: ModelContext) {
        let center = NotificationCenter.default
        lifecycleObservers.append(center.addObserver(
            forName: ModelContext.didSave,
            object: modelContext,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.unsavedResults.isEmpty, self.pendingRetryTask == nil else { return }
                self.pendingRetryTask = Task { @MainActor [weak self] in
                    self?.pendingRetryTask = nil
                    self?.retryUnsavedResults()
                }
            }
        })

        #if os(macOS)
            let lifecycleNotifications = [NSApplication.willResignActiveNotification]
        #else
            let lifecycleNotifications = [
                UIApplication.willResignActiveNotification,
                UIApplication.didEnterBackgroundNotification,
            ]
        #endif
        for name in lifecycleNotifications {
            lifecycleObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.retryUnsavedResults()
                }
            })
        }
    }

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
        var checkpoint = session.progress ?? ResearchSessionCheckpoint()
        checkpoint.completedStage = activeStage ?? checkpoint.completedStage
        checkpoint.sourceCount = result.sources.count
        checkpoint.activityFeed = ResearchProgressMonitor.shared.activityFeed
        checkpoint.degradationNotes = result.degradationNotes
        checkpoint.canResume = wasCancelled

        let isPartial = result.isPartial || !result.degradationNotes.isEmpty
        let status: ResearchSessionStatus
        let isUnviewed: Bool
        if wasCancelled {
            status = .cancelled
            isUnviewed = !result.reportMarkdown.isEmpty
        } else {
            status = isPartial ? .completedPartial : .completed
            isUnviewed = true
        }

        var completed = CompletedRun(
            result: result,
            status: status,
            completedAt: .now,
            isUnviewed: isUnviewed,
            checkpoint: checkpoint
        )
        completed.apply(to: session)

        do {
            try modelContext.map { try saveHandler($0) }
        } catch {
            // Keep the result on the coordinator, not just as unsaved changes
            // on the shared context another component may roll back, and
            // retry it later. Say so instead of announcing a completion that
            // isn't durable.
            Self.logger.error("Could not save research result: \(String(describing: error))")
            completed.saveFailureMessage = """
                The report couldn't be saved yet: \(error.localizedDescription) SwiftClaw \
                will try again automatically; use Save to Notes to keep a copy now.
                """
            completed.apply(to: session)
            unsavedResults[session.id] = completed
            return
        }

        if !wasCancelled {
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
            try saveHandler(modelContext)
        } catch {
            Self.logger.error("Could not save research session: \(String(describing: error))")
        }
    }

    private static func isRunningFamily(_ status: ResearchSessionStatus) -> Bool {
        status == .running || status == .planning || status == .clarifying
    }
}

/// Everything a finished run writes onto its session, held as a value so the
/// coordinator can re-apply it after the shared context rolls back.
private nonisolated struct CompletedRun {
    let result: DeepResearchRunResult
    let status: ResearchSessionStatus
    let completedAt: Date
    /// Only ever goes from unviewed to viewed, so re-applying the result
    /// never marks a report the user already opened as unread again.
    private(set) var isUnviewed: Bool
    let checkpoint: ResearchSessionCheckpoint
    /// The session's `errorMessage` while the result isn't durable.
    var saveFailureMessage: String?

    /// Records that the user opened the report since it was applied
    /// (`markViewed` clears the session's flag).
    @MainActor
    mutating func noteViewedState(of session: ResearchSession) {
        if isUnviewed, !session.isUnviewed, isApplied(to: session) {
            isUnviewed = false
        }
    }

    @MainActor
    func apply(to session: ResearchSession) {
        session.reportMarkdown = result.reportMarkdown
        session.sources = result.sources
        session.evidence = result.evidence
        session.openQuestions = result.openQuestions
        session.unverifiedClaimCount = result.unverifiedClaimCount
        session.completedAt = completedAt
        session.errorMessage = saveFailureMessage
        session.progress = checkpoint
        session.status = status
        session.isUnviewed = isUnviewed
    }

    /// Whether `session` still shows this result (no rollback reverted it).
    @MainActor
    func isApplied(to session: ResearchSession) -> Bool {
        session.status == status
            && session.reportMarkdown == result.reportMarkdown
            && session.errorMessage == saveFailureMessage
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
