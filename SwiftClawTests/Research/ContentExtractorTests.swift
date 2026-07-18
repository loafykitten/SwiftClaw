import Foundation
import Testing
@testable import SwiftClaw

@Suite("Research content extractor")
struct ContentExtractorTests {
    private let extractor = ContentExtractor()

    @Test func stripsChromeAndPrefersArticleContent() {
        let html = """
            <html><body>
              <header>Site name</header>
              <nav>Home Products Pricing</nav>
              <div>This teaser is outside the article and should not win.</div>
              <article>
                <h1>Useful report</h1>
                <p>First paragraph with <strong>important</strong> detail.</p>
                <script>window.secret = "do not include";</script>
                <style>.hidden { display: none; }</style>
                <p>Second paragraph.</p>
              </article>
              <footer>Copyright</footer>
            </body></html>
            """

        let text = extractor.extractMainText(fromHTML: html)

        #expect(text.contains("Useful report"))
        #expect(text.contains("First paragraph with important detail."))
        #expect(text.contains("First paragraph with important detail.\n\nSecond paragraph."))
        #expect(!text.contains("Site name"))
        #expect(!text.contains("Home Products"))
        #expect(!text.contains("window.secret"))
        #expect(!text.contains("display: none"))
        #expect(!text.contains("Copyright"))
        #expect(!text.contains("teaser"))
    }

    @Test func decodesNamedAndNumericEntities() {
        let html = """
            <main><p>Fish &amp; Chips &lt;3 &gt; 2 &quot;yes&quot; &#39;ok&#39;&nbsp;
            &#65; &#x42;.</p></main>
            """

        #expect(extractor.extractMainText(fromHTML: html) == "Fish & Chips <3 > 2 \"yes\" 'ok' A B.")
    }

    @Test func extractsTitleThenFallsBackToFirstHeading() {
        #expect(extractor.extractTitle(fromHTML: "<title> A &amp; B </title><h1>Heading</h1>") == "A & B")
        #expect(extractor.extractTitle(fromHTML: "<main><h1>Fallback <em>heading</em></h1></main>") == "Fallback heading")
        #expect(extractor.extractTitle(fromHTML: "<p>No title here</p>") == nil)
    }

    @Test func malformedLargeAttributeTerminatesWithAvailableText() {
        let hugeAttribute = String(repeating: "x", count: 1_000_000)
        let html = "<article><p>Readable before damage.</p><div data-bad=\"\(hugeAttribute)"

        #expect(extractor.extractMainText(fromHTML: html) == "Readable before damage.")
    }
}
