import Foundation

/// Unified interface for parsing all supported book formats
enum BookParser {

    /// Parse the book at `url` directly from its source file. HTML,
    /// Markdown, and plain-text sources are decoded by `TextFileDecoder`,
    /// exactly as the Markdown cache decodes them, so both readings start
    /// from the same text whatever the file's encoding and line endings.
    static func parse(url: URL, format: BookFormat) throws -> DocumentContent {
        switch format {
        case .epub:
            return try EPUBParser.parse(url: url)
        case .html:
            let html = try TextFileDecoder.readText(at: url, format: format)
            return try HTMLParser.parse(html: html, title: url.deletingPathExtension().lastPathComponent)
        case .markdown:
            let text = try TextFileDecoder.readText(at: url, format: format)
            return try MarkdownDocParser.parse(markdown: text, title: url.deletingPathExtension().lastPathComponent)
        case .txt:
            let text = try TextFileDecoder.readText(at: url, format: format)
            return PlainTextParser.parse(text: text, title: url.deletingPathExtension().lastPathComponent)
        case .docx:
            return try DOCXParser.parse(url: url)
        case .rtf, .rtfd, .doc, .odt, .wordml:
            // textutil's formats, read through a child process (FMT13).
            return try TextutilDocumentReader.parse(url: url, bookFormat: format)
        case .daisy:
            return try DAISYParser.parse(url: url)
        case .pdf:
            return try PDFTextParser.parse(url: url)
        case .audio:
            // Audio parsing is async, so wait for it through the shared bridge.
            return try AsyncBridge.waitForResult {
                try await AudioBookParser.parse(url: url)
            }
        }
    }
}
