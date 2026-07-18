import Foundation

/// A source-backed excerpt supporting one research finding.
nonisolated struct EvidenceRecord: Codable, Sendable, Hashable {
    let id: UUID
    let sourceIndex: Int
    let url: String
    let title: String
    let quote: String
    let claimSummary: String
    let retrievedAt: Date
}

/// Assigns stable citation numbers and stores the evidence gathered from them.
actor EvidenceStore {
    private var sources = [(title: String, url: String)]()
    private var indexByURL = [String: Int]()
    private var records = [EvidenceRecord]()

    /// Registers a source and returns its stable 1-based citation number.
    func register(title: String, url: String) -> Int {
        if let existing = indexByURL[url] {
            return existing
        }

        sources.append((title: title, url: url))
        let index = sources.count
        indexByURL[url] = index
        return index
    }

    func indices(forURLs urls: [String]) -> [Int] {
        urls.compactMap { indexByURL[$0] }.sorted()
    }

    func numberedList() -> [(index: Int, title: String, url: String)] {
        sources.enumerated().map { offset, source in
            (index: offset + 1, title: source.title, url: source.url)
        }
    }

    @discardableResult
    func addEvidence(
        sourceIndex: Int,
        url: String,
        title: String,
        quote: String,
        claimSummary: String,
        retrievedAt: Date = .now
    ) -> EvidenceRecord {
        let record = EvidenceRecord(
            id: UUID(),
            sourceIndex: sourceIndex,
            url: url,
            title: title,
            quote: quote,
            claimSummary: claimSummary,
            retrievedAt: retrievedAt
        )
        records.append(record)
        return record
    }

    func evidence(forSourceIndex sourceIndex: Int) -> [EvidenceRecord] {
        records.filter { $0.sourceIndex == sourceIndex }
    }

    func allEvidence() -> [EvidenceRecord] {
        records
    }
}
