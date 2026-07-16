import Foundation

/// Pure date, path, and Markdown formatting for Notes daily capture.
nonisolated struct DailyNoteResolver: Equatable {
    struct Resolution: Equatable {
        let localDate: String
        let time: String
        let relativePath: String

        var heading: String {
            "# \(localDate)"
        }

        func newNoteContent(text: String) -> String {
            "\(heading)\n\n\(bullet(text: text))"
        }

        func appending(text: String, to existing: String) -> String {
            existing + (existing.hasSuffix("\n") ? "" : "\n") + bullet(text: text)
        }

        private func bullet(text: String) -> String {
            "- \(time) \(text)"
        }
    }

    let calendar: Calendar

    init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    func resolve(now: Date, folder: String?) -> Resolution {
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        let localDate = String(
            format: "%04d-%02d-%02d",
            locale: Locale(identifier: "en_US_POSIX"),
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
        let time = String(
            format: "%02d:%02d",
            locale: Locale(identifier: "en_US_POSIX"),
            components.hour ?? 0,
            components.minute ?? 0
        )
        let filename = "\(localDate).md"
        let path = NotesFilenameSanitizer.sanitizeFolder(folder).map { "\($0)/\(filename)" } ?? filename
        return Resolution(localDate: localDate, time: time, relativePath: path)
    }
}
