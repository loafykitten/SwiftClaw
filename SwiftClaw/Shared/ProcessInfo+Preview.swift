import Foundation

extension ProcessInfo {
    /// `true` when the process is running inside an Xcode SwiftUI preview.
    ///
    /// Previews must avoid work that hits the Keychain or the network; their
    /// update budget is far smaller than the app's request timeouts.
    var isRunningInPreview: Bool {
        environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }

    /// `true` when the app is only hosting the `SwiftClawTests` bundle.
    ///
    /// The test host must not open the real stores, start mail sync or
    /// review schedules, or render UI that calls providers with the
    /// developer's real settings and Keychain credentials.
    nonisolated var isRunningAsTestHost: Bool {
        environment["XCTestConfigurationFilePath"] != nil
    }
}
