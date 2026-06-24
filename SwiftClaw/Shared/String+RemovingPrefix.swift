import Foundation

extension String {
    /// Returns the string with `prefix` removed, or `nil` when the string does
    /// not start with `prefix`.
    func removingPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else {
            return nil
        }

        return String(dropFirst(prefix.count))
    }
}
