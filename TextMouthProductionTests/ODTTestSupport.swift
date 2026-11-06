import XCTest
import ZIPFoundation
@testable import TextMouth

// MARK: - Making OpenDocument Packages for the Tests of the Reader

/// Helpers that build small OpenDocument text packages in code, shared by the
/// tests of TextMouth's own OpenDocument reader (FMT27), its hostile-file
/// tests, and its comparison with textutil.
extension XCTestCase {
    /// The namespace declarations every part the tests build carries.
    static let odfNamespaces = """
        xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" \
        xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" \
        xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" \
        xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0" \
        xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0" \
        xmlns:draw="urn:oasis:names:tc:opendocument:xmlns:drawing:1.0" \
        xmlns:svg="urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0" \
        xmlns:dc="http://purl.org/dc/elements/1.1/" \
        xmlns:meta="urn:oasis:names:tc:opendocument:xmlns:meta:1.0" \
        office:version="1.3"
        """

    /// The `content.xml` of a document whose body is `body` and whose
    /// automatic styles are `automaticStyles`.
    func odfContent(body: String, automaticStyles: String = "") -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content \(Self.odfNamespaces)>\
        <office:automatic-styles>\(automaticStyles)</office:automatic-styles>\
        <office:body><office:text>\(body)</office:text></office:body>\
        </office:document-content>
        """
    }

    /// An OpenDocument text package holding the given parts, removed when the
    /// test ends.
    /// - Parameters:
    ///   - mediaType: the first entry, `mimetype`; nil leaves it out.
    ///   - styles: the whole `styles.xml`, or nil for none.
    ///   - meta: the whole `meta.xml`, or nil for none.
    ///   - compression: how the parts are stored.
    func makeODT(
        content: String,
        mediaType: String? = "application/vnd.oasis.opendocument.text",
        styles: String? = nil,
        meta: String? = nil,
        compression: CompressionMethod = .none
    ) throws -> URL {
        var entries: [TestZIPEntry] = []
        if let mediaType { entries.append(TestZIPEntry("mimetype", Data(mediaType.utf8))) }
        entries.append(TestZIPEntry("content.xml", Data(content.utf8)))
        if let styles { entries.append(TestZIPEntry("styles.xml", Data(styles.utf8))) }
        if let meta { entries.append(TestZIPEntry("meta.xml", Data(meta.utf8))) }
        return try makeODT(entries: entries, compression: compression)
    }

    /// Runs `work` on another thread, bound to an import of its own, and
    /// returns what it did; or, if it has not finished in `seconds`, fails the
    /// test, cancels the import (a reader stops at its next check), waits a
    /// little for the thread, and returns nil. A read that hangs fails its
    /// test and does not stop the suite, and every agent behind it.
    func finishing<T>(
        within seconds: Double,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ work: @escaping () throws -> T
    ) -> Result<T, Error>? {
        let cancellation = ImportCancellation()
        let outcome = TimedOutcome<T>()
        let done = DispatchSemaphore(value: 0)
        // A thread of its own with a large stack, as the main thread has.
        let thread = Thread {
            outcome.result = Result { try ImportCancellation.$current.withValue(cancellation) { try work() } }
            done.signal()
        }
        thread.stackSize = 8 << 20
        thread.start()
        if done.wait(timeout: .now() + seconds) == .timedOut {
            cancellation.cancel()
            // Work that asks stops now; work that does not is given a moment.
            _ = done.wait(timeout: .now() + 5)
            XCTFail("\(label) took more than \(seconds) seconds", file: file, line: line)
            return nil
        }
        return outcome.result
    }

    /// An OpenDocument package holding exactly `entries`, in order.
    func makeODT(entries: [TestZIPEntry], compression: CompressionMethod = .none) throws -> URL {
        let url = try makeTemporaryZip(prefix: "ODT", orderedEntries: entries, compressionMethod: compression)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// An OpenDocument text package whose body is `body`.
    func makeODT(body: String, automaticStyles: String = "") throws -> URL {
        try makeODT(content: odfContent(body: body, automaticStyles: automaticStyles))
    }

    /// The `styles.xml` of a document with the given named styles.
    func odfStyles(_ styles: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-styles \(Self.odfNamespaces)>\
        <office:styles>\(styles)</office:styles>\
        </office:document-styles>
        """
    }

    /// The `meta.xml` of a document with `metadata` inside `office:meta`.
    func odfMeta(_ metadata: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-meta \(Self.odfNamespaces)><office:meta>\(metadata)</office:meta></office:document-meta>
        """
    }

    /// The lines of the body of `html`, an HTML document of the reader,
    /// without the blank ones.
    func odfBodyLines(_ html: String) -> [String] {
        guard let start = html.range(of: "<body>"), let end = html.range(of: "</body>") else { return [] }
        return html[start.upperBound..<end.lowerBound]
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    /// The body of the HTML the reader makes of a document with the given
    /// body and automatic styles, as lines.
    func odfLines(
        _ body: String,
        styles: String = "",
        pages: Bool = false
    ) throws -> [String] {
        let url = try makeODT(body: body, automaticStyles: styles)
        return odfBodyLines(try ODTDocumentReader.html(of: url, includesPages: pages))
    }

    /// The words a listener hears of the document whose body is `body`: the
    /// reading text (`MarkdownDocParser.parseChapter`, which writes no list
    /// marker) of the HTML the reader makes, split at white space.
    func odfHeard(_ body: String, styles: String = "") throws -> [String] {
        let url = try makeODT(body: body, automaticStyles: styles)
        let html = try ODTDocumentReader.html(of: url, includesPages: false)
        let markdown = try HTMLToMarkdownConverter.convert(html, includesPages: false)
        return try MarkdownDocParser.parseChapter(markdown: markdown, title: "", includeNavigationHeadings: true)
            .text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// The text of `html`'s body with no markup, for a test that cares about
    /// words alone.
    func odfPlainText(_ html: String) -> String {
        odfBodyLines(html).joined(separator: " ")
            .replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

// MARK: - The Samples Compared with textutil Instead of a Golden

extension TextPipelineFixtures {
    /// Whether the format sample `name` (a path in `formatSampleNames`) is one
    /// of the real OpenDocument files from LibreOffice, whose reading
    /// `ODTTextutilComparisonTests` compares with textutil's, naming every
    /// difference, instead of `DocumentGoldenTests` recording a golden of it
    /// (a golden of textutil's reading would pin what the own reader
    /// replaces). It is not part of `formatSamplesHeldBack`, which the other
    /// readers' samples change too.
    static func isComparedByODTTests(_ name: String) -> Bool {
        name.hasPrefix("format-samples/odt/libreoffice-")
    }

    /// The two OpenDocument samples whose goldens record textutil's reading,
    /// which loses the author: the own reader reads it, so the goldens change
    /// by that one line. They are not compared until the goldens are recorded
    /// again with `Scripts/test/update-goldens.sh`, which runs the hosted
    /// tests and so is not run by the reader's agent; the commit that records
    /// them removes this list and its use in
    /// `DocumentGoldenTests.recordedFormatSampleNames`.
    static func isAwaitingGoldenRerecording(_ name: String) -> Bool {
        ["format-samples/odt/handwritten.odt", "format-samples/ott/handwritten.ott"].contains(name)
    }
}

/// What a thread that `finishing(within:_:_:)` runs left, read only after the
/// thread has signalled that it is done.
final class TimedOutcome<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}
