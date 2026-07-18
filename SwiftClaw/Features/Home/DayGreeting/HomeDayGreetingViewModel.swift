import Combine
import Foundation
import os

@MainActor
final class HomeDayGreetingViewModel: ObservableObject {
    @Published private(set) var greeting = HomeDayGreetingGenerator.initial
    @Published private(set) var blurb = HomeBlurb.initial

    private let contextProvider = HomeDayGreetingContextProvider()
    private let cache = HomeGeneratedContentCache.shared
    private var refreshTask: Task<Void, Never>?

    deinit {
        refreshTask?.cancel()
    }

    func refresh(swiftModel: String, personaKey: String, force: Bool = false) {
        refreshTask?.cancel()

        refreshTask = Task {
            await generateContent(
                swiftModel: swiftModel,
                personaKey: personaKey,
                force: force
            )
        }
    }

    private func generateContent(swiftModel: String, personaKey: String, force: Bool) async {
        guard !ProcessInfo.processInfo.isRunningInPreview else {
            return
        }

        let userName = HomeDayGreetingGenerator.currentUserName

        guard !swiftModel.isEmpty else {
            greeting = HomeDayGreetingGenerator.fallbackGreeting(for: .localOnly(), userName: userName)
            return
        }

        let context = await contextProvider.loadContext()
        guard !Task.isCancelled else { return }

        let key = HomeGeneratedContentCache.Key(
            phase: context.phase.cachePhase,
            persona: personaKey,
            model: swiftModel,
            location: context.locationKey
        )
        let cached = force ? nil : cache.content(for: key)
        if let cachedGreeting = cached?.greeting {
            greeting = cachedGreeting
        }
        if let cachedBlurb = cached?.blurb {
            blurb = cachedBlurb
        }
        guard cached?.greeting == nil || cached?.blurb == nil else { return }

        async let greetingResult = generateGreeting(
            ifMissing: cached?.greeting,
            context: context,
            userName: userName,
            swiftModel: swiftModel
        )
        async let generatedBlurb = generateBlurb(
            ifMissing: cached?.blurb,
            swiftModel: swiftModel
        )
        let (newGreeting, newBlurb) = await (greetingResult, generatedBlurb)
        guard !Task.isCancelled else { return }

        if let newGreeting {
            greeting = newGreeting.displayValue
        }
        if let newBlurb {
            blurb = newBlurb
        }
        cache.store(
            greeting: newGreeting?.cacheValue,
            blurb: newBlurb,
            for: key
        )
    }

    private func generateGreeting(
        ifMissing cached: String?,
        context: HomeDayGreetingContext,
        userName: String,
        swiftModel: String
    ) async -> GeneratedGreeting? {
        guard cached == nil else { return nil }

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
                return GeneratedGreeting(displayValue: cleaned, cacheValue: cleaned)
            } else {
                return GeneratedGreeting(
                    displayValue: HomeDayGreetingGenerator.fallbackGreeting(for: context, userName: userName),
                    cacheValue: nil
                )
            }
        } catch is CancellationError {
            return nil
        } catch {
            HomeDayGreetingGenerator.logger.error("Greeting generation failed: \(String(describing: error), privacy: .public)")
            return GeneratedGreeting(
                displayValue: HomeDayGreetingGenerator.fallbackGreeting(for: context, userName: userName),
                cacheValue: nil
            )
        }
    }

    private func generateBlurb(ifMissing cached: String?, swiftModel: String) async -> String? {
        guard cached == nil else { return nil }

        do {
            let response = try await InferenceService.shared.complete(
                messages: [
                    .system(HomeBlurb.systemPrompt),
                    .user("Write one new blurb."),
                ],
                model: swiftModel,
                systemPromptMode: .standalone
            )

            let cleaned = HomeBlurb.cleaned(response)
            return cleaned.isEmpty ? nil : cleaned
        } catch is CancellationError {
            return nil
        } catch {
            HomeBlurb.logger.error("Blurb generation failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private struct GeneratedGreeting {
        let displayValue: String
        let cacheValue: String?
    }
}

@MainActor
final class HomeGeneratedContentCache {
    struct Key: Hashable, Sendable {
        let phase: HomeDayCachePhase
        let persona: String
        let model: String
        let location: HomeDayGreetingLocationKey
    }

    struct Content: Equatable {
        var greeting: String?
        var blurb: String?
    }

    static let shared = HomeGeneratedContentCache()

    private var values: [Key: Content] = [:]

    func content(for key: Key) -> Content? {
        values[key]
    }

    /// Entries are reused only for exact phase/persona/model/location content;
    /// a changed key is the invalidation signal, while explicit refreshes skip
    /// this lookup and replace the matching entry.
    func store(greeting: String?, blurb: String?, for key: Key) {
        var content = values[key] ?? Content()
        if let greeting {
            content.greeting = greeting
        }
        if let blurb {
            content.blurb = blurb
        }
        values[key] = content
    }
}
