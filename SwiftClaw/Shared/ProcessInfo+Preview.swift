import Foundation

extension ProcessInfo {
    /// `true` when the process is running inside an Xcode SwiftUI preview.
    ///
    /// Previews must avoid work that hits the Keychain or the network; their
    /// update budget is far smaller than the app's request timeouts.
    var isRunningInPreview: Bool {
        environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }
}
