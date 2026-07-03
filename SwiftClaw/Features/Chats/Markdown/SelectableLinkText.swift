#if os(macOS)
import AppKit
import SwiftUI

/// AppKit-backed, self-sizing text view. SwiftUI's `Text` suppresses the
/// pointing-hand link cursor whenever text selection is enabled, so blocks
/// containing links render through `NSTextView`, which provides selection,
/// the correct cursor, and link activation natively.
struct SelectableLinkText: NSViewRepresentable {
    let attributed: NSAttributedString
    let linkColor: NSColor
    let maximumWidth: CGFloat

    func makeNSView(context: Context) -> WrappingTextView {
        let textView = WrappingTextView()
        textView.maxLayoutWidth = maximumWidth
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = false
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        return textView
    }

    func updateNSView(_ textView: WrappingTextView, context: Context) {
        textView.linkTextAttributes = [
            .foregroundColor: linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand
        ]
        textView.textStorage?.setAttributedString(attributed)
    }

    /// Wraps the text to the width SwiftUI proposes, capped at the chat bubble
    /// content width passed in by the SwiftUI row.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: WrappingTextView,
        context: Context
    ) -> CGSize? {
        let proposed = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? maximumWidth
        let width = max(1, min(proposed, maximumWidth))
        nsView.maxLayoutWidth = width
        return nsView.measuredSize(forWidth: width)
    }
}

extension ChatInlineMarkdownParser {
    static func nsAttributedString(
        runs: [InlineRun],
        style: BlockStyle,
        codeAccent: Color,
        quoteAccent: Color,
        linkAccent: Color
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = style.lineSpacing
        paragraph.lineBreakMode = .byCharWrapping

        let codeColor = NSColor(codeAccent)
        let quoteColor = NSColor(quoteAccent)
        let linkColor = NSColor(linkAccent)
        let defaultColor = NSColor(style.foreground)

        for run in runs {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: nsFont(for: run.style, style: style),
                .paragraphStyle: paragraph
            ]

            if let link = run.link {
                attributes[.link] = link
                attributes[.foregroundColor] = linkColor
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            } else if run.style.contains(.code) {
                attributes[.foregroundColor] = codeColor
                attributes[.backgroundColor] = codeColor.withAlphaComponent(0.12)
            } else if run.style.contains(.quote) || style.isQuote {
                attributes[.foregroundColor] = quoteColor
            } else {
                attributes[.foregroundColor] = defaultColor
            }

            result.append(NSAttributedString(string: run.text, attributes: attributes))
        }

        return result
    }

    private static func nsFont(for style: ChatInlineStyle, style blockStyle: BlockStyle) -> NSFont {
        let size = NSFont.preferredFont(forTextStyle: blockStyle.appKitTextStyle).pointSize
        var weight = blockStyle.appKitWeight

        if style.contains(.bold) {
            weight = weight == .regular ? .semibold : .bold
        }

        var font = style.contains(.code)
            ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)

        if style.contains(.italic) {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }

        return font
    }
}

/// `NSTextView` subclass that hugs its laid-out text like a SwiftUI `Text`.
///
/// Measurement is pure: it never mutates stored state or calls
/// `invalidateIntrinsicContentSize()` during a layout/constraints pass, which
/// would otherwise recurse and trip AppKit's update-constraints guard.
final class WrappingTextView: NSTextView {
    /// Width SwiftUI last proposed; only drives `intrinsicContentSize` and is
    /// set outside the constraints pass (in `sizeThatFits`).
    var maxLayoutWidth: CGFloat = 1

    func measuredSize(forWidth width: CGFloat) -> CGSize {
        guard let layoutManager, let textContainer else {
            return .zero
        }

        textContainer.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer).size
        return CGSize(width: ceil(used.width), height: ceil(used.height))
    }

    override var intrinsicContentSize: NSSize {
        measuredSize(forWidth: maxLayoutWidth)
    }
}
#endif
