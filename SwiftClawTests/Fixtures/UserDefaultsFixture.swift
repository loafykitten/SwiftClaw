import Foundation
import Testing

/// Shared `UserDefaults` test fixture: a per-instance `UserDefaults` suite
/// isolated from `.standard` so test suites don't pollute each other under
/// parallel Swift Testing execution. Always `cleanup()`s the suite on teardown.
struct UserDefaultsFixture {
    let suiteName: String
    let defaults: UserDefaults

    init() throws {
        suiteName = "SwiftClawTests-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}
