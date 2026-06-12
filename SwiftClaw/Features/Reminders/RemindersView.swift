import SwiftUI

struct RemindersView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "checklist")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Reminders")
                .font(.title2)
                .fontWeight(.semibold)
            Text("No reminders")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
