import AppKit
import SwiftUI

struct ImageAttachmentPreviewSelection: Identifiable {
    let id = UUID()
    let attachments: [ImageAttachmentRecord]
    let initialIndex: Int

    init(attachments: [ImageAttachmentRecord], initialIndex: Int) {
        self.attachments = attachments
        self.initialIndex = initialIndex
    }
}

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

struct ImageAttachmentPreviewer: View {
    let attachments: [ImageAttachmentRecord]
    let initialIndex: Int
    let availableSize: CGSize
    let onClose: () -> Void

    @State private var selectedIndex: Int

    private enum NavigationDirection {
        case previous
        case next
    }

    init(
        attachments: [ImageAttachmentRecord],
        initialIndex: Int,
        availableSize: CGSize,
        onClose: @escaping () -> Void
    ) {
        self.attachments = attachments
        self.initialIndex = initialIndex
        self.availableSize = availableSize
        self.onClose = onClose
        _selectedIndex = State(initialValue: min(max(0, initialIndex), max(0, attachments.count - 1)))
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Spacer()

                ImagePreviewControlButton(
                    systemName: "xmark",
                    iconSize: 13,
                    buttonSize: 34,
                    action: onClose
                )
                .help("Close")
                .accessibilityLabel("Close")
                .zIndex(3)
            }

            ZStack {
                currentImage
                    .allowsHitTesting(false)

                if attachments.count > 1 {
                    HStack {
                        previewButton(
                            systemName: "chevron.left",
                            action: { navigate(.previous, source: "button.previous") }
                        )

                        Spacer()

                        previewButton(
                            systemName: "chevron.right",
                            action: { navigate(.next, source: "button.next") }
                        )
                    }
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .zIndex(2)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Text("\(selectedIndex + 1) / \(attachments.count)")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.68))
                .monospacedDigit()
        }
        .padding(18)
        .frame(
            width: min(max(availableSize.width - 64, 360), 1100),
            height: min(max(availableSize.height - 64, 320), 820)
        )
        .background(.black.opacity(0.92), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.35), radius: 24, x: 0, y: 12)
        .background {
            ImagePreviewKeyMonitor(
                isEnabled: true,
                onPrevious: { navigate(.previous, source: "keyboard.previous") },
                onNext: { navigate(.next, source: "keyboard.next") },
                onClose: onClose
            )
            .frame(width: 0, height: 0)
        }
    }

    @ViewBuilder
    private var currentImage: some View {
        if let attachment = attachments[safe: selectedIndex],
           let image = NSImage(contentsOf: attachment.fileURL) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Attached image")
        } else {
            VStack(spacing: 10) {
                Image(systemName: "photo")
                    .font(.system(size: 42))
                Text("Image unavailable")
                    .font(.callout)
            }
            .foregroundStyle(.white.opacity(0.72))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func previewButton(systemName: String, action: @escaping () -> Void) -> some View {
        ImagePreviewControlButton(
            systemName: systemName,
            iconSize: 24,
            buttonSize: 46,
            action: action
        )
    }

    private func navigate(_ direction: NavigationDirection, source: String) {
        guard attachments.count > 1 else {
            logNavigation(source: source, from: selectedIndex, to: selectedIndex, didMove: false)
            return
        }

        let previousIndex = selectedIndex
        let nextIndex: Int
        switch direction {
        case .previous:
            nextIndex = (selectedIndex - 1 + attachments.count) % attachments.count
        case .next:
            nextIndex = (selectedIndex + 1) % attachments.count
        }

        selectedIndex = nextIndex

        logNavigation(
            source: source,
            from: previousIndex,
            to: nextIndex,
            didMove: previousIndex != nextIndex
        )
    }

    private func logNavigation(source: String, from previousIndex: Int, to selectedIndex: Int, didMove: Bool) {
        #if DEBUG
        print(
            """
            [ImageAttachmentPreview] \(source) moved=\(didMove) \
            \(previousIndex + 1)/\(attachments.count) -> \(selectedIndex + 1)/\(attachments.count)
            """
        )
        #endif
    }
}

private struct ImagePreviewControlButton: View {
    let systemName: String
    let iconSize: CGFloat
    let buttonSize: CGFloat
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(.white.opacity(isHovering ? 1 : 0.88))
                .frame(width: buttonSize, height: buttonSize)
                .background {
                    Circle()
                        .fill(Color.white.opacity(isHovering ? 0.24 : 0.14))
                }
                .overlay {
                    Circle()
                        .strokeBorder(Color.white.opacity(isHovering ? 0.38 : 0.18), lineWidth: 1)
                }
                .shadow(
                    color: .black.opacity(isHovering ? 0.28 : 0.18),
                    radius: isHovering ? 10 : 6,
                    x: 0,
                    y: isHovering ? 4 : 2
                )
                .scaleEffect(isHovering ? 1.06 : 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

struct ImageAttachmentPreviewOverlay: ViewModifier {
    @Binding var selection: ImageAttachmentPreviewSelection?

    func body(content: Content) -> some View {
        ZStack {
            content

            if let selection {
                GeometryReader { proxy in
                    ZStack {
                        Color.black.opacity(0.45)
                            .ignoresSafeArea()
                            .contentShape(Rectangle())
                            .onTapGesture {
                                self.selection = nil
                            }

                        ImageAttachmentPreviewer(
                            attachments: selection.attachments,
                            initialIndex: selection.initialIndex,
                            availableSize: proxy.size,
                            onClose: { self.selection = nil }
                        )
                    }
                }
                .transition(.opacity)
                .zIndex(10)
            }
        }
    }
}

extension View {
    func imageAttachmentPreviewOverlay(
        selection: Binding<ImageAttachmentPreviewSelection?>
    ) -> some View {
        modifier(ImageAttachmentPreviewOverlay(selection: selection))
    }
}

private struct ImageAttachmentThumbnail: View {
    let attachment: ImageAttachmentRecord
    let size: CGFloat

    var body: some View {
        ZStack {
            if let image = NSImage(contentsOf: attachment.fileURL) {
                Image(nsImage: image)
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

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else {
            return nil
        }

        return self[index]
    }
}
