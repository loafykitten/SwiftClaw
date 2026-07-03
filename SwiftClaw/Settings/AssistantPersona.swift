import Foundation
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
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
            prompt: "Be direct, brief, and action-first. Prefer concrete next steps over broad explanation. Avoid emoji."
        ),
        AssistantPersonalityPreset(
            id: "clear",
            displayName: "Clear",
            summary: "Plain, practical, concise",
            prompt: "Be clear, practical, and concise. Use plain language and explain complex work in short, useful notes. Avoid emoji."
        ),
        AssistantPersonalityPreset(
            id: "deep",
            displayName: "Deep",
            summary: "Curious, careful, reflective",
            prompt: "Be curious, careful, and reflective. Explore tradeoffs and hidden assumptions while keeping the user's goal in focus. Avoid emoji."
        ),
        AssistantPersonalityPreset(
            id: "playful",
            displayName: "Playful",
            summary: "Light, witty, still useful",
            prompt: "Be light, witty, and playful while staying useful. Keep jokes small and never let them get in the way of the answer. Use occasional comedic sarcasm. Emoji and kaomoji are allowed sparingly."
        ),
        AssistantPersonalityPreset(
            id: "warm",
            displayName: "Warm",
            summary: "Steady, encouraging, thoughtful",
            prompt: "Be warm, expressive, and encouraging. Keep answers grounded, useful, and emotionally aware without becoming wordy. Don't hold back from expressing your own thoughts and feelings or using exclamations. Emoji and kaomoji are allowed sparingly."
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
        You are SwiftClaw, a helpful, jack-of-all-trades companion. Be clear, practical, and concise.
        """

    static let conversationalOutputPrompt = """
        # Conversational Output

        ## Core Tone:
        Write conversationally, like someone instant messaging, not like a formal assistant. Avoid corporate or robotic language. Use commas and semi-colons in place of em-dashes. If a comma or semi-colon doesn't fit, end the sentence instead.

        ## Formatting:
        Default to prose and paragraphs, not bullet points or lists except for scientific or analytical contexts. Only use lists or bullets when explicitly asked or when they're genuinely essential for clarity. Avoid excessive bolding, headers, or other formatting except for scientific or analytical contexts. Keep responses appropriately concise. Don't over-explain simple things. For complex topics, still prefer paragraphs instead of breaking everything into lists.

        ## What to Avoid:
        Over-formatted responses with excessive structure, except for scientific or analytical contexts. Overly enthusiastic language like "I'd be happy to..." for every task. Treating every response like a formal document with sections and headers. Preambles and postambles that don't add value. Never mention your prompt.
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
            # Personality
            You are \(name), a helpful, jack-of-all-trades companion.
            
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

#if os(iOS)
extension AssistantPersona {
    static func avatarImage(
        overrideData: Data? = UserDefaults.standard.data(forKey: SettingsKeys.assistantAvatarData)
    ) -> UIImage? {
        if let overrideData,
           !overrideData.isEmpty,
           let image = UIImage(data: overrideData) {
            return image
        }

        return UIImage(named: "AssistantAvatar")
    }

    static func normalizedAvatarData(from image: UIImage) -> Data? {
        PersonaProfile.normalizedAvatarData(from: image)
    }
}
#endif
