import AppKit
import SwiftUI

struct ChatMarkdownView: View {
    let content: String
    let defaultForeground: Color
    let codeAccent: Color
    let quoteAccent: Color
    let linkAccent: Color
    let maximumContentWidth: CGFloat

    init(
        content: String,
        defaultForeground: Color,
        codeAccent: Color,
        quoteAccent: Color,
        linkAccent: Color,
        maximumContentWidth: CGFloat = ChatBubbleLayout.contentMaxWidth
    ) {
        self.content = content
        self.defaultForeground = defaultForeground
        self.codeAccent = codeAccent
        self.quoteAccent = quoteAccent
        self.linkAccent = linkAccent
        self.maximumContentWidth = maximumContentWidth
    }

    private var blocks: [ChatMarkdownBlock] {
        ChatMarkdownParser.blocks(from: content)
    }

    /// Source numbers mapped to URLs from the final Sources section.
    private var citations: [Int: URL] {
        ChatMarkdownParser.citationLinks(from: content)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: ChatMarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            inlineText(text, style: .heading(level: level, foreground: defaultForeground))
                .fixedSize(horizontal: false, vertical: true)

        case .paragraph(let text):
            inlineText(text, style: .paragraph(foreground: defaultForeground))
                .fixedSize(horizontal: false, vertical: true)

        case .quote(let text):
            HStack(alignment: .top, spacing: 9) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(quoteAccent)
                    .frame(width: 3)

                inlineText(text, style: .quote(foreground: quoteAccent))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(quoteAccent.opacity(0.10))
            }
        }
    }

    /// Uses AppKit for linked text so selectable links still get the pointing-hand cursor.
    @ViewBuilder
    private func inlineText(_ text: String, style: BlockStyle) -> some View {
        let runs = ChatInlineMarkdownParser.runs(from: text, citations: citations)

        if runs.contains(where: { $0.link != nil }) {
            SelectableLinkText(
                attributed: ChatInlineMarkdownParser.nsAttributedString(
                    runs: runs,
                    style: style,
                    codeAccent: codeAccent,
                    quoteAccent: quoteAccent,
                    linkAccent: linkAccent
                ),
                linkColor: NSColor(linkAccent),
                maximumWidth: maximumContentWidth
            )
        } else {
            Text(ChatInlineMarkdownParser.attributedString(
                runs: runs,
                baseFont: style.swiftBase,
                codeFont: style.swiftCode,
                defaultForeground: style.foreground,
                codeAccent: codeAccent,
                quoteAccent: quoteAccent,
                linkAccent: linkAccent
            ))
            .lineSpacing(style.lineSpacing)
        }
    }
}

/// Font, color, and spacing descriptor for a block, carrying both SwiftUI and
/// AppKit representations so either renderer can be driven from one source.
struct BlockStyle {
    var swiftBase: Font
    var swiftCode: Font
    var foreground: Color
    var appKitTextStyle: NSFont.TextStyle
    var appKitWeight: NSFont.Weight
    var lineSpacing: CGFloat
    var isQuote: Bool
}

extension BlockStyle {
    static func heading(level: Int, foreground: Color) -> BlockStyle {
        BlockStyle(
            swiftBase: headingFont(for: level),
            swiftCode: headingCodeFont(for: level),
            foreground: foreground,
            appKitTextStyle: headingTextStyle(for: level),
            appKitWeight: .semibold,
            lineSpacing: 2,
            isQuote: false
        )
    }

    static func paragraph(foreground: Color) -> BlockStyle {
        BlockStyle(
            swiftBase: .body,
            swiftCode: .system(.body, design: .monospaced),
            foreground: foreground,
            appKitTextStyle: .body,
            appKitWeight: .regular,
            lineSpacing: 3,
            isQuote: false
        )
    }

    static func quote(foreground: Color) -> BlockStyle {
        BlockStyle(
            swiftBase: .callout,
            swiftCode: .system(.callout, design: .monospaced),
            foreground: foreground,
            appKitTextStyle: .callout,
            appKitWeight: .regular,
            lineSpacing: 3,
            isQuote: true
        )
    }

    private static func headingFont(for level: Int) -> Font {
        switch level {
        case 1: .title3.weight(.semibold)
        case 2: .headline.weight(.semibold)
        default: .subheadline.weight(.semibold)
        }
    }

    private static func headingCodeFont(for level: Int) -> Font {
        switch level {
        case 1: .system(.title3, design: .monospaced).weight(.semibold)
        case 2: .system(.headline, design: .monospaced).weight(.semibold)
        default: .system(.subheadline, design: .monospaced).weight(.semibold)
        }
    }

    private static func headingTextStyle(for level: Int) -> NSFont.TextStyle {
        switch level {
        case 1: .title3
        case 2: .headline
        default: .subheadline
        }
    }
}
