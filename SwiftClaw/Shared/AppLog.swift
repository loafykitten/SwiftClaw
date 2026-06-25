import Foundation
import os

/// Centralized logging. Wraps `os.Logger` — so Console.app and `log show`
/// keep working exactly as before — and, in DEBUG builds only, mirrors each
/// line to stdout in a clean, greppable format:
///
///     HH:mm:ss.SSS  level  category                  message
///
/// That mirror is what makes a DEBUG run readable in the Xcode console and
/// trivial to capture from the command line (e.g. launching the built binary
/// and piping stdout). Existing call sites keep the familiar
/// `logger.info("… \(x, privacy: .public) …")` form; the `privacy:` markers
/// are accepted for source compatibility but the rendered message is logged
/// as `.public` (this is a personal app), so values are never `<private>` in
/// either channel.
enum AppLog {
    static let subsystem = Bundle.main.bundleIdentifier ?? "com.caffeineplz.SwiftClaw"

    static func make(_ category: String) -> AppLogger {
        AppLogger(category: category)
    }

    #if DEBUG
    // Serializes format + print so concurrent log lines don't interleave and
    // the (non-thread-safe) formatter is only touched under the lock.
    private static let lock = NSLock()
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static func mirror(category: String, level: String, text: String) {
        lock.lock()
        defer { lock.unlock() }
        let time = timeFormatter.string(from: Date())
        let paddedCategory = category.count < 24
            ? category + String(repeating: " ", count: 24 - category.count)
            : category
        print("\(time)  \(level)  \(paddedCategory)  \(text)")
    }
    #endif
}

struct AppLogger: Sendable {
    let category: String
    private let logger: Logger

    init(category: String) {
        self.category = category
        self.logger = Logger(subsystem: AppLog.subsystem, category: category)
    }

    func debug(_ message: AppLogMessage) {
        logger.debug("\(message.text, privacy: .public)")
        mirror("debug", message.text)
    }

    func info(_ message: AppLogMessage) {
        logger.info("\(message.text, privacy: .public)")
        mirror("info ", message.text)
    }

    func notice(_ message: AppLogMessage) {
        logger.notice("\(message.text, privacy: .public)")
        mirror("note ", message.text)
    }

    func warning(_ message: AppLogMessage) {
        logger.warning("\(message.text, privacy: .public)")
        mirror("warn ", message.text)
    }

    func error(_ message: AppLogMessage) {
        logger.error("\(message.text, privacy: .public)")
        mirror("error", message.text)
    }

    private func mirror(_ level: String, _ text: String) {
        #if DEBUG
        AppLog.mirror(category: category, level: level, text: text)
        #endif
    }
}

/// Message type for `AppLogger`. Mirrors `os.Logger`'s string-interpolation
/// API closely enough that existing call sites — including
/// `\(x, privacy: .public)` — compile unchanged, while also capturing the
/// rendered text so DEBUG builds can mirror it to stdout.
struct AppLogMessage: ExpressibleByStringInterpolation {
    let text: String

    init(stringLiteral value: String) {
        text = value
    }

    init(stringInterpolation: StringInterpolation) {
        text = stringInterpolation.text
    }

    struct StringInterpolation: StringInterpolationProtocol {
        var text = ""

        init(literalCapacity: Int, interpolationCount: Int) {
            text.reserveCapacity(literalCapacity)
        }

        mutating func appendLiteral(_ literal: String) {
            text += literal
        }

        mutating func appendInterpolation(_ value: Any) {
            text += String(describing: value)
        }

        // Accepts the `privacy:` marker used throughout the codebase. The
        // marker is intentionally ignored for the mirror (DEBUG output shows
        // full values); the os.Logger side renders the whole message public.
        mutating func appendInterpolation(_ value: Any, privacy: OSLogPrivacy) {
            text += String(describing: value)
        }
    }
}
