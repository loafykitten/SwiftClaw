import SwiftUI

struct HomeDayGreetingView: View {
    let swiftModel: String

    @StateObject private var viewModel = HomeDayGreetingViewModel()

    var body: some View {
        Text(viewModel.greeting)
            .font(.title3)
            .foregroundStyle(.secondary)
            .contentTransition(.opacity)
            .animation(.easeInOut(duration: 0.4), value: viewModel.greeting)
            .task(id: swiftModel) {
                viewModel.refresh(swiftModel: swiftModel)
            }
    }
}

#Preview {
    HomeDayGreetingView(swiftModel: "")
        .frame(width: 300, height: 80)
}
