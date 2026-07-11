import SwiftUI

/// The compact event pill used in the month grid, all-day row, and overflow
/// popovers: calendar-colored bar + title (+ start time when timed and
/// there's room).
struct CalendarEventChipView: View {
    let occurrence: EventOccurrence
    var showsTime = false

    private var color: Color {
        Color(calendarHex: occurrence.colorHex)
    }

    var body: some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1)
                .fill(color)
                .frame(width: 3)

            Text(occurrence.title.isEmpty ? "New Event" : occurrence.title)
                .font(.caption)
                .lineLimit(1)

            if showsTime && !occurrence.isAllDay {
                Spacer(minLength: 2)
                Text(occurrence.start, format: .dateTime.hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Hug the text vertically: the color bar makes the HStack flexible,
        // and in a tall month cell the VStack would otherwise stretch the
        // chip through the whole cell.
        .fixedSize(horizontal: false, vertical: true)
        .background(color.opacity(0.14), in: .rect(cornerRadius: 4))
        .contentShape(.rect(cornerRadius: 4))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        if occurrence.isAllDay {
            "\(occurrence.title), all day"
        } else {
            "\(occurrence.title), \(occurrence.start.formatted(date: .omitted, time: .shortened))"
        }
    }
}

/// The timeline's block rendering of a timed occurrence (filled slab with
/// title + time, clipped to its frame).
struct CalendarTimelineEventBlock: View {
    let occurrence: EventOccurrence
    var isCompact = false

    private var color: Color {
        Color(calendarHex: occurrence.colorHex)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(occurrence.title.isEmpty ? "New Event" : occurrence.title)
                .font(.caption.weight(.medium))
                .lineLimit(isCompact ? 1 : 2)
            if !isCompact {
                Text(occurrence.start, format: .dateTime.hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(color.opacity(0.16), in: .rect(cornerRadius: 5))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 5, bottomLeadingRadius: 5)
                .fill(color)
                .frame(width: 3)
        }
        .contentShape(.rect(cornerRadius: 5))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(occurrence.title), \(occurrence.start.formatted(date: .abbreviated, time: .shortened))")
    }
}
