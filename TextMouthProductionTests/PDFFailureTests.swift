import PDFKit
import XCTest
@testable import TextMouth

/// PDFs the parser cannot read, and the sentences a listener hears for
/// them (audit U18): a file that is not a PDF, a page with no text that OCR
/// could not read or found nothing on, and a PDF locked by a password; and
/// an outline nested deeper than the parser reads. Each test makes its PDF
/// in memory or in a sandbox folder of its own.
final class PDFFailureTests: XCTestCase {

    // MARK: - Failures

    /// Bytes that are not a PDF, in a file named as one, cannot be opened.
    func testBytesThatAreNotAPDFCannotBeOpened() throws {
        let url = try makeSandboxDirectory("PDFFailure").appendingPathComponent("Tide Tables.pdf")
        try Data("not a PDF".utf8).write(to: url)
        let recognizer = ScriptedTextRecognizer.findingNothing()

        XCTAssertThrowsError(try PDFTextParser.extract(from: url, recognizer: recognizer)) { error in
            guard case .cannotOpenPDF? = error as? PDFParserError else {
                return XCTFail("Expected cannotOpenPDF, got \(error)")
            }
            XCTAssertEqual(error.localizedDescription, "The PDF file could not be opened.")
        }
        XCTAssertEqual(recognizer.requests, [], "nothing that cannot be opened is read by OCR")
    }

    /// A page with no text, which only OCR could read, whose recognizer
    /// throws, fails saying OCR could not run, and why.
    func testAPageOCRCouldNotReadGivesTheRecognizersReason() throws {
        let url = try makeBlankPDF()
        let recognizer = ScriptedTextRecognizer { _ in
            throw NSError(domain: "PDFFailureTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "The scanner gave up."])
        }

        XCTAssertThrowsError(try PDFTextParser.extract(from: url, recognizer: recognizer)) { error in
            guard case .ocrFailed(let reason)? = error as? PDFParserError else {
                return XCTFail("Expected ocrFailed, got \(error)")
            }
            XCTAssertEqual(reason, "text recognition failed: The scanner gave up.")
            XCTAssertEqual(
                error.localizedDescription,
                "No text could be read from the PDF: it has no embedded text, and OCR could not run "
                    + "(text recognition failed: The scanner gave up.)."
            )
        }
        XCTAssertEqual(recognizer.requests.map(\.pageNumber), [1], "OCR must be asked to read the page")
    }

    /// The same page, where OCR finds nothing, has no text to read.
    func testAPageOCRFindsNothingOnHasNoTextContent() throws {
        let url = try makeBlankPDF()
        let recognizer = ScriptedTextRecognizer.findingNothing()

        XCTAssertThrowsError(try PDFTextParser.extract(from: url, recognizer: recognizer)) { error in
            guard case .noTextContent? = error as? PDFParserError else {
                return XCTFail("Expected noTextContent, got \(error)")
            }
            XCTAssertEqual(error.localizedDescription, "No text content could be extracted from the PDF.")
        }
        XCTAssertEqual(recognizer.requests.map(\.pageNumber), [1], "OCR must be asked to read the page")
    }

    /// A PDF locked by a password opens, but PDFKit gives its page neither
    /// text nor a drawing: it is refused as needing a password, before OCR
    /// is asked for anything, not as a failure of OCR.
    func testAPasswordProtectedPDFSaysItNeedsAPassword() throws {
        let url = try makeProtectedPDF(holding: "Close the sluice before the spring tide.", options: [
            PDFDocumentWriteOption.userPasswordOption: "lock-keeper",
            PDFDocumentWriteOption.ownerPasswordOption: "lock-keeper-owner",
        ])
        let document = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertTrue(document.isLocked, "the fixture must be locked")
        let recognizer = ScriptedTextRecognizer.findingNothing()

        XCTAssertThrowsError(try PDFTextParser.extract(from: url, recognizer: recognizer)) { error in
            guard case .passwordProtected? = error as? PDFParserError else {
                return XCTFail("Expected passwordProtected, got \(error)")
            }
            XCTAssertEqual(error.localizedDescription, "This PDF needs a password to open.")
        }
        XCTAssertTrue(recognizer.requests.isEmpty, "a locked PDF must be refused before OCR is asked to read a page")
    }

    /// A PDF that has an owner password only (it restricts what a reader may
    /// do, such as copying, but opens without a password) is not locked: it
    /// imports and reads as usual, with OCR never asked for a page.
    func testAPDFWithOnlyAnOwnerPasswordImports() throws {
        let text = "Close the sluice before the spring tide."
        let url = try makeProtectedPDF(holding: text, options: [PDFDocumentWriteOption.ownerPasswordOption: "lock-keeper-owner"])
        let document = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertFalse(document.isLocked, "an owner password alone must not lock the PDF")
        let recognizer = ScriptedTextRecognizer.findingNothing()

        let extraction = try PDFTextParser.extract(from: url, recognizer: recognizer)

        XCTAssertTrue(extraction.markdown.contains(text), extraction.markdown)
        XCTAssertTrue(recognizer.requests.isEmpty, "the embedded text must be read without OCR")
    }

    // MARK: - Outline Depth

    /// An outline nested 80 levels deep is read whole, in document order:
    /// the walk keeps its own stack rather than calling itself for each
    /// level, so no depth can exhaust the import thread's stack and no
    /// entry is left out.
    func testAnOutlineEightyLevelsDeepIsReadWhole() throws {
        let document = try Self.document(withOutlineLevels: 80)

        let entries = PDFTextParser.extractOutline(from: document)

        XCTAssertEqual(entries.count, 80, "an outline 80 levels deep must be read whole")
        XCTAssertEqual(entries.map(\.level), Array(0..<80))
        XCTAssertEqual(entries.map(\.title), (0..<80).map { "Level \($0)" })
    }

    /// An outline within the limit keeps every level, each leading to its page.
    func testAnOutlineWithinTheLimitKeepsEveryLevel() throws {
        let document = try Self.document(withOutlineLevels: 10)

        let entries = PDFTextParser.extractOutline(from: document)

        XCTAssertEqual(entries.map(\.level), Array(0..<10))
        XCTAssertEqual(entries.map(\.title), (0..<10).map { "Level \($0)" })
        XCTAssertEqual(entries.map(\.pageIndex), Array(repeating: 0, count: 10))
    }

    // MARK: - Fixtures

    /// A one-page PDF document, in memory, whose outline is a chain
    /// `levels` deep built with `PDFOutline.insertChild`: each entry the
    /// only child of the one above, labelled "Level 0" on, and leading to
    /// the page. The depth is kept modest; no test needs a deep stack.
    private static func document(withOutlineLevels levels: Int) throws -> PDFDocument {
        let document = PDFDocument()
        document.insert(PDFPage(), at: 0)
        let page = try XCTUnwrap(document.page(at: 0))
        let root = PDFOutline()
        document.outlineRoot = root
        var parent = root
        for level in 0..<levels {
            let entry = PDFOutline()
            entry.label = "Level \(level)"
            entry.destination = PDFDestination(page: page, at: CGPoint(x: 0, y: PDFFixtures.letter.maxY))
            parent.insertChild(entry, at: 0)
            parent = entry
        }
        return document
    }

    /// A one-page blank PDF made with PDFKit, in a sandbox folder of its
    /// own: a letter-size page with no text and no picture, which only OCR
    /// could read.
    private func makeBlankPDF() throws -> URL {
        let document = PDFDocument()
        document.insert(PDFPage(), at: 0)
        let url = try makeSandboxDirectory("PDFFailure").appendingPathComponent("Blank Page.pdf")
        XCTAssertTrue(document.write(to: url), "PDFKit could not write the blank PDF")
        return url
    }

    /// A one-page PDF whose page holds `text` as embedded text, written by
    /// PDFKit in a sandbox folder of its own with the passwords `options`
    /// name (`PDFDocumentWriteOption.userPasswordOption` is the one needed
    /// to open it, `.ownerPasswordOption` the one that lifts its
    /// restrictions). The page is drawn with `PDFFixtures`, and the
    /// unprotected copy is checked to read `text`, so only the protection
    /// can keep the parser from it.
    private func makeProtectedPDF(holding text: String, options: [PDFDocumentWriteOption: Any]) throws -> URL {
        let unlocked = try PDFFixtures.makePDF(for: self) { context, _ in
            PDFFixtures.drawText(text, size: 14, at: CGPoint(x: 72, y: 700), in: context)
        }
        let document = try XCTUnwrap(PDFDocument(url: unlocked))
        XCTAssertEqual(document.page(at: 0)?.string?.trimmingCharacters(in: .whitespacesAndNewlines), text)
        let url = try makeSandboxDirectory("PDFFailure").appendingPathComponent("Sluice Notes.pdf")
        XCTAssertTrue(document.write(to: url, withOptions: options), "PDFKit could not write the protected PDF")
        return url
    }
}
