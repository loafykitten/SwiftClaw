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
/// and piping stdout). Call sites use the familiar
/// `logger.info("… \(x, privacy: .public) …")` form, and the unified-log
/// channel follows `os.Logger`'s privacy rules: numbers and booleans are
/// public by default, every other value is redacted to `<private>` unless
/// marked `.public`. Only the DEBUG stdout mirror shows full values.
nonisolated enum AppLog {
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

nonisolated struct AppLogger: Sendable {
    let category: String
    private let logger: Logger

    init(category: String) {
        self.category = category
        self.logger = Logger(subsystem: AppLog.subsystem, category: category)
    }

    func debug(_ message: AppLogMessage) {
        logger.debug("\(message.redactedText, privacy: .public)")
        mirror("debug", message.text)
    }

    func info(_ message: AppLogMessage) {
        logger.info("\(message.redactedText, privacy: .public)")
        mirror("info ", message.text)
    }

    func notice(_ message: AppLogMessage) {
        logger.notice("\(message.redactedText, privacy: .public)")
        mirror("note ", message.text)
    }

    func warning(_ message: AppLogMessage) {
        logger.warning("\(message.redactedText, privacy: .public)")
        mirror("warn ", message.text)
    }

    func error(_ message: AppLogMessage) {
        logger.error("\(message.redactedText, privacy: .public)")
        mirror("error", message.text)
    }

    private func mirror(_ level: String, _ text: String) {
        #if DEBUG
        AppLog.mirror(category: category, level: level, text: text)
        #endif
    }
}

/// Privacy marker accepted by `AppLogMessage` interpolations. Mirrors the
/// `OSLogPrivacy` spellings the codebase uses, so `privacy: .public` call
/// sites read exactly like `os.Logger` ones.
nonisolated enum AppLogPrivacy: Sendable {
    /// Numbers and booleans public, everything else private — `os.Logger`'s default.
    case auto
    case `public`
    case `private`
    case sensitive
}

/// Message type for `AppLogger`. Mirrors `os.Logger`'s string-interpolation
/// API closely enough that call sites — including `\(x, privacy: .public)` —
/// read the same, while capturing two renderings: the full text for the
/// DEBUG stdout mirror, and a redacted one for the unified log.
nonisolated struct AppLogMessage: ExpressibleByStringInterpolation {
    static let redactedPlaceholder = "<private>"

    let text: String
    let redactedText: String

    init(stringLiteral value: String) {
        text = value
        redactedText = value
    }

    init(stringInterpolation: StringInterpolation) {
        text = stringInterpolation.text
        redactedText = stringInterpolation.redactedText
    }

    nonisolated struct StringInterpolation: StringInterpolationProtocol {
        var text = ""
        var redactedText = ""

        init(literalCapacity: Int, interpolationCount: Int) {
            text.reserveCapacity(literalCapacity)
            redactedText.reserveCapacity(literalCapacity)
        }

        mutating func appendLiteral(_ literal: String) {
            text += literal
            redactedText += literal
        }

        mutating func appendInterpolation(_ value: Any, privacy: AppLogPrivacy = .auto) {
            append(String(describing: value), isPublic: Self.isPublic(value, privacy: privacy))
        }

        // Concrete overloads so unannotated counts and flags stay readable in
        // the unified log, matching `os.Logger` (the `Any` overload costs an
        // existential conversion, so these win overload resolution).
        mutating func appendInterpolation<T: BinaryInteger>(_ value: T, privacy: AppLogPrivacy = .auto) {
            append(String(describing: value), isPublic: privacy == .auto || privacy == .public)
        }

        mutating func appendInterpolation<T: BinaryFloatingPoint>(_ value: T, privacy: AppLogPrivacy = .auto) {
            append(String(describing: value), isPublic: privacy == .auto || privacy == .public)
        }

        mutating func appendInterpolation(_ value: Bool, privacy: AppLogPrivacy = .auto) {
            append(String(describing: value), isPublic: privacy == .auto || privacy == .public)
        }

        private mutating func append(_ rendered: String, isPublic: Bool) {
            text += rendered
            redactedText += isPublic ? rendered : AppLogMessage.redactedPlaceholder
        }

        private static func isPublic(_ value: Any, privacy: AppLogPrivacy) -> Bool {
            switch privacy {
            case .public:
                true
            case .private, .sensitive:
                false
            case .auto:
                value is any BinaryInteger || value is any BinaryFloatingPoint || value is Bool
            }
        }
    }
}
