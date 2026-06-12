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
        Write one short, friendly greeting that helps the user feel ready to start the day. \
        Use the time of day, daylight, and weather as subtle context, not as the main point. \
        Hard rules: reply with only the greeting phrase. End the sentence with the user's \
        name from the context. The phrase may be a statement, exclamation, or question; \
        choose punctuation only when it naturally fits. Do not use a comma before the name. \
        If weather or daylight context is absent, do not mention that absence. Never mention \
        unknown, unavailable, missing, or not-provided context. Avoid plain weather labels \
        like "Clear morning" or "Cloudy afternoon"; make it feel like a warm greeting. \
        Use 3 to 8 words. \
        No emoji, no quotes, no explanation.
        """

    static var currentUserName: String {
        sanitizedUserName(NSFullUserName()) ??
            sanitizedUserName(NSUserName()) ??
            "friend"
    }

    static func userPrompt(for context: HomeDayGreetingContext, userName: String) -> String {
        var lines = [
            "User name: \(userName)",
            "Time zone: \(context.timeZoneIdentifier)",
            "Local time: \(localTime(for: context))",
            "Phase of day: \(context.phase.promptName)",
        ]

        if context.sunrise != nil, context.sunset != nil {
            lines.append("Daylight: \(context.daylightSummary)")
        }

        if !isUnavailableContextSummary(context.weatherSummary) {
            lines.append("Weather: \(context.weatherSummary)")
        }

        return lines.joined(separator: "\n")
    }

    static func fallbackGreeting(for context: HomeDayGreetingContext, userName: String = currentUserName) -> String {
        switch context.phase {
        case .morningTwilight:
            fallbackGreeting(from: "Quiet twilight", userName: userName)
        case .dawn:
            fallbackGreeting(from: "Fresh dawn", userName: userName)
        case .morning:
            fallbackGreeting(from: "Good morning", userName: userName)
        case .afternoon:
            fallbackGreeting(from: "Good afternoon", userName: userName)
        case .evening:
            fallbackGreeting(from: "Good evening", userName: userName)
        case .eveningTwilight:
            fallbackGreeting(from: "Soft twilight", userName: userName)
        case .dusk:
            fallbackGreeting(from: "Peaceful dusk", userName: userName)
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

    static func cleaned(_ raw: String, userName: String = currentUserName) -> String {
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

        return formattedGreeting(from: cleaned, userName: userName)
    }

    private static func formattedGreeting(from rawPhrase: String, userName: String) -> String {
        var phrase = rawPhrase.trimmingCharacters(in: .whitespacesAndNewlines)
        var ending = ""

        if let last = phrase.last, last == "!" || last == "?" {
            ending = String(last)
            phrase.removeLast()
        }

        phrase = phrase
            .replacingOccurrences(of: ",", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,!? "))

        guard !phrase.isEmpty else {
            return ""
        }

        guard !mentionsMissingContext(phrase) else {
            return ""
        }

        guard let normalizedName = sanitizedUserName(userName),
              let phraseWithName = phraseEndingWithUserName(phrase, userName: normalizedName) else {
            return ""
        }

        return "\(phraseWithName)\(ending)"
    }

    private static func fallbackGreeting(from rawPhrase: String, userName: String) -> String {
        let phrase = rawPhrase
            .replacingOccurrences(of: ",", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,!? "))

        guard !phrase.isEmpty, let userName = sanitizedUserName(userName) else {
            return ""
        }

        return "\(phrase) \(userName)"
    }

    private static func sanitizedUserName(_ rawName: String) -> String? {
        let name = rawName
            .replacingOccurrences(of: ",", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,!? "))

        return name.isEmpty ? nil : name
    }

    private static func isUnavailableContextSummary(_ summary: String) -> Bool {
        summary.localizedCaseInsensitiveContains("unavailable")
    }

    private static func mentionsMissingContext(_ phrase: String) -> Bool {
        let phrase = phrase.lowercased()
        let blockedTerms = [
            "unknown",
            "unavailable",
            "missing",
            "not provided",
            "not-provided",
            "without sunrise",
            "without sunset",
            "without weather",
            "no sunrise",
            "no sunset",
            "no weather",
        ]

        return blockedTerms.contains { phrase.contains($0) }
    }

    private static func phraseEndingWithUserName(_ phrase: String, userName: String) -> String? {
        let lowercasedPhrase = phrase.lowercased()
        let lowercasedName = userName.lowercased()

        if lowercasedPhrase == lowercasedName {
            return userName
        }

        guard let nameRange = phrase.range(
            of: " \(userName)",
            options: [.caseInsensitive, .anchored, .backwards]
        ) else {
            return nil
        }

        let prefix = phrase[..<nameRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !prefix.isEmpty else {
            return userName
        }

        return "\(prefix) \(userName)"
    }
}
