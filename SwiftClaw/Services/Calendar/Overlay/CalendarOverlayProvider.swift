import EventKit
import Foundation
import Observation
import os

/// Live, display-only Apple Calendar overlay: reads `EKEvent`s for the
/// visible window and serves them as `EventOccurrence` values tagged
/// `.appleOverlay`, so all native calendar views render them alongside the
/// app's own events. Nothing is imported or stored — hide the overlay and
/// they're gone. Toggled by `SettingsKeys.calendarOverlayEnabled`
/// (device-local: it depends on this machine's calendar permission).
@MainActor
@Observable
final class CalendarOverlayProvider {
    static let shared = CalendarOverlayProvider()

    private static let logger = AppLog.make("calendar.overlay")

    /// Bumped whenever the Apple Calendar database changes so views re-fetch.
    private(set) var changeVersion = 0
    private(set) var hasAccess = false

    @ObservationIgnored private var store: EKEventStore?
    @ObservationIgnored private var changeObserver: (any NSObjectProtocol)?
    /// Cache invalidation is keyed by the requested interval plus
    /// `changeVersion`, which advances on activation and EventKit changes.
    @ObservationIgnored private var cachedKey: CacheKey?
    @ObservationIgnored private var cachedOccurrences: [EventOccurrence] = []

    private struct CacheKey: Equatable {
        let window: DateInterval
        let changeVersion: Int
    }

    private init() {}

    /// Called when the overlay toggle turns on; requests access lazily.
    func activate() async {
        invalidateCache()
        changeVersion &+= 1
        guard store == nil else { return }
        let store = EKEventStore()
        self.store = store
        do {
            hasAccess = try await store.requestFullAccessToEvents()
        } catch {
            Self.logger.warning("overlay access request failed: \(String(describing: error))")
            hasAccess = false
        }
        guard hasAccess else { return }
        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: store,
            queue: nil
        ) { _ in
            Task { @MainActor in
                CalendarOverlayProvider.shared.invalidateCache()
                CalendarOverlayProvider.shared.changeVersion += 1
            }
        }
    }

    func deactivate() {
        if let changeObserver {
            NotificationCenter.default.removeObserver(changeObserver)
        }
        changeObserver = nil
        store = nil
        hasAccess = false
        invalidateCache()
    }

    /// Apple Calendar occurrences intersecting `window`, as display-only
    /// values. Empty when the overlay is off or access wasn't granted.
    func occurrences(in window: DateInterval) -> [EventOccurrence] {
        guard hasAccess, let store else { return [] }
        let key = CacheKey(window: window, changeVersion: changeVersion)
        if cachedKey == key {
            return cachedOccurrences
        }
        let predicate = store.predicateForEvents(
            withStart: window.start,
            end: window.end,
            calendars: nil
        )
        let occurrences = store.events(matching: predicate).compactMap { event -> EventOccurrence? in
            guard let start = event.startDate, let end = event.endDate else { return nil }
            return EventOccurrence(
                // Stable per EK occurrence: hash the event identifier into a
                // UUID-shaped namespace so SwiftUI identity holds across
                // refreshes. Never used for repository lookups.
                eventID: Self.stableID(for: event, start: start),
                calendarID: nil,
                title: event.title ?? "",
                start: start,
                end: end,
                isAllDay: event.isAllDay,
                colorHex: EventKitMapping.colorHex(from: event.calendar?.cgColor),
                source: .appleOverlay,
                isOverride: false
            )
        }
        cachedKey = key
        cachedOccurrences = occurrences
        return occurrences
    }

    private func invalidateCache() {
        cachedKey = nil
        cachedOccurrences = []
    }

    private static func stableID(for event: EKEvent, start: Date) -> UUID {
        var hasher = Hasher()
        hasher.combine(event.calendarItemExternalIdentifier ?? event.eventIdentifier ?? "")
        hasher.combine(start.timeIntervalSinceReferenceDate)
        let hash = UInt64(bitPattern: Int64(hasher.finalize()))
        return UUID(uuid: (
            UInt8(truncatingIfNeeded: hash >> 56), UInt8(truncatingIfNeeded: hash >> 48),
            UInt8(truncatingIfNeeded: hash >> 40), UInt8(truncatingIfNeeded: hash >> 32),
            UInt8(truncatingIfNeeded: hash >> 24), UInt8(truncatingIfNeeded: hash >> 16),
            UInt8(truncatingIfNeeded: hash >> 8), UInt8(truncatingIfNeeded: hash),
            0x8A, 0x0C, 0xCA, 0x1E, 0x9D, 0xA2, 0x00, 0x01
        ))
    }
}
