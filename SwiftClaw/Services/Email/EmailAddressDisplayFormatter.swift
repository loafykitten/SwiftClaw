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
