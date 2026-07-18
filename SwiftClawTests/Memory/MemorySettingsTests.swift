import Foundation
import Testing
@testable import SwiftClaw

struct MemorySettingsTests {
    @Test func memoryDefaultsOffAndReadsTheStoredChoice() throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }

        #expect(!SettingsStorage.isMemoryEnabled(userDefaults: fixture.defaults))

        fixture.defaults.set(true, forKey: SettingsKeys.memoryEnabled)
        #expect(SettingsStorage.isMemoryEnabled(userDefaults: fixture.defaults))
    }

    @Test func workspaceFeatureEnablementRoutesToMemorySettings() throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }

        #expect(
            SettingsStorage.defaultWorkspaceFeatureEnabled(.memory)
                == SettingsStorage.defaultMemoryEnabled
        )
        #expect(!SettingsStorage.isWorkspaceFeatureEnabled(.memory, userDefaults: fixture.defaults))

        fixture.defaults.set(true, forKey: SettingsKeys.memoryEnabled)
        #expect(SettingsStorage.isWorkspaceFeatureEnabled(.memory, userDefaults: fixture.defaults))
    }
}
