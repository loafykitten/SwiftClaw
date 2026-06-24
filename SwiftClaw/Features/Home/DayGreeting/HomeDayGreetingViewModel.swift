import Combine
import Foundation
import os

@MainActor
final class HomeDayGreetingViewModel: ObservableObject {
    @Published private(set) var greeting = HomeDayGreetingGenerator.initial

    private let contextProvider = HomeDayGreetingContextProvider()
    private var refreshTask: Task<Void, Never>?

    deinit {
        refreshTask?.cancel()
    }

    func refresh(swiftModel: String) {
        refreshTask?.cancel()

        refreshTask = Task {
            await generateGreeting(swiftModel: swiftModel)
        }
    }

    private func generateGreeting(swiftModel: String) async {
        guard !ProcessInfo.processInfo.isRunningInPreview else {
            return
        }

        let userName = HomeDayGreetingGenerator.currentUserName

        guard !swiftModel.isEmpty else {
            greeting = HomeDayGreetingGenerator.fallbackGreeting(for: .localOnly(), userName: userName)
            return
        }

        let context = await contextProvider.loadContext()

        do {
            let response = try await InferenceService.shared.complete(
                messages: [
                    .system(HomeDayGreetingGenerator.systemPrompt),
                    .user(HomeDayGreetingGenerator.userPrompt(for: context, userName: userName)),
                ],
                model: swiftModel,
                temperature: 0.8,
                systemPromptMode: .standalone
            )

            let cleaned = HomeDayGreetingGenerator.cleaned(response, userName: userName)
            if !cleaned.isEmpty {
                greeting = cleaned
            } else {
                greeting = HomeDayGreetingGenerator.fallbackGreeting(for: context, userName: userName)
            }
        } catch {
            HomeDayGreetingGenerator.logger.error("Greeting generation failed: \(String(describing: error), privacy: .public)")
            greeting = HomeDayGreetingGenerator.fallbackGreeting(for: context, userName: userName)
        }
    }
}
