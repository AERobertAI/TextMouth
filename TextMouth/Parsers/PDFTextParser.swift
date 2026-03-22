import Foundation
import PDFKit
import Vision
import AppKit

// MARK: - Error Types

/// Errors that can occur when parsing a PDF file
enum PDFParserError: LocalizedError {
    case fileNotFound(String)
    case cannotOpenPDF
    case noTextContent
    case ocrFailed(String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path): return "PDF file not found at: \(path)"
        case .cannotOpenPDF: return "The PDF file could not be opened."
        case .noTextContent: return "No text content could be extracted from the PDF."
        case .ocrFailed(let msg): return "OCR failed: \(msg)"
        }
    }
}

// MARK: - PDF Parser

/// Parses text-based and scanned PDF files into Markdown.
/// Uses PDFKit for text extraction with font-based heading detection,
/// PDFOutline for table of contents, and Vision OCR as a fallback
/// for scanned/image-only pages.
enum PDFTextParser {

    // MARK: - Public API

    /// Parse a PDF file into DocumentContent for reading/playback
    static func parse(url: URL) throws -> DocumentContent {
        let markdown = try extractMarkdown(from: url)
        let metadata = readMetadata(from: url)
        let title = metadata?.title ?? url.deletingPathExtension().lastPathComponent
        let author = metadata?.author ?? "Unknown"

        let content = try MarkdownDocParser.parse(markdown: markdown, title: title)
        return DocumentContent(title: title, author: author, chapters: content.chapters)
    }

    /// Extract Markdown from a PDF file. Main entry point for MarkdownCacheService.
    /// Uses PDFKit text extraction with font-based heading detection.
    /// Falls back to Vision OCR for pages with no embedded text.
    static func extractMarkdown(from url: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PDFParserError.fileNotFound(url.path)
        }
        guard let document = PDFDocument(url: url) else {
            throw PDFParserError.cannotOpenPDF
        }

        // Try outline-based chapter extraction first
        let outline = extractOutline(from: document)

        // Extract text from all pages with font analysis
        var allPageTexts: [(pageIndex: Int, markdown: String, wasOCR: Bool)] = []

        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else { continue }

            let pageText = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if pageText.count >= 10 {
                // Text-based page — use attributed string for heading detection
                let markdown = extractMarkdownFromTextPage(page)
                allPageTexts.append((i, markdown, false))
            } else {
                // Possibly scanned page — try OCR
                let ocrText = performOCR(on: page)
                if !ocrText.isEmpty {
                    allPageTexts.append((i, ocrText, true))
                }
            }
        }

        guard !allPageTexts.isEmpty else {
            throw PDFParserError.noTextContent
        }

        // If we have an outline, use it to insert chapter markers
        if !outline.isEmpty {
            return buildMarkdownWithOutline(
                pageTexts: allPageTexts,
                outline: outline,
                document: document
            )
        }

        // No outline — just concatenate page text
        return allPageTexts.map { $0.markdown }
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Read metadata (title, author) from PDF document attributes
    static func readMetadata(from url: URL) -> PDFMetadata? {
        guard let document = PDFDocument(url: url) else { return nil }

        let attrs = document.documentAttributes ?? [:]
        let title = (attrs[PDFDocumentAttribute.titleAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let author = (attrs[PDFDocumentAttribute.authorAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if title.isEmpty && author.isEmpty { return nil }
        return PDFMetadata(title: title, author: author)
    }

    // MARK: - Text Page Extraction

    /// Extract Markdown from a text-based PDF page using font attribute analysis
    /// to detect headings, bold, and italic formatting.
    private static func extractMarkdownFromTextPage(_ page: PDFPage) -> String {
        guard let attrString = page.attributedString else {
            return page.string ?? ""
        }

        // First pass: determine the body font size (most common size)
        let bodyFontSize = detectBodyFontSize(in: attrString)

        // Second pass: convert runs to Markdown with heading detection
        var markdown = ""
        var currentLine = ""
        var currentLineIsHeading = false
        var currentHeadingLevel = 0

        let fullRange = NSRange(location: 0, length: attrString.length)

        attrString.enumerateAttributes(in: fullRange, options: []) { attrs, range, _ in
            let text = attrString.attributedSubstring(from: range).string

            // Skip empty runs
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty || text.contains("\n") else {
                return
            }

            // Detect font properties
            let font = attrs[.font] as? NSFont
            let fontSize = font?.pointSize ?? bodyFontSize
            let isBold = font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false
            let isItalic = font?.fontDescriptor.symbolicTraits.contains(.italic) ?? false

            // Check if this run is a heading based on font size
            let isHeading = fontSize > bodyFontSize * 1.15 && bodyFontSize > 0
            let headingLevel = headingLevelFromFontSize(fontSize, bodySize: bodyFontSize)

            // Process text, splitting on newlines
            let segments = text.components(separatedBy: "\n")
            for (segIndex, segment) in segments.enumerated() {
                // Handle newline boundaries
                if segIndex > 0 {
                    // Flush the current line
                    markdown += flushLine(
                        currentLine,
                        isHeading: currentLineIsHeading,
                        headingLevel: currentHeadingLevel
                    )
                    currentLine = ""
                    currentLineIsHeading = false
                    currentHeadingLevel = 0
                }

                let trimmed = segment.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }

                // Apply inline formatting
                var formatted = trimmed
                if isBold && isItalic {
                    formatted = "***\(formatted)***"
                } else if isBold && !isHeading {
                    // Don't bold headings — the # prefix is sufficient
                    formatted = "**\(formatted)**"
                } else if isItalic {
                    formatted = "*\(formatted)*"
                }

                if isHeading {
                    currentLineIsHeading = true
                    currentHeadingLevel = max(currentHeadingLevel, headingLevel)
                }

                if !currentLine.isEmpty {
                    currentLine += " "
                }
                currentLine += formatted
            }
        }

        // Flush final line
        markdown += flushLine(
            currentLine,
            isHeading: currentLineIsHeading,
            headingLevel: currentHeadingLevel
        )

        return markdown.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Flush a line of text, adding heading prefix if needed
    private static func flushLine(_ text: String, isHeading: Bool, headingLevel: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "\n" }

        if isHeading {
            let prefix = String(repeating: "#", count: max(1, min(headingLevel, 6)))
            return "\n\(prefix) \(trimmed)\n\n"
        }

        return "\n\(trimmed)\n"
    }

    /// Detect the most common font size in an attributed string (the "body" size)
    private static func detectBodyFontSize(in attrString: NSAttributedString) -> CGFloat {
        var sizeCounts: [CGFloat: Int] = [:]
        let fullRange = NSRange(location: 0, length: attrString.length)

        attrString.enumerateAttribute(.font, in: fullRange, options: []) { value, range, _ in
            guard let font = value as? NSFont else { return }
            let roundedSize = (font.pointSize * 2).rounded() / 2 // Round to nearest 0.5
            let charCount = range.length
            sizeCounts[roundedSize, default: 0] += charCount
        }

        // Return the size used for the most characters
        return sizeCounts.max(by: { $0.value < $1.value })?.key ?? 12.0
    }

    /// Map a font size to a heading level relative to the body font size
    private static func headingLevelFromFontSize(_ fontSize: CGFloat, bodySize: CGFloat) -> Int {
        guard bodySize > 0 else { return 2 }
        let ratio = fontSize / bodySize

        if ratio >= 2.0 { return 1 }       // 2x+ body size → h1
        if ratio >= 1.6 { return 2 }       // 1.6x+ → h2
        if ratio >= 1.3 { return 3 }       // 1.3x+ → h3
        if ratio >= 1.15 { return 4 }      // 1.15x+ → h4
        return 5
    }

    // MARK: - OCR

    /// Perform OCR on a PDF page using Vision framework.
    /// Renders the page to an image and runs text recognition.
    private static func performOCR(on page: PDFPage) -> String {
        // Render page to CGImage at 2x scale for better OCR accuracy
        let pageRect = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2.0
        let width = Int(pageRect.width * scale)
        let height = Int(pageRect.height * scale)

        guard width > 0 && height > 0 else { return "" }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return "" }

        // White background
        context.setFillColor(CGColor.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Scale and draw the PDF page
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)

        guard let cgImage = context.makeImage() else { return "" }

        // Run Vision OCR
        var recognizedText = ""
        let semaphore = DispatchSemaphore(value: 0)

        let request = VNRecognizeTextRequest { request, error in
            defer { semaphore.signal() }
            guard let observations = request.results as? [VNRecognizedTextObservation] else { return }

            // Sort observations top-to-bottom, left-to-right for reading order
            let sorted = observations.sorted { a, b in
                // Vision uses bottom-left origin, so higher y = higher on page
                if abs(a.boundingBox.midY - b.boundingBox.midY) > 0.01 {
                    return a.boundingBox.midY > b.boundingBox.midY
                }
                return a.boundingBox.midX < b.boundingBox.midX
            }

            var lines: [String] = []
            for observation in sorted {
                guard let candidate = observation.topCandidates(1).first else { continue }
                lines.append(candidate.string)
            }
            recognizedText = lines.joined(separator: "\n")
        }

        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])
        semaphore.wait()

        return recognizedText
    }

    // MARK: - Outline / Table of Contents

    /// Outline entry extracted from PDF bookmarks
    struct OutlineEntry {
        var title: String
        var level: Int     // 0-based depth in the outline tree
        var pageIndex: Int // zero-based page index
    }

    /// Extract the table of contents from a PDF's outline/bookmarks
    static func extractOutline(from document: PDFDocument) -> [OutlineEntry] {
        guard let root = document.outlineRoot else { return [] }

        var entries: [OutlineEntry] = []
        traverseOutline(root, depth: -1, document: document, entries: &entries)
        return entries
    }

    /// Recursively traverse the PDF outline tree
    private static func traverseOutline(
        _ outline: PDFOutline,
        depth: Int,
        document: PDFDocument,
        entries: inout [OutlineEntry]
    ) {
        for i in 0..<outline.numberOfChildren {
            guard let child = outline.child(at: i) else { continue }
            let label = child.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if !label.isEmpty, let page = child.destination?.page {
                let pageIndex = document.index(for: page)
                entries.append(OutlineEntry(
                    title: label,
                    level: max(0, depth + 1),
                    pageIndex: pageIndex
                ))
            }

            traverseOutline(child, depth: depth + 1, document: document, entries: &entries)
        }
    }

    // MARK: - Outline-Based Markdown Assembly

    /// Build Markdown with chapter markers derived from the PDF outline.
    /// Inserts heading markers at the appropriate page boundaries.
    private static func buildMarkdownWithOutline(
        pageTexts: [(pageIndex: Int, markdown: String, wasOCR: Bool)],
        outline: [OutlineEntry],
        document: PDFDocument
    ) -> String {
        // Build a map from page index → outline entries that start on that page
        var pageOutlineMap: [Int: [OutlineEntry]] = [:]
        for entry in outline {
            pageOutlineMap[entry.pageIndex, default: []].append(entry)
        }

        var markdown = ""

        for (pageIndex, pageMarkdown, _) in pageTexts {
            // Insert outline headings for this page
            if let entries = pageOutlineMap[pageIndex] {
                for entry in entries {
                    let level = min(entry.level + 1, 6) // outline depth 0 → h1
                    let prefix = String(repeating: "#", count: level)

                    // Check if the page text already starts with this heading
                    // (from font-based detection) to avoid duplicates
                    let headingText = entry.title
                    if !pageMarkdown.contains(headingText) {
                        markdown += "\n\(prefix) \(headingText)\n\n"
                    }
                }
            }

            markdown += pageMarkdown + "\n\n"
        }

        return markdown.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Metadata

/// Basic metadata extracted from PDF document attributes
struct PDFMetadata {
    var title: String
    var author: String
}
