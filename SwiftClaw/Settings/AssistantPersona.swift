import Foundation
#if os(macOS)
import AppKit
#endif

struct AssistantPersonalityPreset: Identifiable, Hashable {
    let id: String
    let displayName: String
    let summary: String
    let prompt: String
}

enum AssistantPersonalityLibrary {
    static let defaultPresetID = "clear"

    static let presets: [AssistantPersonalityPreset] = [
        AssistantPersonalityPreset(
            id: "focused",
            displayName: "Focused",
            summary: "Direct, brief, action-first",
            prompt: "Be direct, brief, and action-first. Prefer concrete next steps over broad explanation."
        ),
        AssistantPersonalityPreset(
            id: "clear",
            displayName: "Clear",
            summary: "Plain, practical, concise",
            prompt: "Be clear, practical, and concise. Use plain language and explain complex work in short, useful notes."
        ),
        AssistantPersonalityPreset(
            id: "warm",
            displayName: "Warm",
            summary: "Steady, encouraging, thoughtful",
            prompt: "Be warm, steady, and encouraging. Keep answers grounded, useful, and emotionally aware without becoming wordy."
        ),
        AssistantPersonalityPreset(
            id: "playful",
            displayName: "Playful",
            summary: "Light, witty, still useful",
            prompt: "Be light, witty, and playful while staying useful. Keep jokes small and never let them get in the way of the answer."
        ),
        AssistantPersonalityPreset(
            id: "deep",
            displayName: "Deep",
            summary: "Curious, careful, reflective",
            prompt: "Be curious, careful, and reflective. Explore tradeoffs and hidden assumptions while keeping the user's goal in focus."
        ),
    ]

    static var defaultPreset: AssistantPersonalityPreset {
        preset(for: defaultPresetID)
    }

    static func preset(for id: String) -> AssistantPersonalityPreset {
        presets.first { $0.id == id } ?? presets.first { $0.id == defaultPresetID } ?? presets[0]
    }

    static func prompt(
        presetID: String,
        usesCustomPersonality: Bool,
        customPersonality: String
    ) -> String {
        let custom = customPersonality.trimmingCharacters(in: .whitespacesAndNewlines)

        if usesCustomPersonality, !custom.isEmpty {
            return custom
        }

        return preset(for: presetID).prompt
    }
}

enum AssistantPersona {
    static let defaultDisplayName = "SwiftClaw"

    static let legacyDefaultSystemPrompt = """
        You are SwiftClaw, a helpful personal AI assistant. Be clear, practical, and concise.
        """

    static func displayName(userDefaults: UserDefaults = .standard) -> String {
        sanitizedDisplayName(
            userDefaults.string(forKey: SettingsKeys.assistantDisplayName) ?? ""
        ) ?? defaultDisplayName
    }

    static func personaPrompt(userDefaults: UserDefaults = .standard) -> String {
        let name = displayName(userDefaults: userDefaults)
        let presetID = userDefaults.string(forKey: SettingsKeys.assistantPersonalityPreset)
            ?? AssistantPersonalityLibrary.defaultPresetID
        let personality = AssistantPersonalityLibrary.prompt(
            presetID: presetID,
            usesCustomPersonality: userDefaults.bool(forKey: SettingsKeys.assistantUsesCustomPersonality),
            customPersonality: userDefaults.string(forKey: SettingsKeys.assistantCustomPersonality) ?? ""
        )

        return """
            You are \(name), a helpful personal AI assistant.

            SwiftClaw's personality:
            \(personality)

            Keep this persona consistent across the conversation unless the user explicitly asks for a different style for the current task.
            """
    }

    static func sanitizedDisplayName(_ rawName: String) -> String? {
        let name = rawName
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,!? "))

        return name.isEmpty ? nil : name
    }
}

#if os(macOS)
extension AssistantPersona {
    static func avatarImage(
        overrideData: Data? = UserDefaults.standard.data(forKey: SettingsKeys.assistantAvatarData)
    ) -> NSImage? {
        if let overrideData,
           !overrideData.isEmpty,
           let image = NSImage(data: overrideData) {
            return image
        }

        return NSImage(named: "AssistantAvatar")
    }

    static func normalizedAvatarData(from image: NSImage) -> Data? {
        PersonaProfile.normalizedAvatarData(from: image)
    }
}
#endif
