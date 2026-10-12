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
        /// Wall-clock minutes on the day's 24-hour grid, clamped to the day (multi-day spills
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
        let dayMinutes = Self.gridMinutes
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
            let start = wallClockMinute(of: occurrence.start, in: day, calendar: calendar)
            let rawEnd = wallClockMinute(of: occurrence.end, in: day, calendar: calendar)
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

    // MARK: - Wall-clock mapping

    /// The grid is a fixed 24 labelled hours, so every position maps through
    /// wall-clock time, never elapsed time: on a 23-hour spring-forward day
    /// 09:00 is 540 minutes down (not 480), and a 25-hour fall-back day's
    /// last hour isn't clipped.
    static let gridMinutes: Double = 24 * 60

    /// Wall-clock minute of `date` on `day`'s grid, clamped to it (an instant
    /// before the day maps to 0, one at or after its end to `gridMinutes`).
    static func wallClockMinute(of date: Date, in day: DateInterval, calendar: Calendar) -> Double {
        guard date > day.start else { return 0 }
        guard date < day.end else { return gridMinutes }
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        let minute = Double(parts.hour ?? 0) * 60 + Double(parts.minute ?? 0) + Double(parts.second ?? 0) / 60
        return min(gridMinutes, max(0, minute))
    }

    /// The instant shown at wall-clock `minute` on the day starting at
    /// `dayStart`. A minute inside a spring-forward gap resolves to the next
    /// valid instant, like `Calendar` does for any nonexistent local time.
    static func date(atWallClockMinute minute: Double, onDayStarting dayStart: Date, calendar: Calendar) -> Date {
        var parts = calendar.dateComponents([.year, .month, .day], from: dayStart)
        let wholeMinutes = Int(minute.rounded())
        parts.hour = wholeMinutes / 60
        parts.minute = wholeMinutes % 60
        return calendar.date(from: parts) ?? dayStart.addingTimeInterval(minute * 60)
    }

    /// Moves `date` by `minutes` of wall-clock time (a drag of N grid rows),
    /// so a move across a DST transition lands on the row it was dropped on.
    static func shiftingWallClock(_ date: Date, byMinutes minutes: Double, calendar: Calendar) -> Date {
        var parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        parts.minute = (parts.minute ?? 0) + Int(minutes.rounded())
        return calendar.date(from: parts) ?? date.addingTimeInterval(minutes * 60)
    }
}
