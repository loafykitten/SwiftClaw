import Foundation

/// Pure-func email thread clustering, per RFC 822 `References` / `In-Reply-To` +
/// normalized subject. Used by `EmailRepository.resolveThreads()`.
///
/// Two emails belong to the same thread if:
///   - they share at least one Message-ID ancestry token (their `References`,
///     `In-Reply-To`, or their own `Message-ID` overlap), OR
///   - their normalized subjects are equal AND at least one of them carries
///     reply markers (`Re:`/`Fwd:`) — i.e. the subject line itself signals a
///     reply chain. Without the reply-marker guard we would cluster unrelated
///     "Lunch?" messages.
enum ThreadResolver {
    /// Reply-marker prefixes recognized by both `replyMarker` and
    /// `normalizedSubject`. Single source of truth so the two stay in lockstep.
    private static let replyPrefixes = ["re:", "fw:", "fwd:", "aw:", "wg:"]

    /// Clusters the supplied messages into threads. Idempotent: running it
    /// twice on the same input produces the same output.
    static func cluster(_ messages: [Email]) -> [EmailThread] {
        var threads: [EmailThread] = []
        // Index: maps any reference ID (Message-ID, In-Reply-To, References
        // entries) to the index in `threads` of the thread that owns it.
        var referenceIndex: [String: Int] = [:]
        // Index: maps a normalized subject to thread index, but only when
        // the thread has no `messageID`/`references` ancestry yet (the
        // "subject-merge" fallback for poorly-behaved mailers). Subject
        // clusters require every contributing message to carry a reply marker.
        var subjectIndex: [String: Int] = [:]

        for message in messages {
            let subject = ThreadResolver.normalizedSubject(message.subject)
            let ancestry = message.allReferenceIDs
            let hasReplyMarker = !ThreadResolver.replyMarker(message.subject).isEmpty

            var matchedThreadIndex: Int? = nil

            // 1) Try ancestry match first (deterministic, strong).
            for ref in ancestry {
                if let index = referenceIndex[ref] {
                    matchedThreadIndex = index
                    break
                }
            }

            // 2) Fall back to subject clustering only when the message carries
            // a reply marker AND there's an existing thread with this subject.
            if matchedThreadIndex == nil, hasReplyMarker, let index = subjectIndex[subject] {
                matchedThreadIndex = index
            }

            if let index = matchedThreadIndex {
                let thread = threads[index]
                thread.messages.append(message)
                message.thread = thread
                thread.lastDate = max(thread.lastDate, message.date)
                thread.firstDate = min(thread.firstDate, message.date)
                // Re-register all ancestry tokens to point at this thread, so
                // later messages replying to any leg of the thread find it.
                for ref in ancestry {
                    referenceIndex[ref] = index
                }
                // If this is the first message in an existing subject-only
                // cluster to carry a Message-ID, register it as an anchor.
                if let mid = message.messageID, !mid.isEmpty {
                    referenceIndex[mid] = index
                }
            } else {
                let thread = EmailThread(
                    subjectNormalized: subject,
                    messages: [message],
                    firstDate: message.date,
                    lastDate: message.date
                )
                message.thread = thread
                threads.append(thread)
                let newIndex = threads.count - 1
                for ref in ancestry {
                    referenceIndex[ref] = newIndex
                }
                subjectIndex[subject] = newIndex
            }
        }

        return threads
    }

    /// Strips `Re:`, `Fwd:`, `Fw:`, `[List]` markers and trims whitespace.
    /// Used for both clustering and display. NOTE: case is preserved so the
    /// subject can be shown verbatim in the UI; clustering is therefore
    /// case-sensitive (a known trade-off).
    static func normalizedSubject(_ subject: String) -> String {
        var current = subject
        while true {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = trimmed.lowercased()

            var didStrip = false
            for prefix in ThreadResolver.replyPrefixes {
                if lower.hasPrefix(prefix) {
                    current = String(trimmed.dropFirst(prefix.count))
                    didStrip = true
                    break
                }
            }

            // Strip bracketed mailing-list tags like "[swift-evolution] ".
            if current.first == "[" {
                if let closeIndex = current.firstIndex(of: "]") {
                    current = String(current[current.index(after: closeIndex)...])
                    didStrip = true
                }
            }

            if !didStrip {
                return trimmed
            }
        }
    }

    /// Returns the reply marker prefix (`"re:"`, `"fwd:"`, etc.) if the subject
    /// carries one; empty string otherwise.
    static func replyMarker(_ subject: String) -> String {
        let lower = subject.lowercased()
        for prefix in ThreadResolver.replyPrefixes {
            if lower.hasPrefix(prefix) {
                return prefix
            }
        }
        return ""
    }
}
