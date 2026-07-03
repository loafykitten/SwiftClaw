import SwiftUI
#if os(macOS)
import WebKit
#elseif os(iOS)
import WebKit
#endif

/// Renders HTML email bodies via WKWebView. Used when the server provides
/// an HTML part. Links open in the default browser. Extracted from
/// `EmailView.swift` along the HTML-renderer concern boundary.
struct EmailHTMLBodyView: View {
    let html: String
    @State private var contentHeight: CGFloat = 160

    var body: some View {
        EmailHTMLView(html: html, contentHeight: $contentHeight)
            .frame(height: max(contentHeight, 120))
    }
}

#if os(macOS)
struct EmailHTMLView: NSViewRepresentable {
    let html: String
    @Binding var contentHeight: CGFloat

    func makeNSView(context: Context) -> WKWebView {
        let webView = EmailScrollPassthroughWebView()
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        disableScrolling(in: webView)
        loadHTML(in: webView, coordinator: context.coordinator)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        disableScrolling(in: webView)
        context.coordinator.contentHeight = $contentHeight
        if context.coordinator.currentHTML != html {
            loadHTML(in: webView, coordinator: context.coordinator)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(contentHeight: $contentHeight)
    }

    private func loadHTML(in webView: WKWebView, coordinator: Coordinator) {
        coordinator.currentHTML = html
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let bg = isDark ? "#1e1e1e" : "#ffffff"
        let fg = isDark ? "#e0e0e0" : "#1a1a1a"
        let wrapped = """
        <html><head><meta charset="utf-8">
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
        </head><body>\(html)</body></html>
        """
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

        init(contentHeight: Binding<CGFloat>) {
            self.contentHeight = contentHeight
        }

        func webView(_ webView: WKWebView,
                      decidePolicyFor navigationAction: WKNavigationAction,
                      decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            updateContentHeight(for: webView)
        }

        private func updateContentHeight(for webView: WKWebView) {
            webView.evaluateJavaScript(
                """
                (() => {
                    const nodes = [document.documentElement, document.body, ...document.body.querySelectorAll('*')];
                    return Math.ceil(nodes.reduce((height, node) => {
                        const rect = node.getBoundingClientRect();
                        return Math.max(height, rect.bottom, node.scrollHeight || 0, node.offsetHeight || 0);
                    }, 0));
                })()
                """
            ) { [weak self] value, _ in
                guard let self else { return }
                let measured = (value as? NSNumber)?.doubleValue ?? 0
                Task { @MainActor in
                    self.contentHeight.wrappedValue = max(CGFloat(measured), 120)
                }
            }
        }
    }
}
#elseif os(iOS)
struct EmailHTMLView: UIViewRepresentable {
    let html: String
    @Binding var contentHeight: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
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
        if context.coordinator.currentHTML != html || context.coordinator.colorScheme != colorScheme {
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
        let isDark = colorScheme == .dark
        let bg = isDark ? "#1e1e1e" : "#ffffff"
        let fg = isDark ? "#e0e0e0" : "#1a1a1a"
        let wrapped = """
        <html><head><meta charset="utf-8">
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
        </head><body>\(html)</body></html>
        """
        webView.loadHTMLString(wrapped, baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var contentHeight: Binding<CGFloat>
        var colorScheme: ColorScheme
        var currentHTML: String?
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
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                openURL(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            updateContentHeight(for: webView)
        }

        private func updateContentHeight(for webView: WKWebView) {
            webView.evaluateJavaScript(
                """
                (() => {
                    const nodes = [document.documentElement, document.body, ...document.body.querySelectorAll('*')];
                    return Math.ceil(nodes.reduce((height, node) => {
                        const rect = node.getBoundingClientRect();
                        return Math.max(height, rect.bottom, node.scrollHeight || 0, node.offsetHeight || 0);
                    }, 0));
                })()
                """
            ) { [weak self] value, _ in
                guard let self else { return }
                let measured = (value as? NSNumber)?.doubleValue ?? 0
                Task { @MainActor in
                    self.contentHeight.wrappedValue = max(CGFloat(measured), 120)
                }
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
