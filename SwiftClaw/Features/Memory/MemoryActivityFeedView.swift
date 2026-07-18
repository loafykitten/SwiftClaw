import SwiftData
import SwiftUI

/// Presentation for activity-event kinds — shared by the feed rows and their
/// VoiceOver strings.
nonisolated enum MemoryActivityPresentation {
    static func verb(for kind: MemoryActivityEvent.Kind) -> String {
        switch kind {
        case .added: "Added"
        case .edited: "Edited"
        case .superseded: "Superseded"
        case .movedCollection: "Moved"
        case .deleted: "Deleted"
        case .accessChanged: "Access level changed"
        case .undone: "Undone"
        case .proposalAccepted: "Proposal accepted"
        case .proposalDismissed: "Proposal dismissed"
        }
    }

    static func systemImage(for kind: MemoryActivityEvent.Kind) -> String {
        switch kind {
        case .added: "plus.circle"
        case .edited: "pencil.circle"
        case .superseded: "arrow.triangle.2.circlepath"
        case .movedCollection: "folder"
        case .deleted: "trash"
        case .accessChanged: "hand.raised.circle"
        case .undone: "arrow.uturn.backward.circle"
        case .proposalAccepted: "checkmark.circle"
        case .proposalDismissed: "xmark.circle"
        }
    }

    static func actorDescription(for actor: MemoryActor) -> String {
        switch actor {
        case .user: "by you"
        case .ai: "by the AI"
        }
    }
}

/// The compact audit trail over `MemoryActivityEvent`: additions, edits,
/// supersessions, moves, deletes, access changes, undos, and proposal
/// resolutions. Snapshots in these rows are the record behind hard-delete
/// undo — what the store said before each mutation.
struct MemoryActivityFeedView: View {
    private static let pageSize = 50
    @State private var windowLimit = pageSize

    var body: some View {
        MemoryActivityFeedWindow(
            windowLimit: windowLimit,
            loadEarlier: { windowLimit += Self.pageSize }
        )
    }
}

/// The descriptor retains only the visible recent window plus one sentinel
/// row. Increasing the limit rebuilds the query for explicit pagination.
private struct MemoryActivityFeedWindow: View {
    let windowLimit: Int
    let loadEarlier: () -> Void

    @Query private var events: [MemoryActivityEvent]
    @Query private var collections: [MemoryCollection]

    init(windowLimit: Int, loadEarlier: @escaping () -> Void) {
        self.windowLimit = windowLimit
        self.loadEarlier = loadEarlier
        var descriptor = FetchDescriptor<MemoryActivityEvent>(
            sortBy: [SortDescriptor(\MemoryActivityEvent.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = windowLimit + 1
        _events = Query(descriptor)
    }

    var body: some View {
        let visibleEvents = Array(events.prefix(windowLimit))
        let hasEarlier = events.count > windowLimit
        let collectionTitles = Dictionary(uniqueKeysWithValues: collections.map { ($0.id, $0.title) })
        List {
            if visibleEvents.isEmpty {
                ContentUnavailableView(
                    "No Activity Yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Changes to memory — additions, edits, deletions — appear here.")
                )
            } else {
                ForEach(visibleEvents) { event in
                    row(for: event, collectionTitles: collectionTitles)
                }
                if hasEarlier {
                    Button("Load Earlier", action: loadEarlier)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle("Activity")
    }

    private func row(
        for event: MemoryActivityEvent,
        collectionTitles: [UUID: String]
    ) -> some View {
        let title = headline(for: event, collectionTitles: collectionTitles)
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: MemoryActivityPresentation.systemImage(for: event.kind))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                if let snapshot = event.snapshotText, !snapshot.isEmpty {
                    Text(snapshot)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                Text(event.createdAt.formatted(.relative(presentation: .named)))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(for: event, headline: title))
    }

    private func headline(
        for event: MemoryActivityEvent,
        collectionTitles: [UUID: String]
    ) -> String {
        // Collection-level rows (nil entryID: create/edit/delete/access
        // change of a collection) name the collection as the object —
        // "Created collection by you", with the title in the snapshot line —
        // instead of the entry phrasing "Added in X".
        if event.entryID == nil, [.added, .edited, .deleted].contains(event.kind) {
            let verb = switch event.kind {
            case .added: "Created collection"
            case .edited: "Edited collection"
            default: "Deleted collection"
            }
            return "\(verb) \(MemoryActivityPresentation.actorDescription(for: event.actor))"
        }
        var parts = [MemoryActivityPresentation.verb(for: event.kind)]
        if let collectionID = event.collectionID {
            if let title = collectionTitles[collectionID] {
                parts.append(event.kind == .movedCollection ? "to \(title)" : "in \(title)")
            } else {
                parts.append("in a deleted collection")
            }
        }
        parts.append(MemoryActivityPresentation.actorDescription(for: event.actor))
        return parts.joined(separator: " ")
    }

    private func accessibilityLabel(for event: MemoryActivityEvent, headline: String) -> String {
        var label = headline
        if let snapshot = event.snapshotText, !snapshot.isEmpty {
            label += ". \(snapshot)"
        }
        label += ". \(event.createdAt.formatted(.relative(presentation: .named)))"
        return label
    }
}
