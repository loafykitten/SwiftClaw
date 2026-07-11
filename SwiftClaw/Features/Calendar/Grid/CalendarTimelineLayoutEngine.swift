import Foundation

/// Pure column-packing for the week/day timeline: turns one day's timed
/// occurrences into minute-space frames (column index / column count + start
/// and end minutes from the day's start). The timeline views are dumb
/// renderers over these frames, so all overlap logic is testable without UI.
///
/// Packing: occurrences sorted by start are grouped into overlap clusters
/// (a cluster ends when an occurrence starts after everything before it has
/// ended). Within a cluster each occurrence takes the lowest column whose
/// previous occupant has ended, and every member shares the cluster's total
/// column count so widths line up.
nonisolated enum CalendarTimelineLayoutEngine {
    struct Frame: Equatable {
        let occurrence: EventOccurrence
        let columnIndex: Int
        let columnCount: Int
        /// Minutes from the day's start, clamped to the day (multi-day spills
        /// render as full-height slabs on intermediate days).
        let startMinute: Double
        let endMinute: Double
    }

    /// Minimum rendered duration so zero/short events stay clickable.
    static let minimumSlotMinutes: Double = 15

    static func frames(
        for occurrences: [EventOccurrence],
        day: DateInterval,
        calendar: Calendar
    ) -> [Frame] {
        let dayMinutes = day.duration / 60
        let timed = occurrences
            .filter { !$0.isAllDay && $0.start < day.end && $0.end > day.start }
            .sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        guard !timed.isEmpty else { return [] }

        // Minute-space intervals, clamped to the day and padded to the
        // minimum slot so packing sees what will actually be drawn.
        struct Entry {
            let occurrence: EventOccurrence
            let startMinute: Double
            let endMinute: Double
        }
        let entries = timed.map { occurrence in
            let start = max(0, occurrence.start.timeIntervalSince(day.start) / 60)
            let rawEnd = min(dayMinutes, occurrence.end.timeIntervalSince(day.start) / 60)
            let end = min(dayMinutes, max(rawEnd, start + minimumSlotMinutes))
            return Entry(occurrence: occurrence, startMinute: start, endMinute: end)
        }

        var frames: [Frame] = []
        var cluster: [Entry] = []
        var clusterColumns: [Int] = [] // column index per cluster entry
        var columnEnds: [Double] = []  // running end minute per column
        var clusterMaxEnd = -Double.infinity

        func flushCluster() {
            let columnCount = columnEnds.count
            for (entry, column) in zip(cluster, clusterColumns) {
                frames.append(Frame(
                    occurrence: entry.occurrence,
                    columnIndex: column,
                    columnCount: columnCount,
                    startMinute: entry.startMinute,
                    endMinute: entry.endMinute
                ))
            }
            cluster = []
            clusterColumns = []
            columnEnds = []
            clusterMaxEnd = -Double.infinity
        }

        for entry in entries {
            if !cluster.isEmpty && entry.startMinute >= clusterMaxEnd {
                flushCluster()
            }
            let column = columnEnds.firstIndex { $0 <= entry.startMinute } ?? columnEnds.count
            if column == columnEnds.count {
                columnEnds.append(entry.endMinute)
            } else {
                columnEnds[column] = entry.endMinute
            }
            cluster.append(entry)
            clusterColumns.append(column)
            clusterMaxEnd = max(clusterMaxEnd, entry.endMinute)
        }
        flushCluster()
        return frames
    }
}
