import AppKit
import Foundation

@MainActor
enum ClipboardImageImporter {
    static func imagesForPaste(
        from pasteboard: NSPasteboard = .general
    ) -> [NSImage] {
        var images: [NSImage] = []

        for item in pasteboard.pasteboardItems ?? [] {
            if let image = image(from: item) {
                images.append(image)
            }
        }

        if images.isEmpty, let image = NSImage(pasteboard: pasteboard) {
            images.append(image)
        }

        return images
    }

    private static func image(from item: NSPasteboardItem) -> NSImage? {
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = item.data(forType: type),
               let image = NSImage(data: data) {
                return image
            }
        }

        if let fileURLString = item.string(forType: .fileURL),
           let url = URL(string: fileURLString),
           let image = NSImage(contentsOf: url) {
            return image
        }

        return nil
    }
}
