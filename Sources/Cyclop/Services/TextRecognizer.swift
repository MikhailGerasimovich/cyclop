import Foundation
import PDFKit
import UniformTypeIdentifiers
import Vision

/// Reads the text in pictures, for the Markdown converter.
///
/// markitdown's own OCR asks a language model, which means a key, a bill and
/// the picture leaving the Mac. Vision does the same job on the machine, in
/// both languages the panel speaks, so the converter asks it instead.
enum TextRecognizer {
    /// Scanned PDFs are rendered page by page, and a long scan is minutes of
    /// work. Past this the rest is left unread rather than holding the queue.
    private static let pageLimit = 50

    /// markitdown's output, with what Vision found added where markitdown
    /// cannot see: the text in an image, and the pages of a scanned PDF.
    static func supplement(_ markdown: String, for url: URL) async -> String {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return markdown }

        if type.conforms(to: .image) {
            guard let text = await recognize(imageAt: url), !text.isEmpty else { return markdown }
            let heading = "# \(localized("Recognized Text"))"
            let metadata = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
            return metadata.isEmpty ? "\(heading)\n\n\(text)" : "\(metadata)\n\n\(heading)\n\n\(text)"
        }

        if type.conforms(to: .pdf), let document = PDFDocument(url: url), document.pageCount > 0 {
            // A PDF with a text layer gives thousands of characters a page;
            // a scan gives page numbers and stray marks, if anything.
            let found = markdown.filter { !$0.isWhitespace }.count
            guard found < 40 * document.pageCount else { return markdown }
            guard let text = await recognize(pdf: document), !text.isEmpty else { return markdown }
            return text
        }

        return markdown
    }

    private static func recognize(imageAt url: URL) async -> String? {
        guard let observations = try? await request().perform(on: url) else { return nil }
        return lines(observations)
    }

    private static func recognize(pdf document: PDFDocument) async -> String? {
        var pages: [String] = []
        for index in 0..<min(document.pageCount, pageLimit) {
            guard !Task.isCancelled else { return nil }
            guard let page = document.page(at: index), let image = render(page) else { continue }
            guard let observations = try? await request().perform(on: image) else { continue }
            let text = lines(observations)
            if !text.isEmpty { pages.append(text) }
        }
        return pages.isEmpty ? nil : pages.joined(separator: "\n\n---\n\n")
    }

    private static func request() -> RecognizeTextRequest {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        request.recognitionLanguages = [Locale.Language(identifier: "ru-RU"), Locale.Language(identifier: "en-US")]
        return request
    }

    private static func lines(_ observations: [RecognizedTextObservation]) -> String {
        observations
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Twice the page's own size: Vision reads small print far better with
    /// more pixels per letter, and a page at 2× is still a modest bitmap.
    private static func render(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2
        let width = Int(bounds.width * scale)
        let height = Int(bounds.height * scale)
        guard width > 0, height > 0,
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }
}
