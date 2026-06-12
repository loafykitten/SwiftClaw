import Foundation
import os

enum HomeDayGreetingGenerator {
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.caffeineplz.SwiftClaw",
        category: "HomeDayGreeting"
    )

    static let initial = " "

    static let systemPrompt = """
        You write the home-screen greeting for SwiftClaw, a personal macOS AI assistant. \
        Write one short greeting using the time of day, daylight, and weather context. \
        Hard rules: reply with only the greeting phrase. Do not include User, names, \
        usernames, or a comma. Use 2 to 6 words. The phrase may end with ! or ?. \
        No emoji, no quotes, no explanation.
        """

    static func userPrompt(for context: HomeDayGreetingContext) -> String {
        """
        Time zone: \(context.timeZoneIdentifier)
        Local time: \(localTime(for: context))
        Phase of day: \(context.phase.promptName)
        Daylight: \(context.daylightSummary)
        Weather: \(context.weatherSummary)
        """
    }

    static func fallbackGreeting(for context: HomeDayGreetingContext) -> String {
        switch context.phase {
        case .morningTwilight:
            formattedGreeting(from: "Quiet twilight")
        case .dawn:
            formattedGreeting(from: "Fresh dawn")
        case .morning:
            formattedGreeting(from: "Good morning")
        case .afternoon:
            formattedGreeting(from: "Good afternoon")
        case .evening:
            formattedGreeting(from: "Good evening")
        case .eveningTwilight:
            formattedGreeting(from: "Soft twilight")
        case .dusk:
            formattedGreeting(from: "Peaceful dusk")
        }
    }

    private static func localTime(for context: HomeDayGreetingContext) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short

        if let timeZone = TimeZone(identifier: context.timeZoneIdentifier) {
            formatter.timeZone = timeZone
        }

        return formatter.string(from: context.now)
    }

    static func cleaned(_ raw: String) -> String {
        let firstLine = raw
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""

        let cleaned = firstLine
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'\u{201C}\u{201D}\u{2018}\u{2019}"))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else {
            return ""
        }

        return formattedGreeting(from: cleaned)
    }

    private static func formattedGreeting(from rawPhrase: String) -> String {
        var phrase = rawPhrase.trimmingCharacters(in: .whitespacesAndNewlines)
        var ending = ""

        if let last = phrase.last, last == "!" || last == "?" {
            ending = String(last)
            phrase.removeLast()
        }

        phrase = phrase.replacingOccurrences(
            of: #",?\s*\buser\b"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        phrase = phrase
            .replacingOccurrences(of: ",", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,!? "))

        guard !phrase.isEmpty else {
            return ""
        }

        return "\(phrase), User\(ending)"
    }
}
