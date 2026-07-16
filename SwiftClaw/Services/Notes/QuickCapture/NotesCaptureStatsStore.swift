import Foundation

/// Durable count of successful quick-capture operations for the local day.
nonisolated struct NotesCaptureStatsStore {
    let userDefaults: UserDefaults
    let calendar: Calendar

    init(userDefaults: UserDefaults = .standard, calendar: Calendar = .current) {
        self.userDefaults = userDefaults
        self.calendar = calendar
    }

    func capturedCount(on date: Date) -> Int {
        guard userDefaults.string(forKey: SettingsKeys.notesQuickCaptureStatsDay) == dayKey(for: date) else { return 0 }
        return max(0, userDefaults.integer(forKey: SettingsKeys.notesQuickCaptureStatsCount))
    }

    @discardableResult
    func recordSuccessfulCapture(on date: Date) -> Int {
        let day = dayKey(for: date)
        let next = (userDefaults.string(forKey: SettingsKeys.notesQuickCaptureStatsDay) == day ? capturedCount(on: date) : 0) + 1
        userDefaults.set(day, forKey: SettingsKeys.notesQuickCaptureStatsDay)
        userDefaults.set(next, forKey: SettingsKeys.notesQuickCaptureStatsCount)
        return next
    }

    private func dayKey(for date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            locale: Locale(identifier: "en_US_POSIX"),
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }
}
