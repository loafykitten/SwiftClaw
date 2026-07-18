import SwiftUI
#if os(macOS)
import AppKit
#endif

struct ChatMarkdownView: View {
    let content: String
    let defaultForeground: Color
    let codeAccent: Color
    let quoteAccent: Color
    let linkAccent: Color
    let maximumContentWidth: CGFloat
    private let presentation: ChatMarkdownPresentation

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
        self.presentation = ChatMarkdownPresentationCache.shared.presentation(for: content)
    }

    var body: some View {
        let renderedBlocks = presentation.blocks

        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(renderedBlocks.enumerated()), id: \.offset) { index, block in
                view(for: block)
                    .padding(.top, topPadding(for: block, at: index, in: renderedBlocks))
                    .padding(.bottom, bottomPadding(for: block, at: index, in: renderedBlocks))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func topPadding(
        for block: ChatMarkdownBlock,
        at index: Int,
        in blocks: [ChatMarkdownBlock]
    ) -> CGFloat {
        guard index > 0 else {
            return 0
        }

        if let level = headingLevel(for: block) {
            if level <= 2 {
                return 14
            }

            if let previousHeadingLevel = headingLevel(for: blocks[index - 1]),
               previousHeadingLevel <= 2 {
                return 6
            }

            return 0
        }

        if let previousHeadingLevel = headingLevel(for: blocks[index - 1]) {
            return previousHeadingLevel == 2 || previousHeadingLevel == 3 ? 4 : -4
        }

        return 8
    }

    private func bottomPadding(
        for block: ChatMarkdownBlock,
        at index: Int,
        in blocks: [ChatMarkdownBlock]
    ) -> CGFloat {
        guard headingLevel(for: block) == nil,
              blocks.indices.contains(index + 1),
              headingLevel(for: blocks[index + 1]) == 3,
              activeHeadingLevel(at: index, in: blocks) == 3 else {
            return 0
        }

        return 6
    }

    private func headingLevel(for block: ChatMarkdownBlock) -> Int? {
        if case .heading(let level, _) = block {
            return level
        }

        return nil
    }

    private func activeHeadingLevel(at index: Int, in blocks: [ChatMarkdownBlock]) -> Int? {
        for blockIndex in stride(from: index, through: 0, by: -1) {
            if let level = headingLevel(for: blocks[blockIndex]) {
                return level
            }
        }

        return nil
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
        let runs = ChatInlineMarkdownParser.runs(from: text, citations: presentation.citations)

        #if os(macOS)
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
            swiftInlineText(runs, style: style)
        }
        #else
        swiftInlineText(runs, style: style)
        #endif
    }

    private func swiftInlineText(_ runs: [InlineRun], style: BlockStyle) -> some View {
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

/// Font, color, and spacing descriptor for a block, carrying both SwiftUI and
/// AppKit representations so either renderer can be driven from one source.
struct BlockStyle {
    var swiftBase: Font
    var swiftCode: Font
    var foreground: Color
    #if os(macOS)
    var appKitTextStyle: NSFont.TextStyle
    var appKitWeight: NSFont.Weight
    #endif
    var lineSpacing: CGFloat
    var isQuote: Bool
}

extension BlockStyle {
    static func heading(level: Int, foreground: Color) -> BlockStyle {
        #if os(macOS)
        BlockStyle(
            swiftBase: headingFont(for: level),
            swiftCode: headingCodeFont(for: level),
            foreground: foreground,
            appKitTextStyle: headingTextStyle(for: level),
            appKitWeight: .semibold,
            lineSpacing: 2,
            isQuote: false
        )
        #else
        BlockStyle(
            swiftBase: headingFont(for: level),
            swiftCode: headingCodeFont(for: level),
            foreground: foreground,
            lineSpacing: 2,
            isQuote: false
        )
        #endif
    }

    static func paragraph(foreground: Color) -> BlockStyle {
        #if os(macOS)
        BlockStyle(
            swiftBase: .body,
            swiftCode: .system(.body, design: .monospaced),
            foreground: foreground,
            appKitTextStyle: .body,
            appKitWeight: .regular,
            lineSpacing: 3,
            isQuote: false
        )
        #else
        BlockStyle(
            swiftBase: .body,
            swiftCode: .system(.body, design: .monospaced),
            foreground: foreground,
            lineSpacing: 3,
            isQuote: false
        )
        #endif
    }

    static func quote(foreground: Color) -> BlockStyle {
        #if os(macOS)
        BlockStyle(
            swiftBase: .callout,
            swiftCode: .system(.callout, design: .monospaced),
            foreground: foreground,
            appKitTextStyle: .callout,
            appKitWeight: .regular,
            lineSpacing: 3,
            isQuote: true
        )
        #else
        BlockStyle(
            swiftBase: .callout,
            swiftCode: .system(.callout, design: .monospaced),
            foreground: foreground,
            lineSpacing: 3,
            isQuote: true
        )
        #endif
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

    #if os(macOS)
    private static func headingTextStyle(for level: Int) -> NSFont.TextStyle {
        switch level {
        case 1: .title3
        case 2: .headline
        default: .subheadline
        }
    }
    #endif
}
