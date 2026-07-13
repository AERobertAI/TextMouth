import Foundation

private final class ParserResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedResult: Result<DocumentContent, Error>?

    var result: Result<DocumentContent, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return storedResult
    }

    func store(_ result: Result<DocumentContent, Error>) {
        lock.lock()
        storedResult = result
        lock.unlock()
    }
}

/// Unified interface for parsing all supported book formats
enum BookParser {

    static func parse(url: URL, format: BookFormat) throws -> DocumentContent {
        switch format {
        case .epub:
            return try EPUBParser.parse(url: url)
        case .html:
            let html = try String(contentsOf: url, encoding: .utf8)
            return try HTMLParser.parse(html: html, title: url.deletingPathExtension().lastPathComponent)
        case .markdown:
            let text = try String(contentsOf: url, encoding: .utf8)
            return try MarkdownDocParser.parse(markdown: text, title: url.deletingPathExtension().lastPathComponent)
        case .txt:
            let text = try String(contentsOf: url, encoding: .utf8)
            return PlainTextParser.parse(text: text, title: url.deletingPathExtension().lastPathComponent)
        case .docx:
            return try DOCXParser.parse(url: url)
        case .daisy:
            return try DAISYParser.parse(url: url)
        case .pdf:
            return try PDFTextParser.parse(url: url)
        case .audio:
            // Audio parsing is async — use a synchronous bridge here
            let resultBox = ParserResultBox()
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached {
                do {
                    resultBox.store(.success(try await AudioBookParser.parse(url: url)))
                } catch {
                    resultBox.store(.failure(error))
                }
                semaphore.signal()
            }
            semaphore.wait()
            guard let result = resultBox.result else { throw AudioParseError.invalidDuration }
            return try result.get()
        }
    }
}
