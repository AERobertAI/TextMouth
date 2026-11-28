import XCTest
@testable import TextMouth

/// TextMouth's own RTF reader (FMT47) on files built to hurt it: a book's
/// file is untrusted input, and the reader must end every one of them with
/// an HTML document or a clean error, in well under a second, whatever the
/// file claims about its own size.
final class RTFHostileReaderTests: XCTestCase {

    // MARK: - Helpers

    /// The longest any one hostile read may take. A read takes a fraction of
    /// a second even in a debug build; the margin is for a busy Mac.
    private let allowedSeconds = 2.0

    /// Reads `source` and returns the HTML, or nil when the reader refused it
    /// with an error; fails the test if the read took too long. Reaching the
    /// return at all is the test that nothing trapped.
    @discardableResult
    private func read(_ source: String, _ label: String, file: StaticString = #filePath, line: UInt = #line) -> String? {
        read(bytes: Data(source.utf8), label, file: file, line: line)
    }

    /// `read(_:_:)` for bytes.
    @discardableResult
    private func read(bytes: Data, _ label: String, file: StaticString = #filePath, line: UInt = #line) -> String? {
        let start = Date()
        let html = try? RTFDocumentReader.html(from: bytes, includesPages: true)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, allowedSeconds, "\(label) took \(elapsed) seconds", file: file, line: line)
        return html
    }

    /// A small deterministic random number generator (SplitMix64), so the
    /// byte flips of one run are the byte flips of every run.
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

    /// The bytes of every RTF sample, with a name each.
    private func sampleBytes() throws -> [(name: String, bytes: Data)] {
        let paths = [
            "rtf/headings.rtf", "rtf/page-breaks.rtf", "rtf/word-list-table.rtf", "rtf/word-styles.rtf",
            "rtfd/with-image.rtfd/TXT.rtf"
        ]
        return try paths.map { path in
            (name: path, bytes: try Data(contentsOf: copyOfFormatSample(path)))
        }
    }

    // MARK: - Nesting

    /// 100,000 nested groups are refused with the sentence for a damaged
    /// file, without a stack of that depth.
    func testGroupsNestedPastTheCapAreRefused() throws {
        let source = "{\\rtf1 " + String(repeating: "{", count: 100_000) + "text"
        let start = Date()
        XCTAssertThrowsError(try RTFDocumentReader.html(from: Data(source.utf8), includesPages: true)) { error in
            XCTAssertEqual(error as? TextutilConverter.Failure, .unreadable(.rtf))
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), allowedSeconds)
    }

    /// Nesting just inside the cap is read, with its text.
    func testGroupsNestedWithinTheCapAreRead() throws {
        let depth = RTFInterpreter.deepestNesting - 2
        let source = "{\\rtf1 " + String(repeating: "{\\b ", count: depth - 1) + "deep words" + String(repeating: "}", count: depth)
        let html = try XCTUnwrap(read(source, "nesting within the cap"))
        XCTAssertEqual(try rtfWords(html), ["deep", "words"])
    }

    /// Nested groups in a skipped destination cost nothing to skip.
    func testSkippedDestinationsNestedDeeplyAreSkipped() throws {
        let depth = RTFInterpreter.deepestNesting - 10
        let source = "{\\rtf1 A{\\*\\junk " + String(repeating: "{", count: depth) + "hidden" + String(repeating: "}", count: depth) + "}B\\par}"
        let html = try XCTUnwrap(read(source, "deep skipped destination"))
        // The skipped destination leaves the two letters side by side.
        XCTAssertEqual(try rtfWords(html), ["AB"])
    }

    // MARK: - Lengths and numbers

    /// A \bin longer than the file ends the document where the file ends; a
    /// negative or zero one skips nothing; the binary data is never read as
    /// RTF, even when it looks like RTF.
    func testBinaryDataIsHeldToTheFile() throws {
        let beyond = try XCTUnwrap(read("{\\rtf1 Before\\par\\bin99999999 After", "bin beyond the file"))
        XCTAssertEqual(try rtfWords(beyond), ["Before"])
        let negative = try XCTUnwrap(read("{\\rtf1 A\\bin-5 B\\bin0 C\\par}", "negative bin"))
        // Nothing separates the three letters in the file, so they are one word.
        XCTAssertEqual(try rtfWords(negative), ["ABC"])
        let binary = "{\\b Hidden \\par}"
        let looksLikeRTF = try XCTUnwrap(read("{\\rtf1 A\\bin\(binary.utf8.count) \(binary) B\\par}", "bin that looks like RTF"))
        XCTAssertEqual(try rtfWords(looksLikeRTF), ["A", "B"])
        let atTheEnd = read("{\\rtf1 A\\bin", "bin at the end")
        XCTAssertNotNil(atTheEnd)
    }

    /// Every number a file can set is clamped, not trusted: none overflows,
    /// indexes, or allocates.
    func testNumbersAtTheirLargestAreHarmless() throws {
        let big = "2147483647", huge = "99999999999999999999999999"
        let source = """
            {\\rtf1\\ansi\\ansicpg\(big)\\deff\(big){\\fonttbl{\\f\(big)\\fcharset\(big) A;}{\\f\(huge)\\cpg\(huge) B;}}
            {\\stylesheet{\\s\(big)\\sbasedon\(big)\\outlinelevel\(big) heading 1;}}
            \\pard\\s\(big)\\ls\(big)\\ilvl\(big)\\outlinelevel\(big)\\fs\(big)\\uc\(big)\\f\(big) Words\\u\(big)? here\\par
            \\itap\(big)\\intbl In a table\\cell\\row
            \\pard\\fs-\(big)\\ilvl-\(big)\\uc-5 Negative\\par}
            """
        let html = try XCTUnwrap(read(source, "large numbers"))
        XCTAssertTrue(try rtfWords(html).contains("Words"))
        XCTAssertTrue(try rtfWords(html).contains("Negative"))
    }

    /// A \u of any size is a character or the replacement character.
    func testUnicodeOfAnySizeIsHarmless() throws {
        for number in ["99999999", "-99999999", "65536", "-65537", "0", "-0", "55296", "57343", "-9216", "32768"] {
            let html = read("{\\rtf1 a\\u\(number)?b\\par}", "\\u\(number)")
            XCTAssertNotNil(html, "\\u\(number)")
        }
    }

    // MARK: - Structure

    /// A group that never ends, a document of one brace, and an empty group
    /// are read.
    func testUnterminatedAndTrivialDocuments() throws {
        for source in ["{", "{}", "{\\rtf1", "{\\rtf1 {", "{\\rtf1 {\\fonttbl", "{\\rtf1 {\\stylesheet {\\s1", "{\\rtf1 {\\*", "{\\rtf1 \\", "{\\rtf1 \\'", "{\\rtf1 \\'4"] {
            read(source, source)
        }
        XCTAssertNotNil(read("{\\rtf1 Text with no end", "unterminated"))
    }

    /// An invalid hex escape, wherever it falls, reads as no byte.
    func testInvalidHexEscapes() throws {
        for source in ["{\\rtf1 \\'}", "{\\rtf1 \\'g0 x}", "{\\rtf1 \\'0}", "{\\rtf1 \\' \\' x}", "{\\rtf1 \\'\\'\\'\\' x}"] {
            let html = try XCTUnwrap(read(source, source))
            XCTAssertFalse(html.isEmpty)
        }
    }

    /// A megabyte of control words is read in linear time, and a megabyte of
    /// paragraph, line, and page marks costs a small page, not a large one.
    func testAMegabyteOfControlWords() throws {
        let words = String(repeating: "\\b0\\i\\fs24\\ql\\li0 ", count: 50_000)
        XCTAssertNotNil(read("{\\rtf1 " + words + "Done\\par}", "control words"))
        let breaks = String(repeating: "\\par\\line\\page\\sect\\tab ", count: 50_000)
        XCTAssertNotNil(read("{\\rtf1 " + breaks + "Done\\par}", "breaks"))
        let cells = String(repeating: "\\cell\\row\\nestcell\\nestrow ", count: 50_000)
        XCTAssertNotNil(read("{\\rtf1 " + cells + "Done\\par}", "cells"))
    }

    /// More page breaks than a book has pages are read without pages; the
    /// words stay.
    func testMorePageBreaksThanPagesAreReadWithoutPages() throws {
        let source = "{\\rtf1 " + String(repeating: "x\\page ", count: TextutilPageBreaks.maximumPages + 10) + "end\\par}"
        let html = try XCTUnwrap(read(source, "too many pages"))
        XCTAssertEqual(try rtfPages(html), [])
    }

    /// Cycles: styles based on themselves or each other, list overrides that
    /// name themselves.
    func testCyclesAreCut() throws {
        let source = #"""
            {\rtf1{\stylesheet{\s1\sbasedon2 A;}{\s2\sbasedon3 B;}{\s3\sbasedon1 C;}{\s4\sbasedon4 D;}}
            {\*\listtable{\list\listid1{\listlevel\levelnfc0}}}
            {\*\listoverridetable{\listoverride\listid1\ls1}{\listoverride\listid1\ls1}{\listoverride\listid2\ls2}}
            \pard\s1 One\par\pard\s2 Two\par\pard\s3 Three\par\pard\s4 Four\par
            \pard\ls1\ilvl0 Item\par\pard\ls2 Other\par}
            """#
        let html = try XCTUnwrap(read(source, "cycles"))
        XCTAssertEqual(try rtfWords(html), ["One", "Two", "Three", "Four", "Item", "Other"])
        XCTAssertEqual(try rtfHeadings(html), [])
    }

    // MARK: - Size

    /// Text past the limit in force is refused with the sentence for a
    /// document that is too large, before it fills the Mac's memory.
    func testTextPastTheLimitIsRefused() throws {
        let source = "{\\rtf1 " + String(repeating: "word \\par ", count: 20_000) + "}"
        try DocumentByteLimit.$current.withValue(10_000) {
            XCTAssertThrowsError(try RTFDocumentReader.html(from: Data(source.utf8), includesPages: true)) { error in
                XCTAssertEqual(error as? DocumentTooLargeError, DocumentTooLargeError(limit: 10_000))
            }
        }
    }

    /// Emphasis toggled between single letters makes markup far larger than
    /// the file; the budget stops it.
    func testMarkupBloatIsStopped() throws {
        let source = "{\\rtf1 " + String(repeating: "\\b a\\b0 b", count: 100_000) + "\\par}"
        try DocumentByteLimit.$current.withValue(200_000) {
            XCTAssertThrowsError(try RTFDocumentReader.html(from: Data(source.utf8), includesPages: true)) { error in
                XCTAssertTrue(error is DocumentTooLargeError)
            }
        }
    }

    // MARK: - Samples, cut and flipped

    /// Every sample cut at many lengths is read or refused, never trapped.
    func testSamplesTruncatedAtManyLengths() throws {
        for (name, bytes) in try sampleBytes() {
            // Every length for a small file; a stride for a larger one.
            let stride = max(1, bytes.count / 400)
            for length in Swift.stride(from: 0, through: bytes.count, by: stride) {
                read(bytes: bytes.prefix(length), "\(name) cut at \(length)")
            }
        }
    }

    /// Every sample with random bytes changed (a fixed seed) is read or
    /// refused, never trapped.
    func testSamplesWithRandomByteFlips() throws {
        var generator = SeededGenerator(state: 20_261_104)
        for (name, bytes) in try sampleBytes() {
            for round in 0..<60 {
                var flipped = [UInt8](bytes)
                // From one byte to about one in twenty.
                let flips = 1 + Int(generator.next() % UInt64(max(1, flipped.count / 20)))
                for _ in 0..<flips {
                    let index = Int(generator.next() % UInt64(flipped.count))
                    flipped[index] = UInt8(truncatingIfNeeded: generator.next())
                }
                read(bytes: Data(flipped), "\(name) flipped, round \(round)")
            }
        }
    }

    /// Every sample with a piece of its own text pasted over itself, so
    /// groups and words repeat.
    func testSamplesWithRepeatedPieces() throws {
        var generator = SeededGenerator(state: 99)
        for (name, bytes) in try sampleBytes() {
            for round in 0..<20 {
                var pieces = [UInt8](bytes)
                let start = Int(generator.next() % UInt64(pieces.count))
                let end = min(pieces.count, start + 1 + Int(generator.next() % 200))
                let piece = Array(pieces[start..<end])
                pieces.insert(contentsOf: Array(repeating: piece, count: 50).flatMap { $0 }, at: start)
                read(bytes: Data(pieces), "\(name) repeated, round \(round)")
            }
        }
    }

    /// Bytes that are not RTF at all, of every value, are read or refused.
    func testNoiseIsReadOrRefused() throws {
        var generator = SeededGenerator(state: 7)
        for round in 0..<40 {
            var noise = [UInt8](repeating: 0, count: 5_000)
            for index in noise.indices { noise[index] = UInt8(truncatingIfNeeded: generator.next()) }
            // Some begin as RTF, so the reader meets the noise inside it.
            let head = round.isMultiple(of: 2) ? Array("{\\rtf1".utf8) : []
            read(bytes: Data(head + noise), "noise \(round)")
        }
    }

    // MARK: - Files

    /// The file entry point holds a file to the byte limit and a package to
    /// its TXT.rtf.
    func testTheFileEntryPointHoldsTheByteLimit() throws {
        let folder = try makeSandboxDirectory("RTFLimit")
        let file = folder.appendingPathComponent("big.rtf")
        try Data("{\\rtf1 Some words, more than the limit allows.\\par}".utf8).write(to: file)
        try DocumentByteLimit.$current.withValue(10) {
            XCTAssertThrowsError(try RTFDocumentReader.html(of: file, as: .rtf, includesPages: true)) { error in
                XCTAssertEqual(error as? DocumentTooLargeError, DocumentTooLargeError(limit: 10))
            }
        }
    }

    /// A missing file is refused, not a trap.
    func testAMissingFileThrows() throws {
        let missing = try makeSandboxDirectory("RTFMissing").appendingPathComponent("nothing.rtf")
        XCTAssertThrowsError(try RTFDocumentReader.html(of: missing, as: .rtf, includesPages: true))
    }
}
