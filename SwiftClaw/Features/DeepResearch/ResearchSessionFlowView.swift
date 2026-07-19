import SwiftData
import SwiftUI

/// Drives one session through its lifecycle: clarify → plan review → running
/// → report. Each status renders its own screen; the coordinator owns every
/// transition.
struct ResearchSessionFlowView: View {
    @Bindable var session: ResearchSession

    var body: some View {
        content
            .navigationTitle(session.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
    }

    @ViewBuilder
    private var content: some View {
        switch session.status {
        case .pending, .clarifying:
            ResearchClarifyView(session: session)
        case .planning:
            ResearchWaitingView(
                title: "Planning the research…",
                detail: session.topic
            )
        case .awaitingPlanApproval:
            ResearchPlanReviewView(session: session)
        case .running:
            ResearchRunningView(session: session)
        case .completed, .completedPartial:
            ResearchReportView(session: session)
        case .cancelled:
            if session.reportMarkdown?.isEmpty == false {
                ResearchReportView(session: session)
            } else {
                ResearchStoppedView(session: session)
            }
        case .failed:
            ResearchFailedView(session: session)
        }
    }
}

// MARK: - Clarify

/// Up to three optional questions from the Research Model. "Skip" is always
/// visible and never blocked on the questions loading — being able to bail
/// out of the smart step is the accessibility baseline here.
private struct ResearchClarifyView: View {
    let session: ResearchSession

    @State private var questions: [String]?
    @State private var answers: [String] = []
    @State private var isSubmitting = false

    var body: some View {
        Form {
            Section {
                Text(session.topic)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Topic")
            }

            if let questions, !questions.isEmpty {
                Section {
                    ForEach(questions.indices, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(questions[index])
                            TextField("Optional answer", text: binding(for: index))
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel(questions[index])
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("A few questions first")
                } footer: {
                    Text("Answers sharpen the plan. Leave any blank.")
                }
            } else if questions == nil {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Checking whether anything needs clarifying…")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Button {
                    submit(usingAnswers: true)
                } label: {
                    Label("Continue", systemImage: "arrow.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSubmitting || questions == nil)
                .accessibilityIdentifier("research.clarify.continue")

                Button("Skip — research as asked") {
                    submit(usingAnswers: false)
                }
                .disabled(isSubmitting)
                .accessibilityIdentifier("research.clarify.skip")
            }
        }
        .formStyle(.grouped)
        .task(id: session.id) {
            await loadQuestions()
        }
    }

    private func binding(for index: Int) -> Binding<String> {
        Binding(
            get: { index < answers.count ? answers[index] : "" },
            set: { newValue in
                while answers.count <= index {
                    answers.append("")
                }
                answers[index] = newValue
            }
        )
    }

    private func loadQuestions() async {
        guard questions == nil else { return }
        let engine = ResearchEngine(configuration: .deepResearch())
        let loaded = await engine.clarifyingQuestions(topic: session.topic)
        guard !Task.isCancelled else { return }
        questions = loaded
        answers = Array(repeating: "", count: loaded.count)
        if loaded.isEmpty {
            // Nothing to ask — go straight to planning.
            submit(usingAnswers: false)
        }
    }

    private func submit(usingAnswers: Bool) {
        guard !isSubmitting else { return }
        isSubmitting = true
        var clarifications = [ResearchClarification]()
        if usingAnswers, let questions {
            clarifications = zip(questions, answers)
                .map { ResearchClarification(question: $0, answer: $1.trimmingCharacters(in: .whitespacesAndNewlines)) }
                .filter { !$0.answer.isEmpty }
        }
        let coordinator = ResearchSessionCoordinator.shared
        coordinator.submitClarifications(session: session, answers: clarifications)
        Task {
            await coordinator.generatePlan(session: session)
        }
    }
}

// MARK: - Plan review

/// The editable plan gate: overview and sub-questions can be reworded,
/// removed, or added before anything is spent. This screen doubles as the
/// cost preview — no quotas, just an honest estimate.
private struct ResearchPlanReviewView: View {
    let session: ResearchSession

    @State private var editedPlan: ResearchPlan?

    var body: some View {
        Form {
            if var plan = editedPlan {
                Section {
                    TextField(
                        "Overview",
                        text: Binding(
                            get: { plan.overview },
                            set: { plan.overview = $0; editedPlan = plan }
                        ),
                        axis: .vertical
                    )
                    .lineLimit(2...5)
                } header: {
                    Text("What this run is about")
                }

                Section {
                    ForEach(plan.threads.indices, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 6) {
                            TextField(
                                "Question",
                                text: Binding(
                                    get: { plan.threads[index].question },
                                    set: { plan.threads[index].question = $0; editedPlan = plan }
                                ),
                                axis: .vertical
                            )
                            TextField(
                                "Search query",
                                text: Binding(
                                    get: { plan.threads[index].query },
                                    set: { plan.threads[index].query = $0; editedPlan = plan }
                                )
                            )
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Search query for question \(index + 1)")
                        }
                        .padding(.vertical, 2)
                    }
                    .onDelete { offsets in
                        plan.threads.remove(atOffsets: offsets)
                        editedPlan = plan
                    }

                    Button("Add a question", systemImage: "plus") {
                        plan.threads.append(ResearchThreadPlan(question: "", query: ""))
                        editedPlan = plan
                    }
                    .accessibilityIdentifier("research.plan.addThread")
                } header: {
                    Text("Questions to research")
                } footer: {
                    Text("""
                        Edit, remove, or add questions — the run follows this \
                        list. Expect roughly 10–20 minutes and up to 60 \
                        searches with your keys.
                        """)
                }

                Section {
                    Button {
                        startRun(with: plan)
                    } label: {
                        Label("Start Research", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(usableThreads(in: plan).isEmpty || isAnotherRunActive)
                    .accessibilityIdentifier("research.plan.start")
                } footer: {
                    if isAnotherRunActive {
                        Text("Another research session is running. Wait for it to finish, or stop it first — one run at a time.")
                    }
                }
            } else {
                Section {
                    Text("The saved plan could not be loaded.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if editedPlan == nil {
                editedPlan = session.planPayload?.plan
            }
        }
    }

    private var isAnotherRunActive: Bool {
        let running = ResearchSessionCoordinator.shared.runningSessionID
        return running != nil && running != session.id
    }

    private func usableThreads(in plan: ResearchPlan) -> [ResearchThreadPlan] {
        plan.threads.filter {
            !$0.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func startRun(with plan: ResearchPlan) {
        var approved = plan
        approved.threads = usableThreads(in: plan)
        ResearchSessionCoordinator.shared.startRun(session: session, approvedPlan: approved)
    }
}

// MARK: - Running

/// Stage timeline plus the live activity feed. Everything here reads from
/// `ResearchProgressMonitor`; if the app relaunched mid-run the coordinator
/// already remapped the session, so this view only ever shows a live run.
private struct ResearchRunningView: View {
    let session: ResearchSession

    @State private var monitor = ResearchProgressMonitor.shared
    @State private var isConfirmingCancel = false

    private static let stages: [(ResearchStage, String, String)] = [
        (.planning, "Planning", "list.bullet.clipboard"),
        (.searching, "Searching", "magnifyingglass"),
        (.reading, "Reading", "doc.text"),
        (.crossChecking, "Cross-checking", "checkmark.shield"),
        (.writing, "Writing", "pencil.line"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                stageTimeline

                if monitor.sourceCount > 0 {
                    Label("\(monitor.sourceCount) sources so far", systemImage: "books.vertical")
                        .foregroundStyle(.secondary)
                }

                elapsedView

                if !monitor.activityFeed.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Activity")
                            .font(.headline)
                        ForEach(Array(monitor.activityFeed.suffix(8).enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Recent activity")
                }

                Button("Stop research", systemImage: "stop.fill", role: .destructive) {
                    isConfirmingCancel = true
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("research.running.stop")
                .confirmationDialog(
                    "Stop this research run?",
                    isPresented: $isConfirmingCancel,
                    titleVisibility: .visible
                ) {
                    Button("Stop and keep partial results", role: .destructive) {
                        ResearchSessionCoordinator.shared.cancel(session: session)
                    }
                    Button("Keep researching", role: .cancel) {}
                } message: {
                    Text("Everything gathered so far is kept and written up.")
                }
            }
            .padding(20)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var stageTimeline: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Self.stages, id: \.0) { stage, label, icon in
                HStack(spacing: 12) {
                    stageIndicator(for: stage, icon: icon)
                        .frame(width: 22)
                    Text(label)
                        .fontWeight(stage == monitor.stage ? .semibold : .regular)
                        .foregroundStyle(stageState(for: stage) == .upcoming ? .secondary : .primary)
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(label): \(accessibilityState(for: stage))")
            }
        }
    }

    private enum StageState {
        case done, current, upcoming
    }

    private func stageState(for stage: ResearchStage) -> StageState {
        guard let current = monitor.stage,
              let currentIndex = Self.stages.firstIndex(where: { $0.0 == current }),
              let stageIndex = Self.stages.firstIndex(where: { $0.0 == stage }) else {
            return .upcoming
        }
        if stageIndex < currentIndex { return .done }
        if stageIndex == currentIndex { return .current }
        return .upcoming
    }

    @ViewBuilder
    private func stageIndicator(for stage: ResearchStage, icon: String) -> some View {
        switch stageState(for: stage) {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.accentColor)
        case .current:
            ProgressView()
                .controlSize(.small)
        case .upcoming:
            Image(systemName: icon)
                .foregroundStyle(.tertiary)
        }
    }

    private func accessibilityState(for stage: ResearchStage) -> String {
        switch stageState(for: stage) {
        case .done: "done"
        case .current: "in progress"
        case .upcoming: "not started"
        }
    }

    @ViewBuilder
    private var elapsedView: some View {
        if let startedAt = monitor.startedAt, let budget = monitor.budgetDuration {
            TimelineView(.periodic(from: startedAt, by: 1)) { timeline in
                let elapsed = timeline.date.timeIntervalSince(startedAt)
                let total = Double(budget.components.seconds)
                ProgressView(value: min(elapsed, total), total: total) {
                    Text("Elapsed \(Self.minutes(elapsed)) of about \(Self.minutes(total))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }

    private static func minutes(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond))
    }
}

// MARK: - Waiting / terminal states

private struct ResearchWaitingView: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ResearchStoppedView: View {
    let session: ResearchSession
    @Environment(\.modelContext) private var modelContext

    private var isAnotherRunActive: Bool {
        let running = ResearchSessionCoordinator.shared.runningSessionID
        return running != nil && running != session.id
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "stop.circle")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Research stopped")
                .font(.headline)
            Text("Nothing was written up before the stop.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if session.progress?.canResume == true, session.planPayload != nil {
                Button("Resume research", systemImage: "play.fill") {
                    resume()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isAnotherRunActive)
                .accessibilityIdentifier("research.stopped.resume")
                if isAnotherRunActive {
                    Text("Another research session is running — one run at a time.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: markViewed)
    }

    private func markViewed() {
        guard session.isUnviewed else { return }
        session.isUnviewed = false
        try? modelContext.save()
    }

    private func resume() {
        guard let plan = session.planPayload?.plan else { return }
        ResearchSessionCoordinator.shared.startRun(session: session, approvedPlan: plan)
    }
}

private struct ResearchFailedView: View {
    let session: ResearchSession
    @Environment(\.modelContext) private var modelContext

    private var isAnotherRunActive: Bool {
        let running = ResearchSessionCoordinator.shared.runningSessionID
        return running != nil && running != session.id
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "xmark.circle")
                .font(.system(size: 40))
                .foregroundStyle(.red)
            Text("Research failed")
                .font(.headline)
            if let message = session.errorMessage {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if session.planPayload != nil {
                Button("Try again", systemImage: "arrow.clockwise") {
                    retry()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isAnotherRunActive)
                .accessibilityIdentifier("research.failed.retry")
            } else {
                // Planning itself failed — the session has no saved plan yet,
                // so offer to plan again rather than stranding it.
                Button("Try planning again", systemImage: "arrow.clockwise") {
                    retryPlanning()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("research.failed.retryPlanning")
            }
            if isAnotherRunActive {
                Text("Another research session is running — one run at a time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: markViewed)
    }

    private func markViewed() {
        guard session.isUnviewed else { return }
        session.isUnviewed = false
        try? modelContext.save()
    }

    private func retry() {
        guard let plan = session.planPayload?.plan else { return }
        ResearchSessionCoordinator.shared.startRun(session: session, approvedPlan: plan)
    }

    private func retryPlanning() {
        let coordinator = ResearchSessionCoordinator.shared
        Task {
            await coordinator.generatePlan(session: session)
        }
    }
}
