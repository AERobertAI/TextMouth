import XCTest
import ZIPFoundation
@testable import TextMouth

/// TextMouth's own OpenDocument reader (FMT27) on files built to hurt it: a
/// book's file is untrusted input, and the reader must end every one of
/// them with an HTML document or a clean error, in well under a second,
/// whatever the file claims about its own size.
final class ODTHostileReaderTests: XCTestCase {

    // MARK: - Helpers

    /// The longest any one hostile read may take. A read takes a fraction of
    /// a second even in a debug build; the margin is for a busy Mac.
    private let allowedSeconds = 2.0

    /// Reads the package at `url` and returns the HTML, or nil when the
    /// reader refused it with an error it names (the sentence for an
    /// unreadable document, or for one too large); fails the test if the
    /// read took too long or threw any other error. Reaching the return at
    /// all is the test that nothing trapped.
    @discardableResult
    private func read(
        _ url: URL,
        _ label: String,
        within seconds: Double? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> String? {
        // On another thread, so that a read that hangs fails the test.
        guard let outcome = finishing(within: seconds ?? allowedSeconds, label, file: file, line: line, {
            try ODTDocumentReader.html(of: url, includesPages: true)
        }) else { return nil }
        do {
            return try outcome.get()
        } catch {
            let known = error is TextutilConverter.Failure || error is DocumentTooLargeError || error is FileImportError
            XCTAssertTrue(known, "\(label) threw an error the reader does not name: \(error)", file: file, line: line)
            return nil
        }
    }

    /// A small deterministic random number generator, so the byte flips of
    /// one run are the byte flips of every run.
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            return value ^ (value >> 31)
        }
    }

    // MARK: - Truncation

    /// A sample cut off at many lengths ends in a clean error or a document,
    /// never a trap: the end of a ZIP archive is where its directory is.
    func testPackagesTruncatedAtManyLengths() throws {
        for sample in ["odt/handwritten.odt", "odt/libreoffice-tdf169882.odt"] {
            let whole = try Data(contentsOf: copyOfFormatSample(sample))
            let folder = try makeSandboxDirectory("ODTTruncated")
            let stride = max(whole.count / 120, 1)
            for length in Swift.stride(from: 0, to: whole.count, by: stride) {
                let cut = folder.appendingPathComponent("cut-\(length).odt")
                try whole.prefix(length).write(to: cut)
                read(cut, "\(sample) cut at \(length)")
            }
        }
    }

    /// A part cut off in the middle ends the read: a half-read document
    /// would give a listener half a book without saying so.
    func testContentCutOffInTheMiddleIsRefused() throws {
        let content = odfContent(body: "<text:p>First</text:p><text:p>Second words that are cut o")
        let url = try makeODT(content: content)
        XCTAssertThrowsError(try ODTDocumentReader.html(of: url, includesPages: true)) {
            XCTAssertEqual($0 as? TextutilConverter.Failure, .unreadable(.odt))
        }
    }

    // MARK: - Missing Parts

    /// Parts that may be absent are absent: the document reads without
    /// styles and without metadata; one without content is refused.
    func testMissingPartsAreHandled() throws {
        let content = odfContent(body: "<text:h text:outline-level=\"1\">Title</text:h><text:p>Words</text:p>")
        let bare = try makeODT(entries: [TestZIPEntry("content.xml", Data(content.utf8))])
        let html = try XCTUnwrap(read(bare, "no mimetype, styles, or metadata"))
        XCTAssertTrue(html.contains("<h1>Title</h1>"))

        let none = try makeODT(entries: [TestZIPEntry("styles.xml", Data(odfStyles("").utf8))])
        XCTAssertNil(read(none, "no content.xml"))

        let folder = try makeODT(entries: [TestZIPEntry.folder("content.xml/")])
        XCTAssertNil(read(folder, "content.xml is a folder"))
    }

    // MARK: - Nesting

    /// 100,000 nested elements are refused, quickly, without a stack of that
    /// depth.
    func testElementsNestedPastTheCapAreRefused() throws {
        let depth = 100_000
        let body = "<text:p>" + String(repeating: "<text:span>", count: depth) + "words"
            + String(repeating: "</text:span>", count: depth) + "</text:p>"
        let url = try makeODT(body: body)
        XCTAssertNil(read(url, "100,000 spans"))
    }

    /// Nesting well inside the cap is read, with its text.
    func testNestingWithinTheCapIsRead() throws {
        let depth = 100
        let body = "<text:p>" + String(repeating: "<text:span>", count: depth) + "deep words"
            + String(repeating: "</text:span>", count: depth) + "</text:p>"
        let html = try XCTUnwrap(read(makeODT(body: body), "100 spans"))
        XCTAssertEqual(odfPlainText(html), "deep words")
    }

    /// Lists, tables, and sections nested past the cap are refused too.
    func testListsTablesAndSectionsNestedPastTheCapAreRefused() throws {
        let depth = 20_000
        let lists = String(repeating: "<text:list><text:list-item>", count: depth) + "<text:p>words</text:p>"
            + String(repeating: "</text:list-item></text:list>", count: depth)
        XCTAssertNil(read(try makeODT(body: lists), "nested lists"))
        let tables = String(repeating: "<table:table><table:table-row><table:table-cell>", count: depth) + "<text:p>words</text:p>"
            + String(repeating: "</table:table-cell></table:table-row></table:table>", count: depth)
        XCTAssertNil(read(try makeODT(body: tables), "nested tables"))
        let sections = String(repeating: "<text:section>", count: depth) + "<text:p>words</text:p>"
            + String(repeating: "</text:section>", count: depth)
        XCTAssertNil(read(try makeODT(body: sections), "nested sections"))
    }

    /// A deep nest inside a hidden section is skipped but still counted, so
    /// it is refused as well.
    func testNestingInsideSkippedMarkupIsRefused() throws {
        let depth = 50_000
        let body = "<text:tracked-changes>" + String(repeating: "<a>", count: depth) + String(repeating: "</a>", count: depth)
            + "</text:tracked-changes><text:p>words</text:p>"
        XCTAssertNil(read(try makeODT(body: body), "nesting in tracked changes"))
    }

    // MARK: - Repetition

    /// A million cells, columns, and rows asked for in one attribute each
    /// cost nothing: the repeated cell is read 16 times (the most a cell is
    /// repeated), a repeated column and row once, and the covered cells not
    /// at all; `read` holds the time to seconds.
    func testRepeatedCellsColumnsAndRowsCostNothing() throws {
        let body = """
            <table:table><table:table-column table:number-columns-repeated="1000000"/>\
            <table:table-row table:number-rows-repeated="1000000000">\
            <table:table-cell table:number-columns-repeated="1000000"><text:p>cell</text:p></table:table-cell>\
            <table:covered-table-cell table:number-columns-repeated="999999999"/></table:table-row></table:table>
            """
        let html = try XCTUnwrap(read(makeODT(body: body), "repeated cells"))
        XCTAssertEqual(odfBodyLines(html).filter { $0.hasPrefix("<tr>") }.count, 1)
        XCTAssertEqual(odfPlainText(html), Array(repeating: "cell", count: 16).joined(separator: " "))
        XCTAssertEqual(odfBodyLines(html).joined().components(separatedBy: "<td>").count - 1, 16)
    }

    /// A count of a billion spaces in one `text:s` is held to a handful, and
    /// a file whose spaces and text come to more than the byte limit is
    /// refused.
    func testSpacesAreBoundedAndTextPastTheLimitIsRefused() throws {
        let spaces = try XCTUnwrap(read(makeODT(body: "<text:p>a<text:s text:c=\"999999999999\"/>b</text:p>"), "huge text:s"))
        XCTAssertLessThan(spaces.utf8.count, 4_000)

        // Thirty elements of a thousand spaces each, in a part of a few
        // hundred bytes, against a limit of 20,000 bytes of text.
        let body = "<text:p>x" + String(repeating: "<text:s text:c=\"1000\"/>y", count: 30) + "</text:p>"
        let url = try makeODT(body: body)
        try DocumentByteLimit.$current.withValue(20_000) {
            XCTAssertThrowsError(try ODTDocumentReader.html(of: url, includesPages: true)) {
                XCTAssertEqual($0 as? DocumentTooLargeError, DocumentTooLargeError(limit: 20_000))
            }
        }
    }

    // MARK: - Loops

    /// A style that is its own ancestor, a pair that name each other, and a
    /// list style that names itself all read.
    func testStyleCyclesEndAndTheDocumentIsRead() throws {
        let styles = """
            <style:style style:name="A" style:family="paragraph" style:parent-style-name="B"/>\
            <style:style style:name="B" style:family="paragraph" style:parent-style-name="A"/>\
            <style:style style:name="C" style:family="paragraph" style:parent-style-name="C" style:list-style-name="C"/>\
            <text:list-style style:name="C"><text:list-level-style-number text:level="1" style:num-format="1"/></text:list-style>
            """
        let body = """
            <text:p text:style-name="A">one</text:p><text:p text:style-name="B">two</text:p>\
            <text:list text:style-name="C"><text:list-item><text:p text:style-name="C">three</text:p></text:list-item></text:list>
            """
        let html = try XCTUnwrap(read(makeODT(body: body, automaticStyles: styles), "style cycles"))
        XCTAssertEqual(odfPlainText(html), "one two three")
    }

    /// A chain of 100 styles, each based on the next, is followed only 64
    /// styles far: the bold at its tenth is read, the italic at its
    /// eightieth is not. More than 100,000 styles are refused.
    func testVeryLongStyleChainsAreCutAndVeryManyStylesAreRefused() throws {
        var chain = ""
        for index in 0..<100 {
            let properties = index == 10 ? "<style:text-properties fo:font-weight=\"bold\"/>"
                : index == 80 ? "<style:text-properties fo:font-style=\"italic\"/>" : ""
            chain += "<style:style style:name=\"S\(index)\" style:family=\"paragraph\" style:parent-style-name=\"S\(index + 1)\">\(properties)</style:style>"
        }
        let html = try XCTUnwrap(read(makeODT(body: "<text:p text:style-name=\"S0\">words</text:p>", automaticStyles: chain), "long chain"))
        // The read has pages, so the first words follow the span of page 1.
        let page1 = "<span role=\"\(TextutilPageBreaks.pageBreakRole)\" aria-label=\"1\"></span>"
        XCTAssertEqual(odfBodyLines(html), [page1 + "<p><strong>words</strong></p>"])

        // One more than the most styles a document may define: the edge, and
        // the last style in the part, so that nothing follows it to count it.
        var many = ""
        for index in 0...ODTStyleSheet.maximumStyles {
            many += "<style:style style:name=\"M\(index)\" style:family=\"text\"/>"
        }
        // A hundred thousand elements of styles take longer than a hostile
        // read of one thing: they are what is being refused.
        XCTAssertNil(read(try makeODT(body: "<text:p>words</text:p>", automaticStyles: many), "too many styles", within: 15))
    }

    // MARK: - Markup the Reader Refuses

    /// A document type declaration, which could declare entities that expand
    /// into gigabytes, is refused.
    func testADocumentTypeDeclarationIsRefused() throws {
        let laughs = """
            <?xml version="1.0"?><!DOCTYPE lolz [<!ENTITY lol "lol">\
            <!ENTITY lol2 "&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;">\
            <!ENTITY lol3 "&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;">]>\
            <office:document-content \(Self.odfNamespaces)><office:body><office:text><text:p>&lol3;</text:p></office:text></office:body>\
            </office:document-content>
            """
        XCTAssertNil(read(try makeODT(content: laughs), "entity expansion"))
    }

    /// An entity the document does not declare, which is how a reference to
    /// an external one looks without a declaration, is a damaged document.
    func testAnUndeclaredEntityIsADamagedDocument() throws {
        let content = """
            <?xml version="1.0"?><office:document-content \(Self.odfNamespaces)><office:body><office:text>\
            <text:p>before &external; after</text:p></office:text></office:body></office:document-content>
            """
        XCTAssertNil(read(try makeODT(content: content), "undeclared entity"))
    }

    // MARK: - Sizes

    /// A part that inflates past the byte limit is refused before it is
    /// read whole, and a part that lies about its size is refused.
    func testAPartPastTheLimitIsRefused() throws {
        let big = odfContent(body: "<text:p>" + String(repeating: "word ", count: 200_000) + "</text:p>")
        let url = try makeODT(content: big, compression: .deflate)
        try DocumentByteLimit.$current.withValue(100_000) {
            XCTAssertThrowsError(try ODTDocumentReader.html(of: url, includesPages: true)) {
                XCTAssertEqual($0 as? DocumentTooLargeError, DocumentTooLargeError(limit: 100_000))
            }
        }
        // The archive itself is held to the limit as well.
        try DocumentByteLimit.$current.withValue(500) {
            XCTAssertThrowsError(try ODTDocumentReader.html(of: url, includesPages: true)) {
                XCTAssertEqual($0 as? DocumentTooLargeError, DocumentTooLargeError(limit: 500))
            }
        }
    }

    /// An archive that records a size smaller than the part holds is refused
    /// when the part passes it.
    func testAPartThatHoldsMoreThanTheArchiveRecordsIsRefused() throws {
        let content = odfContent(body: "<text:p>" + String(repeating: "word ", count: 5_000) + "</text:p>")
        let url = try makeODT(content: content, compression: .deflate)
        try setRecordedSize(of: "content.xml", in: url, to: 100)
        XCTAssertNil(read(url, "a part larger than recorded"))
    }

    // MARK: - Damage

    /// A part with a wrong checksum is refused.
    func testAWrongChecksumIsRefused() throws {
        let url = try makeODT(content: odfContent(body: "<text:p>words</text:p>"), compression: .deflate)
        try setRecordedChecksum(of: "content.xml", in: url, to: 12345)
        XCTAssertNil(read(url, "a wrong checksum"))
    }

    /// Bytes flipped in the markup of a sample (and in the package around
    /// it) give a document or a clean error, every time, with a fixed seed.
    func testFlippedBytesNeverTrap() throws {
        for (sample, seed) in [("odt/handwritten.odt", UInt64(20_261_105)), ("odt/libreoffice-tdf156905.odt", UInt64(7))] {
            let url = try copyOfFormatSample(sample)
            var generator = SeededGenerator(state: seed)
            // The markup, flipped before it is packaged.
            let archive = try Archive(url: url, accessMode: .read)
            let contentEntry = try XCTUnwrap(archive["content.xml"])
            var markup = Data()
            _ = try archive.extract(contentEntry) { markup.append($0) }
            for round in 0..<60 {
                var damaged = markup
                for _ in 0..<(1 + round % 8) {
                    damaged[Int.random(in: 0..<damaged.count, using: &generator)] = UInt8.random(in: 0...255, using: &generator)
                }
                let package = try makeODT(entries: [
                    TestZIPEntry("mimetype", Data("application/vnd.oasis.opendocument.text".utf8)),
                    TestZIPEntry("content.xml", damaged),
                ])
                read(package, "\(sample) markup round \(round)")
            }
            // The package itself, flipped.
            let whole = try Data(contentsOf: url)
            let folder = try makeSandboxDirectory("ODTFlipped")
            for round in 0..<60 {
                var damaged = whole
                for _ in 0..<(1 + round % 8) {
                    damaged[Int.random(in: 0..<damaged.count, using: &generator)] = UInt8.random(in: 0...255, using: &generator)
                }
                let flipped = folder.appendingPathComponent("flipped-\(round).odt")
                try damaged.write(to: flipped)
                read(flipped, "\(sample) package round \(round)")
            }
        }
    }
}
