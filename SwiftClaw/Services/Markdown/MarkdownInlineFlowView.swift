import SwiftUI
import Markdown

/// Renders one run of sibling inline markup (a paragraph, heading, table
/// cell, …) as SwiftUI. Consecutive text-like runs (plain text, emphasis,
/// links, wikilinks) are merged into a single `Text` built from an
/// `AttributedString`, so per-substring tap targets work via SwiftUI's
/// built-in `AttributedString.link` handling; image embeds break the flow
/// into their own async-loaded subview.
struct MarkdownInlineFlowView: View {
    let inlines: [InlineMarkup]
    let onWikilinkTap: ((String) -> Void)?
    let imageLoadScope: String
    let loadImage: ((String) async -> PlatformImage?)?

    var body: some View {
        let elements = MarkdownInlineRenderer.flowElements(from: inlines)
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(elements.enumerated()), id: \.offset) { _, element in
                switch element {
                case .text(let attributed):
                    Text(attributed)
                        .environment(\.openURL, OpenURLAction { url in
                            guard let target = MarkdownInlineRenderer.wikilinkTarget(from: url) else {
                                return .systemAction
                            }
                            onWikilinkTap?(target)
                            return .handled
                        })
                case .image(let source, let alt):
                    NoteAsyncImageView(relativePath: source, altText: alt, imageLoadScope: imageLoadScope, loadImage: loadImage)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// One renderable piece of a flattened inline run: either a merged text
/// span, or a standalone image (which can't be embedded inline in a
/// `Text`-based flow the way this reader renders it).
enum MarkdownFlowElement {
    case text(AttributedString)
    case image(source: String, alt: String)
}

enum MarkdownInlineRenderer {
    static func flowElements(from inlines: [InlineMarkup]) -> [MarkdownFlowElement] {
        var elements: [MarkdownFlowElement] = []
        var current = AttributedString()

        func flushText() {
            guard !current.characters.isEmpty else { return }
            elements.append(.text(current))
            current = AttributedString()
        }

        func append(_ run: AttributedString) {
            current += run
        }

        func appendPlainText(_ text: String, style: InlineStyle) {
            for segment in WikilinkTextScanner.segments(in: text) {
                switch segment {
                case .plain(let string):
                    append(style.apply(to: string, monospaced: false))
                case .wikilink(let target, let label):
                    var run = style.apply(to: label, monospaced: false)
                    if let url = wikilinkURL(for: target) {
                        run.link = url
                    }
                    run.foregroundColor = .accentColor
                    run.underlineStyle = .single
                    append(run)
                case .embed(let target):
                    flushText()
                    elements.append(.image(source: target, alt: target))
                }
            }
        }

        func walk(_ inlines: [InlineMarkup], style: InlineStyle) {
            for inline in inlines {
                switch inline {
                case let text as Markdown.Text:
                    appendPlainText(text.string, style: style)
                case let emphasis as Emphasis:
                    walk(Array(emphasis.inlineChildren), style: style.adding(.italic))
                case let strong as Strong:
                    walk(Array(strong.inlineChildren), style: style.adding(.bold))
                case let strikethrough as Strikethrough:
                    walk(Array(strikethrough.inlineChildren), style: style.adding(.strikethrough))
                case let code as InlineCode:
                    var run = style.apply(to: code.code, monospaced: true)
                    run.backgroundColor = .gray.opacity(0.18)
                    append(run)
                case let link as Markdown.Link:
                    let label = link.plainText.isEmpty ? (link.destination ?? "") : link.plainText
                    var run = style.apply(to: label, monospaced: false)
                    if let destination = link.destination, let url = URL(string: destination) {
                        run.link = url
                        run.foregroundColor = .accentColor
                        run.underlineStyle = .single
                    }
                    append(run)
                case let image as Markdown.Image:
                    flushText()
                    elements.append(.image(source: image.source ?? "", alt: image.plainText))
                case is SoftBreak:
                    append(AttributedString(" "))
                case is LineBreak:
                    append(AttributedString("\n"))
                default:
                    break
                }
            }
        }

        walk(inlines, style: InlineStyle())
        flushText()
        return elements
    }

    /// A same-app-only URL scheme used purely as an `AttributedString.link`
    /// carrier so SwiftUI's `Text` makes the wikilink substring tappable;
    /// never sent anywhere or opened as a real link.
    private static let wikilinkScheme = "swiftclaw-wikilink"

    static func wikilinkURL(for target: String) -> URL? {
        var components = URLComponents()
        components.scheme = wikilinkScheme
        components.host = ""
        components.path = target.hasPrefix("/") ? target : "/\(target)"
        return components.url
    }

    static func wikilinkTarget(from url: URL) -> String? {
        guard url.scheme == wikilinkScheme else { return nil }
        let path = url.path
        return path.hasPrefix("/") ? String(path.dropFirst()) : path
    }
}

private struct InlineStyle {
    enum Trait {
        case bold, italic, strikethrough
    }

    var isBold = false
    var isItalic = false
    var isStrikethrough = false

    func adding(_ trait: Trait) -> InlineStyle {
        var copy = self
        switch trait {
        case .bold: copy.isBold = true
        case .italic: copy.isItalic = true
        case .strikethrough: copy.isStrikethrough = true
        }
        return copy
    }

    /// Only monospaced runs get an explicit `font` attribute — inline code
    /// must look monospaced regardless of context. Bold/italic/strikethrough
    /// are expressed as `inlinePresentationIntent` instead of an explicit
    /// `Font`, so they compose with whatever ambient font the surrounding
    /// block set (heading level, table header weight, …) rather than
    /// silently forcing every run back to `.body`.
    func apply(to string: String, monospaced: Bool) -> AttributedString {
        var run = AttributedString(string)
        if monospaced {
            run.font = .system(.body, design: .monospaced)
        }
        var intent: InlinePresentationIntent = []
        if isBold { intent.insert(.stronglyEmphasized) }
        if isItalic { intent.insert(.emphasized) }
        if isStrikethrough { intent.insert(.strikethrough) }
        if !intent.isEmpty { run.inlinePresentationIntent = intent }
        return run
    }
}

/// Recognizes Obsidian-style `[[page]]`/`[[page|alias]]` wikilinks and
/// `![[embed]]` image embeds inside a plain-text run. `swift-markdown`
/// parses these as ordinary `Text` since they aren't standard CommonMark
/// syntax, so the reader has to find them itself.
enum WikilinkTextScanner {
    enum Segment: Equatable {
        case plain(String)
        case wikilink(target: String, label: String)
        case embed(target: String)
    }

    private static let pattern = try! NSRegularExpression(pattern: "!?\\[\\[([^\\[\\]]+)\\]\\]")

    static func segments(in text: String) -> [Segment] {
        let nsText = text as NSString
        let matches = pattern.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return [.plain(text)] }

        var segments: [Segment] = []
        var lastEnd = 0
        for match in matches {
            let fullRange = match.range
            if fullRange.location > lastEnd {
                segments.append(.plain(nsText.substring(with: NSRange(location: lastEnd, length: fullRange.location - lastEnd))))
            }
            let inner = nsText.substring(with: match.range(at: 1))
            let isEmbed = nsText.substring(with: NSRange(location: fullRange.location, length: 1)) == "!"
            if isEmbed {
                segments.append(.embed(target: inner))
            } else if let pipeIndex = inner.firstIndex(of: "|") {
                let target = String(inner[inner.startIndex..<pipeIndex])
                let alias = String(inner[inner.index(after: pipeIndex)...])
                segments.append(.wikilink(target: target, label: alias))
            } else {
                segments.append(.wikilink(target: inner, label: inner))
            }
            lastEnd = fullRange.location + fullRange.length
        }
        if lastEnd < nsText.length {
            segments.append(.plain(nsText.substring(with: NSRange(location: lastEnd, length: nsText.length - lastEnd))))
        }
        return segments
    }
}
