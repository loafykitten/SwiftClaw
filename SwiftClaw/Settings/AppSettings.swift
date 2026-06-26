import SwiftUI

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

enum AccentColor {
    static let defaultHue = 0.52
    static let defaultSaturation = 0.72
    static let defaultBrightness = 0.82
    static let defaultLightness = defaultBrightness * (2 - defaultSaturation) / 2
    static let defaultQuoteHue = 0.08
    static let defaultQuoteLightness = 0.62
    static let lightnessRange: ClosedRange<Double> = 0.18...0.95

    static func color(hue: Double, lightness: Double = defaultLightness) -> Color {
        let rgb = hslToRGB(
            hue: hue,
            saturation: defaultSaturation,
            lightness: min(max(lightness, lightnessRange.lowerBound), lightnessRange.upperBound)
        )

        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    static func migrateStoredLightnessIfNeeded(userDefaults: UserDefaults = .standard) {
        guard userDefaults.object(forKey: SettingsKeys.accentLightness) == nil else {
            return
        }

        guard userDefaults.object(forKey: SettingsKeys.accentBrightness) != nil else {
            return
        }

        let brightness = userDefaults.double(forKey: SettingsKeys.accentBrightness)
        let lightness = brightness * (2 - defaultSaturation) / 2
        userDefaults.set(
            min(max(lightness, lightnessRange.lowerBound), lightnessRange.upperBound),
            forKey: SettingsKeys.accentLightness
        )
    }

    private static func hslToRGB(hue: Double, saturation: Double, lightness: Double) -> (red: Double, green: Double, blue: Double) {
        let hue = min(max(hue, 0), 1)
        let saturation = min(max(saturation, 0), 1)
        let lightness = min(max(lightness, 0), 1)

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

enum SettingsKeys {
    static let theme = "settings.appearance.theme"
    static let accentHue = "settings.appearance.accentHue"
    static let accentLightness = "settings.appearance.accentLightness"
    static let accentBrightness = "settings.appearance.accentBrightness"
    static let quoteAccentHue = "settings.appearance.quoteAccentHue"
    static let quoteAccentLightness = "settings.appearance.quoteAccentLightness"
    static let azureResourceName = "settings.azure.resourceName"
    static let azureAPIKey = "settings.azure.apiKey"
    static let azureDeployments = "settings.azure.deployments"
    static let neuralwattAPIKey = "settings.neuralwatt.apiKey"
    static let neuralwattModels = "settings.neuralwatt.models"
    static let openRouterAPIKey = "settings.openRouter.apiKey"
    static let braveSearchAPIKey = "settings.braveSearch.apiKey"
    static let braveSearchRequestsPerSecond = "settings.braveSearch.requestsPerSecond"
    static let webSearchEnabled = "settings.tools.webSearch.enabled"
    static let investigationEnabled = "settings.tools.investigation.enabled"
    static let investigationMaxSubAgents = "settings.tools.investigation.maxSubAgents"
    static let openRouterModels = "settings.openRouter.models"
    static let swiftModel = "settings.behaviors.swiftModel"
    static let clawModel = "settings.behaviors.clawModel"
    static let deepResearchModel = "settings.behaviors.deepResearchModel"
    static let homeModel = "settings.home.model"
    static let homeReasoningEffort = "settings.home.reasoningEffort"
    static let personaDisplayName = "settings.persona.displayName"
    static let personaAvatarData = "settings.persona.avatarData"
    static let assistantDisplayName = "settings.assistant.displayName"
    static let assistantAvatarData = "settings.assistant.avatarData"
    static let assistantPersonalityPreset = "settings.assistant.personalityPreset"
    static let assistantUsesCustomPersonality = "settings.assistant.usesCustomPersonality"
    static let assistantCustomPersonality = "settings.assistant.customPersonality"
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
    static let emailAutoNavigateToReviewChat = "settings.email.autoNavigateToReviewChat"
    static let emailMailboxSyncStates = "settings.email.mailboxSyncStates"
}

enum SettingsNotifications {
    static let keychainDidChange = Notification.Name("settings.keychain.didChange")
    static let emailReviewScheduleDidChange = Notification.Name(
        "settings.email.reviewSchedule.didChange"
    )
    static let changedKey = "changedKey"
}

struct AzureDeployment: Identifiable, Codable, Hashable {
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

enum ModelCapability: String, CaseIterable, Codable, Hashable, Identifiable {
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

struct ProviderModel: Identifiable, Codable, Hashable {
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

struct EmailReviewFetchDefaults: Equatable, Sendable {
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

private extension ClosedRange where Bound == Int {
    func clamping(_ value: Int) -> Int {
        min(max(value, lowerBound), upperBound)
    }
}

enum SettingsStorage {
    static func loadModelSelection(
        forKey key: String,
        userDefaults: UserDefaults = .standard
    ) -> String {
        userDefaults.string(forKey: key) ?? ""
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

    static func loadAvailableModels(userDefaults: UserDefaults = .standard) -> [String] {
        availableModels(
            azureDeployments: loadDeployments(userDefaults: userDefaults),
            neuralwattModels: loadProviderModels(forKey: SettingsKeys.neuralwattModels, userDefaults: userDefaults),
            openRouterModels: loadProviderModels(forKey: SettingsKeys.openRouterModels, userDefaults: userDefaults)
        )
    }

    static func availableModels(
        azureDeployments: [AzureDeployment],
        neuralwattModels: [ProviderModel],
        openRouterModels: [ProviderModel]
    ) -> [String] {
        let azureModels = azureDeployments.map { deployment in
            InferenceProviderID.azure.modelPrefix + deployment.modelPickerTitle
        }
        let neuralwatt = neuralwattModels.map { InferenceProviderID.neuralwatt.modelPrefix + $0.name }
        let openRouter = openRouterModels.map { InferenceProviderID.openRouter.modelPrefix + $0.name }

        return azureModels + neuralwatt + openRouter
    }

    static func capabilities(
        for modelSelection: String,
        userDefaults: UserDefaults = .standard
    ) -> Set<ModelCapability> {
        let selection = modelSelection.trimmingCharacters(in: .whitespacesAndNewlines)

        if let title = selection.removingPrefix(InferenceProviderID.azure.modelPrefix) {
            return loadDeployments(userDefaults: userDefaults)
                .first { $0.modelPickerTitle == title }?
                .capabilities ?? ModelCapability.defaultCapabilities
        }

        if let model = selection.removingPrefix(InferenceProviderID.neuralwatt.modelPrefix) {
            return loadProviderModels(forKey: SettingsKeys.neuralwattModels, userDefaults: userDefaults)
                .first { $0.name == model }?
                .capabilities ?? ModelCapability.defaultCapabilities
        }

        if let model = selection.removingPrefix(InferenceProviderID.openRouter.modelPrefix) {
            return loadProviderModels(forKey: SettingsKeys.openRouterModels, userDefaults: userDefaults)
                .first { $0.name == model }?
                .capabilities ?? ModelCapability.defaultCapabilities
        }

        return ModelCapability.defaultCapabilities
    }

    static func loadDeployments(userDefaults: UserDefaults = .standard) -> [AzureDeployment] {
        loadCodable([AzureDeployment].self, forKey: SettingsKeys.azureDeployments, default: [], userDefaults: userDefaults)
    }

    static func saveDeployments(_ deployments: [AzureDeployment], userDefaults: UserDefaults = .standard) {
        saveCodable(deployments, forKey: SettingsKeys.azureDeployments, userDefaults: userDefaults)
    }

    static func loadProviderModels(
        forKey key: String,
        userDefaults: UserDefaults = .standard
    ) -> [ProviderModel] {
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
    }

    static let defaultBraveSearchRequestsPerSecond = 1.0
    static let braveSearchRequestsPerSecondRange: ClosedRange<Double> = 0.5...20
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

    static func loadBraveSearchRequestsPerSecond() -> Double {
        let stored = UserDefaults.standard.double(forKey: SettingsKeys.braveSearchRequestsPerSecond)

        guard stored > 0 else {
            return defaultBraveSearchRequestsPerSecond
        }

        return min(
            max(stored, braveSearchRequestsPerSecondRange.lowerBound),
            braveSearchRequestsPerSecondRange.upperBound
        )
    }

    static let defaultInvestigationMaxSubAgents = 3
    static let investigationMaxSubAgentsRange: ClosedRange<Int> = 1...5

    static let defaultEmailEnabled = false
    static let defaultEmailImapPort = 993
    static let defaultEmailSmtpPort = 587
    static let defaultEmailPollIntervalSeconds = 300
    static let emailPollIntervalSecondsRange: ClosedRange<Int> = 60...3600
    static let defaultEmailReviewIntervalSeconds = 1800
    static let emailReviewIntervalSecondsRange: ClosedRange<Int> = 300...86400
    static let emailReviewFirstRunMinimumDelaySeconds = 60
    static let defaultEmailReviewScheduleMode = EmailReviewScheduleMode.interval
    static let defaultEmailReviewDailyTimes = [9 * 60]
    static let emailReviewDailyTimeRange: ClosedRange<Int> = 0...1439
    static let defaultEmailReviewMaxThreads = 10
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
    static let defaultEmailAutoNavigateToReviewChat = false

    static func isEmailEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        toolEnabled(
            forKey: SettingsKeys.emailEnabled,
            defaultValue: defaultEmailEnabled,
            userDefaults: userDefaults
        )
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
        return emailReviewIntervalSecondsRange.clamping(stored)
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

    static func loadInvestigationMaxSubAgents() -> Int {
        let stored = UserDefaults.standard.integer(forKey: SettingsKeys.investigationMaxSubAgents)

        guard stored > 0 else {
            return defaultInvestigationMaxSubAgents
        }

        return min(
            max(stored, investigationMaxSubAgentsRange.lowerBound),
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
