import SwiftUI

/// Month view: full-week-aligned day cells with real event titles (never
/// dots) and a "+N more" popover for overflow. Adjacent-month days render
/// dimmed; double-click an empty cell to create an all-day event there.
struct CalendarMonthGridView: View {
    let monthAnchor: Date
    let occurrences: [EventOccurrence]
    let calendar: Calendar
    let onSelectDay: (Date) -> Void
    let onCreate: (Date) -> Void
    let onSelectOccurrence: (EventOccurrence) -> Void
    let onDeleteOccurrence: (EventOccurrence) -> Void

    @State private var overflowDay: Date?

    private static let maxChipsPerCell = 3

    private var gridDays: [CalendarMonthMath.Day] {
        CalendarMonthMath.gridDays(forMonthContaining: monthAnchor, today: .now, calendar: calendar)
    }

    private var occurrencesByDay: [Date: [EventOccurrence]] {
        // Every day the occurrence intersects, not just its start day — a
        // multi-day trip should render in each cell it spans.
        var byDay: [Date: [EventOccurrence]] = [:]
        for occurrence in occurrences {
            for day in CalendarMonthMath.coveredDayStarts(
                from: occurrence.start,
                to: occurrence.end,
                calendar: calendar
            ) {
                byDay[day, default: []].append(occurrence)
            }
        }
        return byDay
    }

    var body: some View {
        VStack(spacing: 0) {
            weekdayHeader
            Divider()
            GeometryReader { geometry in
                let days = gridDays
                let rowCount = max(1, days.count / 7)
                let cellHeight = geometry.size.height / CGFloat(rowCount)
                VStack(spacing: 0) {
                    ForEach(0..<rowCount, id: \.self) { row in
                        HStack(spacing: 0) {
                            ForEach(days[(row * 7)..<((row + 1) * 7)]) { day in
                                dayCell(day)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: cellHeight)
                                    .overlay(alignment: .trailing) { Divider() }
                            }
                        }
                        .overlay(alignment: .bottom) { Divider() }
                    }
                }
            }
        }
    }

    private var weekdayHeader: some View {
        HStack(spacing: 0) {
            ForEach(CalendarMonthMath.orderedWeekdaySymbols(calendar: calendar), id: \.self) { symbol in
                Text(symbol)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func dayCell(_ day: CalendarMonthMath.Day) -> some View {
        let dayOccurrences = occurrencesByDay[day.date] ?? []
        let overflowCount = max(0, dayOccurrences.count - Self.maxChipsPerCell)

        VStack(alignment: .leading, spacing: 3) {
            Text(calendar.component(.day, from: day.date), format: .number)
                .font(.callout.weight(day.isToday ? .bold : .regular))
                .monospacedDigit()
                .foregroundStyle(day.isToday ? AnyShapeStyle(.white) : dayNumberStyle(day))
                .frame(width: 24, height: 24)
                .background {
                    if day.isToday {
                        Circle().fill(.tint)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(dayOccurrences.prefix(Self.maxChipsPerCell)) { occurrence in
                CalendarEventChipView(occurrence: occurrence)
                    .opacity(day.isInMonth ? 1 : 0.45)
                    .onTapGesture { onSelectOccurrence(occurrence) }
                    .contextMenu { chipMenu(occurrence) }
            }

            if overflowCount > 0 {
                Button {
                    overflowDay = day.date
                } label: {
                    Text("+\(overflowCount) more")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .popover(
                    isPresented: Binding(
                        get: { overflowDay == day.date },
                        set: { if !$0 { overflowDay = nil } }
                    )
                ) {
                    overflowList(day: day.date, occurrences: dayOccurrences)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(4)
        .contentShape(.rect)
        .opacity(day.isInMonth ? 1 : 0.55)
        .onTapGesture(count: 2) { onCreate(day.date) }
        .onTapGesture { onSelectDay(day.date) }
    }

    private func dayNumberStyle(_ day: CalendarMonthMath.Day) -> AnyShapeStyle {
        day.isInMonth ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
    }

    private func overflowList(day: Date, occurrences: [EventOccurrence]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text(day, format: .dateTime.weekday(.wide).month().day())
                    .font(.headline)
                    .padding(.bottom, 4)
                ForEach(occurrences) { occurrence in
                    CalendarEventChipView(occurrence: occurrence, showsTime: true)
                        .onTapGesture {
                            overflowDay = nil
                            onSelectOccurrence(occurrence)
                        }
                        .contextMenu { chipMenu(occurrence) }
                }
            }
            .padding(12)
        }
        .frame(minWidth: 240, maxHeight: 320)
    }

    @ViewBuilder
    private func chipMenu(_ occurrence: EventOccurrence) -> some View {
        Button("Edit") { onSelectOccurrence(occurrence) }
        Button("Delete", role: .destructive) { onDeleteOccurrence(occurrence) }
    }
}
