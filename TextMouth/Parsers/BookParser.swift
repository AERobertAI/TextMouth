import Foundation

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
            var result: DocumentContent?
            var parseError: Error?
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                do {
                    result = try await AudioBookParser.parse(url: url)
                } catch {
                    parseError = error
                }
                semaphore.signal()
            }
            semaphore.wait()
            if let error = parseError { throw error }
            guard let content = result else { throw AudioParseError.invalidDuration }
            return content
        }
    }
}
