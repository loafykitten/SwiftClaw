import Foundation
import SwiftUI
import Markdown

struct MarkdownRenderModel {
    struct Block: Identifiable {
        let id = UUID()
        let markup: BlockMarkup
    }

    let source: String
    let blocks: [Block]

    init(source: String) {
        self.source = source
        blocks = Document(parsing: MarkdownRenderedView.body(of: source), options: [])
            .blockChildren
            .map { Block(markup: $0) }
    }
}

@MainActor
final class MarkdownRenderModelCache {
    static let shared = MarkdownRenderModelCache()

    private final class Entry {
        let model: MarkdownRenderModel
        init(model: MarkdownRenderModel) { self.model = model }
    }

    private let cache = NSCache<NSString, Entry>()

    private init() {
        cache.totalCostLimit = 8 * 1024 * 1024
    }

    func model(for source: String) -> MarkdownRenderModel {
        let key = source as NSString
        if let cached = cache.object(forKey: key) {
            return cached.model
        }
        // Exact source content is the invalidation key: any edit misses this
        // entry and produces a new immutable parse model.
        let model = MarkdownRenderModel(source: source)
        cache.setObject(Entry(model: model), forKey: key, cost: source.utf8.count)
        return model
    }
}

/// SwiftUI reading-mode rendering for a markdown source string, shared
/// across features (not a Notes type). Covers headings, paragraphs,
/// emphasis/strong/strikethrough, lists, tables, fenced/inline code,
/// thematic breaks, and Obsidian-style `> [!kind]` callout quotes.
///
/// Obsidian wikilinks (`[[page]]`/`[[page|alias]]`) aren't standard
/// CommonMark, so `swift-markdown` sees them as plain text; this view
/// recognizes them itself and renders them tappable through
/// `onWikilinkTap`. Relative images — both `![alt](path)` and Obsidian's
/// `![[image.png]]` embed form — are only ever loaded through the
/// caller-supplied `loadImage`, never direct file access, so callers must
/// route it through their vault/repository abstraction.
struct MarkdownRenderedView: View {
    let source: String
    /// Identifies the owning note for image loads (its relative path,
    /// typically). Threaded down to every `NoteAsyncImageView` so its
    /// `.task(id:)` changes — and stale image/failure state resets — when
    /// the owning note changes, even if two notes reference an
    /// identically-named relative image (e.g. both use `image.png`).
    var imageLoadScope: String = ""
    var onWikilinkTap: ((String) -> Void)?
    var loadImage: ((String) async -> PlatformImage?)?

    var body: some View {
        let renderModel = MarkdownRenderModelCache.shared.model(for: source)
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(renderModel.blocks) { block in
                MarkdownBlockView(
                    block: block.markup,
                    onWikilinkTap: onWikilinkTap,
                    imageLoadScope: imageLoadScope,
                    loadImage: loadImage
                )
            }
        }
        .textSelection(.enabled)
    }

    /// The portion of `source` that should actually be handed to CommonMark:
    /// everything past a leading front-matter block, or the whole source
    /// when there is none. Front matter is metadata, not document content —
    /// reading mode must never render its keys/delimiters as text. Kept as a
    /// small, directly testable helper (see `MarkdownRenderedViewTests`)
    /// rather than only being exercisable through the SwiftUI view tree.
    static func body(of source: String) -> String {
        guard let frontMatter = FrontMatterBlock(source: source) else { return source }
        return String(source[frontMatter.range.upperBound...])
    }
}

struct MarkdownBlockView: View {
    let block: BlockMarkup
    let onWikilinkTap: ((String) -> Void)?
    let imageLoadScope: String
    let loadImage: ((String) async -> PlatformImage?)?

    /// Stable scroll anchor for a heading's plain text. Duplicate headings
    /// share an anchor; scrollTo lands on the first, which is acceptable for
    /// outline navigation.
    static func headingAnchorID(for plainText: String) -> String {
        "md-heading-\(plainText)"
    }

    var body: some View {
        switch block {
        case let heading as Heading:
            MarkdownInlineFlowView(inlines: Array(heading.inlineChildren), onWikilinkTap: onWikilinkTap, imageLoadScope: imageLoadScope, loadImage: loadImage)
                .font(Self.font(forHeadingLevel: heading.level))
                .accessibilityHeading(Self.accessibilityHeadingLevel(for: heading.level))
                .accessibilityAddTraits(.isHeader)
                // Anchor for outline navigation (e.g. the research report's
                // table of contents) via `ScrollViewReader.scrollTo`.
                .id(Self.headingAnchorID(for: heading.plainText))

        case let paragraph as Paragraph:
            MarkdownInlineFlowView(inlines: Array(paragraph.inlineChildren), onWikilinkTap: onWikilinkTap, imageLoadScope: imageLoadScope, loadImage: loadImage)

        case let codeBlock as CodeBlock:
            MarkdownCodeBlockView(code: codeBlock.code)

        case let list as UnorderedList:
            MarkdownListView(items: Array(list.listItems), ordered: false, startIndex: 1, onWikilinkTap: onWikilinkTap, imageLoadScope: imageLoadScope, loadImage: loadImage)

        case let list as OrderedList:
            MarkdownListView(items: Array(list.listItems), ordered: true, startIndex: list.startIndex, onWikilinkTap: onWikilinkTap, imageLoadScope: imageLoadScope, loadImage: loadImage)

        case let quote as BlockQuote:
            MarkdownQuoteView(blockQuote: quote, onWikilinkTap: onWikilinkTap, imageLoadScope: imageLoadScope, loadImage: loadImage)

        case is ThematicBreak:
            Divider()

        case let table as Markdown.Table:
            MarkdownTableView(table: table, onWikilinkTap: onWikilinkTap, imageLoadScope: imageLoadScope, loadImage: loadImage)

        default:
            EmptyView()
        }
    }

    static func font(forHeadingLevel level: Int) -> Font {
        switch level {
        case 1: .largeTitle
        case 2: .title
        case 3: .title2
        case 4: .title3
        case 5: .headline
        default: .subheadline
        }
    }

    static func accessibilityHeadingLevel(for level: Int) -> AccessibilityHeadingLevel {
        switch level {
        case 1: .h1
        case 2: .h2
        case 3: .h3
        case 4: .h4
        case 5: .h5
        default: .h6
        }
    }
}

private struct MarkdownCodeBlockView: View {
    let code: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(code)
                .font(.system(.body, design: .monospaced))
                .padding(8)
        }
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct MarkdownListView: View {
    let items: [ListItem]
    let ordered: Bool
    /// The first marker number for an ordered list, per CommonMark's
    /// `start` attribute (e.g. `3.` `4.` `5.` for a list beginning `3.`).
    /// Ignored for unordered lists.
    let startIndex: UInt
    let onWikilinkTap: ((String) -> Void)?
    let imageLoadScope: String
    let loadImage: ((String) async -> PlatformImage?)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                itemRow(item, index: index)
            }
        }
    }

    @ViewBuilder
    private func itemRow(_ item: ListItem, index: Int) -> some View {
        let row = HStack(alignment: .top, spacing: 6) {
            Text(Self.marker(checkbox: item.checkbox, ordered: ordered, startIndex: startIndex, index: index))
                .foregroundStyle(.secondary)
                .frame(minWidth: 16, alignment: .trailing)
            itemContent(item)
        }

        if let taskLabel = Self.taskAccessibilityLabel(checkbox: item.checkbox) {
            row.accessibilityRepresentation {
                HStack(alignment: .top, spacing: 6) {
                    // `Text` alone is ambiguous here: this file imports
                    // swift-markdown, whose `Markdown.Text` also has a
                    // string initializer.
                    SwiftUI.Text(taskLabel)
                    itemContent(item)
                }
                .accessibilityElement(children: .combine)
            }
        } else {
            row
        }
    }

    private func itemContent(_ item: ListItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(item.blockChildren.enumerated()), id: \.offset) { _, child in
                MarkdownBlockView(block: child, onWikilinkTap: onWikilinkTap, imageLoadScope: imageLoadScope, loadImage: loadImage)
            }
        }
    }

    /// Kept as a small, directly testable static helper (see
    /// `MarkdownRenderedViewTests`) rather than only being exercisable
    /// through the SwiftUI view tree.
    static func marker(checkbox: Markdown.Checkbox?, ordered: Bool, startIndex: UInt, index: Int) -> String {
        switch checkbox {
        case .checked: "☑"
        case .unchecked: "☐"
        case nil: ordered ? "\(startIndex + UInt(index))." : "•"
        }
    }

    static func taskAccessibilityLabel(checkbox: Markdown.Checkbox?) -> String? {
        switch checkbox {
        case .checked: "Completed task"
        case .unchecked: "Incomplete task"
        case nil: nil
        }
    }
}

/// Recognizes Obsidian-style `> [!kind] Title` callouts by inspecting the
/// first line of the quote's first paragraph; falls back to a plain quote
/// style when no `[!kind]` tag is present.
struct MarkdownQuoteView: View {
    let blockQuote: BlockQuote
    let onWikilinkTap: ((String) -> Void)?
    let imageLoadScope: String
    let loadImage: ((String) async -> PlatformImage?)?

    private var blocks: [BlockMarkup] {
        Array(blockQuote.blockChildren)
    }

    private var callout: (kind: String, title: String)? {
        guard let firstParagraph = blocks.first as? Paragraph,
              let firstText = Array(firstParagraph.children).first as? Markdown.Text,
              firstText.string.hasPrefix("[!"),
              let closeBracket = firstText.string.firstIndex(of: "]")
        else { return nil }
        let kindStart = firstText.string.index(firstText.string.startIndex, offsetBy: 2)
        let kind = String(firstText.string[kindStart..<closeBracket])
        let afterBracket = firstText.string.index(after: closeBracket)
        let title = firstText.string[afterBracket...].trimmingCharacters(in: .whitespaces)
        return (kind, title.isEmpty ? kind.capitalized : title)
    }

    var body: some View {
        if let callout {
            VStack(alignment: .leading, spacing: 6) {
                Label(callout.title, systemImage: Self.icon(forKind: callout.kind))
                    .font(.subheadline.weight(.semibold))
                calloutBodyView
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .leading) {
                Rectangle().fill(Color.accentColor).frame(width: 3)
            }
            .accessibilityElement(children: .combine)
        } else {
            HStack(spacing: 8) {
                Rectangle().fill(Color.secondary.opacity(0.5)).frame(width: 3)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, child in
                        MarkdownBlockView(block: child, onWikilinkTap: onWikilinkTap, imageLoadScope: imageLoadScope, loadImage: loadImage)
                    }
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    /// The rest of the callout's content: the first paragraph's tag/title
    /// text is dropped, but any remaining inline content on the same
    /// paragraph (after a soft break) and every following block are kept.
    @ViewBuilder
    private var calloutBodyView: some View {
        let firstParagraphChildren = (blocks.first as? Paragraph).map { Array($0.children) } ?? []
        let firstParagraphRest = Array(firstParagraphChildren.dropFirst())
        let remainingBlocks = Array(blocks.dropFirst())
        if !firstParagraphRest.isEmpty {
            MarkdownInlineFlowView(
                inlines: firstParagraphRest.compactMap { $0 as? InlineMarkup },
                onWikilinkTap: onWikilinkTap,
                imageLoadScope: imageLoadScope,
                loadImage: loadImage
            )
        }
        ForEach(Array(remainingBlocks.enumerated()), id: \.offset) { _, child in
            MarkdownBlockView(block: child, onWikilinkTap: onWikilinkTap, imageLoadScope: imageLoadScope, loadImage: loadImage)
        }
    }

    private static func icon(forKind kind: String) -> String {
        switch kind.lowercased() {
        case "note": "note.text"
        case "tip", "hint": "lightbulb"
        case "important": "exclamationmark.circle"
        case "warning", "caution": "exclamationmark.triangle"
        case "danger", "bug", "error", "fail", "failure", "missing": "xmark.octagon"
        case "success", "check", "done": "checkmark.circle"
        case "question", "help", "faq": "questionmark.circle"
        case "quote", "cite": "quote.opening"
        case "example": "list.bullet.rectangle"
        case "abstract", "summary", "tldr": "text.alignleft"
        default: "info.circle"
        }
    }
}

private struct MarkdownTableView: View {
    let table: Markdown.Table
    let onWikilinkTap: ((String) -> Void)?
    let imageLoadScope: String
    let loadImage: ((String) async -> PlatformImage?)?

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                ForEach(Array(table.head.cells.enumerated()), id: \.offset) { _, cell in
                    MarkdownInlineFlowView(inlines: Array(cell.inlineChildren), onWikilinkTap: onWikilinkTap, imageLoadScope: imageLoadScope, loadImage: loadImage)
                        .font(.subheadline.weight(.semibold))
                }
            }
            Divider()
            ForEach(Array(table.body.rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.cells.enumerated()), id: \.offset) { _, cell in
                        MarkdownInlineFlowView(inlines: Array(cell.inlineChildren), onWikilinkTap: onWikilinkTap, imageLoadScope: imageLoadScope, loadImage: loadImage)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}
