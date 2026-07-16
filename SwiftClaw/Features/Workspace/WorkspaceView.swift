import SwiftData
import SwiftUI

private enum WorkspaceItem: String, CaseIterable, Hashable, Identifiable {
    case email = "Email"
    case calendar = "Calendar"
    case reminders = "Reminders"
    case notes = "Notes"
    case memory = "Memory"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .email: "envelope"
        case .calendar: "calendar"
        case .reminders: "checklist"
        case .notes: "note.text"
        case .memory: "brain"
        }
    }

    /// The toggleable feature backing this item; `nil` for always-on items.
    var feature: WorkspaceFeature? {
        switch self {
        case .email: .email
        case .calendar: .calendar
        case .reminders: .reminders
        case .notes: .notes
        case .memory: nil
        }
    }
}

/// A hub listing the workspace features; selecting one pushes it. A single
/// stack (rather than a nested split view) keeps the chrome sane on every
/// platform — the app-level sidebar or tab bar is the only outer navigation.
struct WorkspaceView: View {
    var pendingEmailID: UUID?
    var onEmailPresented: () -> Void = {}
    var pendingCalendarFocus = false
    var onCalendarPresented: () -> Void = {}
    var pendingReminderFocusID: UUID?
    var onReminderPresented: () -> Void = {}

    @Query(sort: \Email.date, order: .reverse)
    private var emails: [Email]
    @AppStorage(SettingsKeys.emailEnabled) private var isEmailEnabled = SettingsStorage.defaultEmailEnabled
    @AppStorage(SettingsKeys.calendarEnabled) private var isCalendarEnabled = SettingsStorage.defaultCalendarEnabled
    @AppStorage(SettingsKeys.remindersEnabled) private var isRemindersEnabled = SettingsStorage.defaultRemindersEnabled
    @AppStorage(SettingsKeys.notesEnabled) private var isNotesEnabled = SettingsStorage.defaultNotesEnabled

    @State private var navigationPath = NavigationPath()
    @State private var hasAppliedLaunchSelection = false
    @State private var notesModel = NotesFeatureModel.shared
    @State private var hasActivatedNotesModel = false
    @State private var isShowingNotesQuickCapture = false

    private var visibleItems: [WorkspaceItem] {
        WorkspaceItem.allCases.filter { item in
            item.feature.map(isFeatureEnabled) ?? true
        }
    }

    private var disabledFeatures: [WorkspaceFeature] {
        WorkspaceFeature.allCases.filter { !isFeatureEnabled($0) }
    }

    private func isFeatureEnabled(_ feature: WorkspaceFeature) -> Bool {
        switch feature {
        case .email: isEmailEnabled
        case .calendar: isCalendarEnabled
        case .reminders: isRemindersEnabled
        case .notes: isNotesEnabled
        }
    }

    private var widgetColumns: [GridItem] {
        #if os(iOS)
        [GridItem(.adaptive(minimum: 220), spacing: 16)]
        #else
        [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 16)]
        #endif
    }

    var body: some View {
        let emailContent = WorkspaceEmailWidgetContent(
            emails: emails,
            accounts: EmailAccountStore.shared.accounts
        )

        NavigationStack(path: $navigationPath) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    LazyVGrid(
                        columns: widgetColumns,
                        alignment: .leading,
                        spacing: 16
                    ) {
                        ForEach(visibleItems) { item in
                            ZStack(alignment: .topTrailing) {
                                NavigationLink(value: item) {
                                    WorkspaceWidgetPanel(
                                        item: item,
                                        emailContent: emailContent,
                                        notesModel: notesModel
                                    )
                                }
                                .buttonStyle(.plain)

                                if item == .notes {
                                    Button {
                                        isShowingNotesQuickCapture = true
                                    } label: {
                                        Label("Quick Capture", systemImage: "bolt.fill")
                                            .labelStyle(.iconOnly)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .padding(12)
                                    .disabled(notesModel.configurationState != .configured)
                                    .help("Quick Capture to Notes")
                                    .accessibilityLabel("Quick Capture to Notes")
                                    .accessibilityIdentifier("workspace.notes.quickCapture")
                                }
                            }
                        }
                    }

                    if !disabledFeatures.isEmpty {
                        WorkspaceDisabledFeaturesList(features: disabledFeatures)
                    }
                }
                .padding(20)
            }
            .navigationTitle("Workspace")
            .navigationDestination(for: WorkspaceItem.self) { item in
                destination(for: item)
                    .navigationTitle(item.rawValue)
            }
        }
        .onAppear(perform: prepareSelection)
        .onChange(of: pendingEmailID) { _, _ in
            prepareSelection()
        }
        .onChange(of: pendingCalendarFocus) { _, _ in
            prepareSelection()
        }
        .onChange(of: pendingReminderFocusID) { _, _ in
            prepareSelection()
        }
        .task(id: isNotesEnabled) {
            if isNotesEnabled, !hasActivatedNotesModel {
                hasActivatedNotesModel = true
                await notesModel.activate()
            } else if !isNotesEnabled, hasActivatedNotesModel {
                notesModel.deactivate()
                hasActivatedNotesModel = false
            }
        }
        .onDisappear {
            guard hasActivatedNotesModel else { return }
            notesModel.deactivate()
            hasActivatedNotesModel = false
        }
        .sheet(isPresented: $isShowingNotesQuickCapture) {
            NotesQuickCaptureSheet(model: notesModel)
        }
    }

    @ViewBuilder
    private func destination(for item: WorkspaceItem) -> some View {
        switch item {
        case .email:
            EmailView(
                pendingEmailID: pendingEmailID,
                openCompactThread: openEmailThread,
                onPendingEmailHandled: onEmailPresented
            )
        case .calendar:
            CalendarView()
        case .reminders:
            RemindersView(
                focusReminderID: pendingReminderFocusID,
                onFocusHandled: onReminderPresented
            )
        case .notes:
            NotesView()
        case .memory:
            MemoryView()
        }
    }

    private func prepareSelection() {
        #if DEBUG
        if !hasAppliedLaunchSelection,
           let requestedItem = ProcessInfo.processInfo.argumentValue(after: "-SwiftClawInitialWorkspaceItem"),
           let item = WorkspaceItem(launchArgument: requestedItem),
           visibleItems.contains(item) {
            hasAppliedLaunchSelection = true
            navigate(to: item)
            return
        }
        hasAppliedLaunchSelection = true
        #endif

        if pendingEmailID != nil, isEmailEnabled {
            navigate(to: .email)
        } else if pendingCalendarFocus, isCalendarEnabled {
            navigate(to: .calendar)
            onCalendarPresented()
        } else if pendingReminderFocusID != nil, isRemindersEnabled {
            // RemindersView clears the focus once it has applied the
            // selection, so the ID stays available while the view appears.
            navigate(to: .reminders)
        }
    }

    private func navigate(to item: WorkspaceItem) {
        var path = NavigationPath()
        path.append(item)
        navigationPath = path
    }

    private func openEmailThread(mailbox: EmailMailbox, threadID: UUID) {
        var path = NavigationPath()
        path.append(WorkspaceItem.email)
        path.append(mailbox)
        path.append(threadID)
        navigationPath = path
    }
}

#if DEBUG
private extension WorkspaceItem {
    init?(launchArgument: String) {
        switch launchArgument.lowercased().filter(\.isLetter) {
        case "email", "mail":
            self = .email
        case "calendar":
            self = .calendar
        case "reminder", "reminders":
            self = .reminders
        case "note", "notes":
            self = .notes
        case "memory":
            self = .memory
        default:
            return nil
        }
    }
}
#endif

#Preview {
    WorkspaceView()
}

/// Disabled features listed under the widget grid; tapping one opens
/// Settings › Tools scrolled to that feature's row with a brief outline.
private struct WorkspaceDisabledFeaturesList: View {
    let features: [WorkspaceFeature]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("More features")
                    .font(.headline)
                Text("Tap a feature to enable it in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(features) { feature in
                AppSettingsButton(section: .tools, highlightToolsFeature: feature) {
                    HStack(spacing: 10) {
                        Image(systemName: feature.systemImage)
                            .foregroundStyle(.secondary)
                            .frame(width: 24)

                        Text(feature.displayName)
                            .font(.subheadline)

                        Spacer(minLength: 0)

                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .glassEffect(in: .rect(cornerRadius: 10.0))
                    .contentShape(.rect(cornerRadius: 10.0))
                }
                .buttonStyle(.plain)
                .help("Enable \(feature.displayName) in Settings › Tools")
                .accessibilityLabel("Enable \(feature.displayName)")
            }
        }
        .frame(maxWidth: 480, alignment: .leading)
    }
}

private struct WorkspaceWidgetPanel: View {
    let item: WorkspaceItem
    let emailContent: WorkspaceEmailWidgetContent
    let notesModel: NotesFeatureModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: item.systemImage)
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 28, height: 28)

                Text(item.rawValue)
                    .font(.headline)
                    .lineLimit(1)

                Spacer(minLength: 0)

                if item == .email {
                    Text(accountCountLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            switch item {
            case .email:
                WorkspaceEmailStatsView(summary: emailContent.summary)
            case .calendar:
                WorkspaceCalendarStatsView()
            case .reminders:
                WorkspaceRemindersStatsView()
            case .notes:
                WorkspaceNotesStatsView(model: notesModel)
            case .memory:
                Text("Coming soon")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .padding(18)
        .glassEffect(in: .rect(cornerRadius: 16.0))
        .contentShape(.rect(cornerRadius: 16.0))
        .accessibilityElement(children: .combine)
    }

    private var accountCountLabel: String {
        let count = emailContent.completeAccountCount
        return "\(count) \(count == 1 ? "account" : "accounts")"
    }
}

/// Notes widget body: live catalog size, the durable quick-capture count for
/// today, and a compact health state. The shared feature model owns the only
/// vault watcher; Workspace never creates a second repository.
private struct WorkspaceNotesStatsView: View {
    let model: NotesFeatureModel
    @State private var captureVersion = 0

    var body: some View {
        Group {
            switch model.configurationState {
            case .unknown:
                ProgressView("Loading Notes…")
            case .needsOnboarding:
                Text("Choose a vault in Notes")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            case .configured:
                stats
            }
        }
        .task(id: model.configurationState) {
            guard model.configurationState == .configured else { return }
            await model.refreshCatalog()
            await model.refreshHealth()
        }
        .onReceive(NotificationCenter.default.publisher(for: .notesQuickCaptureDidChange)) { _ in
            captureVersion += 1
        }
    }

    private var stats: some View {
        let summary = WorkspaceNotesSummary(
            notes: model.notes,
            capturedTodayCount: model.capturedTodayCount(),
            healthSummary: model.healthSummary
        )

        return VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                GridRow(alignment: .firstTextBaseline) {
                    WorkspaceEmailStatTile(count: summary.noteCount, label: "Notes")
                    WorkspaceEmailStatTile(count: summary.capturedTodayCount, label: "Captured Today")
                }
            }

            Label(healthLabel(summary.health), systemImage: healthImage(summary.health))
                .font(.caption)
                .foregroundStyle(
                    summary.health == .healthy
                        ? AnyShapeStyle(.secondary)
                        : AnyShapeStyle(.orange)
                )
                .accessibilityIdentifier("workspace.notes.health")
        }
        .id(captureVersion)
        .accessibilityIdentifier("workspace.notes.stats")
    }

    private func healthLabel(_ health: WorkspaceNotesSummary.Health) -> String {
        switch health {
        case .healthy: "Vault healthy"
        case .warning: "Vault needs attention"
        case .unavailable: "Health unavailable"
        }
    }

    private func healthImage(_ health: WorkspaceNotesSummary.Health) -> String {
        switch health {
        case .healthy: "checkmark.circle"
        case .warning: "exclamationmark.triangle"
        case .unavailable: "questionmark.circle"
        }
    }
}

/// Calendar widget body: today / tomorrow / week counts plus a "next event"
/// footer. `@Query` keeps it live as events change; the summary itself is the
/// testable `WorkspaceCalendarSummary`.
private struct WorkspaceCalendarStatsView: View {
    @Query private var events: [CalendarEvent]

    var body: some View {
        let calendar = Calendar.current
        let now = Date.now
        let start = calendar.startOfDay(for: now)
        let window = DateInterval(start: start, duration: 7 * 24 * 3600)
        let summary = WorkspaceCalendarSummary(
            occurrences: CalendarOccurrenceBuilder.occurrences(from: events, in: window),
            now: now,
            calendar: calendar
        )

        VStack(alignment: .leading, spacing: 12) {
            // 2×2 like the Email card so the two panels line up in the grid;
            // the fourth cell stays empty until there's a fourth stat.
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                GridRow(alignment: .firstTextBaseline) {
                    WorkspaceEmailStatTile(count: summary.todayRemainingCount, label: "Today")
                    WorkspaceEmailStatTile(count: summary.tomorrowCount, label: "Tomorrow")
                }
                GridRow(alignment: .firstTextBaseline) {
                    WorkspaceEmailStatTile(count: summary.weekCount, label: "This Week")
                    Color.clear
                        .gridCellUnsizedAxes([.horizontal, .vertical])
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                if let next = summary.nextEvent {
                    Text(next.title)
                        .lineLimit(1)
                    if next.start > now {
                        Text("in \(Text(next.start, style: .relative))")
                    } else {
                        Text("happening now")
                    }
                } else {
                    Text("Nothing scheduled this week")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

/// Reminders widget body: today / overdue / week / flagged counts plus a
/// "next deadline" footer. `@Query` keeps it live as reminders change; the
/// summary itself is the testable `WorkspaceRemindersSummary`.
private struct WorkspaceRemindersStatsView: View {
    /// Masters and one-offs only — the summary never counts completion-log
    /// history, which grows unbounded.
    @Query(filter: #Predicate<Reminder> { $0.parentReminderID == nil })
    private var reminders: [Reminder]

    var body: some View {
        // Minute ticks keep the counts honest while Workspace sits open —
        // deadlines cross into Overdue (and Today rolls at midnight) without
        // waiting for a store change to re-render.
        TimelineView(.everyMinute) { timeline in
            stats(now: timeline.date)
        }
    }

    private func stats(now: Date) -> some View {
        let summary = WorkspaceRemindersSummary(
            reminders: reminders,
            now: now,
            calendar: .current
        )

        return VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                GridRow(alignment: .firstTextBaseline) {
                    WorkspaceEmailStatTile(count: summary.todayCount, label: "Today")
                    WorkspaceEmailStatTile(count: summary.overdueCount, label: "Overdue")
                }
                GridRow(alignment: .firstTextBaseline) {
                    WorkspaceEmailStatTile(count: summary.weekCount, label: "This Week")
                    WorkspaceEmailStatTile(count: summary.flaggedCount, label: "Flagged")
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                if let next = summary.nextReminder {
                    Text(next.title)
                        .lineLimit(1)
                    if next.due > now {
                        Text("due in \(Text(next.due, style: .relative))")
                    } else {
                        Text("due now")
                    }
                } else if summary.todayCount > 0 {
                    Text("\(summary.todayCount) to finish today")
                } else {
                    Text("Nothing due soon")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

private struct WorkspaceEmailStatsView: View {
    let summary: WorkspaceEmailSummary

    /// Bumped when Settings posts `emailReviewScheduleDidChange` or a review
    /// pass posts `emailReviewCompletionDidChange` so the footer re-reads the
    /// schedule from UserDefaults — otherwise the view only re-renders when
    /// the `@Query` email data changes, so an interval edit in Settings (or a
    /// review that surfaced nothing) wouldn't move "Reviewed"/"Next review".
    @State private var scheduleVersion = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                GridRow(alignment: .firstTextBaseline) {
                    WorkspaceEmailStatTile(count: summary.unreadCount, label: "Unread")
                    WorkspaceEmailStatTile(count: summary.inboxThreadCount, label: "Inbox")
                }
                GridRow(alignment: .firstTextBaseline) {
                    WorkspaceEmailStatTile(count: summary.flaggedThreadCount, label: "Flagged")
                    WorkspaceEmailStatTile(count: summary.notatedThreadCount, label: "Notated")
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                if let reviewedAt = SettingsStorage.loadEmailLastReviewCompletedAt() {
                    Text("Reviewed \(Text(reviewedAt, style: .relative)) ago")
                }
                let nextReview = SettingsStorage.nextEmailReviewDate()
                if nextReview > .now {
                    Text("Next review in \(Text(nextReview, style: .relative))")
                } else {
                    Text("Review due")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .id(scheduleVersion)
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: SettingsNotifications.emailReviewScheduleDidChange
            )
        ) { _ in
            scheduleVersion += 1
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: SettingsNotifications.emailReviewCompletionDidChange
            )
        ) { _ in
            scheduleVersion += 1
        }
    }
}

private struct WorkspaceEmailStatTile: View {
    let count: Int
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(count, format: .number)
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(count == 0 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .gridColumnAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count) \(label)")
    }
}
