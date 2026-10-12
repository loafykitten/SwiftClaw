import Foundation
import Testing
import WebKit
@testable import SwiftClaw

/// Hardening for sender-controlled HTML email (`EmailHTMLDocument`): the CSP,
/// navigation policy, remote-content detection, and — on a real WKWebView —
/// that message scripts don't run while the app's height probe still does.
@MainActor
struct EmailHTMLDocumentTests {
    @Test func defaultPolicyBlocksScriptsAndRemoteLoads() {
        let policy = EmailHTMLDocument.contentSecurityPolicy(allowsRemoteContent: false)
        #expect(policy.contains("default-src 'none'"))
        #expect(policy.contains("script-src 'none'"))
        #expect(policy.contains("frame-src 'none'"))
        #expect(policy.contains("form-action 'none'"))
        #expect(policy.contains("base-uri 'none'"))
        #expect(policy.contains("img-src data: cid:;"))
        #expect(!policy.contains("http"))
    }

    @Test func optInPolicyAllowsRemoteImagesButStillNoScripts() {
        let policy = EmailHTMLDocument.contentSecurityPolicy(allowsRemoteContent: true)
        #expect(policy.contains("img-src data: cid: https: http:"))
        #expect(policy.contains("style-src 'unsafe-inline' https: http:"))
        #expect(policy.contains("script-src 'none'"))
        #expect(policy.contains("frame-src 'none'"))
    }

    @Test func wrapPutsThePolicyFirstInHead() throws {
        let wrapped = EmailHTMLDocument.wrap(
            "<meta http-equiv=\"Content-Security-Policy\" content=\"img-src *\"><p>Hi</p>",
            allowsRemoteContent: false,
            head: "<style>body{}</style>"
        )
        let policyRange = try #require(wrapped.range(of: "http-equiv=\"Content-Security-Policy\""))
        let headClose = try #require(wrapped.range(of: "</head>"))
        let body = try #require(wrapped.range(of: "<body>"))
        #expect(policyRange.lowerBound < headClose.lowerBound)
        // The sender's own (looser) policy lands in <body>, after ours.
        #expect(wrapped[body.upperBound...].contains("img-src *"))
    }

    @Test func detectsCommonRemoteReferences() {
        let remote = [
            #"<img src="https://t.example.com/open.gif" width="1">"#,
            #"<img src=http://t.example.com/p.gif>"#,
            #"<td background="//cdn.example.com/bg.png">"#,
            #"<div style="background:url('https://cdn.example.com/x.png')">"#,
            #"<link rel="stylesheet" href="https://cdn.example.com/a.css">"#,
            #"<style>@import "https://cdn.example.com/b.css";</style>"#,
            #"<IMG SRCSET="https://cdn.example.com/x.png 2x">"#,
        ]
        for html in remote {
            #expect(EmailHTMLDocument.referencesRemoteContent(html), "\(html)")
        }

        let local = [
            #"<a href="https://example.com/article">Read more</a>"#,
            #"<img src="data:image/png;base64,iVBORw0KGgo=">"#,
            #"<img src="cid:logo@example.com">"#,
            "<p>Visit https://example.com today</p>",
        ]
        for html in local {
            #expect(!EmailHTMLDocument.referencesRemoteContent(html), "\(html)")
        }
    }

    @Test func navigationPolicyOnlyAllowsTheMessageDocument() throws {
        let https = try #require(URL(string: "https://example.com/a"))
        let mailto = try #require(URL(string: "mailto:someone@example.com"))
        let blank = try #require(URL(string: "about:blank"))
        let script = try #require(URL(string: "javascript:alert(1)"))
        let custom = try #require(URL(string: "someapp://do-something"))
        let file = try #require(URL(string: "file:///etc/hosts"))

        #expect(EmailHTMLDocument.navigationPolicy(for: blank, isLinkActivated: false) == .allow)
        #expect(EmailHTMLDocument.navigationPolicy(for: https, isLinkActivated: true) == .openExternally(https))
        #expect(EmailHTMLDocument.navigationPolicy(for: mailto, isLinkActivated: true) == .openExternally(mailto))
        // Meta refresh, form posts, and redirects aren't link clicks.
        #expect(EmailHTMLDocument.navigationPolicy(for: https, isLinkActivated: false) == .cancel)
        #expect(EmailHTMLDocument.navigationPolicy(for: script, isLinkActivated: true) == .cancel)
        #expect(EmailHTMLDocument.navigationPolicy(for: custom, isLinkActivated: true) == .cancel)
        #expect(EmailHTMLDocument.navigationPolicy(for: file, isLinkActivated: true) == .cancel)
        #expect(EmailHTMLDocument.navigationPolicy(for: nil, isLinkActivated: false) == .cancel)
    }

    @Test(.timeLimit(.minutes(1)))
    func webViewRunsNoMessageScriptsButMeasuresHeight() async throws {
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 200),
                                configuration: EmailHTMLDocument.makeConfiguration())
        let loader = LoadWaiter()
        webView.navigationDelegate = loader
        let body = """
        <script>document.title = 'script-ran';</script>
        <img src="x" onerror="document.title = 'handler-ran'">
        <div style="height: 900px">Tall message</div>
        """
        webView.loadHTMLString(
            EmailHTMLDocument.wrap(body, allowsRemoteContent: false, head: "<title>untouched</title>"),
            baseURL: nil
        )
        await loader.waitForFinish()

        #expect(webView.title == "untouched")
        let height = await withCheckedContinuation { continuation in
            EmailHTMLDocument.measureContentHeight(of: webView) { continuation.resume(returning: $0) }
        }
        #expect(height >= 900)
    }

    private final class LoadWaiter: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var finished = false

        func waitForFinish() async {
            if finished { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            finished = true
            continuation?.resume()
            continuation = nil
        }
    }
}
