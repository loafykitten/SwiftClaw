import Foundation
import Testing
@testable import SwiftClaw

struct TextChunkerTests {
    private func reslice(_ text: String, _ chunk: TextChunker.Chunk) -> String {
        String(decoding: Array(text.utf8)[chunk.byteStart..<chunk.byteEnd], as: UTF8.self)
    }

    @Test func everyChunkByteRangeReslicesTheSourceExactly() {
        let text = """
        # Title

        Intro paragraph.

        ## Section One

        Body text for section one.

        ## Section Two

        Body text for section two.
        """
        let chunks = TextChunker.chunk(text)
        #expect(!chunks.isEmpty)
        for chunk in chunks {
            #expect(reslice(text, chunk) == chunk.content)
        }
    }

    @Test func exactByteRangesSurviveMultibyteUnicodeContent() {
        let text = """
        # 日本語の見出し

        本文はマルチバイト文字を含みます。café résumé 🎉 emoji too.

        ## 二番目

        もう少し本文。
        """
        let chunks = TextChunker.chunk(text)
        #expect(!chunks.isEmpty)
        for chunk in chunks {
            #expect(reslice(text, chunk) == chunk.content)
        }
    }

    @Test func chunksCarryTheNestedHeadingPath() throws {
        let text = """
        # Top

        ## Middle

        ### Leaf

        Leaf body content.
        """
        let chunks = TextChunker.chunk(text)
        let leafChunk = try #require(chunks.last)
        #expect(leafChunk.headingPath == "Top > Middle > Leaf")
    }

    @Test func chunksDoNotOverlap() {
        let text = String(repeating: "word ", count: 100) + "\n\n## Next\n\n" + String(repeating: "more ", count: 100)
        let chunks = TextChunker.chunk(text, maxChunkSize: 200)
        for index in 1..<chunks.count {
            #expect(chunks[index].byteStart >= chunks[index - 1].byteEnd)
        }
    }

    @Test func oversizedSectionsAreSplitUnderTheMaxChunkSize() {
        let longLine = String(repeating: "a", count: 400)
        let text = (0..<10).map { _ in longLine }.joined(separator: "\n")
        let chunks = TextChunker.chunk(text, maxChunkSize: 1000)
        #expect(chunks.count > 1)
        for chunk in chunks {
            #expect(chunk.content.utf8.count <= 1000 + longLine.utf8.count)
        }
    }

    @Test func emptyTextProducesNoChunks() {
        #expect(TextChunker.chunk("").isEmpty)
    }
}
