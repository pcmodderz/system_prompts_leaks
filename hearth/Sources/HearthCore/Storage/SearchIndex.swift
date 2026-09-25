import Foundation

/// In-memory inverted index rebuilt from decrypted records when the store opens.
///
/// Deliberately *not* persisted: a plaintext full-text index on disk would defeat
/// application-level encryption. Households hold thousands, not millions, of records, so
/// rebuilding on launch is cheap. Restricted records are only indexed while the vault is
/// unlocked and are dropped from the index when it locks.
final class SearchIndex: @unchecked Sendable {
    private var postings: [String: Set<String>] = [:]
    private var tokensByRecord: [String: Set<String>] = [:]
    private var vaultRecords: Set<String> = []
    private let lock = NSLock()

    static func tokenize(_ text: String) -> Set<String> {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        var tokens = Set<String>()
        var current = ""
        for ch in folded {
            if ch.isLetter || ch.isNumber { current.append(ch) } else if !current.isEmpty { tokens.insert(current); current = "" }
        }
        if !current.isEmpty { tokens.insert(current) }
        return tokens
    }

    func index(_ record: RecordEnvelope) {
        lock.lock(); defer { lock.unlock() }
        removeLocked(record.id)
        guard !record.deleted else { return }
        var text = record.fields.values.flatMap(\.searchableText)
        text.append(record.kind.rawValue)
        let tokens = text.reduce(into: Set<String>()) { $0.formUnion(Self.tokenize($1)) }
        tokensByRecord[record.id] = tokens
        for t in tokens { postings[t, default: []].insert(record.id) }
        if record.keyClass == .vault { vaultRecords.insert(record.id) }
    }

    func remove(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        removeLocked(id)
    }

    private func removeLocked(_ id: String) {
        guard let tokens = tokensByRecord.removeValue(forKey: id) else { return }
        for t in tokens {
            postings[t]?.remove(id)
            if postings[t]?.isEmpty == true { postings[t] = nil }
        }
        vaultRecords.remove(id)
    }

    func dropVaultRecords() {
        lock.lock(); let ids = vaultRecords; lock.unlock()
        ids.forEach(remove)
    }

    /// AND of all query terms; each term matches as a prefix.
    func search(_ query: String) -> [String: Int] {
        let terms = Self.tokenize(query)
        guard !terms.isEmpty else { return [:] }
        lock.lock(); defer { lock.unlock() }
        var result: [String: Int]?
        for term in terms {
            var hits: [String: Int] = [:]
            for (token, ids) in postings where token.hasPrefix(term) {
                let score = token == term ? 3 : 1
                for id in ids { hits[id, default: 0] += score }
            }
            if let r = result {
                result = r.filter { hits[$0.key] != nil }.mapValues { $0 } .merging(hits.filter { r[$0.key] != nil }) { $0 + $1 }
            } else {
                result = hits
            }
        }
        return result ?? [:]
    }

    func clear() {
        lock.lock(); postings.removeAll(); tokensByRecord.removeAll(); vaultRecords.removeAll(); lock.unlock()
    }
}
