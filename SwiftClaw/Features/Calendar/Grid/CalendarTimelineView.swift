import SwiftUI

/// Week/day timeline: an all-day strip on top, then a scrolling hour grid
/// with one column per day. Frames come precomputed from
/// `CalendarTimelineLayoutEngine`, so the columns are dumb renderers.
///
/// Interactions (macOS pointer; taps everywhere):
/// - drag on empty grid: 15-minute-snapped create preview → `onCreate`
/// - drag a block: move it (snapped, across days) → `onMove`
/// - drag a block's bottom edge: resize → `onResize`
/// - tap: edit; context menu: edit/delete
/// Recurring-master occurrences don't drag — a stray drag silently rewriting
/// a whole series is worse than requiring the editor's explicit scope choice.
struct CalendarTimelineView: View {
    let days: [Date]
    let occurrences: [EventOccurrence]
    let calendar: Calendar
    /// Master events with a recurrence rule; their occurrences are not
    /// directly draggable.
    let recurringEventIDs: Set<UUID>
    let onSelectOccurrence: (EventOccurrence) -> Void
    let onDeleteOccurrence: (EventOccurrence) -> Void
    let onCreate: (Date, Date) -> Void
    let onMove: (EventOccurrence, Date) -> Void
    let onResize: (EventOccurrence, Date) -> Void

    /// Floor for the hour row height; tall windows stretch hours further so
    /// the day fills the viewport instead of leaving dead space below 11 PM.
    private static let baseHourHeight: CGFloat = 48
    private static let gutterWidth: CGFloat = 52
    private static let snapMinutes: Double = 15

    @State private var hourHeight: CGFloat = CalendarTimelineView.baseHourHeight

    /// In-flight drag state, keyed to what's being dragged.
    private struct DragState {
        enum Kind {
            case create(day: Date)
            case move(EventOccurrence)
            case resize(EventOccurrence)
        }

        let kind: Kind
        var startLocation: CGPoint
        var location: CGPoint
    }

    @State private var dragState: DragState?

    var body: some View {
        VStack(spacing: 0) {
            headerRow
            allDayRow
            Divider()
            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView {
                        timelineGrid
                            .frame(height: hourHeight * 24)
                    }
                    .onAppear {
                        updateHourHeight(available: geometry.size.height)
                        proxy.scrollTo("hour-8", anchor: .top)
                    }
                    .onChange(of: geometry.size.height) { _, height in
                        updateHourHeight(available: height)
                    }
                }
            }
        }
    }

    private func updateHourHeight(available: CGFloat) {
        hourHeight = max(Self.baseHourHeight, available / 24)
    }

    // MARK: - Header / all-day

    private var headerRow: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: Self.gutterWidth, height: 0)
            ForEach(days, id: \.self) { day in
                let isToday = calendar.isDateInToday(day)
                VStack(spacing: 1) {
                    Text(day, format: .dateTime.weekday(.abbreviated))
                        .font(.caption)
                        .foregroundStyle(isToday ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    Text(calendar.component(.day, from: day), format: .number)
                        .font(.title3.weight(isToday ? .bold : .regular))
                        .monospacedDigit()
                        .foregroundStyle(isToday ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var allDayRow: some View {
        let allDay = occurrences.filter(\.isAllDay)
        if !allDay.isEmpty {
            HStack(alignment: .top, spacing: 0) {
                Text("all-day")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(width: Self.gutterWidth)
                ForEach(days, id: \.self) { day in
                    // Calendar-derived interval: a fixed 24h would reach into
                    // the next day on 23-hour spring-forward days.
                    let dayInterval = calendar.dateInterval(of: .day, for: day)
                        ?? DateInterval(start: day, duration: 24 * 3600)
                    VStack(spacing: 2) {
                        ForEach(allDay.filter { $0.start < dayInterval.end && $0.end > dayInterval.start }) { occurrence in
                            CalendarEventChipView(occurrence: occurrence)
                                .onTapGesture { onSelectOccurrence(occurrence) }
                                .contextMenu {
                                    Button("Edit") { onSelectOccurrence(occurrence) }
                                    Button("Delete", role: .destructive) { onDeleteOccurrence(occurrence) }
                                }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 2)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Grid

    private var timelineGrid: some View {
        HStack(alignment: .top, spacing: 0) {
            hourGutter
            ForEach(days, id: \.self) { day in
                dayColumn(day)
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .leading) { Divider() }
            }
        }
    }

    private var hourGutter: some View {
        ZStack(alignment: .topTrailing) {
            Color.clear
            ForEach(0..<24, id: \.self) { hour in
                Text(hourLabel(hour))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .padding(.trailing, 6)
                    .offset(y: CGFloat(hour) * hourHeight - 6)
                    .id("hour-\(hour)")
            }
        }
        .frame(width: Self.gutterWidth)
    }

    private func hourLabel(_ hour: Int) -> String {
        guard hour > 0 else { return "" }
        var components = DateComponents()
        components.hour = hour
        let date = calendar.date(from: components) ?? .now
        return date.formatted(.dateTime.hour())
    }

    private func dayColumn(_ day: Date) -> some View {
        // Same DST-safe interval as the all-day row above.
        let dayInterval = calendar.dateInterval(of: .day, for: day)
            ?? DateInterval(start: day, duration: 24 * 3600)
        let frames = CalendarTimelineLayoutEngine.frames(
            for: occurrences,
            day: dayInterval,
            calendar: calendar
        )
        return GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .topLeading) {
                gridLines
                    .contentShape(.rect)
                    .gesture(createGesture(day: day))

                ForEach(frames, id: \.occurrence.id) { frame in
                    eventBlock(frame, day: day, columnWidth: width)
                }

                if calendar.isDateInToday(day) {
                    nowIndicator(day: day, width: width)
                }

                if case .create(let createDay) = dragState?.kind, createDay == day, let state = dragState {
                    createPreview(state, width: width)
                }
            }
        }
        .clipped()
    }

    private var gridLines: some View {
        ZStack(alignment: .top) {
            Color.clear
            ForEach(1..<24, id: \.self) { hour in
                Divider()
                    .offset(y: CGFloat(hour) * hourHeight)
            }
        }
    }

    private func nowIndicator(day: Date, width: CGFloat) -> some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            let minutes = timeline.date.timeIntervalSince(day) / 60
            HStack(spacing: 0) {
                Circle().fill(.red).frame(width: 7, height: 7)
                Rectangle().fill(.red).frame(height: 1)
            }
            .frame(width: width)
            .offset(y: CGFloat(minutes / 60) * hourHeight - 3.5)
            .allowsHitTesting(false)
        }
    }

    // MARK: - Event blocks

    @ViewBuilder
    private func eventBlock(
        _ frame: CalendarTimelineLayoutEngine.Frame,
        day: Date,
        columnWidth: CGFloat
    ) -> some View {
        let occurrence = frame.occurrence
        let isDraggable = !recurringEventIDs.contains(occurrence.eventID)
        let blockWidth = columnWidth / CGFloat(frame.columnCount)
        let height = CGFloat(frame.endMinute - frame.startMinute) / 60 * hourHeight
        let dragOffset = activeDragOffset(for: occurrence)

        CalendarTimelineEventBlock(
            occurrence: occurrence,
            isCompact: height < 34
        )
        .frame(width: max(0, blockWidth - 2), height: max(12, height + activeResizeDelta(for: occurrence)))
        .overlay(alignment: .bottom) {
            if isDraggable {
                // Invisible resize handle along the bottom edge.
                Color.clear
                    .frame(height: 7)
                    .contentShape(.rect)
                    .gesture(resizeGesture(occurrence))
                    #if os(macOS)
                    .onHover { inside in
                        if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                    }
                    #endif
            }
        }
        .offset(
            x: CGFloat(frame.columnIndex) * blockWidth + 1 + dragOffset.width,
            y: CGFloat(frame.startMinute) / 60 * hourHeight + dragOffset.height
        )
        .opacity(dragOffset == .zero ? 1 : 0.75)
        .onTapGesture { onSelectOccurrence(occurrence) }
        .contextMenu {
            Button("Edit") { onSelectOccurrence(occurrence) }
            Button("Delete", role: .destructive) { onDeleteOccurrence(occurrence) }
        }
        .gesture(isDraggable ? moveGesture(occurrence, day: day, columnWidth: columnWidth) : nil)
    }

    // MARK: - Gestures

    private func createGesture(day: Date) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                dragState = DragState(
                    kind: .create(day: day),
                    startLocation: dragState?.startLocation ?? value.startLocation,
                    location: value.location
                )
            }
            .onEnded { value in
                dragState = nil
                let startMinute = snappedMinute(fromY: min(value.startLocation.y, value.location.y))
                let endMinute = snappedMinute(fromY: max(value.startLocation.y, value.location.y))
                let start = day.addingTimeInterval(startMinute * 60)
                let end = day.addingTimeInterval(max(endMinute, startMinute + Self.snapMinutes * 2) * 60)
                onCreate(start, end)
            }
    }

    private func moveGesture(_ occurrence: EventOccurrence, day: Date, columnWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 5)
            .onChanged { value in
                dragState = DragState(
                    kind: .move(occurrence),
                    startLocation: value.startLocation,
                    location: value.location
                )
            }
            .onEnded { value in
                dragState = nil
                let minuteDelta = snappedMinuteDelta(value.translation.height)
                let dayDelta = days.count > 1
                    ? Int((value.translation.width / columnWidth).rounded())
                    : 0
                var newStart = occurrence.start.addingTimeInterval(minuteDelta * 60)
                if dayDelta != 0,
                   let shifted = calendar.date(byAdding: .day, value: dayDelta, to: newStart) {
                    newStart = shifted
                }
                if newStart != occurrence.start {
                    onMove(occurrence, newStart)
                }
            }
    }

    private func resizeGesture(_ occurrence: EventOccurrence) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                dragState = DragState(
                    kind: .resize(occurrence),
                    startLocation: value.startLocation,
                    location: value.location
                )
            }
            .onEnded { value in
                dragState = nil
                let minuteDelta = snappedMinuteDelta(value.translation.height)
                let newEnd = occurrence.end.addingTimeInterval(minuteDelta * 60)
                if newEnd > occurrence.start && newEnd != occurrence.end {
                    onResize(occurrence, newEnd)
                }
            }
    }

    // MARK: - Drag helpers

    private func activeDragOffset(for occurrence: EventOccurrence) -> CGSize {
        guard let dragState, case .move(let dragged) = dragState.kind, dragged.id == occurrence.id else {
            return .zero
        }
        return CGSize(
            width: dragState.location.x - dragState.startLocation.x,
            height: dragState.location.y - dragState.startLocation.y
        )
    }

    private func activeResizeDelta(for occurrence: EventOccurrence) -> CGFloat {
        guard let dragState, case .resize(let dragged) = dragState.kind, dragged.id == occurrence.id else {
            return 0
        }
        return dragState.location.y - dragState.startLocation.y
    }

    private func createPreview(_ state: DragState, width: CGFloat) -> some View {
        let top = min(state.startLocation.y, state.location.y)
        let bottom = max(state.startLocation.y, state.location.y)
        return RoundedRectangle(cornerRadius: 5)
            .fill(.tint.opacity(0.18))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.tint.opacity(0.5)))
            .frame(width: max(0, width - 2), height: max(hourHeight / 4, bottom - top))
            .offset(x: 1, y: top)
            .allowsHitTesting(false)
    }

    private func snappedMinute(fromY y: CGFloat) -> Double {
        let raw = Double(y / hourHeight) * 60
        let snapped = (raw / Self.snapMinutes).rounded() * Self.snapMinutes
        return min(max(0, snapped), 24 * 60 - Self.snapMinutes)
    }

    private func snappedMinuteDelta(_ translationHeight: CGFloat) -> Double {
        let raw = Double(translationHeight / hourHeight) * 60
        return (raw / Self.snapMinutes).rounded() * Self.snapMinutes
    }
}
