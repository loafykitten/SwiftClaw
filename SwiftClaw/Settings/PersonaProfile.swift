import Foundation
#if os(macOS)
import AppKit
import Collaboration
import Darwin
import OpenDirectory
#elseif os(iOS)
import UIKit
#endif

enum PersonaProfile {
    static var detectedDisplayName: String {
        #if os(macOS)
        sanitizedDisplayName(NSFullUserName()) ??
            sanitizedDisplayName(NSUserName()) ??
            "friend"
        #else
        "friend"
        #endif
    }

    static var displayName: String {
        let override = UserDefaults.standard.string(forKey: SettingsKeys.personaDisplayName) ?? ""

        return sanitizedDisplayName(override) ?? detectedDisplayName
    }

    static func sanitizedDisplayName(_ rawName: String) -> String? {
        let name = rawName
            .replacingOccurrences(of: ",", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,!? "))

        return name.isEmpty ? nil : name
    }
}

#if os(macOS)
extension PersonaProfile {
    static func avatarImage(overrideData: Data? = UserDefaults.standard.data(forKey: SettingsKeys.personaAvatarData), pointSize: CGFloat) -> NSImage? {
        if let image = overrideAvatarImage(data: overrideData, pointSize: pointSize) {
            return image
        }

        return detectedAvatarImage(pointSize: pointSize)
    }

    static func overrideAvatarImage(data: Data? = UserDefaults.standard.data(forKey: SettingsKeys.personaAvatarData), pointSize: CGFloat) -> NSImage? {
        guard let data,
              !data.isEmpty,
              let image = NSImage(data: data) else {
            return nil
        }

        return image.normalizedForAvatar(pointSize: pointSize)
    }

    static func detectedAvatarImage(pointSize: CGFloat) -> NSImage? {
        let cacheKey = NSNumber(value: Double(pointSize))
        if let image = DetectedAvatarCache.normalizedImages.image(for: cacheKey) {
            return image
        }

        guard let image = DetectedAvatarCache.sourceImage?.normalizedForAvatar(pointSize: pointSize) else {
            return nil
        }

        DetectedAvatarCache.normalizedImages.set(image, for: cacheKey)
        return image
    }

    static func normalizedAvatarData(from image: NSImage, pointSize: CGFloat = 256) -> Data? {
        image.normalizedForAvatar(pointSize: pointSize)?.pngData
    }

    private enum DetectedAvatarCache {
        static let normalizedImages = AvatarImageCache()

        static let sourceImage: NSImage? = {
            if let image = openDirectoryImage() {
                return image
            }

            return CBUserIdentity(
                posixUID: getuid(),
                authority: .default()
            )?.image
        }()
    }

    private final class AvatarImageCache: @unchecked Sendable {
        private let cache = NSCache<NSNumber, NSImage>()

        func image(for key: NSNumber) -> NSImage? {
            cache.object(forKey: key)
        }

        func set(_ image: NSImage, for key: NSNumber) {
            cache.setObject(image, forKey: key)
        }
    }

    private static func openDirectoryImage(username: String = NSUserName()) -> NSImage? {
        guard let localNode = try? ODNode(session: .default(), name: "/Local/Default"),
              let record = try? localNode.record(
                withRecordType: kODRecordTypeUsers,
                name: username,
                attributes: [
                    kODAttributeTypeJPEGPhoto,
                    kODAttributeTypePicture,
                ]
              ),
              let details = try? record.recordDetails(
                forAttributes: [
                    kODAttributeTypeJPEGPhoto,
                    kODAttributeTypePicture,
                ]
              ) else {
            return nil
        }

        if let jpegData = firstAttributeValue(
            in: details,
            for: kODAttributeTypeJPEGPhoto,
            as: Data.self
        ), let image = NSImage(data: jpegData) {
            return image
        }

        let picturePaths = attributeValues(
            in: details,
            for: kODAttributeTypePicture,
            as: String.self
        )

        for path in picturePaths {
            if let image = NSImage(contentsOfFile: path) {
                return image
            }
        }

        return nil
    }

    private static func firstAttributeValue<T>(
        in details: [AnyHashable: Any],
        for key: String,
        as type: T.Type
    ) -> T? {
        attributeValues(in: details, for: key, as: type).first
    }

    private static func attributeValues<T>(
        in details: [AnyHashable: Any],
        for key: String,
        as type: T.Type
    ) -> [T] {
        if let values = details[key] as? [T] {
            return values
        }

        if let value = details[key] as? T {
            return [value]
        }

        return []
    }
}

private extension NSImage {
    func normalizedForAvatar(pointSize: CGFloat) -> NSImage? {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let pixelSize = CGSize(width: pointSize * scale, height: pointSize * scale)
        let image = NSImage(size: pixelSize)

        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        draw(
            in: CGRect(origin: .zero, size: pixelSize),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        image.unlockFocus()
        image.size = CGSize(width: pointSize, height: pointSize)

        return image
    }

    var pngData: Data? {
        guard let tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffRepresentation) else {
            return nil
        }

        return bitmap.representation(using: .png, properties: [:])
    }
}
#endif

#if os(iOS)
extension PersonaProfile {
    static func avatarImage(
        overrideData: Data? = UserDefaults.standard.data(forKey: SettingsKeys.personaAvatarData),
        pointSize: CGFloat
    ) -> UIImage? {
        overrideAvatarImage(data: overrideData, pointSize: pointSize)
    }

    static func overrideAvatarImage(
        data: Data? = UserDefaults.standard.data(forKey: SettingsKeys.personaAvatarData),
        pointSize: CGFloat
    ) -> UIImage? {
        guard let data,
              !data.isEmpty,
              let image = UIImage(data: data) else {
            return nil
        }

        return image.normalizedForAvatar(pointSize: pointSize)
    }

    static func normalizedAvatarData(from image: UIImage, pointSize: CGFloat = 256) -> Data? {
        image.normalizedForAvatar(pointSize: pointSize).pngData()
    }
}

private extension UIImage {
    func normalizedForAvatar(pointSize: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale

        let size = CGSize(width: pointSize, height: pointSize)
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
#endif
