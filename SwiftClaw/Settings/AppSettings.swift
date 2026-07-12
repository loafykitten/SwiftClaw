import SwiftUI
import Observation

enum AppTheme: String, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// HSL color model backing the chat blockquote accent (Settings > Appearance >
/// Quote Accent). The app's primary accent follows the macOS system accent, so
/// this only powers the quote styling.
enum QuoteAccent {
    static let defaultSaturation = 0.72
    static let defaultQuoteHue = 0.08
    static let defaultQuoteLightness = 0.62
    static let lightnessRange: ClosedRange<Double> = 0.18...0.95

    static func color(hue: Double, lightness: Double) -> Color {
        let rgb = hslToRGB(
            hue: hue,
            saturation: defaultSaturation,
            lightness: Swift.min(Swift.max(lightness, lightnessRange.lowerBound), lightnessRange.upperBound)
        )

        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    private static func hslToRGB(hue: Double, saturation: Double, lightness: Double) -> (red: Double, green: Double, blue: Double) {
        let hue = Swift.min(Swift.max(hue, 0), 1)
        let saturation = Swift.min(Swift.max(saturation, 0), 1)
        let lightness = Swift.min(Swift.max(lightness, 0), 1)

        guard saturation > 0 else {
            return (lightness, lightness, lightness)
        }

        let chroma = (1 - abs(2 * lightness - 1)) * saturation
        let huePrime = hue == 1 ? 0 : hue * 6
        let x = chroma * (1 - abs(huePrime.truncatingRemainder(dividingBy: 2) - 1))
        let match = lightness - chroma / 2

        let rgb: (red: Double, green: Double, blue: Double)
        switch huePrime {
        case 0..<1:
            rgb = (chroma, x, 0)
        case 1..<2:
            rgb = (x, chroma, 0)
        case 2..<3:
            rgb = (0, chroma, x)
        case 3..<4:
            rgb = (0, x, chroma)
        case 4..<5:
            rgb = (x, 0, chroma)
        default:
            rgb = (chroma, 0, x)
        }

        return (rgb.red + match, rgb.green + match, rgb.blue + match)
    }
}

enum SettingsKeys { }

// MARK: - Appearance keys

extension SettingsKeys {
    static let theme = "settings.appearance.theme"
    static let quoteAccentHue = "settings.appearance.quoteAccentHue"
    static let quoteAccentLightness = "settings.appearance.quoteAccentLightness"
}

// MARK: - Provider keys

extension SettingsKeys {
    static let azureResourceName = "settings.azure.resourceName"
    static let azureAPIKey = "settings.azure.apiKey"
    static let azureDeployments = "settings.azure.deployments"
    static let neuralwattAPIKey = "settings.neuralwatt.apiKey"
    static let neuralwattModels = "settings.neuralwatt.models"
    static let openRouterAPIKey = "settings.openRouter.apiKey"
    static let openRouterModels = "settings.openRouter.models"
    static let braveSearchAPIKey = "settings.braveSearch.apiKey"
    nonisolated static let braveSearchRequestsPerSecond = "settings.braveSearch.requestsPerSecond"
}

// MARK: - Tool keys

extension SettingsKeys {
    static let webSearchEnabled = "settings.tools.webSearch.enabled"
    static let investigationEnabled = "settings.tools.investigation.enabled"
    nonisolated static let investigationMaxSubAgents = "settings.tools.investigation.maxSubAgents"
}

// MARK: - Model behavior keys

extension SettingsKeys {
    static let swiftModel = "settings.behaviors.swiftModel"
    static let clawModel = "settings.behaviors.clawModel"
    static let clawReasoningEffort = "settings.behaviors.clawReasoningEffort"
    static let deepResearchModel = "settings.behaviors.deepResearchModel"
    static let homeModel = "settings.home.model"
    static let homeReasoningEffort = "settings.home.reasoningEffort"
}

// MARK: - Persona keys

extension SettingsKeys {
    static let personaDisplayName = "settings.persona.displayName"
    static let personaAvatarData = "settings.persona.avatarData"
    static let assistantDisplayName = "settings.assistant.displayName"
    static let assistantAvatarData = "settings.assistant.avatarData"
    static let assistantPersonalityPreset = "settings.assistant.personalityPreset"
    static let assistantUsesCustomPersonality = "settings.assistant.usesCustomPersonality"
    static let assistantCustomPersonality = "settings.assistant.customPersonality"
}

// MARK: - Workspace feature keys

extension SettingsKeys {
    static let calendarEnabled = "settings.calendar.enabled"
    static let remindersEnabled = "settings.reminders.enabled"
    static let notesEnabled = "settings.notes.enabled"
}

// MARK: - Calendar keys

extension SettingsKeys {
    /// UUID string of the calendar new events default into.
    static let calendarDefaultCalendarID = "settings.calendar.defaultCalendarID"
    /// App state (not a user setting): whether the first-enable import
    /// onboarding has been completed or dismissed.
    static let calendarHasCompletedOnboarding = "settings.calendar.hasCompletedOnboarding"
    /// Seconds between scheduled calendar-review passes; 0 = manual only.
    static let calendarReviewIntervalSeconds = "settings.calendar.reviewIntervalSeconds"
    /// App state: when the last calendar review pass completed.
    static let calendarLastReviewCompletedAt = "settings.calendar.lastReviewCompletedAt"
    /// Whether Apple Calendar events are shown read-only alongside native
    /// events (device-local — depends on this machine's calendar permission).
    static let calendarOverlayEnabled = "settings.calendar.overlayEnabled"
}

// MARK: - Reminders keys

extension SettingsKeys {
    /// UUID string of the list new reminders default into.
    static let remindersDefaultListID = "settings.reminders.defaultListID"
    /// Minutes after local midnight when date-only (no due time) reminders
    /// fire their alert.
    static let remindersAllDayAlertMinutes = "settings.reminders.allDayAlertMinutes"
    /// App state (not a user setting): whether the first-enable import
    /// onboarding has been completed or dismissed.
    static let remindersHasCompletedOnboarding = "settings.reminders.hasCompletedOnboarding"
}

// MARK: - Notification keys

extension SettingsKeys {
    static let notificationsEnabled = "settings.notifications.enabled"
    static let notificationsNewMailEnabled = "settings.notifications.newMail.enabled"
    static let notificationsReviewResultsEnabled = "settings.notifications.reviewResults.enabled"
    static let notificationsChatRepliesEnabled = "settings.notifications.chatReplies.enabled"
    static let notificationsCalendarAlertsEnabled = "settings.notifications.calendarAlerts.enabled"
    static let notificationsReminderAlertsEnabled = "settings.notifications.reminderAlerts.enabled"
    /// App state (not a user setting): whether the one-time launch offer to
    /// enable notifications has been answered (either way), so it never nags.
    static let notificationsLaunchPromptCompleted = "state.notifications.launchPromptCompleted"
}

// MARK: - Email keys

extension SettingsKeys {
    static let emailEnabled = "settings.email.enabled"
    static let emailAccounts = "settings.email.accounts"
    static let emailImapHost = "settings.email.imapHost"
    static let emailImapPort = "settings.email.imapPort"
    static let emailImapUsername = "settings.email.imapUsername"
    static let emailImapPassword = "settings.email.imapPassword"
    static let emailSmtpHost = "settings.email.smtpHost"
    static let emailSmtpPort = "settings.email.smtpPort"
    static let emailSmtpUsername = "settings.email.smtpUsername"
    static let emailSmtpPassword = "settings.email.smtpPassword"
    static let emailFromAddress = "settings.email.fromAddress"
    static let emailPollIntervalSeconds = "settings.email.pollIntervalSeconds"
    static let emailReviewIntervalSeconds = "settings.email.reviewIntervalSeconds"
    static let emailReviewScheduleMode = "settings.email.reviewScheduleMode"
    static let emailReviewDailyTimes = "settings.email.reviewDailyTimes"
    static let emailLastReviewCompletedAt = "settings.email.lastReviewCompletedAt"
    static let emailReviewMaxThreads = "settings.email.reviewMaxThreads"
    static let emailReviewDefaultMaxAgeEnabled = "settings.email.reviewDefaultMaxAge.enabled"
    static let emailReviewDefaultMaxAgeDays = "settings.email.reviewDefaultMaxAge.days"
    static let emailReviewDefaultIncludeFlagged = "settings.email.reviewDefaultInclude.flagged"
    static let emailReviewDefaultIncludeNotated = "settings.email.reviewDefaultInclude.notated"
    static let emailReviewDefaultIncludeRead = "settings.email.reviewDefaultInclude.read"
    static let emailReviewDefaultIncludeUnread = "settings.email.reviewDefaultInclude.unread"
    static let emailReviewDefaultIncludeArchived = "settings.email.reviewDefaultInclude.archived"
    static let emailReviewDefaultIncludeTrashed = "settings.email.reviewDefaultInclude.trashed"
    static let emailReviewSlideAction = "settings.email.reviewSlideAction"
    static let emailAutoNavigateToReviewChat = "settings.email.autoNavigateToReviewChat"
    static let emailMailboxSyncStates = "settings.email.mailboxSyncStates"
    /// App state (not a user setting): chat IDs currently marked unread,
    /// persisted so the sidebar dots + dock badge survive a relaunch.
    static let unreadChatIDs = "state.chats.unreadChatIDs"
}

enum SettingsNotifications {
    static let keychainDidChange = Notification.Name("settings.keychain.didChange")
    static let emailReviewScheduleDidChange = Notification.Name(
        "settings.email.reviewSchedule.didChange"
    )
    static let calendarReviewScheduleDidChange = Notification.Name(
        "settings.calendar.reviewSchedule.didChange"
    )
    /// Posted after each review pass finishes (whether or not it produced a
    /// card) so views showing "Reviewed … ago / Next review …" re-read the
    /// persisted schedule. Distinct from `emailReviewScheduleDidChange`,
    /// which `EmailWorkflowManager` treats as "settings changed — restart
    /// the review loop"; posting that after every pass would churn the loop.
    static let emailReviewCompletionDidChange = Notification.Name(
        "settings.email.reviewCompletion.didChange"
    )
    static let changedKey = "changedKey"
}

struct AzureDeployment: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var deploymentName: String
    var displayName: String
    var capabilities = ModelCapability.defaultCapabilities

    var modelPickerTitle: String {
        if displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return deploymentName
        }

        return displayName
    }

    init(
        id: UUID = UUID(),
        deploymentName: String,
        displayName: String,
        capabilities: Set<ModelCapability> = ModelCapability.defaultCapabilities
    ) {
        self.id = id
        self.deploymentName = deploymentName
        self.displayName = displayName
        self.capabilities = capabilities
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case deploymentName
        case displayName
        case capabilities
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        deploymentName = try container.decode(String.self, forKey: .deploymentName)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        capabilities = try container.decodeIfPresent(Set<ModelCapability>.self, forKey: .capabilities)
            ?? ModelCapability.defaultCapabilities
    }
}

enum ModelCapability: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case reasoning
    case tools
    case vision
    case json

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .reasoning: "Reasoning"
        case .tools: "Tools"
        case .vision: "Vision"
        case .json: "JSON"
        }
    }

    static let defaultCapabilities: Set<ModelCapability> = [.vision, .json]
}

struct ProviderModel: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var capabilities = ModelCapability.defaultCapabilities

    init(
        id: UUID = UUID(),
        name: String,
        capabilities: Set<ModelCapability> = ModelCapability.defaultCapabilities
    ) {
        self.id = id
        self.name = name
        self.capabilities = capabilities
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case capabilities
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        capabilities = try container.decodeIfPresent(Set<ModelCapability>.self, forKey: .capabilities)
            ?? ModelCapability.defaultCapabilities
    }
}

enum ModelReasoningEffort: String, CaseIterable, Identifiable, Sendable {
    case off
    case minimal
    case low
    case medium
    case high

    var id: String { rawValue }

    static let selectableCases: [Self] = [.off, .low, .medium, .high]

    var displayName: String {
        switch self {
        case .off: "Off"
        case .minimal: "Minimal"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }

    var isReasoningEnabled: Bool {
        self != .off
    }
}

enum EmailReviewScheduleMode: String, CaseIterable, Identifiable, Sendable {
    case interval
    case daily

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .interval: "Interval"
        case .daily: "Daily Times"
        }
    }
}

enum EmailReviewSlideAction: String, CaseIterable, Identifiable, Sendable {
    case review
    case reply
    case flag
    case delete

    var id: String { rawValue }

    var token: ReviewActionToken {
        switch self {
        case .review: .review
        case .reply: .reply
        case .flag: .flag
        case .delete: .delete
        }
    }

    var displayName: String {
        token.displayName
    }
}

/// Discrete choices offered for the Inbox review interval in Settings > Email.
/// `rawValue` is the interval in seconds. Declared in ascending order so
/// `CaseIterable.allCases` yields the menu order.
enum EmailReviewIntervalOption: Int, CaseIterable, Sendable, Hashable, Identifiable {
    case minutes5 = 300
    case minutes10 = 600
    case minutes20 = 1_200
    case minutes30 = 1_800
    case minutes45 = 2_700
    case hour1 = 3_600
    case hour2 = 7_200
    case hour3 = 10_800
    case hour4 = 14_400
    case hour5 = 18_000
    case hour6 = 21_600
    case hour8 = 28_800
    case hour10 = 36_000
    case hour12 = 43_200
    case hour16 = 57_600
    case hour19 = 68_400
    case hour21 = 75_600
    case hour24 = 86_400

    var id: Int { rawValue }

    var displayName: String {
        let totalMinutes = rawValue / 60
        if totalMinutes.isMultiple(of: 60) {
            let hours = totalMinutes / 60
            return "\(hours) hr"
        }
        return "\(totalMinutes) min"
    }
}

/// Discrete choices offered for the mail sync (poll) interval in Settings > Email.
/// `rawValue` is the interval in seconds. Declared in ascending order so
/// `CaseIterable.allCases` yields the menu order.
enum EmailSyncIntervalOption: Int, CaseIterable, Sendable, Hashable, Identifiable {
    case minute1 = 60
    case minutes2 = 120
    case minutes5 = 300
    case minutes10 = 600
    case minutes15 = 900
    case minutes30 = 1_800
    case hour1 = 3_600

    var id: Int { rawValue }

    var displayName: String {
        let totalMinutes = rawValue / 60
        if totalMinutes.isMultiple(of: 60) {
            let hours = totalMinutes / 60
            return "\(hours) hr"
        }
        return "\(totalMinutes) min"
    }
}

nonisolated struct EmailReviewFetchDefaults: Equatable, Sendable {
    var maxAgeDays: Int?
    var limit: Int
    var includeFlagged: Bool
    var includeNotated: Bool
    var includeRead: Bool
    var includeUnread: Bool
    var includeArchived: Bool
    var includeTrashed: Bool

    func filter(applySuppression: Bool) -> EmailReviewFetchFilter {
        var filter = EmailReviewFetchFilter(applySuppression: applySuppression)
        filter.maxAgeDays = maxAgeDays ?? Int.max
        filter.limit = limit
        filter.includeFlagged = includeFlagged
        filter.includeNotated = includeNotated
        filter.includeRead = includeRead
        filter.includeUnread = includeUnread
        filter.includeArchived = includeArchived
        filter.includeTrashed = includeTrashed
        return filter
    }

    var maxAgeDescription: String {
        maxAgeDays.map { "\($0) day\($0 == 1 ? "" : "s")" } ?? "omitted (no hard age cap)"
    }
}

struct ModelAvailabilityLoadFailure: Equatable, Identifiable, Sendable {
    let providerName: String
    let reason: String

    var id: String {
        "\(providerName):\(reason)"
    }

    var message: String {
        "\(providerName): \(reason)"
    }
}

struct ModelAvailabilitySnapshot: Equatable, Sendable {
    let azureDeployments: [AzureDeployment]
    let neuralwattModels: [ProviderModel]
    let openRouterModels: [ProviderModel]
    let loadFailures: [ModelAvailabilityLoadFailure]

    var availableModels: [String] {
        SettingsStorage.availableModels(
            azureDeployments: azureDeployments,
            neuralwattModels: neuralwattModels,
            openRouterModels: openRouterModels
        )
    }

    func availableModels(requiresReasoning: Bool?) -> [String] {
        guard let requiresReasoning else {
            return availableModels
        }

        return availableModels.filter { selection in
            let capabilities = capabilities(for: selection)
            return requiresReasoning
                ? capabilities.contains(.reasoning)
                : !capabilities.contains(.reasoning)
        }
    }

    func capabilities(for modelSelection: String) -> Set<ModelCapability> {
        let selection = modelSelection.trimmingCharacters(in: .whitespacesAndNewlines)

        if let title = selection.removingPrefix(InferenceProviderID.azure.modelPrefix) {
            return azureDeployments
                .first { $0.modelPickerTitle == title }?
                .capabilities ?? ModelCapability.defaultCapabilities
        }

        if let model = selection.removingPrefix(InferenceProviderID.neuralwatt.modelPrefix) {
            return neuralwattModels
                .first { $0.name == model }?
                .capabilities ?? ModelCapability.defaultCapabilities
        }

        if let model = selection.removingPrefix(InferenceProviderID.openRouter.modelPrefix) {
            return openRouterModels
                .first { $0.name == model }?
                .capabilities ?? ModelCapability.defaultCapabilities
        }

        return ModelCapability.defaultCapabilities
    }
}

@MainActor
@Observable
final class ModelAvailabilityStore {
    static let shared = ModelAvailabilityStore()

    private let userDefaults: UserDefaults
    private(set) var snapshot: ModelAvailabilitySnapshot

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        snapshot = SettingsStorage.modelAvailabilitySnapshot(userDefaults: userDefaults)
    }

    var availableModels: [String] {
        snapshot.availableModels
    }

    var loadFailures: [ModelAvailabilityLoadFailure] {
        snapshot.loadFailures
    }

    func availableModels(requiresReasoning: Bool?) -> [String] {
        snapshot.availableModels(requiresReasoning: requiresReasoning)
    }

    func capabilities(for modelSelection: String) -> Set<ModelCapability> {
        snapshot.capabilities(for: modelSelection)
    }

    func refresh() {
        SettingsStorage.invalidateModelAvailabilityCache(userDefaults: userDefaults)
        snapshot = SettingsStorage.modelAvailabilitySnapshot(userDefaults: userDefaults)
    }
}

private struct ModelAvailabilityFingerprint: Equatable, Sendable {
    let azureDeploymentsData: Data?
    let neuralwattModelsData: Data?
    let neuralwattLegacyModels: [String]?
    let openRouterModelsData: Data?
    let openRouterLegacyModels: [String]?

    init(userDefaults: UserDefaults) {
        azureDeploymentsData = userDefaults.data(forKey: SettingsKeys.azureDeployments)
        neuralwattModelsData = userDefaults.data(forKey: SettingsKeys.neuralwattModels)
        neuralwattLegacyModels = userDefaults.stringArray(forKey: SettingsKeys.neuralwattModels)
        openRouterModelsData = userDefaults.data(forKey: SettingsKeys.openRouterModels)
        openRouterLegacyModels = userDefaults.stringArray(forKey: SettingsKeys.openRouterModels)
    }
}

private struct CachedModelAvailability: Sendable {
    let fingerprint: ModelAvailabilityFingerprint
    let snapshot: ModelAvailabilitySnapshot
}

private final class ModelAvailabilityCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cachedByDefaults: [ObjectIdentifier: CachedModelAvailability] = [:]

    func snapshot(userDefaults: UserDefaults) -> ModelAvailabilitySnapshot {
        let defaultsID = ObjectIdentifier(userDefaults)
        let fingerprint = ModelAvailabilityFingerprint(userDefaults: userDefaults)

        lock.lock()
        if let cached = cachedByDefaults[defaultsID], cached.fingerprint == fingerprint {
            lock.unlock()
            return cached.snapshot
        }
        lock.unlock()

        let snapshot = Self.decodeSnapshot(from: fingerprint)

        lock.lock()
        cachedByDefaults[defaultsID] = CachedModelAvailability(
            fingerprint: fingerprint,
            snapshot: snapshot
        )
        lock.unlock()

        return snapshot
    }

    func invalidate(userDefaults: UserDefaults) {
        let defaultsID = ObjectIdentifier(userDefaults)
        lock.lock()
        cachedByDefaults.removeValue(forKey: defaultsID)
        lock.unlock()
    }

    private static func decodeSnapshot(from fingerprint: ModelAvailabilityFingerprint) -> ModelAvailabilitySnapshot {
        var failures: [ModelAvailabilityLoadFailure] = []
        let azureDeployments: [AzureDeployment] = decodeJSONList(
            from: fingerprint.azureDeploymentsData,
            providerName: "Azure",
            valueDescription: "deployments",
            failures: &failures
        )
        let neuralwattModels = decodeProviderModels(
            from: fingerprint.neuralwattModelsData,
            legacyModels: fingerprint.neuralwattLegacyModels,
            providerName: "Neuralwatt",
            failures: &failures
        )
        let openRouterModels = decodeProviderModels(
            from: fingerprint.openRouterModelsData,
            legacyModels: fingerprint.openRouterLegacyModels,
            providerName: "OpenRouter",
            failures: &failures
        )

        return ModelAvailabilitySnapshot(
            azureDeployments: azureDeployments,
            neuralwattModels: neuralwattModels,
            openRouterModels: openRouterModels,
            loadFailures: failures
        )
    }

    private static func decodeProviderModels(
        from data: Data?,
        legacyModels: [String]?,
        providerName: String,
        failures: inout [ModelAvailabilityLoadFailure]
    ) -> [ProviderModel] {
        if let data {
            do {
                return try JSONDecoder().decode([ProviderModel].self, from: data)
            } catch {
                failures.append(
                    ModelAvailabilityLoadFailure(
                        providerName: providerName,
                        reason: "Saved models could not be decoded. Re-save this provider to restore model pickers."
                    )
                )
            }
        }

        return legacyModels?.map {
            ProviderModel(name: $0)
        } ?? []
    }

    private static func decodeJSONList<T: Decodable>(
        from data: Data?,
        providerName: String,
        valueDescription: String,
        failures: inout [ModelAvailabilityLoadFailure]
    ) -> [T] {
        guard let data else {
            return []
        }

        do {
            return try JSONDecoder().decode([T].self, from: data)
        } catch {
            failures.append(
                ModelAvailabilityLoadFailure(
                    providerName: providerName,
                    reason: "Saved \(valueDescription) could not be decoded. Re-save this provider to restore model pickers."
                )
            )
            return []
        }
    }
}

private extension ClosedRange where Bound == Int {
    func clamping(_ value: Int) -> Int {
        Swift.min(Swift.max(value, lowerBound), upperBound)
    }
}

enum SettingsStorage {
    private static let modelAvailabilityCache = ModelAvailabilityCache()

    static func loadModelSelection(
        forKey key: String,
        userDefaults: UserDefaults = .standard
    ) -> String {
        userDefaults.string(forKey: key) ?? ""
    }

    /// Default reasoning effort for the Claw model — the companion model is
    /// designated for reasoning tasks, so it defaults to a non-`.off` effort.
    static let defaultClawReasoningEffort: ModelReasoningEffort = .medium

    static func loadClawReasoningEffort(userDefaults: UserDefaults = .standard) -> ModelReasoningEffort {
        let raw = userDefaults.string(forKey: SettingsKeys.clawReasoningEffort)
        return raw.flatMap(ModelReasoningEffort.init(rawValue:)) ?? defaultClawReasoningEffort
    }

    /// Default reasoning effort the chat composer applies when the model
    /// selection changes (its `onChange(of: modelSelection)` hook). Keeps the
    /// rule in one place, testable without a SwiftUI host.
    ///
    /// - Claw model → the Claw's configured effort (Settings > Model
    ///   Behaviors), so the composer mirrors the companion preset.
    /// - Any other reasoning-capable model → Low.
    /// - Non-reasoning models → `nil`: the reasoning menu is hidden for those
    ///   models, and any previously chosen effort is left untouched until the
    ///   next reasoning-capable selection.
    static func composerDefaultReasoningEffort(
        isClawModel: Bool,
        supportsReasoning: Bool,
        clawReasoningEffort: ModelReasoningEffort = SettingsStorage.loadClawReasoningEffort()
    ) -> ModelReasoningEffort? {
        guard supportsReasoning else { return nil }
        return isClawModel ? clawReasoningEffort : .low
    }

    /// Canonical Codable ⇄ `UserDefaults` helpers: persist a `Codable` value as
    /// JSON under a settings key, decoding with a fallback when the key is
    /// missing or unreadable. Centralizes the encode/decode dance that several
    /// stores otherwise hand-roll.
    static func loadCodable<T: Decodable>(
        _ type: T.Type,
        forKey key: String,
        default fallback: T,
        userDefaults: UserDefaults = .standard
    ) -> T {
        guard let data = userDefaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(T.self, from: data) else {
            return fallback
        }
        return decoded
    }

    static func saveCodable(
        _ value: some Encodable,
        forKey key: String,
        userDefaults: UserDefaults = .standard
    ) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        userDefaults.set(data, forKey: key)
    }

    /// Chat IDs currently marked unread. Written by `AppRouter` on every
    /// unread mutation and read back at launch so the indicators (and the
    /// email review scheduler's unread-review guard) survive a relaunch.
    static func loadUnreadChatIDs(userDefaults: UserDefaults = .standard) -> Set<UUID> {
        Set(loadCodable(
            [UUID].self,
            forKey: SettingsKeys.unreadChatIDs,
            default: [],
            userDefaults: userDefaults
        ))
    }

    static func saveUnreadChatIDs(_ ids: Set<UUID>, userDefaults: UserDefaults = .standard) {
        saveCodable(Array(ids), forKey: SettingsKeys.unreadChatIDs, userDefaults: userDefaults)
    }

    static func loadAvailableModels(
        requiresReasoning: Bool? = nil,
        userDefaults: UserDefaults = .standard
    ) -> [String] {
        modelAvailabilitySnapshot(userDefaults: userDefaults)
            .availableModels(requiresReasoning: requiresReasoning)
    }

    static func modelAvailabilitySnapshot(userDefaults: UserDefaults = .standard) -> ModelAvailabilitySnapshot {
        modelAvailabilityCache.snapshot(userDefaults: userDefaults)
    }

    static func invalidateModelAvailabilityCache(userDefaults: UserDefaults = .standard) {
        modelAvailabilityCache.invalidate(userDefaults: userDefaults)
    }

    static func availableModels(
        azureDeployments: [AzureDeployment],
        neuralwattModels: [ProviderModel],
        openRouterModels: [ProviderModel]
    ) -> [String] {
        func isNamed(_ name: String) -> Bool {
            !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        let azureModels = azureDeployments
            .filter { isNamed($0.modelPickerTitle) }
            .map { InferenceProviderID.azure.modelPrefix + $0.modelPickerTitle }
        let neuralwatt = neuralwattModels
            .filter { isNamed($0.name) }
            .map { InferenceProviderID.neuralwatt.modelPrefix + $0.name }
        let openRouter = openRouterModels
            .filter { isNamed($0.name) }
            .map { InferenceProviderID.openRouter.modelPrefix + $0.name }

        return azureModels + neuralwatt + openRouter
    }

    static func capabilities(
        for modelSelection: String,
        userDefaults: UserDefaults = .standard
    ) -> Set<ModelCapability> {
        modelAvailabilitySnapshot(userDefaults: userDefaults)
            .capabilities(for: modelSelection)
    }

    static func loadDeployments(userDefaults: UserDefaults = .standard) -> [AzureDeployment] {
        modelAvailabilitySnapshot(userDefaults: userDefaults).azureDeployments
    }

    static func saveDeployments(_ deployments: [AzureDeployment], userDefaults: UserDefaults = .standard) {
        saveCodable(deployments, forKey: SettingsKeys.azureDeployments, userDefaults: userDefaults)
        invalidateModelAvailabilityCache(userDefaults: userDefaults)
    }

    static func loadProviderModels(
        forKey key: String,
        userDefaults: UserDefaults = .standard
    ) -> [ProviderModel] {
        if key == SettingsKeys.neuralwattModels {
            return modelAvailabilitySnapshot(userDefaults: userDefaults).neuralwattModels
        }

        if key == SettingsKeys.openRouterModels {
            return modelAvailabilitySnapshot(userDefaults: userDefaults).openRouterModels
        }

        if let data = userDefaults.data(forKey: key),
           let models = try? JSONDecoder().decode([ProviderModel].self, from: data) {
            return models
        }

        return userDefaults.stringArray(forKey: key)?.map {
            ProviderModel(name: $0)
        } ?? []
    }

    static func saveProviderModels(
        _ models: [ProviderModel],
        forKey key: String,
        userDefaults: UserDefaults = .standard
    ) {
        saveCodable(models, forKey: key, userDefaults: userDefaults)
        if key == SettingsKeys.neuralwattModels || key == SettingsKeys.openRouterModels {
            invalidateModelAvailabilityCache(userDefaults: userDefaults)
        }
    }

    nonisolated static let defaultBraveSearchRequestsPerSecond = 1.0
    nonisolated static let braveSearchRequestsPerSecondRange: ClosedRange<Double> = 0.5...20
    static let defaultWebSearchEnabled = true
    static let defaultInvestigationEnabled = true

    static func isWebSearchEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        toolEnabled(
            forKey: SettingsKeys.webSearchEnabled,
            defaultValue: defaultWebSearchEnabled,
            userDefaults: userDefaults
        )
    }

    static func isInvestigationEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        isWebSearchEnabled(userDefaults: userDefaults)
            && toolEnabled(
                forKey: SettingsKeys.investigationEnabled,
                defaultValue: defaultInvestigationEnabled,
                userDefaults: userDefaults
            )
    }

    nonisolated static func loadBraveSearchRequestsPerSecond(userDefaults: UserDefaults = .standard) -> Double {
        let stored = userDefaults.double(forKey: SettingsKeys.braveSearchRequestsPerSecond)

        guard stored > 0 else {
            return defaultBraveSearchRequestsPerSecond
        }

        return Swift.min(
            Swift.max(stored, braveSearchRequestsPerSecondRange.lowerBound),
            braveSearchRequestsPerSecondRange.upperBound
        )
    }

    nonisolated static let defaultInvestigationMaxSubAgents = 3
    nonisolated static let investigationMaxSubAgentsRange: ClosedRange<Int> = 1...5

    static let defaultEmailEnabled = false
    nonisolated static let defaultEmailImapPort = 993
    nonisolated static let defaultEmailSmtpPort = 587
    static let defaultEmailPollIntervalSeconds = 300
    static let emailPollIntervalSecondsRange: ClosedRange<Int> = 60...3600
    static let defaultEmailReviewIntervalSeconds = 1800
    static let emailReviewIntervalSecondsRange: ClosedRange<Int> = 300...86400
    static let emailReviewFirstRunMinimumDelaySeconds = 60
    static let defaultEmailReviewScheduleMode = EmailReviewScheduleMode.interval
    static let defaultEmailReviewDailyTimes = [9 * 60]
    static let emailReviewDailyTimeRange: ClosedRange<Int> = 0...1439
    nonisolated static let defaultEmailReviewMaxThreads = 10
    static let emailReviewMaxThreadsRange: ClosedRange<Int> = 5...100
    static let defaultEmailReviewDefaultMaxAgeEnabled = false
    static let defaultEmailReviewDefaultMaxAgeDays = 30
    static let emailReviewDefaultMaxAgeDaysRange: ClosedRange<Int> = 1...365
    static let defaultEmailReviewDefaultIncludeFlagged = true
    static let defaultEmailReviewDefaultIncludeNotated = true
    static let defaultEmailReviewDefaultIncludeRead = true
    static let defaultEmailReviewDefaultIncludeUnread = true
    static let defaultEmailReviewDefaultIncludeArchived = false
    static let defaultEmailReviewDefaultIncludeTrashed = false
    static let defaultEmailReviewSlideAction = EmailReviewSlideAction.review
    static let defaultEmailAutoNavigateToReviewChat = false

    static func isEmailEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        toolEnabled(
            forKey: SettingsKeys.emailEnabled,
            defaultValue: defaultEmailEnabled,
            userDefaults: userDefaults
        )
    }

    /// Notifications are opt-in: the master toggle defaults to off and the
    /// authorization prompt fires only when the user first enables it.
    static let defaultNotificationsEnabled = false
    static let defaultNewMailNotificationsEnabled = true
    static let defaultReviewResultNotificationsEnabled = true
    static let defaultChatReplyNotificationsEnabled = true

    static func areNotificationsEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        boolSetting(
            forKey: SettingsKeys.notificationsEnabled,
            defaultValue: defaultNotificationsEnabled,
            userDefaults: userDefaults
        )
    }

    static func areNewMailNotificationsEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        areNotificationsEnabled(userDefaults: userDefaults)
            && boolSetting(
                forKey: SettingsKeys.notificationsNewMailEnabled,
                defaultValue: defaultNewMailNotificationsEnabled,
                userDefaults: userDefaults
            )
    }

    static func areReviewResultNotificationsEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        areNotificationsEnabled(userDefaults: userDefaults)
            && boolSetting(
                forKey: SettingsKeys.notificationsReviewResultsEnabled,
                defaultValue: defaultReviewResultNotificationsEnabled,
                userDefaults: userDefaults
            )
    }

    static func hasCompletedNotificationsLaunchPrompt(userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.bool(forKey: SettingsKeys.notificationsLaunchPromptCompleted)
    }

    static func markNotificationsLaunchPromptCompleted(userDefaults: UserDefaults = .standard) {
        userDefaults.set(true, forKey: SettingsKeys.notificationsLaunchPromptCompleted)
    }

    static func areChatReplyNotificationsEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        areNotificationsEnabled(userDefaults: userDefaults)
            && boolSetting(
                forKey: SettingsKeys.notificationsChatRepliesEnabled,
                defaultValue: defaultChatReplyNotificationsEnabled,
                userDefaults: userDefaults
            )
    }

    /// Calendar review default cadence: daily. 0 disables the scheduled loop
    /// (manual "Review Now" still works).
    static let defaultCalendarReviewIntervalSeconds = 24 * 3600

    static func loadCalendarReviewInterval(userDefaults: UserDefaults = .standard) -> Int {
        guard userDefaults.object(forKey: SettingsKeys.calendarReviewIntervalSeconds) != nil else {
            return defaultCalendarReviewIntervalSeconds
        }
        return max(0, userDefaults.integer(forKey: SettingsKeys.calendarReviewIntervalSeconds))
    }

    static func loadCalendarLastReviewCompletedAt(userDefaults: UserDefaults = .standard) -> Date? {
        userDefaults.object(forKey: SettingsKeys.calendarLastReviewCompletedAt) as? Date
    }

    static func saveCalendarLastReviewCompletedAt(_ date: Date, userDefaults: UserDefaults = .standard) {
        userDefaults.set(date, forKey: SettingsKeys.calendarLastReviewCompletedAt)
    }

    static let defaultCalendarOverlayEnabled = false

    static func isCalendarOverlayEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        boolSetting(
            forKey: SettingsKeys.calendarOverlayEnabled,
            defaultValue: defaultCalendarOverlayEnabled,
            userDefaults: userDefaults
        )
    }

    static let defaultCalendarAlertNotificationsEnabled = true

    static func areCalendarAlertNotificationsEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        areNotificationsEnabled(userDefaults: userDefaults)
            && boolSetting(
                forKey: SettingsKeys.notificationsCalendarAlertsEnabled,
                defaultValue: defaultCalendarAlertNotificationsEnabled,
                userDefaults: userDefaults
            )
    }

    static let defaultCalendarEnabled = false
    static let defaultRemindersEnabled = false
    static let defaultNotesEnabled = false

    static func isCalendarEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        toolEnabled(
            forKey: SettingsKeys.calendarEnabled,
            defaultValue: defaultCalendarEnabled,
            userDefaults: userDefaults
        )
    }

    static func loadCalendarDefaultCalendarID(userDefaults: UserDefaults = .standard) -> UUID? {
        userDefaults.string(forKey: SettingsKeys.calendarDefaultCalendarID)
            .flatMap(UUID.init(uuidString:))
    }

    static func saveCalendarDefaultCalendarID(_ id: UUID?, userDefaults: UserDefaults = .standard) {
        if let id {
            userDefaults.set(id.uuidString, forKey: SettingsKeys.calendarDefaultCalendarID)
        } else {
            userDefaults.removeObject(forKey: SettingsKeys.calendarDefaultCalendarID)
        }
    }

    static func isRemindersEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        toolEnabled(
            forKey: SettingsKeys.remindersEnabled,
            defaultValue: defaultRemindersEnabled,
            userDefaults: userDefaults
        )
    }

    static let defaultReminderAlertNotificationsEnabled = true

    static func areReminderAlertNotificationsEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        areNotificationsEnabled(userDefaults: userDefaults)
            && boolSetting(
                forKey: SettingsKeys.notificationsReminderAlertsEnabled,
                defaultValue: defaultReminderAlertNotificationsEnabled,
                userDefaults: userDefaults
            )
    }

    /// 9:00 AM — when date-only reminders fire their alert.
    static let defaultRemindersAllDayAlertMinutes = 9 * 60

    static func loadRemindersAllDayAlertMinutes(userDefaults: UserDefaults = .standard) -> Int {
        guard userDefaults.object(forKey: SettingsKeys.remindersAllDayAlertMinutes) != nil else {
            return defaultRemindersAllDayAlertMinutes
        }
        let minutes = userDefaults.integer(forKey: SettingsKeys.remindersAllDayAlertMinutes)
        return min(max(minutes, 0), 24 * 60 - 1)
    }

    static func saveRemindersAllDayAlertMinutes(_ minutes: Int, userDefaults: UserDefaults = .standard) {
        userDefaults.set(minutes, forKey: SettingsKeys.remindersAllDayAlertMinutes)
    }

    static func loadRemindersDefaultListID(userDefaults: UserDefaults = .standard) -> UUID? {
        userDefaults.string(forKey: SettingsKeys.remindersDefaultListID)
            .flatMap(UUID.init(uuidString:))
    }

    static func saveRemindersDefaultListID(_ id: UUID?, userDefaults: UserDefaults = .standard) {
        if let id {
            userDefaults.set(id.uuidString, forKey: SettingsKeys.remindersDefaultListID)
        } else {
            userDefaults.removeObject(forKey: SettingsKeys.remindersDefaultListID)
        }
    }

    static func isNotesEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        toolEnabled(
            forKey: SettingsKeys.notesEnabled,
            defaultValue: defaultNotesEnabled,
            userDefaults: userDefaults
        )
    }

    static func isWorkspaceFeatureEnabled(
        _ feature: WorkspaceFeature,
        userDefaults: UserDefaults = .standard
    ) -> Bool {
        switch feature {
        case .email: isEmailEnabled(userDefaults: userDefaults)
        case .calendar: isCalendarEnabled(userDefaults: userDefaults)
        case .reminders: isRemindersEnabled(userDefaults: userDefaults)
        case .notes: isNotesEnabled(userDefaults: userDefaults)
        }
    }

    static func defaultWorkspaceFeatureEnabled(_ feature: WorkspaceFeature) -> Bool {
        switch feature {
        case .email: defaultEmailEnabled
        case .calendar: defaultCalendarEnabled
        case .reminders: defaultRemindersEnabled
        case .notes: defaultNotesEnabled
        }
    }

    static func loadEmailPollInterval(userDefaults: UserDefaults = .standard) -> Int {
        let stored = userDefaults.integer(forKey: SettingsKeys.emailPollIntervalSeconds)
        guard stored > 0 else {
            return defaultEmailPollIntervalSeconds
        }
        return emailPollIntervalSecondsRange.clamping(stored)
    }

    static func loadEmailReviewInterval(userDefaults: UserDefaults = .standard) -> Int {
        let stored = userDefaults.integer(forKey: SettingsKeys.emailReviewIntervalSeconds)
        guard stored > 0 else {
            return defaultEmailReviewIntervalSeconds
        }
        // Snap any stale value (e.g. a fine-grained slider setting from before
        // the discrete picker shipped) to the closest offered option so the
        // runtime always agrees with what Settings can show.
        return nearestEmailReviewIntervalSeconds(stored)
    }

    /// Clamps `seconds` to the configured range, then snaps it to the closest
    /// `EmailReviewIntervalOption`. Used both by the loader and the Settings
    /// binding so a stored custom value always resolves to a real option.
    static func nearestEmailReviewIntervalSeconds(_ seconds: Int) -> Int {
        let clamped = emailReviewIntervalSecondsRange.clamping(seconds)
        let options = EmailReviewIntervalOption.allCases.map(\.rawValue)
        return options.min(by: { abs($0 - clamped) < abs($1 - clamped) }) ?? clamped
    }

    /// Clamps `seconds` to the configured range, then snaps it to the closest
    /// `EmailSyncIntervalOption`. Used both by the loader and the Settings
    /// binding so a stored custom value always resolves to a real option.
    static func nearestEmailSyncIntervalSeconds(_ seconds: Int) -> Int {
        let clamped = emailPollIntervalSecondsRange.clamping(seconds)
        let options = EmailSyncIntervalOption.allCases.map(\.rawValue)
        return options.min(by: { abs($0 - clamped) < abs($1 - clamped) }) ?? clamped
    }

    static func loadEmailReviewScheduleMode(userDefaults: UserDefaults = .standard) -> EmailReviewScheduleMode {
        let raw = userDefaults.string(forKey: SettingsKeys.emailReviewScheduleMode)
        return raw.flatMap(EmailReviewScheduleMode.init(rawValue:)) ?? defaultEmailReviewScheduleMode
    }

    static func loadEmailReviewDailyTimes(userDefaults: UserDefaults = .standard) -> [Int] {
        let values: [Int]
        if let data = userDefaults.data(forKey: SettingsKeys.emailReviewDailyTimes),
           let decoded = try? JSONDecoder().decode([Int].self, from: data) {
            values = decoded
        } else {
            values = defaultEmailReviewDailyTimes
        }

        return normalizedEmailReviewDailyTimes(values)
    }

    static func saveEmailReviewDailyTimes(_ times: [Int], userDefaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(normalizedEmailReviewDailyTimes(times)) else {
            return
        }
        userDefaults.set(data, forKey: SettingsKeys.emailReviewDailyTimes)
    }

    static func loadEmailLastReviewCompletedAt(userDefaults: UserDefaults = .standard) -> Date? {
        userDefaults.object(forKey: SettingsKeys.emailLastReviewCompletedAt) as? Date
    }

    static func saveEmailLastReviewCompletedAt(_ date: Date, userDefaults: UserDefaults = .standard) {
        userDefaults.set(date, forKey: SettingsKeys.emailLastReviewCompletedAt)
    }

    static func nextEmailReviewDate(
        now: Date = Date(),
        userDefaults: UserDefaults = .standard,
        calendar: Calendar = .current
    ) -> Date {
        nextEmailReviewDate(
            now: now,
            lastCompletedAt: loadEmailLastReviewCompletedAt(userDefaults: userDefaults),
            userDefaults: userDefaults,
            calendar: calendar
        )
    }

    static func nextEmailReviewDate(
        now: Date,
        lastCompletedAt: Date?,
        userDefaults: UserDefaults = .standard,
        calendar: Calendar = .current
    ) -> Date {
        switch loadEmailReviewScheduleMode(userDefaults: userDefaults) {
        case .interval:
            let interval = TimeInterval(loadEmailReviewInterval(userDefaults: userDefaults))
            guard let lastCompletedAt else {
                return now.addingTimeInterval(max(TimeInterval(emailReviewFirstRunMinimumDelaySeconds), interval / 4))
            }
            return lastCompletedAt.addingTimeInterval(interval)
        case .daily:
            let next = nextDailyEmailReviewDate(
                now: now,
                lastCompletedAt: lastCompletedAt,
                times: loadEmailReviewDailyTimes(userDefaults: userDefaults),
                calendar: calendar
            )
            guard lastCompletedAt != nil else {
                return next <= now
                    ? now.addingTimeInterval(TimeInterval(emailReviewFirstRunMinimumDelaySeconds))
                    : next
            }
            return next
        }
    }

    static func nextDailyEmailReviewDate(
        now: Date,
        lastCompletedAt: Date?,
        times: [Int],
        calendar: Calendar = .current
    ) -> Date {
        let dailyTimes = times.isEmpty ? defaultEmailReviewDailyTimes : times.sorted()
        let todayOccurrences = dailyTimes.compactMap {
            dailyReviewDate(minutesAfterMidnight: $0, onDayContaining: now, calendar: calendar)
        }
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now.addingTimeInterval(-86_400)
        let yesterdayOccurrences = dailyTimes.compactMap {
            dailyReviewDate(minutesAfterMidnight: $0, onDayContaining: yesterday, calendar: calendar)
        }
        let elapsed = (yesterdayOccurrences + todayOccurrences).filter { $0 <= now }

        if let latestElapsed = elapsed.max(),
           lastCompletedAt.map({ $0 < latestElapsed }) ?? true {
            return now
        }

        if let nextToday = todayOccurrences.filter({ $0 > now }).min() {
            return nextToday
        }

        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now.addingTimeInterval(86_400)
        return dailyTimes.compactMap {
            dailyReviewDate(minutesAfterMidnight: $0, onDayContaining: tomorrow, calendar: calendar)
        }.min() ?? now.addingTimeInterval(86_400)
    }

    static func dailyReviewDate(
        minutesAfterMidnight: Int,
        onDayContaining date: Date,
        calendar: Calendar = .current
    ) -> Date? {
        let clamped = emailReviewDailyTimeRange.clamping(minutesAfterMidnight)
        let start = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .minute, value: clamped, to: start)
    }

    static func dailyReviewMinutes(afterMidnightFrom date: Date, calendar: Calendar = .current) -> Int {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let hour = components.hour ?? 0
        let minute = components.minute ?? 0
        return emailReviewDailyTimeRange.clamping(hour * 60 + minute)
    }

    static func loadEmailReviewMaxThreads(userDefaults: UserDefaults = .standard) -> Int {
        let stored = userDefaults.integer(forKey: SettingsKeys.emailReviewMaxThreads)
        guard stored > 0 else {
            return defaultEmailReviewMaxThreads
        }
        return emailReviewMaxThreadsRange.clamping(stored)
    }

    static func loadEmailReviewFetchDefaults(userDefaults: UserDefaults = .standard) -> EmailReviewFetchDefaults {
        let maxAgeEnabled = boolSetting(
            forKey: SettingsKeys.emailReviewDefaultMaxAgeEnabled,
            defaultValue: defaultEmailReviewDefaultMaxAgeEnabled,
            userDefaults: userDefaults
        )
        let rawMaxAgeDays = userDefaults.integer(forKey: SettingsKeys.emailReviewDefaultMaxAgeDays)
        let maxAgeDays = emailReviewDefaultMaxAgeDaysRange.clamping(
            rawMaxAgeDays > 0 ? rawMaxAgeDays : defaultEmailReviewDefaultMaxAgeDays
        )

        return EmailReviewFetchDefaults(
            maxAgeDays: maxAgeEnabled ? maxAgeDays : nil,
            limit: loadEmailReviewMaxThreads(userDefaults: userDefaults),
            includeFlagged: boolSetting(
                forKey: SettingsKeys.emailReviewDefaultIncludeFlagged,
                defaultValue: defaultEmailReviewDefaultIncludeFlagged,
                userDefaults: userDefaults
            ),
            includeNotated: boolSetting(
                forKey: SettingsKeys.emailReviewDefaultIncludeNotated,
                defaultValue: defaultEmailReviewDefaultIncludeNotated,
                userDefaults: userDefaults
            ),
            includeRead: boolSetting(
                forKey: SettingsKeys.emailReviewDefaultIncludeRead,
                defaultValue: defaultEmailReviewDefaultIncludeRead,
                userDefaults: userDefaults
            ),
            includeUnread: boolSetting(
                forKey: SettingsKeys.emailReviewDefaultIncludeUnread,
                defaultValue: defaultEmailReviewDefaultIncludeUnread,
                userDefaults: userDefaults
            ),
            includeArchived: boolSetting(
                forKey: SettingsKeys.emailReviewDefaultIncludeArchived,
                defaultValue: defaultEmailReviewDefaultIncludeArchived,
                userDefaults: userDefaults
            ),
            includeTrashed: boolSetting(
                forKey: SettingsKeys.emailReviewDefaultIncludeTrashed,
                defaultValue: defaultEmailReviewDefaultIncludeTrashed,
                userDefaults: userDefaults
            )
        )
    }

    static func loadEmailReviewSlideAction(userDefaults: UserDefaults = .standard) -> EmailReviewSlideAction {
        userDefaults.string(forKey: SettingsKeys.emailReviewSlideAction)
            .flatMap(EmailReviewSlideAction.init(rawValue:))
            ?? defaultEmailReviewSlideAction
    }

    nonisolated static func loadInvestigationMaxSubAgents(userDefaults: UserDefaults = .standard) -> Int {
        let stored = userDefaults.integer(forKey: SettingsKeys.investigationMaxSubAgents)

        guard stored > 0 else {
            return defaultInvestigationMaxSubAgents
        }

        return Swift.min(
            Swift.max(stored, investigationMaxSubAgentsRange.lowerBound),
            investigationMaxSubAgentsRange.upperBound
        )
    }

    private static func toolEnabled(
        forKey key: String,
        defaultValue: Bool,
        userDefaults: UserDefaults
    ) -> Bool {
        boolSetting(forKey: key, defaultValue: defaultValue, userDefaults: userDefaults)
    }

    private static func boolSetting(
        forKey key: String,
        defaultValue: Bool,
        userDefaults: UserDefaults
    ) -> Bool {
        guard userDefaults.object(forKey: key) != nil else {
            return defaultValue
        }

        return userDefaults.bool(forKey: key)
    }

    private static func normalizedEmailReviewDailyTimes(_ times: [Int]) -> [Int] {
        let unique = Array(Set(times.map(emailReviewDailyTimeRange.clamping))).sorted()
        return unique.isEmpty ? defaultEmailReviewDailyTimes : unique
    }
}
