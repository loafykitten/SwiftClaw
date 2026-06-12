import SwiftUI

struct NotesView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "note.text")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Notes")
                .font(.title2)
                .fontWeight(.semibold)
            Text("No notes yet")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
