import SwiftUI

struct CalendarView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "calendar")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Calendar")
                .font(.title2)
                .fontWeight(.semibold)
            Text("No events today")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
