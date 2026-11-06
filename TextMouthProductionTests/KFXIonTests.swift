import XCTest
@testable import TextMouth

/// The binary Ion reader of the KFX reader (FMT52, layer 2), on documents
/// built by hand with `IonWriter`: every type a book holds, both length
/// forms, pads, annotations, and then the hostile documents, each refused
/// quickly.
final class KFXIonTests: XCTestCase {

    // MARK: - Helpers

    /// The values of `bytes` read as an Ion document.
    private func read(_ bytes: [UInt8], budget: Int = 1_000_000) throws -> [IonValue] {
        var budget = budget
        return try IonReader.values(in: KFXView(bytes), budget: &budget)
    }

    /// The one value of the document that holds `value`, in either length form.
    private func roundTrip(_ value: IonOut, file: StaticString = #filePath, line: UInt = #line) throws -> IonValue {
        let short = try read(IonWriter.document(value))
        let long = try read(IonWriter.document(value, alwaysLong: true))
        XCTAssertEqual(short, long, "the long length form reads the same", file: file, line: line)
        XCTAssertEqual(short.count, 1, file: file, line: line)
        return try XCTUnwrap(short.first, file: file, line: line)
    }

    // MARK: - Scalars

    func testNullsAndBooleans() throws {
        XCTAssertEqual(try read(IonWriter.document(.null, .bool(true), .bool(false))), [.null, .bool(true), .bool(false)])
        // A typed null, such as null.int (0x2F), is a null.
        XCTAssertEqual(try read(IonWriter.marker + [0x2F, 0x8F, 0xBF, 0xDF]), [.null, .null, .null, .null])
    }

    func testIntegersOfEverySize() throws {
        for number: Int64 in [0, 1, 127, 128, 255, 256, 65_535, 1 << 40, Int64.max, -1, -255, -(1 << 40), -Int64.max] {
            XCTAssertEqual(try roundTrip(.int(number)), .int(number), "\(number)")
        }
    }

    func testAnIntegerPast64BitsIsOpaqueNotAnError() throws {
        XCTAssertEqual(try roundTrip(.integerBytes([1, 0, 0, 0, 0, 0, 0, 0, 0])), .opaque)
        // Leading zero bytes make no difference to the value.
        XCTAssertEqual(try roundTrip(.integerBytes([0, 0, 0, 0, 0, 0, 0, 0, 0, 7])), .int(7))
        // One past Int64.max does not fit the reader's integer.
        XCTAssertEqual(try roundTrip(.integerBytes([0x80, 0, 0, 0, 0, 0, 0, 0])), .opaque)
    }

    func testFloatsOfEverySize() throws {
        XCTAssertEqual(try roundTrip(.float32(1.5)), .float(1.5))
        XCTAssertEqual(try roundTrip(.float64(-2.25)), .float(-2.25))
        XCTAssertEqual(try read(IonWriter.marker + [0x40]), [.float(0)])
    }

    func testStringsOfEveryLengthAndScript() throws {
        for text in ["", "a", String(repeating: "x", count: 13), String(repeating: "y", count: 14),
                     String(repeating: "z", count: 200), "Alice\u{2019}s \u{1F600} e\u{301}", String(repeating: "q", count: 20_000)] {
            XCTAssertEqual(try roundTrip(.string(text)), .string(text), String(text.prefix(20)))
        }
    }

    func testSymbols() throws {
        for id in [0, 4, 260, 851, 860, 100_000] {
            XCTAssertEqual(try roundTrip(.symbol(id)), .symbol(id), "\(id)")
        }
    }

    func testDecimalsTimestampsClobsAndBlobsAreFoundButNotRead() throws {
        for type in [5, 6, 9, 10] {
            XCTAssertEqual(try roundTrip(.opaque(type: type, body: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15])), .opaque, "type \(type)")
        }
    }

    // MARK: - Containers

    func testListsNestedAndEmpty() throws {
        let value = IonOut.list([.int(1), .list([]), .sexp([.string("a"), .list([.int(2)])])])
        XCTAssertEqual(
            try roundTrip(value),
            .list([.int(1), .list([]), .list([.string("a"), .list([.int(2)])])]))
    }

    func testStructsWithMembersInTheOrderTheyWereWritten() throws {
        let value = IonOut.structure([(155, .int(7)), (145, .structure([(4, .symbol(900)), (403, .int(2))])), (146, .list([]))])
        let read = try XCTUnwrap(roundTrip(value).structValue)
        XCTAssertEqual(read.fields.map(\.id), [155, 145, 146])
        XCTAssertEqual(read[155], .int(7))
        XCTAssertEqual(read[145]?.structValue?[403], .int(2))
        XCTAssertNil(read[999])
    }

    func testAnEmptyStructAndASortedStructAreRead() throws {
        XCTAssertEqual(try roundTrip(.structure([])), .structure(IonStruct(fields: [])))
        let sorted = try XCTUnwrap(try read(IonWriter.document(.sortedStructure([(4, .int(1)), (5, .int(2))]))).first?.structValue)
        XCTAssertEqual(sorted[5], .int(2))
    }

    func testARepeatedFieldReadsAsItsFirstMember() throws {
        let value = try XCTUnwrap(roundTrip(.structure([(5, .int(1)), (5, .int(2))])).structValue)
        XCTAssertEqual(value[5], .int(1))
    }

    func testAnnotationsOneAndTwo() throws {
        XCTAssertEqual(try roundTrip(.annotated([3], .int(1))), .annotated([3], .int(1)))
        let two = try roundTrip(.annotated([391, 700], .structure([(235, .symbol(212))])))
        XCTAssertEqual(two.annotations, [391, 700])
        XCTAssertEqual(two.structValue?[235]?.symbolID, 212)
        XCTAssertEqual(two.unannotated.structValue?[235], .symbol(212))
    }

    // MARK: - Pads and markers

    func testPadsAreSkippedAtTheTopAndInsideListsAndStructs() throws {
        for padding in [1, 2, 5, 14, 15, 40, 300] {
            let pad = IonOut.pad(padding)
            let document = IonWriter.marker + IonWriter.encode(pad)
                + IonWriter.encode(.list([pad, .int(1), pad, .int(2), pad]))
                + IonWriter.encode(.structure([(5, pad), (6, .int(9)), (7, pad)]))
                + IonWriter.encode(pad)
            XCTAssertEqual(
                try read(document),
                [.list([.int(1), .int(2)]), .structure(IonStruct(fields: [IonField(id: 6, value: .int(9))]))],
                "pad of \(padding)")
        }
    }

    func testAVersionMarkerBetweenValuesIsSkipped() throws {
        let document = IonWriter.document(.int(1)) + IonWriter.document(.int(2))
        XCTAssertEqual(try read(document), [.int(1), .int(2)])
    }

    func testADocumentWithNoValueReadsAsNone() throws {
        XCTAssertEqual(try read(IonWriter.marker), [])
        XCTAssertEqual(try read([]), [])
    }

    // MARK: - A hostile document

    func testEveryTruncationOfARichDocumentIsRefused() throws {
        let value = IonOut.annotated([3], .structure([
            (7, .list([.string(String(repeating: "s", count: 40)), .int(70_000), .float64(1.0), .bool(true)])),
            (6, .structure([(4, .symbol(300)), (5, .annotated([1, 2], .string("hi")))])),
        ]))
        let whole = IonWriter.document(value)
        XCTAssertNoThrow(try read(whole))
        for length in 5..<whole.count {
            // The cut ends in the middle of the one value, so it never reads.
            assertRefusedQuickly("cut at \(length)") { try read(Array(whole.prefix(length))) }
        }
    }

    func testALengthPastTheEndIsRefused() {
        // A string that says 100 bytes and holds 2.
        assertRefusedQuickly("string") { try read(IonWriter.marker + [0x8E, 0xE4, 0x61, 0x62]) }
        // A list that says it is longer than the document.
        assertRefusedQuickly("list") { try read(IonWriter.marker + [0xBE, 0xFF, 0x20]) }
        // A struct member whose value runs past its struct.
        assertRefusedQuickly("member") { try read(IonWriter.marker + [0xD3, 0x84, 0x83, 0x61]) }
    }

    func testAHugeDeclaredLengthNeverSizesAnAllocation() {
        // Nine bytes of VarUInt: 2^62 elements declared, none present.
        let huge: [UInt8] = [0xBE, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80]
        assertRefusedQuickly("huge list") { try read(IonWriter.marker + huge) }
        // A VarUInt too long to be a length.
        let endless: [UInt8] = [0xBE] + [UInt8](repeating: 0x01, count: 12) + [0x81]
        assertRefusedQuickly("endless length") { try read(IonWriter.marker + endless) }
        // Counts at their maximum, in a struct's sorted form too.
        assertRefusedQuickly("huge sorted struct") { try read(IonWriter.marker + [0xD1, 0x7F, 0x7F, 0x7F, 0x7F, 0x7F, 0x7F, 0x7F, 0x7F, 0xFF]) }
    }

    func testDeepNestingIsCutAtTheDepthLimitWithoutRecursion() {
        // Fifty thousand lists inside lists: an explicit stack, so no overflow.
        var bytes: [UInt8] = []
        let depth = 50_000
        for _ in 0..<depth { bytes += [0xBE, 0x00] }  // each opens a list; the depth cap or a bad length stops it
        assertRefusedQuickly("deep") { try read(IonWriter.marker + bytes) }
        // Properly sized nesting just past the limit is refused as well.
        var value = IonOut.int(1)
        for _ in 0...(IonReader.maximumDepth + 2) { value = .list([value]) }
        assertRefusedQuickly("sized deep") { try read(IonWriter.document(value)) }
        // And nesting at the limit is read.
        var allowed = IonOut.int(1)
        for _ in 0..<(IonReader.maximumDepth - 1) { allowed = .list([allowed]) }
        XCTAssertNoThrow(try read(IonWriter.document(allowed)))
    }

    func testReservedTypesAndMalformedValuesAreRefused() {
        assertRefusedQuickly("type 15") { try read(IonWriter.marker + [0xF0]) }
        assertRefusedQuickly("bool 2") { try read(IonWriter.marker + [0x12]) }
        assertRefusedQuickly("negative zero") { try read(IonWriter.marker + [0x30]) }
        assertRefusedQuickly("float of 3 bytes") { try read(IonWriter.marker + [0x43, 0, 0, 0]) }
        assertRefusedQuickly("annotation of one byte") { try read(IonWriter.marker + [0xE1, 0x81]) }
        assertRefusedQuickly("annotation with no ids") { try read(IonWriter.marker + [0xE3, 0x80, 0x20, 0x20]) }
        assertRefusedQuickly("annotation of two values") { try read(IonWriter.marker + [0xE4, 0x81, 0x83, 0x20, 0x20]) }
        assertRefusedQuickly("struct field with no value") { try read(IonWriter.marker + [0xD2, 0x84, 0x21]) }
        assertRefusedQuickly("symbol id too large") { try read(IonWriter.marker + [0x78, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]) }
    }

    func testTheValueBudgetStopsAFileThatHoldsTooMany() throws {
        let many = IonOut.list((0..<1_000).map { .int(Int64($0)) })
        XCTAssertNoThrow(try read(IonWriter.document(many), budget: 1_100))
        assertRefusedQuickly("budget") { try read(IonWriter.document(many), budget: 500) }
    }

    func testAFixedSeedFlipOfARichDocumentNeverTraps() {
        let whole = IonWriter.document(.annotated([3], .structure([
            (7, .list([.string("hello"), .int(70_000), .float64(1.0), .bool(true), .symbol(900)])),
            (6, .structure([(4, .symbol(300)), (5, .annotated([1, 2], .string("hi")))])),
        ])))
        var generator = SeededGenerator(seed: 2026_11_06)
        assertQuick("2,000 flips") {
            for _ in 0..<2_000 {
                var damaged = whole
                for _ in 0..<(1 + Int(generator.next() % 3)) {
                    damaged[Int(generator.next() % UInt64(damaged.count))] = UInt8(truncatingIfNeeded: generator.next())
                }
                // Whatever it reads, it reads without trapping and ends.
                _ = try? read(damaged)
            }
        }
    }

    // MARK: - Typed access

    func testTypedAccessorsLookThroughAnnotations() {
        let value = IonValue.annotated([3], .annotated([4], .int(5)))
        XCTAssertEqual(value.intValue, 5)
        XCTAssertNil(value.stringValue)
        XCTAssertEqual(IonValue.annotated([1], .string("x")).stringValue, "x")
        XCTAssertEqual(IonValue.bool(true).boolValue, true)
        XCTAssertNil(IonValue.int(1).boolValue)
    }
}
