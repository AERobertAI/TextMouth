import AppKit
import CoreText
import PDFKit
import XCTest
@testable import TextMouth

/// Small PDFs built in code for the PDF parser's tests: pages drawn with
/// Quartz (real embedded text, and pictures whose words exist only as
/// pixels), and pages written operator by operator for what Quartz never
/// writes (inline images, nested forms, invisible text).
enum PDFFixtures {
    /// A US Letter page, in points.
    static let letter = CGRect(x: 0, y: 0, width: 612, height: 792)

    // MARK: - Files

    /// A new PDF of `pageCount` letter-size pages, each drawn by `draw`
    /// (given the context and the page's index), in a temporary file that
    /// is removed when `test` ends.
    static func makePDF(
        for test: XCTestCase,
        pages pageCount: Int = 1,
        draw: (CGContext, Int) -> Void
    ) throws -> URL {
        let url = temporaryURL(for: test)
        var box = letter
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        for index in 0..<pageCount {
            context.beginPDFPage(nil)
            draw(context, index)
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    /// `pdf` written to a temporary file that is removed when `test` ends.
    static func write(_ pdf: RawPDF, for test: XCTestCase) throws -> URL {
        let url = temporaryURL(for: test)
        try pdf.data().write(to: url)
        return url
    }

    /// A fresh path for a PDF, removed when `test` ends.
    private static func temporaryURL(for test: XCTestCase) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
        test.addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: - Drawing

    /// Draws `text` as embedded text in Helvetica, its baseline starting at
    /// `origin`. `mode` `.invisible` draws it the way a searchable scan
    /// hides its OCR layer: present in the page's text, never painted.
    static func drawText(
        _ text: String,
        size: CGFloat,
        at origin: CGPoint,
        in context: CGContext,
        mode: CGTextDrawingMode = .fill
    ) {
        let font = NSFont(name: "Helvetica", size: size) ?? NSFont.systemFont(ofSize: size)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        context.saveGState()
        context.setTextDrawingMode(mode)
        context.textPosition = origin
        CTLineDraw(line, context)
        context.restoreGState()
    }

    /// A picture `size` points large at 2 pixels per point: a pale ground,
    /// a dark band along its foot, and each of `words` drawn as pixels in
    /// bold `fontSize`-point type, one line per entry, from the top down.
    /// No text survives into a PDF that draws it.
    static func picture(size: CGSize, words: [String] = [], fontSize: CGFloat = 20) -> CGImage {
        let scale: CGFloat = 2
        let context = CGContext(
            data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(CGColor(red: 0.86, green: 0.90, blue: 0.94, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        context.setFillColor(CGColor(red: 0.45, green: 0.55, blue: 0.62, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height * 0.1))
        let font = NSFont(name: "Helvetica-Bold", size: fontSize) ?? NSFont.boldSystemFont(ofSize: fontSize)
        for (index, text) in words.enumerated() {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
            context.textPosition = CGPoint(
                x: size.width * 0.08,
                y: size.height - fontSize * 2 - CGFloat(index) * fontSize * 1.6
            )
            CTLineDraw(line, context)
        }
        return context.makeImage()!
    }

    // MARK: - Pages

    /// The first page of the PDF at `url`, kept alive with its document
    /// (PDFKit cannot draw a page whose document is gone).
    static func firstPage(of url: URL) throws -> (document: PDFDocument, page: PDFPage) {
        let document = try XCTUnwrap(PDFDocument(url: url))
        return (document, try XCTUnwrap(document.page(at: 0)))
    }

    /// A recognized line reading `text` at `bounds`, as a recognizer
    /// reports one.
    static func line(_ text: String, at bounds: CGRect) -> PDFRecognizedLine {
        PDFRecognizedLine(text: text, bounds: bounds)
    }
}

// MARK: - Hand-Written PDFs

/// A PDF assembled from hand-written objects, with its cross-reference table
/// computed, so a test can use any content-stream operator.
///
/// Object 1 is the catalog and object 2 the page tree, both written by
/// `data()`; the objects a test adds are numbered from 3, so a page or
/// stream can be referred to as `"\(number) 0 R"` before the file exists.
struct RawPDF {
    /// The objects added, numbered from 3.
    private var objects: [String] = []
    /// The numbers of the objects that are pages, in order.
    private var pages: [Int] = []

    /// The number the next object added will have, so an object can refer
    /// to itself (a form that draws itself, say).
    var nextObjectNumber: Int { objects.count + 3 }

    /// Adds an object and returns its number.
    @discardableResult
    mutating func add(_ body: String) -> Int {
        objects.append(body)
        return objects.count + 2
    }

    /// Adds a stream whose dictionary holds `entries` (its length is
    /// added) and returns its number.
    @discardableResult
    mutating func addStream(_ entries: String, _ content: String) -> Int {
        add("<< \(entries) /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream")
    }

    /// Adds a page drawn by `content`, with `entries` such as its
    /// `/Resources` or `/Rotate`, and returns its number.
    @discardableResult
    mutating func addPage(
        _ content: String,
        entries: String = "",
        mediaBox: CGRect = PDFFixtures.letter
    ) -> Int {
        let stream = addStream("", content)
        let box = "[\(mediaBox.minX) \(mediaBox.minY) \(mediaBox.maxX) \(mediaBox.maxY)]"
        let page = add("<< /Type /Page /Parent 2 0 R /MediaBox \(box) \(entries) /Contents \(stream) 0 R >>")
        pages.append(page)
        return page
    }

    /// The file's bytes.
    func data() -> Data {
        let kids = pages.map { "\($0) 0 R" }.joined(separator: " ")
        let all = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [\(kids)] /Count \(pages.count) >>"
        ] + objects
        var text = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (index, body) in all.enumerated() {
            offsets.append(text.utf8.count)
            text += "\(index + 1) 0 obj\n\(body)\nendobj\n"
        }
        let crossReference = text.utf8.count
        text += "xref\n0 \(all.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { text += String(format: "%010d 00000 n \n", offset) }
        text += "trailer\n<< /Size \(all.count + 1) /Root 1 0 R >>\nstartxref\n\(crossReference)\n%%EOF\n"
        return Data(text.utf8)
    }

    /// A 2-by-2 grey image XObject, small enough to write by hand.
    static let tinyImage = "/Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceGray "
        + "/BitsPerComponent 8 /Filter /ASCIIHexDecode"
    /// The tiny image's data, in the hexadecimal its filter reads.
    static let tinyImageData = "00FF00FF>"
}

// MARK: - Recognizers

/// A recognizer that answers from a script instead of running Vision, and
/// records every region it is asked to read, so a test can check both what
/// the parser asked for and what it made of the answers.
final class ScriptedTextRecognizer: PDFPageTextRecognizer, @unchecked Sendable {
    /// One request: the page's number, counting from 1, and the region.
    struct Request: Equatable {
        var pageNumber: Int
        var region: CGRect
    }

    /// Answers a request with lines, or throws as a recognizer may.
    typealias Script = (Request) throws -> [PDFRecognizedLine]

    private let script: Script
    private let lock = NSLock()
    private var recorded: [Request] = []

    /// A recognizer answering each request with `script`.
    init(_ script: @escaping Script) {
        self.script = script
    }

    /// A recognizer that finds nothing anywhere.
    static func findingNothing() -> ScriptedTextRecognizer {
        ScriptedTextRecognizer { _ in [] }
    }

    /// Every request so far, in order.
    var requests: [Request] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func recognizeLines(in region: CGRect, of page: PDFPage) throws -> [PDFRecognizedLine] {
        let pageNumber = (page.document.map { $0.index(for: page) } ?? 0) + 1
        let request = Request(pageNumber: pageNumber, region: region)
        lock.lock()
        recorded.append(request)
        lock.unlock()
        return try script(request)
    }
}
