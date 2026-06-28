import SwiftUI

extension ReviewActionToken {
    /// SwiftUI button role — only `delete` is destructive; the rest are plain.
    var role: ButtonRole? {
        switch self {
        case .delete: .destructive
        default: nil
        }
    }
}
