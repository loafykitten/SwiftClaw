import Foundation

/// Heuristic token estimation — the app has no tokenizer (every inference
/// provider is OpenAI-compatible and remote), and existing size caps are
/// character-based. ASCII estimates at bytes ÷ 4 (tracks English prose
/// closely); every non-ASCII scalar counts as a full token, since BPE
/// tokenizers often spend one or more tokens per CJK character or emoji and
/// bytes ÷ 4 would *under*count them. Overcounting is the safe direction
/// for the one consumer that matters: `MemoryPromptBuilder`'s
/// full-injection tier switch (flipping to the compact index early never
/// blows the context; the reverse can).
nonisolated enum TokenEstimator {
    static func estimatedTokens(for text: String) -> Int {
        var asciiBytes = 0
        var nonASCIIScalars = 0
        for scalar in text.unicodeScalars {
            if scalar.isASCII {
                asciiBytes += 1
            } else {
                nonASCIIScalars += 1
            }
        }
        return (asciiBytes + 3) / 4 + nonASCIIScalars
    }
}
