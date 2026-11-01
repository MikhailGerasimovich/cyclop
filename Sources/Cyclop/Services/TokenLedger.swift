import Foundation

/// Tokens spent by one conversion, or by all of them together.
struct TokenUsage: Codable, Equatable {
    /// Calls to the model. One per picture or scanned page.
    var requests = 0
    var input = 0
    var output = 0

    var total: Int { input + output }

    static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            requests: lhs.requests + rhs.requests,
            input: lhs.input + rhs.input,
            output: lhs.output + rhs.output
        )
    }
}

/// What the language model has cost: in total, and per converted file.
///
/// `~/Library/Application Support/Cyclop/llm-usage.json`. Kept apart from the
/// files themselves because the total outlives them: a converted file deleted
/// from the panel was still paid for. A conversion that failed after the
/// model had already been called counts towards the total as well, for the
/// same reason — it just has no card to show it on.
///
/// Conversions that never reached a model are not recorded at all, so a card
/// without a figure means exactly that: nothing was spent on it.
@MainActor
final class TokenLedger: ObservableObject {
    struct Entry: Codable, Equatable {
        var usage: TokenUsage
        var model: String
        var provider: String
    }

    private struct File: Codable {
        var total = TokenUsage()
        /// When the count started: first use, or the last reset.
        var since = Date()
        /// By file name. A name, not a path: the folder is fixed, and a file
        /// renamed in Finder simply loses its figure rather than taking
        /// someone else's.
        var documents: [String: Entry] = [:]
    }

    @Published private(set) var total = TokenUsage()
    @Published private(set) var since = Date()
    @Published private(set) var documents: [String: Entry] = [:]

    private let file: URL

    init(file: URL = Support.file("llm-usage.json")) {
        self.file = file
        if let data = try? Data(contentsOf: file),
           let stored = try? Self.decoder.decode(File.self, from: data) {
            total = stored.total
            since = stored.since
            documents = stored.documents
        }
    }

    func entry(for document: URL) -> Entry? {
        documents[document.lastPathComponent]
    }

    /// Adds to the total, and to the file's own figure when there is a file.
    func record(_ usage: TokenUsage, model: String, provider: String, document: URL?) {
        guard usage.requests > 0 else { return }
        if total.requests == 0, documents.isEmpty { since = Date() }
        total = total + usage
        if let document {
            let name = document.lastPathComponent
            let previous = documents[name]?.usage ?? TokenUsage()
            documents[name] = Entry(usage: previous + usage, model: model, provider: provider)
        }
        save()
    }

    /// The card is gone; the total keeps what it cost.
    func forget(_ document: URL) {
        guard documents.removeValue(forKey: document.lastPathComponent) != nil else { return }
        save()
    }

    /// Starts the total over. Per-file figures stay with their files.
    func resetTotal() {
        total = TokenUsage()
        since = Date()
        save()
    }

    private func save() {
        let stored = File(total: total, since: since, documents: documents)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        do {
            try encoder.encode(stored).write(to: file, options: .atomic)
        } catch {
            NSLog("Cyclop: cannot write llm-usage.json: \(error.localizedDescription)")
        }
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
