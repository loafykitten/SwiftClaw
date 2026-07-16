@testable import SwiftClaw
import Testing

struct NotesPhaseSixFixtureTests {
    @Test func requiresExactTemporaryFixtureIdentityAndBothArguments() {
        let requiredArguments = [
            NoteProposalFixtureSeeder.launchArgument,
            NotesPhaseSixFixture.launchArgument,
        ]

        #expect(NotesPhaseSixFixture.isEnabled(
            arguments: requiredArguments,
            bundleIdentifier: NoteProposalFixtureLaunch.fixtureBundleIdentifier
        ))
        #expect(!NotesPhaseSixFixture.isEnabled(
            arguments: [NotesPhaseSixFixture.launchArgument],
            bundleIdentifier: NoteProposalFixtureLaunch.fixtureBundleIdentifier
        ))
        #expect(!NotesPhaseSixFixture.isEnabled(
            arguments: [NoteProposalFixtureSeeder.launchArgument],
            bundleIdentifier: NoteProposalFixtureLaunch.fixtureBundleIdentifier
        ))
        #expect(!NotesPhaseSixFixture.isEnabled(
            arguments: requiredArguments,
            bundleIdentifier: "com.caffeineplz.SwiftClaw"
        ))
    }
}
