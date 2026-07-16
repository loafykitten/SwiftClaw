import Foundation
#if os(macOS)
import AppKit

/// Colors/fonts/attributes used by `MarkdownSourceHighlighter`. Honors
/// Increase Contrast even where that means trading a translucent/Liquid
/// Glass-style surface for an opaque, higher-contrast one — this codebase
/// prefers UX/accessibility over strict HIG conformance when the two
/// conflict.
nonisolated struct MarkdownEditorTheme {
    let backgroundColor: NSColor
    let textColor: NSColor
    let secondaryColor: NSColor
    let headingColor: NSColor
    let linkColor: NSColor
    let codeBackgroundColor: NSColor
    let quoteBarColor: NSColor
    let bodyFont: NSFont
    let monospacedFont: NSFont

    /// The current theme, switching to a fully opaque high-contrast palette
    /// whenever the system's Increase Contrast accessibility setting is on.
    /// `nonisolated` so `MarkdownSourceHighlighter` can read it from its
    /// `NSTextStorageDelegate` callback without an actor hop — reading
    /// `NSWorkspace` accessibility state and building value-type colors/fonts
    /// has no actor-isolated mutable state to protect.
    nonisolated static var current: MarkdownEditorTheme {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? .highContrast : .standard
    }

    nonisolated static var standard: MarkdownEditorTheme {
        MarkdownEditorTheme(
            backgroundColor: NSColor.textBackgroundColor.withAlphaComponent(0.92),
            textColor: .labelColor,
            secondaryColor: .secondaryLabelColor,
            headingColor: .labelColor,
            linkColor: .linkColor,
            codeBackgroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.12),
            quoteBarColor: .secondaryLabelColor,
            bodyFont: .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            monospacedFont: .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        )
    }

    /// Fully opaque background (no translucency) and maximum-contrast
    /// foreground colors, for users with Increase Contrast enabled.
    nonisolated static var highContrast: MarkdownEditorTheme {
        MarkdownEditorTheme(
            backgroundColor: .textBackgroundColor,
            textColor: .labelColor,
            secondaryColor: .labelColor,
            headingColor: .labelColor,
            linkColor: .linkColor,
            codeBackgroundColor: NSColor.labelColor.withAlphaComponent(0.18),
            quoteBarColor: .labelColor,
            bodyFont: .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            monospacedFont: .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        )
    }

    func headingFont(level: Int) -> NSFont {
        let size: CGFloat = switch level {
        case 1: NSFont.systemFontSize + 8
        case 2: NSFont.systemFontSize + 6
        case 3: NSFont.systemFontSize + 4
        case 4: NSFont.systemFontSize + 2
        default: NSFont.systemFontSize + 1
        }
        let base = NSFont.monospacedSystemFont(ofSize: size, weight: .bold)
        return base
    }
}
#endif
