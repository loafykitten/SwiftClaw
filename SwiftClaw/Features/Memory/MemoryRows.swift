import SwiftUI

/// Collection row anatomy per the feature doc: title, two or three tag
/// chips, entry count, last-changed date, trailing access badge, scope chip
/// when feature-scoped, and a subtle full-row tint keyed to access level
/// (the badge carries the meaning; the tint only reinforces it).
struct MemoryCollectionRow: View {
    let collection: MemoryCollection
    /// Narrow (macOS sidebar) layout: the access badge drops to its own
    /// line instead of trailing the title, so it stays a labeled badge and
    /// never gets truncated into an unlabeled tint.
    var compact = false

    var body: some View {
        Group {
            if compact {
                VStack(alignment: .leading, spacing: 3) {
                    titleLine
                    HStack(spacing: 4) {
                        // The badge must keep its label at any width (the
                        // badge carries the meaning); the detail text is
                        // what truncates when the sidebar narrows.
                        MemoryAccessBadge(accessLevel: collection.accessLevel)
                            .layoutPriority(1)
                        Spacer(minLength: 2)
                        Text(detailLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if collection.scope != nil || !collection.tags.isEmpty {
                        HStack(spacing: 4) {
                            if let scope = collection.scope {
                                MemoryChip(text: scope.displayName, systemImage: scope.systemImage)
                            }
                            ForEach(collection.tags.prefix(2), id: \.self) { tag in
                                MemoryChip(text: tag)
                            }
                        }
                    }
                }
            } else {
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        titleLine
                        HStack(spacing: 4) {
                            if let scope = collection.scope {
                                MemoryChip(text: scope.displayName, systemImage: scope.systemImage)
                            }
                            ForEach(collection.tags.prefix(3), id: \.self) { tag in
                                MemoryChip(text: tag)
                            }
                            Text(detailLine)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    MemoryAccessBadge(accessLevel: collection.accessLevel)
                }
            }
        }
        .padding(.vertical, 2)
        .listRowBackground(
            MemoryAccessPresentation.tint(for: collection.accessLevel).opacity(0.05)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    private var titleLine: some View {
        HStack(spacing: 5) {
            if collection.isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Text(collection.title)
                .font(.body)
                .lineLimit(1)
        }
    }

    private var detailLine: String {
        let count = collection.activeEntries.count
        let entries = count == 1 ? "1 entry" : "\(count) entries"
        return "\(entries) · \(collection.updatedAt.formatted(.relative(presentation: .named)))"
    }

    private var accessibilityDescription: String {
        var parts = [collection.title]
        if collection.isPinned { parts.append("pinned") }
        if let scope = collection.scope { parts.append("scoped to \(scope.displayName)") }
        parts.append(detailLine)
        parts.append(MemoryAccessPresentation.voiceOverDescription(for: collection.accessLevel))
        return parts.joined(separator: ", ")
    }
}

/// One memory entry in a list: body, tags, provenance (who added it, when),
/// and a superseded marker when a newer fact replaced this one.
struct MemoryEntryRow: View {
    let entry: MemoryEntry
    /// Shown when the list mixes collections (All Memory, Recent, search).
    var showsCollection = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.body)
                .font(.body)
                .lineLimit(3)
                .foregroundStyle(entry.supersededByID == nil ? .primary : .secondary)
            HStack(spacing: 4) {
                if entry.supersededByID != nil {
                    MemoryChip(text: "Superseded", systemImage: "arrow.triangle.2.circlepath")
                }
                if entry.createdBy == .ai {
                    MemoryChip(text: "AI", systemImage: "brain")
                }
                ForEach(entry.tags.prefix(3), id: \.self) { tag in
                    MemoryChip(text: tag)
                }
                if showsCollection, let title = entry.collection?.title {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(entry.updatedAt.formatted(.relative(presentation: .named)))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    private var accessibilityDescription: String {
        var parts = [entry.body]
        if entry.supersededByID != nil { parts.append("superseded") }
        parts.append(entry.createdBy == .ai ? "added by the AI" : "added by you")
        if showsCollection, let title = entry.collection?.title {
            parts.append("in \(title)")
        }
        parts.append(entry.updatedAt.formatted(.relative(presentation: .named)))
        return parts.joined(separator: ", ")
    }
}
