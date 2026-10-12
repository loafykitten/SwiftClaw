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

    /// Pixels in display orientation. On iOS, `cgImage` is the raw sensor
    /// buffer and `imageOrientation` (from EXIF) says how to show it; the
    /// re-encoded JPEG carries no orientation metadata, so bake it in here or
    /// portrait/mirrored photos come out rotated or flipped.
    var attachmentCGImage: CGImage? {
        #if os(macOS)
        cgImage(forProposedRect: nil, context: nil, hints: nil)
        #elseif os(iOS)
        guard imageOrientation != .up else { return cgImage }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format)
            .image { _ in draw(in: CGRect(origin: .zero, size: size)) }
            .cgImage
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
