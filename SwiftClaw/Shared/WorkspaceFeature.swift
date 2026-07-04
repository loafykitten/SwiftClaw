import Foundation

/// A toggleable Workspace feature. Order matches the Features section in
/// Settings › Tools and the disabled-features list at the bottom of Workspace.
enum WorkspaceFeature: String, CaseIterable, Hashable, Identifiable {
    case email
    case calendar
    case reminders
    case notes

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .email: "Email"
        case .calendar: "Calendar"
        case .reminders: "Reminders"
        case .notes: "Notes"
        }
    }

    var systemImage: String {
        switch self {
        case .email: "envelope"
        case .calendar: "calendar"
        case .reminders: "checklist"
        case .notes: "note.text"
        }
    }

    var summary: String {
        switch self {
        case .email: "IMAP/SMTP inbox sync and AI inbox review."
        case .calendar: "Schedule at a glance in Workspace. Coming soon."
        case .reminders: "Task and reminder tracking in Workspace. Coming soon."
        case .notes: "Quick notes in Workspace. Coming soon."
        }
    }

    var settingsKey: String {
        switch self {
        case .email: SettingsKeys.emailEnabled
        case .calendar: SettingsKeys.calendarEnabled
        case .reminders: SettingsKeys.remindersEnabled
        case .notes: SettingsKeys.notesEnabled
        }
    }
}
