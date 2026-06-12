import SwiftUI

struct ChatMarkdownView: View {
    let content: String
    let defaultForeground: Color
    let codeAccent: Color
    let quoteAccent: Color

    private var blocks: [ChatMarkdownBlock] {
        ChatMarkdownParser.blocks(from: content)
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
            Text(ChatInlineMarkdownParser.attributedString(
                from: text,
                baseFont: headingFont(for: level),
                codeFont: headingCodeFont(for: level),
                defaultForeground: defaultForeground,
                codeAccent: codeAccent,
                quoteAccent: quoteAccent
            ))
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)

        case .paragraph(let text):
            Text(ChatInlineMarkdownParser.attributedString(
                from: text,
                baseFont: .body,
                codeFont: .system(.body, design: .monospaced),
                defaultForeground: defaultForeground,
                codeAccent: codeAccent,
                quoteAccent: quoteAccent
            ))
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)

        case .quote(let text):
            HStack(alignment: .top, spacing: 9) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(quoteAccent)
                    .frame(width: 3)

                Text(ChatInlineMarkdownParser.attributedString(
                    from: text,
                    baseFont: .callout,
                    codeFont: .system(.callout, design: .monospaced),
                    defaultForeground: quoteAccent,
                    codeAccent: codeAccent,
                    quoteAccent: quoteAccent
                ))
                .lineSpacing(3)
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

    private func headingFont(for level: Int) -> Font {
        switch level {
        case 1: .title3.weight(.semibold)
        case 2: .headline.weight(.semibold)
        default: .subheadline.weight(.semibold)
        }
    }

    private func headingCodeFont(for level: Int) -> Font {
        switch level {
        case 1: .system(.title3, design: .monospaced).weight(.semibold)
        case 2: .system(.headline, design: .monospaced).weight(.semibold)
        default: .system(.subheadline, design: .monospaced).weight(.semibold)
        }
    }
}

private enum ChatMarkdownBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case quote(String)
}

private enum ChatMarkdownParser {
    static func blocks(from content: String) -> [ChatMarkdownBlock] {
        var blocks: [ChatMarkdownBlock] = []
        var paragraphLines: [String] = []
        var quoteLines: [String] = []

        func flushParagraph() {
            guard !paragraphLines.isEmpty else {
                return
            }

            blocks.append(.paragraph(paragraphLines.joined(separator: "\n")))
            paragraphLines.removeAll()
        }

        func flushQuote() {
            guard !quoteLines.isEmpty else {
                return
            }

            blocks.append(.quote(quoteLines.joined(separator: "\n")))
            quoteLines.removeAll()
        }

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                flushQuote()
                continue
            }

            if let heading = heading(from: trimmed) {
                flushParagraph()
                flushQuote()
                blocks.append(.heading(level: heading.level, text: heading.text))
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                quoteLines.append(quoteText(from: trimmed))
                continue
            }

            flushQuote()
            paragraphLines.append(line)
        }

        flushParagraph()
        flushQuote()

        return blocks.isEmpty ? [.paragraph(content)] : blocks
    }

    private static func heading(from line: String) -> (level: Int, text: String)? {
        let markerCount = line.prefix(while: { $0 == "#" }).count
        guard (1...3).contains(markerCount) else {
            return nil
        }

        let markerEnd = line.index(line.startIndex, offsetBy: markerCount)
        guard markerEnd < line.endIndex, line[markerEnd].isWhitespace else {
            return nil
        }

        let textStart = line.index(after: markerEnd)
        let text = line[textStart...].trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            return nil
        }

        return (markerCount, text)
    }

    private static func quoteText(from line: String) -> String {
        var text = line.dropFirst()

        if text.first == " " {
            text = text.dropFirst()
        }

        return String(text)
    }
}

private struct ChatInlineStyle: OptionSet {
    let rawValue: Int

    static let bold = ChatInlineStyle(rawValue: 1 << 0)
    static let italic = ChatInlineStyle(rawValue: 1 << 1)
    static let code = ChatInlineStyle(rawValue: 1 << 2)
    static let quote = ChatInlineStyle(rawValue: 1 << 3)
}

private enum ChatInlineMarkdownParser {
    static func attributedString(
        from text: String,
        baseFont: Font,
        codeFont: Font,
        defaultForeground: Color,
        codeAccent: Color,
        quoteAccent: Color
    ) -> AttributedString {
        var result = AttributedString()
        appendParsed(
            text[...],
            activeStyle: [],
            to: &result,
            baseFont: baseFont,
            codeFont: codeFont,
            defaultForeground: defaultForeground,
            codeAccent: codeAccent,
            quoteAccent: quoteAccent
        )
        return result
    }

    private static func appendParsed(
        _ text: Substring,
        activeStyle: ChatInlineStyle,
        to result: inout AttributedString,
        baseFont: Font,
        codeFont: Font,
        defaultForeground: Color,
        codeAccent: Color,
        quoteAccent: Color
    ) {
        var index = text.startIndex
        var plainStart = index

        func flushPlain(upTo end: String.Index) {
            guard plainStart < end else {
                return
            }

            append(
                text[plainStart..<end],
                style: activeStyle,
                to: &result,
                baseFont: baseFont,
                codeFont: codeFont,
                defaultForeground: defaultForeground,
                codeAccent: codeAccent,
                quoteAccent: quoteAccent
            )
        }

        while index < text.endIndex {
            let remaining = text[index...]

            if remaining.hasPrefix("`"),
               let end = closingIndex(for: "`", in: text, after: text.index(after: index)) {
                flushPlain(upTo: index)
                append(
                    text[text.index(after: index)..<end],
                    style: activeStyle.union(.code),
                    to: &result,
                    baseFont: baseFont,
                    codeFont: codeFont,
                    defaultForeground: defaultForeground,
                    codeAccent: codeAccent,
                    quoteAccent: quoteAccent
                )
                index = text.index(after: end)
                plainStart = index
                continue
            }

            if remaining.hasPrefix("**"),
               let end = closingIndex(for: "**", in: text, after: text.index(index, offsetBy: 2)) {
                flushPlain(upTo: index)
                appendParsed(
                    text[text.index(index, offsetBy: 2)..<end],
                    activeStyle: activeStyle.union(.bold),
                    to: &result,
                    baseFont: baseFont,
                    codeFont: codeFont,
                    defaultForeground: defaultForeground,
                    codeAccent: codeAccent,
                    quoteAccent: quoteAccent
                )
                index = text.index(end, offsetBy: 2)
                plainStart = index
                continue
            }

            if remaining.hasPrefix("*"),
               let next = text.index(index, offsetBy: 1, limitedBy: text.endIndex),
               next < text.endIndex,
               text[next] != "*",
               let end = closingSingleAsterisk(in: text, after: next) {
                flushPlain(upTo: index)
                appendParsed(
                    text[next..<end],
                    activeStyle: activeStyle.union(.italic),
                    to: &result,
                    baseFont: baseFont,
                    codeFont: codeFont,
                    defaultForeground: defaultForeground,
                    codeAccent: codeAccent,
                    quoteAccent: quoteAccent
                )
                index = text.index(after: end)
                plainStart = index
                continue
            }

            if remaining.hasPrefix("\""),
               let end = closingIndex(for: "\"", in: text, after: text.index(after: index)) {
                flushPlain(upTo: index)
                append(
                    text[index..<text.index(after: index)],
                    style: activeStyle.union(.quote),
                    to: &result,
                    baseFont: baseFont,
                    codeFont: codeFont,
                    defaultForeground: defaultForeground,
                    codeAccent: codeAccent,
                    quoteAccent: quoteAccent
                )
                appendParsed(
                    text[text.index(after: index)..<end],
                    activeStyle: activeStyle.union(.quote),
                    to: &result,
                    baseFont: baseFont,
                    codeFont: codeFont,
                    defaultForeground: defaultForeground,
                    codeAccent: codeAccent,
                    quoteAccent: quoteAccent
                )
                append(
                    text[end..<text.index(after: end)],
                    style: activeStyle.union(.quote),
                    to: &result,
                    baseFont: baseFont,
                    codeFont: codeFont,
                    defaultForeground: defaultForeground,
                    codeAccent: codeAccent,
                    quoteAccent: quoteAccent
                )
                index = text.index(after: end)
                plainStart = index
                continue
            }

            if remaining.hasPrefix("“"),
               let end = closingIndex(for: "”", in: text, after: text.index(after: index)) {
                flushPlain(upTo: index)
                append(
                    text[index..<text.index(after: index)],
                    style: activeStyle.union(.quote),
                    to: &result,
                    baseFont: baseFont,
                    codeFont: codeFont,
                    defaultForeground: defaultForeground,
                    codeAccent: codeAccent,
                    quoteAccent: quoteAccent
                )
                appendParsed(
                    text[text.index(after: index)..<end],
                    activeStyle: activeStyle.union(.quote),
                    to: &result,
                    baseFont: baseFont,
                    codeFont: codeFont,
                    defaultForeground: defaultForeground,
                    codeAccent: codeAccent,
                    quoteAccent: quoteAccent
                )
                append(
                    text[end..<text.index(after: end)],
                    style: activeStyle.union(.quote),
                    to: &result,
                    baseFont: baseFont,
                    codeFont: codeFont,
                    defaultForeground: defaultForeground,
                    codeAccent: codeAccent,
                    quoteAccent: quoteAccent
                )
                index = text.index(after: end)
                plainStart = index
                continue
            }

            index = text.index(after: index)
        }

        flushPlain(upTo: text.endIndex)
    }

    private static func append(
        _ text: Substring,
        style: ChatInlineStyle,
        to result: inout AttributedString,
        baseFont: Font,
        codeFont: Font,
        defaultForeground: Color,
        codeAccent: Color,
        quoteAccent: Color
    ) {
        guard !text.isEmpty else {
            return
        }

        var attributes = AttributeContainer()
        attributes.font = font(for: style, baseFont: baseFont, codeFont: codeFont)
        attributes.foregroundColor = foregroundColor(
            for: style,
            defaultForeground: defaultForeground,
            codeAccent: codeAccent,
            quoteAccent: quoteAccent
        )

        if style.contains(.code) {
            attributes.backgroundColor = codeAccent.opacity(0.12)
        }

        result += AttributedString(String(text), attributes: attributes)
    }

    private static func font(for style: ChatInlineStyle, baseFont: Font, codeFont: Font) -> Font {
        var font = style.contains(.code) ? codeFont : baseFont

        if style.contains(.bold) {
            font = font.weight(.semibold)
        }

        if style.contains(.italic) {
            font = font.italic()
        }

        return font
    }

    private static func foregroundColor(
        for style: ChatInlineStyle,
        defaultForeground: Color,
        codeAccent: Color,
        quoteAccent: Color
    ) -> Color {
        if style.contains(.code) {
            return codeAccent
        }

        if style.contains(.quote) {
            return quoteAccent
        }

        return defaultForeground
    }

    private static func closingIndex(
        for marker: String,
        in text: Substring,
        after start: String.Index
    ) -> String.Index? {
        var index = start

        while index < text.endIndex {
            if text[index...].hasPrefix(marker) {
                return index
            }

            index = text.index(after: index)
        }

        return nil
    }

    private static func closingSingleAsterisk(in text: Substring, after start: String.Index) -> String.Index? {
        var index = start

        while index < text.endIndex {
            if text[index] == "*" {
                let next = text.index(after: index)
                if next == text.endIndex || text[next] != "*" {
                    return index
                }
            }

            index = text.index(after: index)
        }

        return nil
    }
}
