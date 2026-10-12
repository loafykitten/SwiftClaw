import Foundation

nonisolated enum EmailAddressDisplayFormatter {
    static func string(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "\"" else {
            return trimmed
        }

        var displayName = ""
        var isEscaped = false
        var index = trimmed.index(after: trimmed.startIndex)

        while index < trimmed.endIndex {
            let character = trimmed[index]
            if isEscaped {
                displayName.append(character)
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else if character == "\"" {
                let remainder = trimmed[trimmed.index(after: index)...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let cleanedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)

                guard remainder.isEmpty || remainder.first == "<" else {
                    return trimmed
                }
                guard !cleanedDisplayName.isEmpty else {
                    return remainder
                }
                guard !remainder.isEmpty else {
                    return cleanedDisplayName
                }
                return "\(cleanedDisplayName) \(remainder)"
            } else {
                displayName.append(character)
            }

            index = trimmed.index(after: index)
        }

        return trimmed
    }
}

extension Email {
    var displayFromAddress: String {
        EmailAddressDisplayFormatter.string(fromAddress)
    }

    var displayToAddresses: [String] {
        toAddresses.map(EmailAddressDisplayFormatter.string)
    }
}

/// Parses RFC 5322-style address text (`Alice Smith <alice@example.com>`,
/// `"Smith, Alice" <alice@example.com>`, bare `alice@example.com`). Stored
/// addresses keep their display names, but the SMTP envelope needs the bare
/// `addr-spec`, and a comma inside a quoted display name doesn't separate
/// recipients.
nonisolated enum EmailAddressParser {
    struct Mailbox: Equatable, Sendable {
        let name: String?
        let address: String
    }

    /// Splits an address list on commas that sit outside quoted strings,
    /// angle-bracketed addresses, and parenthesized comments.
    static func split(_ raw: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        var isEscaped = false
        var angleDepth = 0
        var commentDepth = 0

        for character in raw {
            if isEscaped {
                current.append(character)
                isEscaped = false
                continue
            }
            switch character {
            case "\\" where inQuotes || commentDepth > 0:
                isEscaped = true
            case "\"" where commentDepth == 0:
                inQuotes.toggle()
            case "<" where !inQuotes && commentDepth == 0:
                angleDepth += 1
            case ">" where !inQuotes && commentDepth == 0:
                angleDepth = max(0, angleDepth - 1)
            case "(" where !inQuotes:
                commentDepth += 1
            case ")" where !inQuotes:
                commentDepth = max(0, commentDepth - 1)
            case "," where !inQuotes && angleDepth == 0 && commentDepth == 0:
                parts.append(current)
                current = ""
                continue
            default:
                break
            }
            current.append(character)
        }
        parts.append(current)

        return parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Parses one mailbox. With an `<addr>` part the text before it is the
    /// display name (quotes and escapes removed); otherwise the whole value
    /// is the address.
    static func mailbox(_ raw: String) -> Mailbox {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var inQuotes = false
        var isEscaped = false
        var angleStart: String.Index?
        var angleRange: Range<String.Index>?

        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            let character = trimmed[index]
            if isEscaped {
                isEscaped = false
            } else if character == "\\" && inQuotes {
                isEscaped = true
            } else if character == "\"" {
                inQuotes.toggle()
            } else if character == "<" && !inQuotes {
                angleStart = index
            } else if character == ">" && !inQuotes, let start = angleStart {
                angleRange = start..<trimmed.index(after: index)
                angleStart = nil
            }
            index = trimmed.index(after: index)
        }

        guard let angleRange else {
            return Mailbox(name: nil, address: trimmed)
        }
        let address = trimmed[angleRange]
            .dropFirst()
            .dropLast()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = unquoted(String(trimmed[..<angleRange.lowerBound]))
        return Mailbox(name: name.isEmpty ? nil : name, address: address)
    }

    /// Whether a bare address (no display name) can go on an SMTP envelope:
    /// a non-empty local part and domain around the last `@`, with no
    /// whitespace or list/angle delimiters. Deliberately loose beyond that —
    /// it rejects typos and fragments (`bob`, `bob@`), not unusual valid forms.
    static func isDeliverableAddress(_ address: String) -> Bool {
        guard let at = address.lastIndex(of: "@") else { return false }
        let localPart = address[..<at]
        let domain = address[address.index(after: at)...]
        guard !localPart.isEmpty, !domain.isEmpty,
              domain.first != ".", domain.last != "." else { return false }
        return !address.contains { $0.isWhitespace || "<>,;".contains($0) }
    }

    /// True for an empty group such as `undisclosed-recipients:;` — a
    /// deliberate entry that names no mailbox to deliver to.
    static func isEmptyGroup(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(";"),
              let colon = trimmed.firstIndex(of: ":"),
              colon != trimmed.startIndex else { return false }
        return trimmed[trimmed.index(after: colon)..<trimmed.index(before: trimmed.endIndex)]
            .allSatisfy(\.isWhitespace)
    }

    /// The entries that are neither a deliverable mailbox nor an empty
    /// group, in order. Sending must reject these rather than drop them.
    static func invalidRecipients(_ entries: [String]) -> [String] {
        entries.filter { entry in
            !isEmptyGroup(entry) && !isDeliverableAddress(mailbox(entry).address)
        }
    }

    /// Renders one stored address for an editable comma-separated field.
    /// Stored addresses are display-formatted (quotes stripped), so a name
    /// like `Smith, Alice` is re-quoted to survive `split(_:)`.
    static func listEntry(_ raw: String) -> String {
        let parsed = mailbox(raw)
        guard let name = parsed.name,
              name.contains(where: { ",;\"<>()@:\\".contains($0) }) else {
            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let escaped = name
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\" <\(parsed.address)>"
    }

    private static func unquoted(_ value: String) -> String {
        var result = ""
        var isEscaped = false
        for character in value.trimmingCharacters(in: .whitespacesAndNewlines) {
            if isEscaped {
                result.append(character)
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else if character != "\"" {
                result.append(character)
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
