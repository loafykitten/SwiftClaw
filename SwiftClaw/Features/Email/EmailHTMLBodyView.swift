import SwiftUI
import WebKit

/// Renders HTML email bodies via WKWebView. Used when the server provides
/// an HTML part. Extracted from `EmailView.swift` along the HTML-renderer
/// concern boundary.
///
/// Email HTML is sender-controlled, so the web view is locked down (see
/// `EmailHTMLDocument`): content JavaScript is off, the page can't navigate
/// itself (clicked links open in the system browser), and remote resources
/// — the classic tracking pixel — stay blocked until the user taps
/// "Load Remote Content" for this message.
struct EmailHTMLBodyView: View {
    let html: String
    @State private var contentHeight: CGFloat = 160
    @State private var allowsRemoteContent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !allowsRemoteContent, EmailHTMLDocument.referencesRemoteContent(html) {
                remoteContentBanner
            }
            EmailHTMLView(
                html: html,
                allowsRemoteContent: allowsRemoteContent,
                contentHeight: $contentHeight
            )
            .frame(height: max(contentHeight, 120))
        }
        .onChange(of: html) { allowsRemoteContent = false }
    }

    private var remoteContentBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "photo.badge.exclamationmark")
                .foregroundStyle(.secondary)
            Text("Remote content is hidden to protect your privacy.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("Load Remote Content") { allowsRemoteContent = true }
                .font(.caption)
                .buttonStyle(.borderless)
        }
    }
}

/// Hardening for sender-controlled email HTML, shared by the macOS and iOS
/// renderers. Three layers:
/// 1. `allowsContentJavaScript = false` on the web view configuration, so
///    scripts in the message never run (the app's own height measurement
///    runs in an isolated content world, unaffected).
/// 2. A strict Content-Security-Policy `<meta>` as the first element of the
///    wrapper's `<head>`: no scripts, frames, forms, `<base>`, or remote
///    loads — only `data:`/`cid:` images and inline styles, plus http(s)
///    images/styles/fonts once the user opts in. A message's own CSP can
///    only tighten this (policies intersect), never loosen it.
/// 3. `navigationPolicy`: the page may only load its own `about:` document;
///    user-clicked web/mail links open externally, everything else (meta
///    refresh, form posts, scripted redirects) is cancelled.
nonisolated enum EmailHTMLDocument {
    enum NavigationPolicy: Equatable {
        case allow
        case openExternally(URL)
        case cancel
    }

    /// Schemes a clicked link may hand to the system. Anything else (custom
    /// app schemes, `file:`, `javascript:`) is dropped.
    static let externalLinkSchemes: Set<String> = ["http", "https", "mailto"]

    static func contentSecurityPolicy(allowsRemoteContent: Bool) -> String {
        let remote = allowsRemoteContent ? " https: http:" : ""
        return [
            "default-src 'none'",
            "script-src 'none'",
            "object-src 'none'",
            "frame-src 'none'",
            "form-action 'none'",
            "base-uri 'none'",
            "style-src 'unsafe-inline'\(remote)",
            "img-src data: cid:\(remote)",
            "font-src data:\(remote)",
        ].joined(separator: "; ")
    }

    /// Wraps the message body in a minimal document whose `<head>` starts
    /// with the CSP, followed by the renderer-specific head markup.
    static func wrap(_ html: String, allowsRemoteContent: Bool, head: String) -> String {
        let policy = contentSecurityPolicy(allowsRemoteContent: allowsRemoteContent)
        return """
        <html><head>
        <meta http-equiv="Content-Security-Policy" content="\(policy)">
        <meta charset="utf-8">
        \(head)
        </head><body>\(html)</body></html>
        """
    }

    /// Whether the message references http(s) or protocol-relative resources
    /// that the default policy blocks — drives the "Load Remote Content"
    /// banner. A heuristic: it only needs to catch the common tracking-pixel
    /// and remote-stylesheet shapes, since the CSP is the actual boundary.
    static func referencesRemoteContent(_ html: String) -> Bool {
        html.range(of: remoteReferencePattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static let remoteReferencePattern =
        #"(?:\b(?:src|srcset|background|poster)\s*=\s*["']?\s*|url\(\s*["']?\s*|<link\b[^>]*\bhref\s*=\s*["']?\s*|@import\s+["']?\s*)(?:https?:)?//"#

    static func navigationPolicy(for url: URL?, isLinkActivated: Bool) -> NavigationPolicy {
        guard let url, let scheme = url.scheme?.lowercased() else { return .cancel }
        if isLinkActivated {
            return externalLinkSchemes.contains(scheme) ? .openExternally(url) : .cancel
        }
        // `loadHTMLString(_:baseURL: nil)` loads as `about:blank`; nothing
        // else may replace the rendered message.
        return scheme == "about" ? .allow : .cancel
    }

    @MainActor
    static func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        // No cookies, cache, or storage shared with other web views, so an
        // opted-in remote load can't be correlated across messages.
        configuration.websiteDataStore = .nonPersistent()
        return configuration
    }

    /// Measures the rendered document height. Runs in the app's isolated
    /// client content world, so it works with content JavaScript disabled
    /// and the message's markup can't observe or tamper with it.
    static let contentHeightScript = """
    (() => {
        const nodes = [document.documentElement, document.body, ...document.body.querySelectorAll('*')];
        return Math.ceil(nodes.reduce((height, node) => {
            const rect = node.getBoundingClientRect();
            return Math.max(height, rect.bottom, node.scrollHeight || 0, node.offsetHeight || 0);
        }, 0));
    })()
    """

    @MainActor
    static func measureContentHeight(
        of webView: WKWebView,
        completion: @escaping @MainActor (CGFloat) -> Void
    ) {
        webView.evaluateJavaScript(contentHeightScript, in: nil, in: .defaultClient) { result in
            let measured = ((try? result.get()) as? NSNumber)?.doubleValue ?? 0
            completion(max(CGFloat(measured), 120))
        }
    }

    /// Shared `decidePolicyFor` body: applies `navigationPolicy` and hands
    /// external links to `open`.
    @MainActor
    static func decidePolicy(
        for navigationAction: WKNavigationAction,
        open: (URL) -> Void
    ) -> WKNavigationActionPolicy {
        switch navigationPolicy(
            for: navigationAction.request.url,
            isLinkActivated: navigationAction.navigationType == .linkActivated
        ) {
        case .allow:
            return .allow
        case .openExternally(let url):
            open(url)
            return .cancel
        case .cancel:
            return .cancel
        }
    }
}

#if os(macOS)
struct EmailHTMLView: NSViewRepresentable {
    let html: String
    let allowsRemoteContent: Bool
    @Binding var contentHeight: CGFloat

    func makeNSView(context: Context) -> WKWebView {
        let webView = EmailScrollPassthroughWebView(
            frame: .zero,
            configuration: EmailHTMLDocument.makeConfiguration()
        )
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        disableScrolling(in: webView)
        loadHTML(in: webView, coordinator: context.coordinator)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        disableScrolling(in: webView)
        context.coordinator.contentHeight = $contentHeight
        if context.coordinator.currentHTML != html
            || context.coordinator.allowsRemoteContent != allowsRemoteContent {
            loadHTML(in: webView, coordinator: context.coordinator)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(contentHeight: $contentHeight)
    }

    private func loadHTML(in webView: WKWebView, coordinator: Coordinator) {
        coordinator.currentHTML = html
        coordinator.allowsRemoteContent = allowsRemoteContent
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let bg = isDark ? "#1e1e1e" : "#ffffff"
        let fg = isDark ? "#e0e0e0" : "#1a1a1a"
        let head = """
        <style>
            html, body { overflow: hidden !important; height: auto !important; }
            body { background: \(bg); color: \(fg); font-family: -apple-system, sans-serif; \
            font-size: 14px; line-height: 1.5; margin: 0; padding: 8px; word-wrap: break-word; }
            * { max-width: 100% !important; max-height: none !important; overflow: visible !important; }
            ::-webkit-scrollbar { width: 0 !important; height: 0 !important; display: none !important; }
            a { color: -webkit-link; }
            img { max-width: 100%; height: auto; }
            table { max-width: 100%; }
            pre { white-space: pre-wrap; word-wrap: break-word; }
        </style>
        """
        let wrapped = EmailHTMLDocument.wrap(html, allowsRemoteContent: allowsRemoteContent, head: head)
        webView.loadHTMLString(wrapped, baseURL: nil)
    }

    private func disableScrolling(in view: NSView) {
        if let scrollView = view as? NSScrollView {
            scrollView.hasVerticalScroller = false
            scrollView.hasHorizontalScroller = false
            scrollView.autohidesScrollers = true
            scrollView.verticalScrollElasticity = .none
            scrollView.horizontalScrollElasticity = .none
        }
        for subview in view.subviews {
            disableScrolling(in: subview)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var contentHeight: Binding<CGFloat>
        var currentHTML: String?
        var allowsRemoteContent = false

        init(contentHeight: Binding<CGFloat>) {
            self.contentHeight = contentHeight
        }

        func webView(_ webView: WKWebView,
                      decidePolicyFor navigationAction: WKNavigationAction,
                      decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            decisionHandler(EmailHTMLDocument.decidePolicy(for: navigationAction) { url in
                NSWorkspace.shared.open(url)
            })
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            EmailHTMLDocument.measureContentHeight(of: webView) { [weak self] height in
                self?.contentHeight.wrappedValue = height
            }
        }
    }
}
#elseif os(iOS)
struct EmailHTMLView: UIViewRepresentable {
    let html: String
    let allowsRemoteContent: Bool
    @Binding var contentHeight: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: EmailHTMLDocument.makeConfiguration())
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        loadHTML(in: webView, coordinator: context.coordinator)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        webView.scrollView.isScrollEnabled = false
        context.coordinator.contentHeight = $contentHeight
        context.coordinator.openURL = openURL
        if context.coordinator.currentHTML != html
            || context.coordinator.colorScheme != colorScheme
            || context.coordinator.allowsRemoteContent != allowsRemoteContent {
            loadHTML(in: webView, coordinator: context.coordinator)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            contentHeight: $contentHeight,
            colorScheme: colorScheme,
            openURL: openURL
        )
    }

    private func loadHTML(in webView: WKWebView, coordinator: Coordinator) {
        coordinator.currentHTML = html
        coordinator.colorScheme = colorScheme
        coordinator.allowsRemoteContent = allowsRemoteContent
        let isDark = colorScheme == .dark
        let bg = isDark ? "#1e1e1e" : "#ffffff"
        let fg = isDark ? "#e0e0e0" : "#1a1a1a"
        let head = """
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
            html, body { overflow: hidden !important; height: auto !important; }
            body { background: \(bg); color: \(fg); font-family: -apple-system, sans-serif; \
            font-size: 16px; line-height: 1.45; margin: 0; padding: 8px; word-wrap: break-word; }
            * { max-width: 100% !important; max-height: none !important; overflow: visible !important; }
            a { color: -webkit-link; }
            img { max-width: 100%; height: auto; }
            table { max-width: 100%; }
            pre { white-space: pre-wrap; word-wrap: break-word; }
        </style>
        """
        let wrapped = EmailHTMLDocument.wrap(html, allowsRemoteContent: allowsRemoteContent, head: head)
        webView.loadHTMLString(wrapped, baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var contentHeight: Binding<CGFloat>
        var colorScheme: ColorScheme
        var currentHTML: String?
        var allowsRemoteContent = false
        var openURL: OpenURLAction

        init(
            contentHeight: Binding<CGFloat>,
            colorScheme: ColorScheme,
            openURL: OpenURLAction
        ) {
            self.contentHeight = contentHeight
            self.colorScheme = colorScheme
            self.openURL = openURL
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            decisionHandler(EmailHTMLDocument.decidePolicy(for: navigationAction) { url in
                openURL(url)
            })
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            EmailHTMLDocument.measureContentHeight(of: webView) { [weak self] height in
                self?.contentHeight.wrappedValue = height
            }
        }
    }
}
#endif

#if os(macOS)
final class EmailScrollPassthroughWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        if let parentScrollView {
            parentScrollView.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    private var parentScrollView: NSScrollView? {
        var current = superview
        while let view = current {
            if let scrollView = view as? NSScrollView {
                return scrollView
            }
            current = view.superview
        }
        return nil
    }
}
#endif
