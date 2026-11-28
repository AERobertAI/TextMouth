import XCTest
@testable import TextMouth

/// Kindle (MOBI) books built to hurt a reader (FMT42): cut short at every
/// length, with every offset, count, and length pointed past the end or set
/// to its largest, record tables that run backward, markup nested without
/// end, an LZ77 phrase that reaches before its record, an index that points
/// outside the file, and a seeded storm of flipped bytes in the real samples.
/// Each must end in a typed error, or in a book that reads, in well under a
/// second, and never in a trap: a book's file is untrusted input, and
/// October 14's Ogg decoder is the reason TextMouth is strict.
final class MOBIHostileFileTests: XCTestCase {

    // MARK: - Helpers

    /// The longest a read of any one hostile file may take. Far above what
    /// the reader needs (milliseconds), because the hosted tests share the
    /// Mac with the build train.
    private let timeLimit: TimeInterval = TestMachine.allowed(1.5)

    /// Reads `bytes` as a book and returns what it threw, or nil when it
    /// read; fails when it took longer than `timeLimit`.
    @discardableResult
    private func read(
        _ bytes: [UInt8], _ what: String, file: StaticString = #filePath, line: UInt = #line
    ) -> Error? {
        let start = Date()
        var failure: Error?
        do { _ = try MOBIBook(bytes: bytes) } catch { failure = error }
        XCTAssertLessThan(Date().timeIntervalSince(start), timeLimit, what, file: file, line: line)
        return failure
    }

    /// Fails unless reading `bytes` throws an error a person can be told:
    /// ours, the size limit's, or the no-text refusal.
    private func assertRefused(
        _ bytes: [UInt8], _ what: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let error = read(bytes, what, file: file, line: line) else {
            return XCTFail("\(what): the book read, and should have been refused", file: file, line: line)
        }
        XCTAssertTrue(
            error is MOBIError || error is DocumentTooLargeError || error is FileImportError,
            "\(what): \(error)", file: file, line: line)
        XCTAssertFalse((error.localizedDescription).isEmpty, what, file: file, line: line)
    }

    /// A book of ten text records and a PalmDOC compression, with no contents.
    private func plainBook() -> MOBIFixture {
        var fixture = MOBIFixture()
        fixture.html = "<html><body>" + (0..<40).map { "<p>Crossing \($0) leaves the Tallow Quay at seven.</p>" }.joined()
            + "</body></html>"
        fixture.compression = 2
        fixture.recordSize = 200
        return fixture
    }

    /// A book with a contents of three entries, two levels deep.
    private func contentsBook() throws -> MOBIFixture {
        var fixture = MOBIFixture()
        fixture.html = "<html><body><p>Alpha words here.</p><p>Beta words here.</p><p>Gamma words here.</p></body></html>"
        fixture.recordSize = 60
        /// The byte offset in the book's HTML of the paragraph that begins with `needle`.
        func offset(of needle: String) throws -> Int {
            let range = try XCTUnwrap(fixture.html.range(of: needle), needle)
            return fixture.html.utf8.distance(from: fixture.html.startIndex, to: range.lowerBound)
        }
        fixture.entries = [
            .init(label: "Alpha", offset: try offset(of: "<p>Alpha"), depth: 0),
            .init(label: "Beta", offset: try offset(of: "<p>Beta"), depth: 1),
            .init(label: "Gamma", offset: try offset(of: "<p>Gamma"), depth: 0),
        ]
        return fixture
    }

    /// `bytes` with the 32-bit number at `offset` set to `value`.
    private func patching32(_ bytes: [UInt8], at offset: Int, to value: Int) -> [UInt8] {
        var copy = bytes
        MOBIFixture.put32(&copy, offset, value)
        return copy
    }

    /// `bytes` with the 16-bit number at `offset` set to `value`.
    private func patching16(_ bytes: [UInt8], at offset: Int, to value: Int) -> [UInt8] {
        var copy = bytes
        MOBIFixture.put16(&copy, offset, value)
        return copy
    }

    /// The big-endian 32-bit number at `offset` of `bytes`.
    private func number32(_ bytes: [UInt8], at offset: Int) -> Int {
        (0..<4).reduce(0) { $0 << 8 | Int(bytes[offset + $1]) }
    }

    // MARK: - Cut short

    func testABookCutAtAnyLengthIsRefused() {
        for fixture in [plainBook(), { var one = plainBook(); one.compression = 1; return one }()] {
            let bytes = fixture.data()
            XCTAssertNil(read(bytes, "the whole book"))
            for length in 0..<bytes.count {
                assertRefused(Array(bytes[0..<length]), "cut at \(length) of \(bytes.count), compression \(fixture.compression)")
            }
        }
    }

    func testABookWithAContentsCutAtAnyLengthNeverTraps() throws {
        let book = try contentsBook()
        let bytes = book.data()
        let firstContentsRecord = MOBIFixture.recordOffsets(of: bytes)[1 + book.textRecords().count]
        for length in 0..<bytes.count {
            let cut = Array(bytes[0..<length])
            // Cut inside the text or before it, the book is refused; cut in
            // the contents, it reads or is refused, as long as it ends.
            if length < firstContentsRecord {
                assertRefused(cut, "cut at \(length) of \(bytes.count)")
            } else {
                read(cut, "cut at \(length) of \(bytes.count)")
            }
        }
    }

    func testARealBookCutShortIsRefusedWhereItsTextIsCut() throws {
        let bytes = [UInt8](try Data(contentsOf: formatSampleURL("mobi/pg1952-yellow-wallpaper.mobi")))
        let offsets = MOBIFixture.recordOffsets(of: bytes)
        // Record 17 is the last text record; record 18 on is not text.
        let endOfText = offsets[18]
        // Every seventh length in the headers, then every 997th, and the lengths around the end of the text.
        var lengths = Set<Int>(stride(from: 0, to: 400, by: 7))
        lengths.formUnion(stride(from: 400, to: bytes.count, by: 997))
        lengths.formUnion([endOfText - 1, endOfText, endOfText + 1])
        for length in lengths.sorted() {
            let cut = Array(bytes[0..<length])
            if length < endOfText {
                assertRefused(cut, "the sample cut at \(length)")
            } else {
                read(cut, "the sample cut at \(length)")
            }
        }
    }

    // MARK: - Fields pointed past the end

    func testEveryRecordOffsetPointedPastTheEndOrBackwardIsRefused() {
        let bytes = plainBook().data()
        let count = Int(bytes[76]) << 8 | Int(bytes[77])
        for record in 0..<count {
            let entry = 78 + record * 8
            for value in [bytes.count + 1, 0xFFFF_FFFF, 0, 77, 78 + count * 8 - 1] {
                assertRefused(patching32(bytes, at: entry, to: value), "record \(record)'s offset set to \(value)")
            }
        }
    }

    func testRecordsOutOfOrderAreRefused() {
        let bytes = plainBook().data()
        let count = Int(bytes[76]) << 8 | Int(bytes[77])
        // Two records swapped: a table that runs backward, which would make
        // a record that ends before it begins. Every pair is tried.
        for first in 1..<(count - 1) {
            for second in (first + 1)..<count {
                var swapped = bytes
                let firstEntry = 78 + first * 8
                let secondEntry = 78 + second * 8
                swapped.replaceSubrange(firstEntry..<firstEntry + 4, with: Array(bytes[secondEntry..<secondEntry + 4]))
                swapped.replaceSubrange(secondEntry..<secondEntry + 4, with: Array(bytes[firstEntry..<firstEntry + 4]))
                assertRefused(swapped, "records \(first) and \(second) swapped")
            }
        }
    }

    func testTheRecordCountPastTheTableOrAtItsLargestIsRefused() {
        let bytes = plainBook().data()
        let count = Int(bytes[76]) << 8 | Int(bytes[77])
        for value in [0, count + 1, count + 1000, 0xFFFF] {
            assertRefused(patching16(bytes, at: 76, to: value), "the record count set to \(value)")
        }
    }

    func testTheTextRecordCountAndLengthAtTheirLargestAreRefused() {
        let bytes = plainBook().data()
        let record0 = MOBIFixture.recordOffsets(of: bytes)[0]
        let count = Int(bytes[76]) << 8 | Int(bytes[77])
        // 65535 text records in a file of ten.
        for value in [0, count, 0xFFFF] {
            assertRefused(patching16(bytes, at: record0 + 8, to: value), "the text record count set to \(value)")
        }
        let declared = number32(bytes, at: record0 + 4)
        for value in [0, declared + 1, declared + 100_000, 63_999_999, 0xFFFF_FFFF] {
            assertRefused(patching32(bytes, at: record0 + 4, to: value), "the text length set to \(value)")
        }
        // A text length that is too large is refused for its size.
        XCTAssertTrue(read(patching32(bytes, at: record0 + 4, to: 0xFFFF_FFFF), "huge") is DocumentTooLargeError)
    }

    func testEveryFieldOfTheMOBIHeaderPointedPastTheEndIsRefusedOrReadsWithoutHarm() {
        let bytes = plainBook().data()
        let record0 = MOBIFixture.recordOffsets(of: bytes)[0]
        let record0Length = MOBIFixture.recordOffsets(of: bytes)[1] - record0
        // The header's length: none, too small, past its record, the largest.
        for value in [0, 4, 7, record0Length, record0Length + 1, 0xFFFF_FFFF] {
            assertRefused(patching32(bytes, at: record0 + 20, to: value), "the header length set to \(value)")
        }
        // The full name's offset and length and the index record, wild: these
        // name things a reader can do without, so they may read or be refused.
        for field in [84, 88, 108, 112, 116, 168, 240, 244] {
            for value in [0, 0xFFFF_FFFF, record0Length + 1, 0x7FFF_FFFF] {
                read(patching32(bytes, at: record0 + field, to: value), "header field at \(field) set to \(value)")
            }
        }
    }

    func testTheEXTHHeaderPointedPastTheEndIsRefused() {
        let bytes = plainBook().data()
        let record0 = MOBIFixture.recordOffsets(of: bytes)[0]
        let exth = record0 + 16 + MOBIFixture.mobiHeaderLength
        XCTAssertEqual(String(decoding: bytes[exth..<exth + 4], as: UTF8.self), "EXTH")
        var noMagic = bytes
        noMagic[exth] = UInt8(ascii: "X")
        assertRefused(noMagic, "the EXTH magic damaged")
        for value in [0, 4, 11, 0xFFFF, 0xFFFF_FFFF] {
            assertRefused(patching32(bytes, at: exth + 4, to: value), "the EXTH length set to \(value)")
        }
        for value in [10_001, 1_000_000, 0xFFFF_FFFF] {
            assertRefused(patching32(bytes, at: exth + 8, to: value), "the EXTH count set to \(value)")
        }
        // The first record's length: too small to hold its own header, and past the end.
        for value in [0, 7, 0xFFFF, 0xFFFF_FFFF] {
            assertRefused(patching32(bytes, at: exth + 12 + 4, to: value), "the first EXTH record's length set to \(value)")
        }
    }

    // MARK: - The contents

    /// The record number of the contents' first INDX record in `bytes`.
    private func indexRecord(of bytes: [UInt8]) -> Int {
        number32(bytes, at: MOBIFixture.recordOffsets(of: bytes)[0] + 244)
    }

    func testAContentsRecordPointedOutsideTheFileIsRefused() throws {
        let bytes = try contentsBook().data()
        let record0 = MOBIFixture.recordOffsets(of: bytes)[0]
        let count = Int(bytes[76]) << 8 | Int(bytes[77])
        // The index's first record: out of the file, at the end, and a record that is not INDX.
        for value in [count, count + 1, 5000, 0xFFFF_FFFE, 0, 1] {
            assertRefused(patching32(bytes, at: record0 + 244, to: value), "the index record set to \(value)")
        }
    }

    func testEveryFieldOfTheContentsPointedPastTheEndIsRefused() throws {
        let bytes = try contentsBook().data()
        let offsets = MOBIFixture.recordOffsets(of: bytes)
        let primary = offsets[indexRecord(of: bytes)]
        let data = offsets[indexRecord(of: bytes) + 1]
        let dataLength = offsets[indexRecord(of: bytes) + 2] - data
        let cases: [(String, Int, [Int])] = [
            ("the primary header's length", primary + 4, [0, 8, 4000, 0xFFFF_FFFF]),
            ("the number of data records", primary + 24, [2, 60_000, 0xFFFF_FFFF]),
            ("the number of string records", primary + 52, [33, 1000, 0xFFFF_FFFF]),
            ("the tag table's length", primary + 192 + 4, [0, 11, 4000, 0xFFFF_FFFF]),
            ("the entry table's offset", data + 20, [0, dataLength, dataLength + 1, 0xFFFF_FFFF]),
            ("the entry count", data + 24, [100_000, 0x7FFF_FFFF, 0xFFFF_FFFF]),
        ]
        for (name, at, values) in cases {
            for value in values {
                assertRefused(patching32(bytes, at: at, to: value), "\(name) set to \(value)")
            }
        }
        // An entry's offset (16 bits) past its record, and an entry name that is longer than its record.
        let tableOffset = number32(bytes, at: data + 20)
        for value in [dataLength, 0xFFFF] {
            assertRefused(patching16(bytes, at: data + tableOffset + 4, to: value), "an entry's offset set to \(value)")
        }
        // An entry name whose length byte says 255: the entry runs off its record.
        let firstEntry = Int(bytes[data + tableOffset + 4]) << 8 | Int(bytes[data + tableOffset + 5])
        var longName = bytes
        longName[data + firstEntry] = 0xFF
        assertRefused(longName, "an entry name of 255 bytes")
    }

    func testAnEntryNamingAPlacePastTheTextIsPassedOver() throws {
        var fixture = try contentsBook()
        fixture.entries[2].offset = 0x0FFF_FFFF
        XCTAssertNil(read(fixture.data(), "an entry past the end"))
    }

    // MARK: - The compressed text

    func testAnLZ77PhraseThatReachesBeforeItsRecordIsRefused() {
        let bytes = plainBook().data()
        let first = MOBIFixture.recordOffsets(of: bytes)[1]
        // Distance 1, length 3, as the record's first code.
        var damaged = bytes
        damaged[first] = 0x80
        damaged[first + 1] = 0x08
        assertRefused(damaged, "a phrase before the start of the first record")
    }

    // MARK: - HUFF/CDIC

    /// A book in the small Huffman code, and the records the tables are in.
    private func huffmanBook() -> (bytes: [UInt8], huff: Int, cdic: Int) {
        var fixture = MOBIFixture()
        fixture.html = "<html><body>" + (0..<30).map { "<p>Crossing \($0): Aa Bb hello Zz.</p>" }.joined() + "</body></html>"
        fixture.compression = 17480
        fixture.recordSize = 300
        let bytes = fixture.data()
        let offsets = MOBIFixture.recordOffsets(of: bytes)
        let huff = 1 + fixture.textRecords().count
        return (bytes, offsets[huff], offsets[huff + 1])
    }

    func testAHuffmanBookReadsAndItsCodedEntryThatNamesItselfIsRefused() throws {
        let (bytes, _, cdic) = huffmanBook()
        XCTAssertNil(read(bytes, "the Huffman book"))
        // "hello" is in the file once: the coded entry's bytes. Make them a
        // codeword for the entry itself (12 bits, 0xF00), then zeros.
        let hello = Array("hello".utf8)
        let places = (cdic..<bytes.count - 4).filter { Array(bytes[$0..<$0 + 5]) == hello }
        XCTAssertEqual(places.count, 1)
        var cyclic = bytes
        cyclic.replaceSubrange(places[0]..<places[0] + 5, with: [0xF0, 0x00, 0x00, 0x00, 0x00])
        assertRefused(cyclic, "an entry coded as itself")
    }

    func testEveryFieldOfTheHuffmanTablesPointedWrongIsRefused() {
        let (bytes, huff, cdic) = huffmanBook()
        let record0 = MOBIFixture.recordOffsets(of: bytes)[0]
        let count = Int(bytes[76]) << 8 | Int(bytes[77])
        // The record the tables begin at, and how many records they fill.
        for value in [0, 1, count - 1, count, 0xFFFF_FFFF] {
            assertRefused(patching32(bytes, at: record0 + 112, to: value), "the tables' record set to \(value)")
        }
        for value in [0, 1, 3, 257, 0xFFFF_FFFF] {
            assertRefused(patching32(bytes, at: record0 + 116, to: value), "the tables' record count set to \(value)")
        }
        let cases: [(String, Int, [Int])] = [
            ("the first table's offset", huff + 8, [0, 0xFFFF, 0xFFFF_FFFF]),
            ("the second table's offset", huff + 12, [0xFFFF, 0xFFFF_FFFF]),
            ("the dictionary's header length", cdic + 4, [0xFFFF, 0xFFFF_FFFF]),
            ("the dictionary's entry count", cdic + 8, [0x20_0000, 0xFFFF_FFFF]),
            ("the dictionary's code length", cdic + 12, [17, 0xFFFF_FFFF]),
        ]
        for (name, at, values) in cases {
            for value in values {
                assertRefused(patching32(bytes, at: at, to: value), "\(name) set to \(value)")
            }
        }
        // A codeword with no length: the first byte settles the code, and its length is 0.
        assertRefused(patching32(bytes, at: huff + 24 + 4 * 0x41, to: 0x0000_EF80), "a codeword of length 0")
        // The magic words.
        for (name, at) in [("HUFF", huff), ("CDIC", cdic)] {
            var damaged = bytes
            damaged[at] = UInt8(ascii: "X")
            assertRefused(damaged, "\(name) damaged")
        }
    }

    func testFlippedBytesInAHuffmanBookNeverTrapOrHang() {
        var generator = SeededGenerator(state: 17_480)
        let (bytes, _, _) = huffmanBook()
        for round in 0..<600 {
            read(flipped(bytes, flips: 1 + round % 5, using: &generator), "Huffman book, round \(round)")
        }
    }

    // MARK: - The markup

    /// What importing a book's file came to: the chapters it read (and the
    /// words of the first), or the guard's refusal, or any other error.
    private enum ImportOutcome: Sendable, Equatable {
        case read(chapters: Int, firstChapterText: String)
        case refused(MarkupRefusal)
        case failed(String)
    }

    /// Imports the book at `url` as the library does, on the stack an import has:
    /// `MOBIParser.prepareBook(url:)`, which cuts the book into HTML sections
    /// and hands each through `MarkupGuard` to the converter. It is here, not
    /// in `MOBIBook(bytes:)`, that the markup's nesting is judged. Returns the
    /// outcome and how long the import took, or nil when it did not end.
    private func imported(_ url: URL) -> (outcome: ImportOutcome, seconds: TimeInterval)? {
        onWorkerSizedStack(timeout: 30) {
            let start = Date()
            let outcome: ImportOutcome
            do {
                let book = try MOBIParser.prepareBook(url: url)
                outcome = .read(chapters: book.chapters.count, firstChapterText: book.chapters.first?.chapter.text ?? "")
            } catch let refusal as MarkupRefusal {
                outcome = .refused(refusal)
            } catch {
                outcome = .failed("\(error)")
            }
            return (outcome, Date().timeIntervalSince(start))
        }
    }

    /// `count` start tags `open` with no end tag (100,000 unless said), read through the whole import.
    ///
    /// The nesting limit lives in `MarkupGuard`, which runs when a section's
    /// HTML is converted, so a test that only opens the book (`MOBIBook(bytes:)`)
    /// sees no refusal. What the import should do with the markup is read from
    /// the guard's own count of the tree the parser will make (never less than
    /// the real tree), not guessed:
    /// - When the count passes the limit (128), the guard refuses the book with
    ///   `MarkupRefusal.nestedTooDeeply` before the parse, so no tree is built.
    /// - When it does not, the book reads, and the tree is no deeper than the
    ///   count. This test imports such a book only when the count is 40 or
    ///   fewer, since the test host's debug converter overflows its stack at
    ///   about 108 levels.
    ///
    /// `nests` is what the HTML rules make of `open` with no end tag, and the
    /// count must agree with it, so a change to the guard or to this test is noticed.
    private func assertImport(
        of open: String, count: Int = 100_000, nests: Bool, timeLimit: TimeInterval? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let timeLimit = timeLimit ?? self.timeLimit
        var fixture = MOBIFixture()
        fixture.html = "<html><body>" + String(repeating: open, count: count) + "words</body></html>"
        let limits = MarkupGuard.Limits.standard
        // The guard's count under the standard limits: it stops at the first
        // level past the limit (so it never counts 100,000 levels, which would
        // take it minutes) and builds no tree.
        var deepest = 0
        var countedPastTheLimit = false
        do {
            deepest = try MarkupGuard.inspect(Array(fixture.html.utf8), as: .html, limits: limits).deepest
        } catch MarkupRefusal.nestedTooDeeply {
            countedPastTheLimit = true
        }
        XCTAssertEqual(countedPastTheLimit, nests, "\(count.formatted()) \(open): the guard counts \(countedPastTheLimit ? "past the limit" : "\(deepest) levels")", file: file, line: line)
        // Never import a document the count calls neither refused nor shallow.
        guard countedPastTheLimit || deepest <= 40 else { return XCTFail("\(count.formatted()) \(open): counted \(deepest) levels", file: file, line: line) }

        let url = try writeMOBI(fixture.data())
        guard let (outcome, seconds) = imported(url) else { return }
        XCTAssertLessThan(seconds, timeLimit, "\(count.formatted()) \(open)", file: file, line: line)
        if countedPastTheLimit {
            XCTAssertEqual(outcome, .refused(.nestedTooDeeply(limit: limits.deepestNesting)), "\(count.formatted()) \(open)", file: file, line: line)
        } else {
            guard case let .read(chapters, text) = outcome else {
                return XCTFail("\(count.formatted()) \(open): \(outcome)", file: file, line: line)
            }
            XCTAssertEqual(chapters, 1, "\(count.formatted()) \(open)", file: file, line: line)
            XCTAssertTrue(text.contains("words"), "\(count.formatted()) \(open): \(text.prefix(80))", file: file, line: line)
        }
    }

    /// These tags nest in HTML with no end tag, so the book is refused for it,
    /// when its markup is converted.
    func testMarkupNestedWithoutEndIsRefusedQuickly() throws {
        for open in ["<div>", "<b>", "<span>", "<blockquote>", "<font size=1>"] {
            try assertImport(of: open, nests: true)
        }
    }

    /// A `table` start tag inside a table that has no cell closes the open
    /// table before it opens its own (HTML's "in table" rule), so 20,000 of
    /// them make a flat row of tables, not a deep tree (the guard counts 3
    /// levels): the book reads. Reading builds the tree, which a debug build
    /// takes over a second to do for 100,000, so this one has fewer tables and
    /// a longer limit than the refusals, which build nothing.
    func testTablesWithoutEndTagsDoNotNestAndTheBookReads() throws {
        try assertImport(of: "<table>", count: 20_000, nests: false, timeLimit: 15)
    }

    func testAMillionBytesOfAngleBracketsAndQuotesTakesOneSecondAtMost() {
        let pieces = ["<", "<<<<", "<a title=\"", "'", ">>>>", "<!--", "<a filepos=", "<mbp:", "</", "<a filepos=99999999999999"]
        var generator = SeededGenerator(state: 7)
        var html = "<html><body>"
        while html.utf8.count < 1_000_000 { html += pieces[Int(generator.next() % UInt64(pieces.count))] }
        var fixture = MOBIFixture()
        fixture.html = html
        // It may read or be refused; it must end.
        read(fixture.data(), "a million bytes of broken tags")
    }

    func testAHundredThousandFileposLinksReadQuicklyAndEachGetsItsDestination() throws {
        var fixture = MOBIFixture()
        fixture.html = "<html><body>" + (0..<100_000).map { "<a filepos=\($0 * 9 % 1_000_000)>x</a>" }.joined() + "</body></html>"
        let start = Date()
        let book = try MOBIBook(bytes: fixture.data())
        XCTAssertLessThan(Date().timeIntervalSince(start), timeLimit)
        XCTAssertEqual(book.sections.count, 1)
        XCTAssertTrue(book.sections[0].html.contains("<a id=\"filepos-"))
    }

    // MARK: - A storm of flipped bytes

    /// `bytes` with `flips` bytes at random places changed to random values.
    private func flipped(_ bytes: [UInt8], flips: Int, using generator: inout SeededGenerator) -> [UInt8] {
        var copy = bytes
        for _ in 0..<flips {
            copy[Int(generator.next() % UInt64(copy.count))] = UInt8(truncatingIfNeeded: generator.next())
        }
        return copy
    }

    func testFlippedBytesInTheRealSamplesNeverTrapOrHang() throws {
        var generator = SeededGenerator(state: 20_261_104)
        for sample in ["mobi/pg1952-yellow-wallpaper.mobi", "mobi/ferry-notes-ncx.mobi"] {
            let bytes = [UInt8](try Data(contentsOf: formatSampleURL(sample)))
            for round in 0..<300 {
                read(flipped(bytes, flips: 1 + round % 8, using: &generator), "\(sample), round \(round)")
            }
        }
    }

    func testFlippedBytesInTheHeadersAndTheContentsOfABuiltBookNeverTrapOrHang() throws {
        var generator = SeededGenerator(state: 1104)
        let bytes = try contentsBook().data()
        for round in 0..<1000 {
            read(flipped(bytes, flips: 1 + round % 4, using: &generator), "built book, round \(round)")
        }
    }

    func testFlippedBytesReachTheConverterWithoutHarm() throws {
        var generator = SeededGenerator(state: 99)
        let bytes = [UInt8](try Data(contentsOf: formatSampleURL("mobi/ferry-notes-ncx.mobi")))
        for round in 0..<40 {
            let url = try writeMOBI(flipped(bytes, flips: 1 + round % 6, using: &generator), named: "flipped\(round).mobi")
            let start = Date()
            // A book that reads must read to chapters; one that does not, to an error.
            if let book = try? MOBIParser.prepareBook(url: url) { XCTAssertFalse(book.chapters.isEmpty) }
            XCTAssertLessThan(Date().timeIntervalSince(start), timeLimit, "round \(round)")
        }
    }
}
