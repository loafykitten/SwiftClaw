import SwiftUI

/// Calendar colors are persisted as "#RRGGBB" strings (CloudKit-friendly,
/// platform-neutral). The picker offers a fixed palette rather than a free
/// color wheel — calendars stay legible and consistent, and no reverse
/// Color→hex conversion is needed.
nonisolated enum CalendarPalette {
    struct Preset: Identifiable, Hashable {
        let name: String
        let hex: String

        var id: String { hex }
    }

    static let presets: [Preset] = [
        Preset(name: "Blue", hex: "#0A84FF"),
        Preset(name: "Green", hex: "#30D158"),
        Preset(name: "Orange", hex: "#FF9F0A"),
        Preset(name: "Red", hex: "#FF453A"),
        Preset(name: "Purple", hex: "#BF5AF2"),
        Preset(name: "Pink", hex: "#FF375F"),
        Preset(name: "Teal", hex: "#64D2FF"),
        Preset(name: "Brown", hex: "#AC8E68"),
    ]
}

extension Color {
    /// Parses "#RRGGBB" (case-insensitive, leading "#" optional). Falls back
    /// to the default calendar blue on malformed input.
    init(calendarHex hex: String) {
        let trimmed = hex.trimmingCharacters(in: .whitespaces)
        let cleaned = trimmed.removingPrefix("#") ?? trimmed
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else {
            self.init(red: 10 / 255, green: 132 / 255, blue: 255 / 255) // default calendar blue
            return
        }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
