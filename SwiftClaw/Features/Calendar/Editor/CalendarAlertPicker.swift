import SwiftUI

/// Alert section of the event editor: relative-offset presets. The model
/// supports multiple alarms; the editor keeps it to one for now (the common
/// case, and Settings can grow a default).
struct CalendarAlertPicker: View {
    @Binding var alarms: [CalendarAlarmPayload]

    private struct Option: Identifiable, Hashable {
        let label: String
        /// nil = no alert.
        let offsetSeconds: TimeInterval?

        var id: String { label }
    }

    private static let options: [Option] = [
        Option(label: "None", offsetSeconds: nil),
        Option(label: "At time of event", offsetSeconds: 0),
        Option(label: "5 minutes before", offsetSeconds: -5 * 60),
        Option(label: "15 minutes before", offsetSeconds: -15 * 60),
        Option(label: "30 minutes before", offsetSeconds: -30 * 60),
        Option(label: "1 hour before", offsetSeconds: -3600),
        Option(label: "1 day before", offsetSeconds: -24 * 3600),
    ]

    var body: some View {
        Picker("Alert", selection: selectionBinding) {
            ForEach(Self.options) { option in
                Text(option.label).tag(option.offsetSeconds)
            }
        }
    }

    private var selectionBinding: Binding<TimeInterval?> {
        Binding(
            get: { alarms.first?.offsetSeconds },
            set: { offset in
                alarms = offset.map { [CalendarAlarmPayload(offsetSeconds: $0)] } ?? []
            }
        )
    }
}
