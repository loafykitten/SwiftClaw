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
    struct Measurement: Sendable, Equatable {
        var asciiBytes = 0
        var nonASCIIScalars = 0

        var estimatedTokens: Int {
            (asciiBytes + 3) / 4 + nonASCIIScalars
        }

        static func + (lhs: Self, rhs: Self) -> Self {
            Self(
                asciiBytes: lhs.asciiBytes + rhs.asciiBytes,
                nonASCIIScalars: lhs.nonASCIIScalars + rhs.nonASCIIScalars
            )
        }
    }

    static func estimatedTokens(for text: String) -> Int {
        measurement(for: text).estimatedTokens
    }

    static func measurement(for text: String) -> Measurement {
        var measurement = Measurement()
        for scalar in text.unicodeScalars {
            if scalar.isASCII {
                measurement.asciiBytes += 1
            } else {
                measurement.nonASCIIScalars += 1
            }
        }
        return measurement
    }
}
