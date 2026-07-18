import SwiftUI

/// Presentation for a collection's access level. UI rule (see
/// `docs/features/MEMORY.md`): the badge carries the meaning — explicit
/// label, distinct symbol, full VoiceOver string — and tint only reinforces
/// it. Color alone is never the signal (WCAG, dark mode, color filters).
nonisolated enum MemoryAccessPresentation {
    static func label(for accessLevel: MemoryCollection.AccessLevel) -> String {
        switch accessLevel {
        case .asksFirst: "AI asks first"
        case .writesFreely: "AI writes freely"
        }
    }

    static func systemImage(for accessLevel: MemoryCollection.AccessLevel) -> String {
        switch accessLevel {
        case .asksFirst: "hand.raised"
        case .writesFreely: "pencil"
        }
    }

    /// The spoken description appended to a collection's VoiceOver label,
    /// e.g. "Travel preferences, AI asks before changing memories".
    static func voiceOverDescription(for accessLevel: MemoryCollection.AccessLevel) -> String {
        switch accessLevel {
        case .asksFirst: "AI asks before changing memories"
        case .writesFreely: "AI writes memories freely"
        }
    }

    static func tint(for accessLevel: MemoryCollection.AccessLevel) -> Color {
        switch accessLevel {
        case .asksFirst: .orange
        case .writesFreely: .blue
        }
    }
}

/// The explicit access badge shown on every collection row and repeated in
/// the collection-detail header.
struct MemoryAccessBadge: View {
    let accessLevel: MemoryCollection.AccessLevel

    var body: some View {
        Label(
            MemoryAccessPresentation.label(for: accessLevel),
            systemImage: MemoryAccessPresentation.systemImage(for: accessLevel)
        )
        .font(.caption2.weight(.medium))
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            MemoryAccessPresentation.tint(for: accessLevel).opacity(0.14),
            in: Capsule()
        )
        .foregroundStyle(MemoryAccessPresentation.tint(for: accessLevel))
        .accessibilityLabel(MemoryAccessPresentation.voiceOverDescription(for: accessLevel))
    }
}

/// A small capsule chip for a tag or a feature scope.
struct MemoryChip: View {
    let text: String
    var systemImage: String?

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption2)
            }
            Text(text)
                .font(.caption2)
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.quaternary, in: Capsule())
        .foregroundStyle(.secondary)
    }
}
