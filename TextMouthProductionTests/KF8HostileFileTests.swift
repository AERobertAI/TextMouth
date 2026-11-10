import XCTest
@testable import TextMouth

/// A KF8 book's file is untrusted input. Each test here builds or damages a
/// book so that a table, a count, a place, or a length lies, and requires
/// the reader to refuse it with a typed error (or read it) in well under a
/// second, never to trap or to grow without bound.
final class KF8HostileFileTests: XCTestCase {

    // MARK: - Helpers

    /// The file the import tests write each damaged copy over (one file for the whole test, so a test of
    /// hundreds of copies makes one folder).
    private var importFile: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        importFile = try writeMOBI([], named: "hostile.azw3")
    }

    /// What importing a damaged book came to.
    private enum ImportOutcome: Sendable, Equatable {
        /// The book read, to this many chapters.
        case read(chapters: Int)
        /// The markup guard refused a section's markup, when it was converted.
        case refused(MarkupRefusal)
        /// The book ended in an error a person can be told: ours, the size limit's, or the no-text refusal.
        case rejected
        /// Any other error, which a Kindle book must never throw.
        case failed(String)
    }

    /// Imports `bytes` as the library does: `MOBIParser.prepareBook(url:)` on a file, on the stack an import
    /// has, which cuts the book into sections and hands each through `MarkupGuard` to the converter. It is
    /// here, not in `MOBIBook(bytes:)`, that the markup's nesting is judged. Returns nil, after a failure is
    /// recorded, when the import did not end.
    @discardableResult
    private func importQuickly(
        _ bytes: [UInt8], hybrid: MOBIBook.HybridChoice = .kf8, timeLimit: TimeInterval = 5, _ what: String,
        file: StaticString = #filePath, line: UInt = #line
    ) -> ImportOutcome? {
        do { try Data(bytes).write(to: importFile) } catch {
            XCTFail("\(what): the file was not written: \(error)", file: file, line: line)
            return nil
        }
        let url: URL = importFile
        guard let (outcome, seconds) = onWorkerSizedStack(timeout: 60, {
            let started = Date()
            let outcome: ImportOutcome
            do {
                outcome = .read(chapters: try MOBIParser.prepareBook(url: url, hybrid: hybrid).chapters.count)
            } catch let refusal as MarkupRefusal {
                outcome = .refused(refusal)
            } catch is MOBIError {
                outcome = .rejected
            } catch is DocumentTooLargeError {
                outcome = .rejected
            } catch is FileImportError {
                outcome = .rejected
            } catch {
                outcome = .failed("\(error)")
            }
            return (outcome, Date().timeIntervalSince(started))
        }) else { return nil }
        XCTAssertLessThan(seconds, timeLimit, "\(what) took too long to import", file: file, line: line)
        if case .failed(let message) = outcome {
            XCTFail("\(what) imported with \(message), which is not an error a Kindle book throws", file: file, line: line)
        }
        return outcome
    }

    /// Reads `bytes` as a book and checks that it ended, in under a second, with a book or one of the
    /// errors a Kindle book throws (never a trap). A book that opens is then imported, since the
    /// converter and the markup guard run only there (`andImport` false skips that). Returns the book, or
    /// nil when it threw.
    @discardableResult
    private func readQuickly(
        _ bytes: [UInt8], hybrid: MOBIBook.HybridChoice = .kf8, andImport: Bool = true, _ what: String,
        file: StaticString = #filePath, line: UInt = #line
    ) -> MOBIBook? {
        let started = Date()
        defer { XCTAssertLessThan(Date().timeIntervalSince(started), TestMachine.allowed(1.0), "\(what) took too long", file: file, line: line) }
        let book: MOBIBook
        do {
            book = try MOBIBook(bytes: bytes, hybrid: hybrid)
        } catch is MOBIError {
            return nil
        } catch is DocumentTooLargeError {
            return nil
        } catch is FileImportError {
            return nil
        } catch {
            XCTFail("\(what) threw \(error), which is not an error a Kindle book throws", file: file, line: line)
            return nil
        }
        if andImport { importQuickly(bytes, hybrid: hybrid, what, file: file, line: line) }
        return book
    }

    /// Requires that `bytes` are refused as damaged.
    private func assertDamaged(_ bytes: [UInt8], _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let started = Date()
        XCTAssertThrowsError(try MOBIBook(bytes: bytes), what, file: file, line: line) {
            guard case .damaged? = $0 as? MOBIError else { return XCTFail("\(what): \($0)", file: file, line: line) }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), TestMachine.allowed(1.0), "\(what) took too long", file: file, line: line)
    }

    /// A book of one document of a body of `count` short paragraphs, the last
    /// `cut` of them each cut out as a fragment.
    private func paragraphs(_ count: Int, cut: Int) -> KF8Fixture {
        let texts = (0..<count).map { "<p>Paragraph \($0).</p>" }
        let html = "<html><head><title>T</title></head><body>" + texts.joined() + "</body></html>"
        return KF8Fixture(documents: [KF8Fixture.Document(html: html, cutting: Array(texts.suffix(cut)))])
    }

    // MARK: - Places and lengths

    func testASkeletonOutsideTheTextIsDamaged() {
        let sound = paragraphs(5, cut: 2)
        let laid = sound.placed()
        let size = laid.text.count
        for (offset, length) in [(size, 1), (size - 3, 100), (0, size + 1), (0x0FFF_FFFF, 10), (10, 0x0FFF_FFFF), (0x0FFF_FFFF, 0x0FFF_FFFF)] {
            var fixture = sound
            var rows = fixture.skeletonRows(laid)
            rows[0].values[6] = [offset, length, offset, length]
            fixture.skeletonRowsOverride = rows
            assertDamaged(fixture.data(), "skeleton at \(offset) of \(length) in a text of \(size)")
        }
    }

    func testAFragmentOutsideTheTextOrThePartIsDamaged() {
        let sound = paragraphs(5, cut: 2)
        let laid = sound.placed()
        for (offset, length) in [(0x0FFF_FFFF, 5), (0, 0x0FFF_FFFF), (laid.text.count, 1), (50, laid.text.count)] {
            var fixture = sound
            var rows = fixture.fragmentRows(laid)
            rows[0].values[6] = [offset, length]
            fixture.fragmentRowsOverride = rows
            assertDamaged(fixture.data(), "fragment at \(offset) of \(length)")
        }
    }

    func testAFragmentThatGoesOutsideItsDocumentIsDamaged() {
        let sound = paragraphs(5, cut: 2)
        let laid = sound.placed()
        // A place far past the end of the document built so far.
        var fixture = sound
        var rows = fixture.fragmentRows(laid)
        rows[1].name = Array("9999999999".utf8)
        fixture.fragmentRowsOverride = rows
        assertDamaged(fixture.data(), "a fragment named for place 9999999999")
        // A place inside the skeleton is where fragments go; a book may name any of them.
        rows[1].name = Array("0000000001".utf8)
        fixture.fragmentRowsOverride = rows
        XCTAssertNotNil(readQuickly(fixture.data(), "a fragment named for place 1"))
    }

    func testAFragmentWhoseNameIsNotANumberIsDamaged() {
        let sound = paragraphs(5, cut: 2)
        let laid = sound.placed()
        for name in ["", "abc", "12 34", "-5", "12345678901", "０１２"] {
            var fixture = sound
            var rows = fixture.fragmentRows(laid)
            rows[0].name = Array(name.utf8)
            fixture.fragmentRowsOverride = rows
            assertDamaged(fixture.data(), "a fragment named \(name)")
        }
    }

    func testRowsMissingTheirTagsAreDamaged() {
        let sound = paragraphs(5, cut: 2)
        let laid = sound.placed()
        var noPlace = sound
        var rows = noPlace.skeletonRows(laid)
        rows[0].values[6] = nil
        noPlace.skeletonRowsOverride = rows
        assertDamaged(noPlace.data(), "a skeleton with no place")

        var noCount = sound
        rows = noCount.skeletonRows(laid)
        rows[0].values[1] = nil
        noCount.skeletonRowsOverride = rows
        assertDamaged(noCount.data(), "a skeleton with no fragment count")

        var shortPlace = sound
        rows = shortPlace.skeletonRows(laid)
        rows[0].values[6] = [0]
        shortPlace.skeletonRowsOverride = rows
        assertDamaged(shortPlace.data(), "a skeleton with half a place")

        var noFragmentNumber = sound
        rows = noFragmentNumber.fragmentRows(laid)
        rows[0].values[4] = nil
        noFragmentNumber.fragmentRowsOverride = rows
        assertDamaged(noFragmentNumber.data(), "a fragment with no number")
    }

    func testAFragmentCountThatTheFragmentIndexCannotMeetIsDamaged() {
        let sound = paragraphs(5, cut: 2)
        let laid = sound.placed()
        for count in [3, 100, 0x0FFF_FFFF] {
            var fixture = sound
            var rows = fixture.skeletonRows(laid)
            rows[0].values[1] = [count, count]
            fixture.skeletonRowsOverride = rows
            assertDamaged(fixture.data(), "\(count) fragments claimed of 2")
        }
    }

    func testDocumentsThatTogetherHoldMoreThanTheTextAreDamaged() {
        // 3,000 skeleton rows that are all the whole of the markup: 3,000 times the text.
        let sound = paragraphs(5, cut: 0)
        let laid = sound.placed()
        var fixture = sound
        let row = sound.skeletonRows(laid)[0]
        fixture.skeletonRowsOverride = Array(repeating: row, count: 3_000)
        fixture.fragmentRowsOverride = []
        assertDamaged(fixture.data(), "3,000 documents that are all the text")
        // Fragments that all name the same range, many times over.
        let cut = paragraphs(5, cut: 2)
        let cutLaid = cut.placed()
        var repeated = cut
        var skeleton = repeated.skeletonRows(cutLaid)[0]
        skeleton.values[1] = [2_000, 2_000]
        repeated.skeletonRowsOverride = [skeleton]
        repeated.fragmentRowsOverride = Array(repeating: repeated.fragmentRows(cutLaid)[0], count: 2_000)
        assertDamaged(repeated.data(), "2,000 fragments that are one range")
    }

    func testTheFlowTableIsOnlyAnAidWhereTheMarkupIsTheWholeText() {
        // A book with nothing after its markup needs no flow table: documents that fill the text are the markup.
        var sound = paragraphs(5, cut: 2)
        sound.flows = []
        let bytes = sound.data()
        let offsets = MOBIFixture.recordOffsets(of: bytes)
        let record0 = offsets[0]
        let flowRecord = (0..<4).reduce(0) { $0 << 8 | Int(bytes[record0 + 192 + $1]) }

        var noMagic = bytes
        noMagic[offsets[flowRecord]] = 0x58
        XCTAssertNotNil(readQuickly(noMagic, "a flow table with no magic"))

        var farEnd = bytes
        MOBIFixture.put32(&farEnd, offsets[flowRecord] + 16, 0xFFFF_FFFF)
        XCTAssertNotNil(readQuickly(farEnd, "a flow table whose markup flow ends past the text"))

        var none = bytes
        MOBIFixture.put32(&none, record0 + 192, 0xFFFF_FFFF)
        XCTAssertNotNil(readQuickly(none, "a book that names no flow table"))

        // A flow table that says the markup ends before the documents do is a lie that is refused.
        var shortEnd = bytes
        MOBIFixture.put32(&shortEnd, offsets[flowRecord] + 16, 3)
        assertDamaged(shortEnd, "a flow table whose markup flow ends at byte 3")
    }

    func testAFlowTableThatIsLostLeavesTheStyleSheetAfterTheMarkupToBeCalledDamage() {
        // With a style sheet after the markup, a flow table that does not read leaves the whole text as
        // the markup, and the documents do not fill it: the book is damaged, not read in part.
        let bytes = paragraphs(5, cut: 2).data()
        let offsets = MOBIFixture.recordOffsets(of: bytes)
        let flowRecord = (0..<4).reduce(0) { $0 << 8 | Int(bytes[offsets[0] + 192 + $1]) }
        var noMagic = bytes
        noMagic[offsets[flowRecord]] = 0x58
        assertDamaged(noMagic, "a flow table with no magic, with a style sheet after the markup")
    }

    func testAFlowTableThatEndsPastTheTextDoesNotLetAPartPastTheTextBeRead() {
        // The markup flow's end is held to the text's: a skeleton past the end of the text is damaged
        // whatever the flow table says, and is not read (which would trap).
        // A document with no fragments, so that nothing else about it is wrong.
        let sound = paragraphs(5, cut: 0)
        let laid = sound.placed()
        var fixture = sound
        var rows = fixture.skeletonRows(laid)
        rows[0].values[6] = [laid.text.count + 10, 20, laid.text.count + 10, 20]
        fixture.skeletonRowsOverride = rows
        var bytes = fixture.data()
        let offsets = MOBIFixture.recordOffsets(of: bytes)
        let flowRecord = (0..<4).reduce(0) { $0 << 8 | Int(bytes[offsets[0] + 192 + $1]) }
        MOBIFixture.put32(&bytes, offsets[flowRecord] + 16, 0x0FFF_FFFF)
        assertDamaged(bytes, "a skeleton past the text, under a flow table that ends far past it")
    }

    // MARK: - Indexes

    func testAnIndexThatClaimsMoreRecordsOrEntriesThanItHoldsIsDamaged() {
        let bytes = paragraphs(5, cut: 2).data()
        let offsets = MOBIFixture.recordOffsets(of: bytes)
        let database = try? MOBIPalmDatabase(bytes: bytes)
        let headers = try? MOBIHeaders(record0: try XCTUnwrap(database).record(0, "r0"), requiresMOBIHeader: true)
        guard let skeleton = headers?.skeletonIndexRecord, let fragment = headers?.fragmentIndexRecord else { return XCTFail("no indexes") }
        for record in [skeleton, fragment] {
            // The record count in the index header (24), the string record count (52), and the entry count of the first data record (24).
            for (target, field, value) in [(record, 24, 0x7FFF_FFFF), (record, 24, 5_000), (record, 52, 0x7FFF_FFFF), (record, 4, 0x7FFF_FFFF),
                                           (record + 1, 24, 0xFFFF), (record + 1, 20, 0xFFFF_FFFF), (record + 1, 20, 3)] {
                var damaged = bytes
                MOBIFixture.put32(&damaged, offsets[target] + field, value)
                assertDamaged(damaged, "index record \(target) field \(field) set to \(value)")
            }
        }
    }

    func testAnEntryWhoseControlByteClaimsOtherValuesThanItHoldsEndsCleanly() {
        let bytes = paragraphs(5, cut: 2).data()
        let offsets = MOBIFixture.recordOffsets(of: bytes)
        guard let database = try? MOBIPalmDatabase(bytes: bytes),
              let headers = try? MOBIHeaders(record0: database.record(0, "r0"), requiresMOBIHeader: true),
              let skeleton = headers.skeletonIndexRecord, let fragment = headers.fragmentIndexRecord else { return XCTFail("no index") }
        // The control byte of the first entry of each index: after the entry's name length and name.
        for record in [skeleton, fragment] {
            let data = offsets[record + 1]
            let entry = data + 192 + 1 + Int(bytes[data + 192])
            for control in [0x00, 0x03, 0x0F, 0x55, 0xAA, 0xF0, 0xFF] {
                var damaged = bytes
                damaged[entry] = UInt8(control)
                // Whether it reads or is refused, it ends at once and with a typed error.
                readQuickly(damaged, "a control byte of \(control) in the index at record \(record)")
            }
        }
        // A count of no values leaves a row with no place, which is refused.
        var empty = bytes
        let data = offsets[fragment + 1]
        empty[data + 192 + 1 + Int(bytes[data + 192])] = 0
        assertDamaged(empty, "a fragment with no values at all")
    }

    func testAnIndexWhoseEntriesAllClaimTheSameThousandsOfNumbersIsDamaged() throws {
        // One entry that holds 20,000 numbers (its first tag's control bits say "a byte length follows"),
        // which 150 places of the entry table all name: three million numbers from a record of 20 KB.
        let numbers = 20_000
        let tags: [[UInt8]] = [[1, 2, 3, 0], [6, 4, 12, 0], [0, 0, 0, 1]]
        let tagx = Array("TAGX".utf8) + MOBIFixture.be32(12 + tags.count * 4) + MOBIFixture.be32(1) + tags.flatMap { $0 }
        var header = [UInt8](repeating: 0, count: 192)
        header.replaceSubrange(0..<4, with: Array("INDX".utf8))
        MOBIFixture.put32(&header, 4, 192)
        MOBIFixture.put32(&header, 24, 1)
        MOBIFixture.put32(&header, 28, 65001)

        var record = header
        let entry = 192
        record += [1, 0x41, 0x03] + MOBIFixture.variableNumber(numbers) + [UInt8](repeating: 0x81, count: numbers)
        let tableOffset = record.count
        record += Array("IDXT".utf8) + (0..<150).flatMap { _ in [UInt8(entry >> 8), UInt8(entry & 0xFF)] }
        MOBIFixture.put32(&record, 20, tableOffset)
        MOBIFixture.put32(&record, 24, 150)

        let file = MOBIFixture.database(
            named: "Hostile_Index", type: "BOOK", creator: "MOBI", records: [[0], header + tagx, record])
        let database = try MOBIPalmDatabase(bytes: file)
        let started = Date()
        XCTAssertThrowsError(try MOBIIndex.table(startingAt: 1, in: database)) {
            guard case .damaged(let detail)? = $0 as? MOBIError else { return XCTFail("\($0)") }
            XCTAssertTrue(detail.contains("too many numbers"), detail)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), TestMachine.allowed(1.0))
        // The same entry named a hundred times is within the bound, and read.
        var fewer = record
        MOBIFixture.put32(&fewer, 24, 90)
        let fewFile = MOBIFixture.database(
            named: "Hostile_Index", type: "BOOK", creator: "MOBI", records: [[0], header + tagx, fewer])
        XCTAssertEqual(try MOBIIndex.table(startingAt: 1, in: try MOBIPalmDatabase(bytes: fewFile)).rows.count, 90)
    }

    func testAnIndexRecordThatEndsInTheMiddleOfAnEntryIsDamaged() {
        let sound = paragraphs(5, cut: 2)
        let bytes = sound.data()
        let offsets = MOBIFixture.recordOffsets(of: bytes)
        guard let database = try? MOBIPalmDatabase(bytes: bytes),
              let headers = try? MOBIHeaders(record0: database.record(0, "r0"), requiresMOBIHeader: true),
              let fragment = headers.fragmentIndexRecord else { return XCTFail("no index") }
        // Cut the file in the first data record of the fragment index.
        for cut in stride(from: offsets[fragment + 1] + 1, to: min(offsets[fragment + 1] + 260, bytes.count), by: 7) {
            readQuickly(Array(bytes[..<cut]), "a file cut at \(cut)")
        }
    }

    func testAMarkupNestedFarDeeperThanAnyBookIsRefusedByTheGuardWhenItIsConverted() {
        let depth = 5_000
        let body = String(repeating: "<div>", count: depth) + "<p>Deep words.</p>" + String(repeating: "</div>", count: depth)
        // The guard's own count of the markup, which builds no tree: past its limit.
        let limits = MarkupGuard.Limits.standard
        XCTAssertThrowsError(try MarkupGuard.inspect(Array(body.utf8), as: .html, limits: limits)) {
            XCTAssertEqual($0 as? MarkupRefusal, .nestedTooDeeply(limit: limits.deepestNesting))
        }
        // The book's structure is sound, so it opens; the import refuses it where the markup is converted,
        // with the guard's sentence, and no tree of 5,000 levels is ever built.
        let deep = KF8Fixture(body: body).data()
        XCTAssertNotNil(readQuickly(deep, andImport: false, "\(depth) levels of nesting, opened"))
        XCTAssertEqual(importQuickly(deep, "\(depth) levels of nesting"), .refused(.nestedTooDeeply(limit: limits.deepestNesting)))
        // The same words at the depth of a real book are read (the converter is run in this host at 40 levels
        // at most: a debug build overflows its stack well before the limit).
        let shallow = String(repeating: "<div>", count: 40) + "<p>Deep words.</p>" + String(repeating: "</div>", count: 40)
        XCTAssertEqual(importQuickly(KF8Fixture(body: shallow).data(), "40 levels of nesting"), .read(chapters: 1))
    }

    /// The review's B1 and B2 inputs, as a KF8 part holds them. Both are the guard's to settle (it reads the
    /// declarations that trapped SwiftSoup's XML parser as nothing, and refuses a nesting the converter's
    /// stack could not hold, before any parse), and `MarkupGuardTests` shows each in a MOBI 6 book; these
    /// show them in a KF8 part, which is joined from fragments and opens as XML.
    func testTheReviewsDeclarationAndNestingInputsAreSettledByTheGuardInAKF8Part() {
        let declaration = "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
        // B1: a part that opens as XML and holds `<?a>` (it trapped SwiftSoup's XML parser): read.
        let broken = KF8Fixture(documents: [KF8Fixture.Document(html: declaration + "<html><body><?a><p>The words.</p></body></html>")])
        XCTAssertEqual(importQuickly(broken.data(), "a broken declaration in a part that opens as XML"), .read(chapters: 1))
        // B2: end tags that close nothing, and void tags counted as nothing (5,000 each): refused, by the guard's count.
        let limit = MarkupRefusal.nestedTooDeeply(limit: MarkupGuard.Limits.standard.deepestNesting)
        for hostile in [
            "<html><body><p>Some words.</p>" + String(repeating: "<div></x>", count: 5_000) + "</body></html>",
            declaration + "<p>Some words.</p>" + String(repeating: "<br>", count: 5_000),
        ] {
            let book = KF8Fixture(documents: [KF8Fixture.Document(html: hostile)])
            XCTAssertEqual(importQuickly(book.data(), String(hostile.prefix(60))), .refused(limit))
        }
    }

    // MARK: - Many pieces

    func testAThousandEntriesAndTwentyThousandFragmentsAreReadInAMoment() throws {
        var fixture = paragraphs(20_000, cut: 20_000)
        fixture.entries = (0..<1_000).map { index in
            KF8Fixture.Entry(label: "Entry \(index)", document: 0, fragment: index * 20, offset: 0, depth: index % 3)
        }
        let started = Date()
        let book = try MOBIBook(bytes: fixture.data())
        XCTAssertLessThan(Date().timeIntervalSince(started), TestMachine.allowed(3.0))
        XCTAssertEqual(book.sections.count, 1)
        XCTAssertEqual(book.sections[0].headingTargets.count, 999)   // the first entry names the whole document
        XCTAssertEqual(book.sections[0].html.anchorsRemoved, fixture.documents[0].html)
    }

    func testReadingGrowsInStepWithTheFragments() throws {
        func seconds(_ count: Int) throws -> TimeInterval {
            let bytes = paragraphs(count, cut: count).data()
            var least = TimeInterval.infinity
            for _ in 0..<3 {
                let started = Date()
                _ = try MOBIBook(bytes: bytes)
                least = min(least, Date().timeIntervalSince(started))
            }
            return least
        }
        let small = try seconds(2_000)
        let large = try seconds(16_000)
        XCTAssertLessThan(large, max(small * 24, 0.2), "2,000 took \(small) s and 16,000 took \(large) s")
    }

    func testOneHugeNumberOfAnchorsCostsNoMoreThanTheirNumber() throws {
        // Entries for many places in one fragment: each gets one anchor.
        let texts = (0..<3_000).map { "<p>Line \($0).</p>" }
        let html = "<html><head><title>T</title></head><body>" + texts.joined() + "</body></html>"
        var fixture = KF8Fixture(documents: [KF8Fixture.Document(html: html, cutting: [texts.joined()])])
        var offset = 0
        fixture.entries = texts.enumerated().map { index, text in
            defer { offset += text.utf8.count }
            return KF8Fixture.Entry(label: "Line \(index)", document: 0, fragment: 0, offset: offset, depth: 1)
        }
        let started = Date()
        let book = try MOBIBook(bytes: fixture.data())
        XCTAssertLessThan(Date().timeIntervalSince(started), TestMachine.allowed(3.0))
        XCTAssertEqual(book.sections[0].headingTargets.count, 2_999)   // the first entry names the whole document
    }

    // MARK: - Damaged real files

    /// A repeatable sequence of numbers, so a failure can be run again.
    private struct SeededNumbers {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func below(_ limit: Int) -> Int { Int(next() % UInt64(limit)) }
    }

    func testTheKF8SampleCutAtManyLengthsEndsCleanly() throws {
        let bytes = [UInt8](try Data(contentsOf: formatSampleURL("mobi/pg1952-yellow-wallpaper-kf8.mobi")))
        var lengths = [0, 1, 2, 77, 78, 79, 100, 400, 1000, 4096, bytes.count - 1, bytes.count - 2]
        lengths += stride(from: 0, to: bytes.count, by: bytes.count / 40).map { $0 }
        for length in lengths where length < bytes.count {
            readQuickly(Array(bytes[..<length]), "the sample cut at \(length)")
        }
    }

    func testTheKF8SampleWithBytesFlippedEndsCleanly() throws {
        let bytes = [UInt8](try Data(contentsOf: formatSampleURL("mobi/pg1952-yellow-wallpaper-kf8.mobi")))
        let offsets = MOBIFixture.recordOffsets(of: bytes)
        let database = try MOBIPalmDatabase(bytes: bytes)
        let headers = try MOBIHeaders(record0: try database.record(0, "r0"), requiresMOBIHeader: true)
        // The records that hold the tables: from the flow table to the guide index.
        let tables = [headers.flowTableRecord, headers.skeletonIndexRecord, headers.fragmentIndexRecord, headers.indexRecord, headers.guideIndexRecord].compactMap { $0 }
        let tableRange = offsets[tables.min() ?? 0]..<bytes.count.advanced(by: 0)
        var random = SeededNumbers(state: 20261106)
        for round in 0..<240 {
            var damaged = bytes
            // Half the rounds damage anywhere; half damage record 0 or the tables.
            for _ in 0...random.below(3) {
                let place: Int
                switch round % 4 {
                case 0: place = random.below(bytes.count)
                case 1: place = offsets[0] + random.below(offsets[1] - offsets[0])
                default: place = tableRange.lowerBound + random.below(min(tableRange.count, 6_000))
                }
                damaged[place] = UInt8(truncatingIfNeeded: random.next())
            }
            // Every fourth copy that opens is imported too: converting a whole book is the slow part.
            readQuickly(damaged, andImport: round % 4 == 0, "the sample with bytes changed, round \(round)")
        }
    }

    func testTheHybridSamplesWithTheirSecondHalfDamagedEndCleanly() throws {
        for sample in ["mobi/pg8121-ghosts-hybrid.mobi", "mobi/libmobi-unicode-huffdic.mobi"] {
            let bytes = [UInt8](try Data(contentsOf: formatSampleURL(sample)))
            let database = try MOBIPalmDatabase(bytes: bytes)
            let headers = try MOBIHeaders(record0: try database.record(0, "r0"), requiresMOBIHeader: true)
            let boundary = try XCTUnwrap(headers.kf8BoundaryRecord, sample)
            let offsets = MOBIFixture.recordOffsets(of: bytes)
            var random = SeededNumbers(state: 1106)
            for round in 0..<80 {
                var damaged = bytes
                damaged[offsets[boundary] + random.below(offsets[min(boundary + 1, offsets.count - 1)] - offsets[boundary])] = UInt8(truncatingIfNeeded: random.next())
                // Every eighth copy that opens is imported too (both halves are whole books).
                readQuickly(damaged, andImport: round % 8 == 0, "\(sample) with record 0 of the KF8 half damaged, round \(round)")
            }
        }
    }
}

private extension String {
    /// The string with every empty anchor (`<a id="filepos-N"></a>`) taken out.
    var anchorsRemoved: String {
        var result = ""
        var rest = self[...]
        while let start = rest.range(of: "<a id=\"filepos-") {
            result += rest[..<start.lowerBound]
            guard let end = rest.range(of: "</a>", range: start.upperBound..<rest.endIndex) else { break }
            rest = rest[end.upperBound...]
        }
        return result + rest
    }
}
