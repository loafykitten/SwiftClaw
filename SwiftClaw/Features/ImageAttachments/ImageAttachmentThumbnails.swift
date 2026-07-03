import SwiftUI

/// Horizontal strip of removable thumbnails shown in the composer for the
/// images queued on the current draft message.
struct ImageAttachmentThumbnailStrip: View {
    let attachments: [ImageAttachmentRecord]
    let onSelect: (Int) -> Void
    let onRemove: (ImageAttachmentRecord) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(attachments.enumerated()), id: \.element.id) { index, attachment in
                    ZStack(alignment: .topTrailing) {
                        Button {
                            onSelect(index)
                        } label: {
                            ImageAttachmentThumbnail(attachment: attachment, size: 52)
                        }
                        .buttonStyle(.plain)

                        Button {
                            onRemove(attachment)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(.plain)
                        .help("Remove image")
                        .accessibilityLabel("Remove image")
                        .offset(x: 6, y: -6)
                    }
                    .frame(width: 60, height: 60)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

/// Overlapping "fanned" stack of thumbnails shown on a sent message; tapping it
/// opens the full-size previewer.
struct ImageAttachmentFanStack: View {
    let attachments: [ImageAttachmentRecord]
    let onSelect: (Int) -> Void

    private var visibleAttachments: [ImageAttachmentRecord] {
        Array(attachments.prefix(4))
    }

    var body: some View {
        Button {
            onSelect(0)
        } label: {
            ZStack(alignment: .bottomTrailing) {
                ZStack {
                    ForEach(Array(visibleAttachments.enumerated()), id: \.element.id) { index, attachment in
                        ImageAttachmentThumbnail(attachment: attachment, size: 72)
                            .rotationEffect(.degrees(rotation(for: index)))
                            .offset(x: offset(for: index).x, y: offset(for: index).y)
                            .shadow(color: .black.opacity(0.18), radius: 4, x: 0, y: 2)
                    }
                }
                .frame(width: 100, height: 86)

                if attachments.count > 1 {
                    Text("\(attachments.count)")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.58), in: Capsule())
                        .padding(.trailing, 6)
                        .padding(.bottom, 4)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("View images")
        .accessibilityLabel("View attached images")
    }

    private func rotation(for index: Int) -> Double {
        let rotations = [-8.0, -2.0, 5.0, 10.0]
        return rotations[index % rotations.count]
    }

    private func offset(for index: Int) -> CGPoint {
        let offsets = [
            CGPoint(x: -10, y: 4),
            CGPoint(x: 0, y: 0),
            CGPoint(x: 9, y: 5),
            CGPoint(x: 16, y: 10),
        ]
        return offsets[index % offsets.count]
    }
}

private struct ImageAttachmentThumbnail: View {
    let attachment: ImageAttachmentRecord
    let size: CGFloat

    var body: some View {
        ZStack {
            if let image = PlatformImage.attachmentImage(contentsOf: attachment.fileURL) {
                Image(platformImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            } else {
                Color.secondary.opacity(0.18)
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(.white.opacity(0.28), lineWidth: 1)
        }
        .accessibilityLabel("Attached image")
    }
}
