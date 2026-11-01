import Foundation
import Testing
@testable import Cyclop

/// Тесты на `TokenLedger` — учёт токенов, потраченных конвертером на модель.
///
/// Обещание у него одно, и в двух местах его легко нарушить: общий итог
/// считает всё, что было оплачено, — включая удалённые карточки и
/// конвертации, которые не дали файла, — а карточка показывает расход только
/// того файла, ради которого модель звали. Каждый тест работает со своим
/// файлом во временной папке: настоящий llm-usage.json не трогается.
@MainActor
struct TokenLedgerTests {

    private static func makeFile() throws -> URL {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cyclop-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("llm-usage.json")
    }

    private static let report = URL(fileURLWithPath: "/tmp/Markdown/report.md")
    private static let slides = URL(fileURLWithPath: "/tmp/Markdown/slides.md")

    @Test func recordsTheTotalAndTheFilesOwnFigure() throws {
        let ledger = TokenLedger(file: try Self.makeFile())
        ledger.record(TokenUsage(requests: 2, input: 1400, output: 60), model: "m", provider: "openai", document: Self.report)
        ledger.record(TokenUsage(requests: 1, input: 1000, output: 50), model: "c", provider: "anthropic", document: Self.slides)

        #expect(ledger.total == TokenUsage(requests: 3, input: 2400, output: 110))
        #expect(ledger.total.total == 2510)
        #expect(ledger.entry(for: Self.report)?.usage == TokenUsage(requests: 2, input: 1400, output: 60))
        #expect(ledger.entry(for: Self.slides)?.model == "c")
        #expect(ledger.entry(for: Self.slides)?.provider == "anthropic")
    }

    @Test func aConversionWithoutAFileCountsOnlyTowardsTheTotal() throws {
        let ledger = TokenLedger(file: try Self.makeFile())
        ledger.record(TokenUsage(requests: 1, input: 900, output: 10), model: "m", provider: "openai", document: nil)

        #expect(ledger.total.requests == 1)
        #expect(ledger.documents.isEmpty)
    }

    @Test func noRequestsMeansNothingIsRecorded() throws {
        let ledger = TokenLedger(file: try Self.makeFile())
        ledger.record(TokenUsage(), model: "m", provider: "openai", document: Self.report)

        #expect(ledger.total == TokenUsage())
        #expect(ledger.entry(for: Self.report) == nil)
    }

    @Test func deletingACardKeepsWhatItCostInTheTotal() throws {
        let ledger = TokenLedger(file: try Self.makeFile())
        ledger.record(TokenUsage(requests: 1, input: 100, output: 5), model: "m", provider: "openai", document: Self.report)
        ledger.forget(Self.report)

        #expect(ledger.entry(for: Self.report) == nil)
        #expect(ledger.total.total == 105)
    }

    @Test func resetClearsTheTotalButNotTheCards() throws {
        let ledger = TokenLedger(file: try Self.makeFile())
        ledger.record(TokenUsage(requests: 1, input: 100, output: 5), model: "m", provider: "openai", document: Self.report)
        ledger.resetTotal()

        #expect(ledger.total == TokenUsage())
        #expect(ledger.entry(for: Self.report)?.usage.total == 105)
    }

    @Test func survivesARelaunch() throws {
        let file = try Self.makeFile()
        let first = TokenLedger(file: file)
        first.record(TokenUsage(requests: 3, input: 3000, output: 150), model: "c", provider: "anthropic", document: Self.report)

        let second = TokenLedger(file: file)
        #expect(second.total == TokenUsage(requests: 3, input: 3000, output: 150))
        #expect(second.entry(for: Self.report)?.model == "c")
        #expect(abs(second.since.timeIntervalSince(first.since)) < 1)
    }

    @Test func aBrokenFileStartsFromZeroInsteadOfCrashing() throws {
        let file = try Self.makeFile()
        try Data("{ not json".utf8).write(to: file)
        let ledger = TokenLedger(file: file)
        #expect(ledger.total == TokenUsage())
    }
}
