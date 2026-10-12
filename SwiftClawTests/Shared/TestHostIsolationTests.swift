import Foundation
import SwiftData
import Testing
@testable import SwiftClaw

/// The app hosts this bundle, so it must recognize the test run and keep its
/// startup away from the developer's real stores and services.
struct TestHostIsolationTests {
    @Test func detectsTheTestHost() {
        #expect(ProcessInfo.processInfo.isRunningAsTestHost)
    }

    @Test func containerFactoryUsesInMemoryStores() throws {
        let container = try SwiftClawModelContainerFactory.make().get()

        #expect(!container.configurations.isEmpty)
        for configuration in container.configurations {
            #expect(configuration.isStoredInMemoryOnly)
        }
    }
}
