import SwiftUI

struct HomeDayGreetingView: View {
    let swiftModel: String

    @AppStorage(SettingsKeys.personaDisplayName) private var personaDisplayName = ""
    @StateObject private var viewModel = HomeDayGreetingViewModel()

    private var refreshID: String {
        "\(swiftModel)|\(personaDisplayName)"
    }

    var body: some View {
        Text(viewModel.greeting)
            .font(.title3)
            .foregroundStyle(.secondary)
            .contentTransition(.opacity)
            .animation(.easeInOut(duration: 0.4), value: viewModel.greeting)
            .task(id: refreshID) {
                viewModel.refresh(swiftModel: swiftModel)
            }
    }
}

#Preview {
    HomeDayGreetingView(swiftModel: "")
        .frame(width: 300, height: 80)
}
