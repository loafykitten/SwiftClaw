import CoreGraphics
import Foundation
import SwiftUI

#if os(macOS)
import AppKit
typealias PlatformImage = NSImage
#elseif os(iOS)
import UIKit
typealias PlatformImage = UIImage
#endif

extension PlatformImage {
    static func attachmentImage(contentsOf url: URL) -> PlatformImage? {
        #if os(macOS)
        PlatformImage(contentsOf: url)
        #elseif os(iOS)
        PlatformImage(contentsOfFile: url.path)
        #endif
    }

    var attachmentCGImage: CGImage? {
        #if os(macOS)
        cgImage(forProposedRect: nil, context: nil, hints: nil)
        #elseif os(iOS)
        cgImage
        #endif
    }
}

extension Image {
    init(platformImage: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: platformImage)
        #elseif os(iOS)
        self.init(uiImage: platformImage)
        #endif
    }
}
