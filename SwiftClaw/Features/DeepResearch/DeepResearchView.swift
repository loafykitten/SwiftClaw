import SwiftData
import SwiftUI

/// The Research tab: durable Deep Research sessions in a list/detail layout.
///
/// macOS uses an `HSplitView` (nesting a `NavigationSplitView` inside
/// `ContentView`'s outer split breaks column layout — same lesson as
/// `NotesView`); iOS uses a feature-owned `NavigationStack` at every size
/// class, per the plan's "macOS split view; iOS stack", which also lets
/// notification taps push programmatically.
struct DeepResearchView: View {
    @Query(sort: \ResearchSession.createdAt, order: .reverse)
    private var sessions: [ResearchSession]

    @State private var selectedSessionID: UUID?
    @State private var isShowingNewSessionSheet = false
    @State private var sessionPendingDeletion: ResearchSession?
    #if os(iOS)
    @State private var navigationPath: [UUID] = []
    #endif
    @State private var router = AppRouter.shared

    var body: some View {
        layout
            .sheet(isPresented: $isShowingNewSessionSheet) {
                NewResearchSessionSheet { session in
                    select(session.id)
                }
            }
            .confirmationDialog(
                "Delete this research?",
                isPresented: Binding(
                    get: { sessionPendingDeletion != nil },
                    set: { if !$0 { sessionPendingDeletion = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let session = sessionPendingDeletion {
                        delete(session)
                    }
                    sessionPendingDeletion = nil
                }
                Button("Cancel", role: .cancel) {
                    sessionPendingDeletion = nil
                }
            } message: {
                if sessionPendingDeletion?.status == .running {
                    Text("The run is still in progress; deleting stops it and discards the report.")
                } else {
                    Text("The report and its sources are removed permanently.")
                }
            }
            .onAppear(perform: consumePendingRoute)
            .onChange(of: router.pendingResearchSessionID) { _, _ in
                consumePendingRoute()
            }
            .onChange(of: sessions.map(\.id)) { _, _ in
                // The route may arrive before @Query has the row (cold
                // launch); retry once the store catches up.
                consumePendingRoute()
            }
    }

    @ViewBuilder
    private var layout: some View {
        #if os(macOS)
        HSplitView {
            sessionList
                .frame(minWidth: 220, idealWidth: 270, maxWidth: 360)
            detailColumn
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar { newSessionToolbarItem }
        #else
        NavigationStack(path: $navigationPath) {
            List {
                ForEach(sessions) { session in
                    NavigationLink(value: session.id) {
                        ResearchSessionRow(session: session)
                    }
                    .swipeActions(edge: .trailing) {
                        deleteButton(for: session)
                    }
                }
            }
            .navigationDestination(for: UUID.self) { sessionID in
                if let session = sessions.first(where: { $0.id == sessionID }) {
                    ResearchSessionFlowView(session: session)
                } else {
                    missingSessionView
                }
            }
            .overlay {
                if sessions.isEmpty {
                    emptyStateView
                }
            }
            .navigationTitle("Research")
            .toolbar { newSessionToolbarItem }
        }
        #endif
    }

    // MARK: - macOS list/detail

    #if os(macOS)
    private var sessionList: some View {
        List(selection: $selectedSessionID) {
            ForEach(sessions) { session in
                ResearchSessionRow(session: session)
                    .tag(session.id)
                    .contextMenu {
                        deleteButton(for: session)
                    }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if sessions.isEmpty {
                Text("No research yet")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityLabel("Research sessions")
    }

    @ViewBuilder
    private var detailColumn: some View {
        if let session = sessions.first(where: { $0.id == selectedSessionID }) {
            ResearchSessionFlowView(session: session)
        } else {
            emptyStateView
        }
    }
    #endif

    // MARK: - Empty states

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Deep Research")
                .font(.title2)
                .fontWeight(.semibold)
            Text("Ask a question and get back a cited, source-checked report.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("New Research", systemImage: "plus") {
                isShowingNewSessionSheet = true
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("research.empty.new")
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var missingSessionView: some View {
        Text("This research session was deleted.")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private var newSessionToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button("New Research", systemImage: "plus") {
                isShowingNewSessionSheet = true
            }
            .accessibilityIdentifier("research.new")
        }
    }

    private func deleteButton(for session: ResearchSession) -> some View {
        Button("Delete", systemImage: "trash", role: .destructive) {
            sessionPendingDeletion = session
        }
        .accessibilityLabel("Delete research \(session.title)")
    }

    private func delete(_ session: ResearchSession) {
        if selectedSessionID == session.id {
            selectedSessionID = nil
        }
        #if os(iOS)
        navigationPath.removeAll { $0 == session.id }
        #endif
        ResearchSessionCoordinator.shared.deleteSession(session: session)
    }

    private func select(_ sessionID: UUID) {
        selectedSessionID = sessionID
        #if os(iOS)
        navigationPath = [sessionID]
        #endif
    }

    /// Lands a completion-notification tap (or any programmatic route) on the
    /// right session. The pending ID is only cleared once the session is
    /// actually selectable, so a route that arrives before the query has the
    /// row survives until `sessions` catches up.
    private func consumePendingRoute() {
        guard let pending = router.pendingResearchSessionID,
              sessions.contains(where: { $0.id == pending }) else { return }
        router.clearPendingResearchSession()
        select(pending)
    }
}

/// One session in the list: status at a glance, title, and relative date.
private struct ResearchSessionRow: View {
    let session: ResearchSession

    var body: some View {
        HStack(spacing: 10) {
            statusIcon
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .lineLimit(2)
                Text(session.createdAt.formatted(.relative(presentation: .named)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if session.isUnviewed {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        var parts = [
            session.title,
            statusDescription,
            session.createdAt.formatted(.relative(presentation: .named)),
        ]
        if session.isUnviewed {
            parts.append("unviewed")
        }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch session.status {
        case .running, .planning, .clarifying:
            ProgressView()
                .controlSize(.small)
        case .pending, .awaitingPlanApproval:
            Image(systemName: "circle.dashed")
                .foregroundStyle(.secondary)
        case .completed:
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.green)
        case .completedPartial:
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        case .cancelled:
            Image(systemName: "stop.circle")
                .foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "xmark.circle")
                .foregroundStyle(.red)
        }
    }

    private var statusDescription: String {
        switch session.status {
        case .pending: "not started"
        case .clarifying: "clarifying"
        case .planning: "planning"
        case .awaitingPlanApproval: "plan ready for review"
        case .running: "researching"
        case .completed: "complete"
        case .completedPartial: "complete with partial results"
        case .failed: "failed"
        case .cancelled: "stopped"
        }
    }
}

/// Topic entry. The session is only created when the user continues, so
/// dismissing leaves no orphan rows.
private struct NewResearchSessionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var topic = ""
    let onCreated: (ResearchSession) -> Void

    private var trimmedTopic: String {
        topic.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(
                        "What should be researched?",
                        text: $topic,
                        axis: .vertical
                    )
                    .lineLimit(3...6)
                    .accessibilityIdentifier("research.topic")
                } footer: {
                    Text("""
                        Deep Research reads full pages and cross-checks \
                        claims. A run takes roughly 10–20 minutes and can \
                        make up to 60 searches with your Brave key.
                        """)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("New Research")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue") {
                        let session = ResearchSessionCoordinator.shared
                            .createSession(topic: trimmedTopic)
                        dismiss()
                        onCreated(session)
                    }
                    .disabled(trimmedTopic.isEmpty)
                    .accessibilityIdentifier("research.topic.continue")
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 260)
        #endif
    }
}
