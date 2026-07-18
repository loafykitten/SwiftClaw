import Foundation

/// The one date/time line every LLM prompt shares — interactive chat and the
/// review services alike — so the model always knows "now" in the user's zone.
nonisolated enum PromptDateContext {
    static func currentString(now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        formatter.timeZone = timeZone

        return "Current user date/time: \(formatter.string(from: now)) (\(timeZone.identifier))"
    }
}
