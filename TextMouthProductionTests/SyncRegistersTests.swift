import XCTest
@testable import TextMouth

/// The registers' merge (FR43): each key keeps its highest entry, in any order.
final class SyncRegistersTests: XCTestCase {
    /// An entry for `key` of `value`, stamped at `wall` by device `device`.
    private func entry(_ key: SyncKey, _ value: JSONValue, wall: Int64, device: String = "a", byHand: Bool = false) -> SyncEntry {
        SyncEntry(key: key, value: value, stamp: SyncStamp(wall: wall, counter: 0, device: device), byHand: byHand)
    }

    /// The first entry of a key is taken, and reported.
    func testFirstEntryWins() {
        let key = SyncKey.book(UUID(), .title)
        var registers = SyncRegisters()
        XCTAssertEqual(registers.merge([entry(key, .string("a"), wall: 1)]), [key])
        XCTAssertEqual(registers.entries[key]?.value, .string("a"))
    }

    /// A later entry replaces an earlier, and an earlier does not replace a later.
    func testLaterEntryWins() {
        let key = SyncKey.book(UUID(), .title)
        var registers = SyncRegisters()
        registers.merge([entry(key, .string("b"), wall: 5)])
        XCTAssertEqual(registers.merge([entry(key, .string("a"), wall: 1)]), [])
        XCTAssertEqual(registers.entries[key]?.value, .string("b"))
        XCTAssertEqual(registers.merge([entry(key, .string("c"), wall: 9)]), [key])
        XCTAssertEqual(registers.entries[key]?.value, .string("c"))
    }

    /// A hand edit stands over a later change that no person made.
    func testHandEditStandsOverALaterRefresh() {
        let key = SyncKey.book(UUID(), .title)
        var registers = SyncRegisters()
        registers.merge([entry(key, .string("mine"), wall: 1, byHand: true), entry(key, .string("read from file"), wall: 9)])
        XCTAssertEqual(registers.entries[key]?.value, .string("mine"))
    }

    /// Merging an entry again changes nothing.
    func testMergingTwiceChangesNothing() {
        let key = SyncKey.book(UUID(), .rate)
        var registers = SyncRegisters()
        let incoming = [entry(key, .integer(200), wall: 3)]
        registers.merge(incoming)
        let before = registers
        XCTAssertEqual(registers.merge(incoming), [])
        XCTAssertEqual(registers, before)
    }

    /// Any order of merging gives the same registers.
    func testOrderDoesNotMatter() {
        let key = SyncKey.book(UUID(), .title)
        let entries = [
            entry(key, .string("a"), wall: 1, device: "a"),
            entry(key, .string("b"), wall: 5, device: "b"),
            entry(key, .string("c"), wall: 5, device: "a"),
        ]
        var forward = SyncRegisters(), backward = SyncRegisters()
        forward.merge(entries)
        backward.merge(entries.reversed())
        XCTAssertEqual(forward, backward)
        XCTAssertEqual(forward.entries[key]?.value, .string("b"))
    }

    /// The registers read back from the file they were written to.
    func testRegistersRoundTripThroughTheirFile() throws {
        var registers = SyncRegisters(throughSeq: 4)
        registers.merge([
            entry(.book(UUID(), .title), .string("T"), wall: 1),
            entry(.folder(UUID(), .name), .string("F"), wall: 2),
            entry(.readingListOption(.skipsFinished), .bool(false), wall: 3),
        ])
        let data = try SyncFormats.encode(registers)
        XCTAssertEqual(try SyncValueCoding.makeDecoder().decode(SyncRegisters.self, from: data), registers)
        XCTAssertEqual(try SyncFormats.encode(registers), data, "the same registers write the same bytes")
    }

    /// A key reads back from its text, and a text that is no key reads as none.
    func testKeysHaveATextForm() throws {
        let book = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001"))
        let other = try XCTUnwrap(UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002"))
        let keys: [SyncKey] = [
            .book(book, .skippedHeadings), .bookmark(book: book, id: other), .folder(other, .parent),
            .readingList(book: book), .readingListOption(.removesFinished),
        ]
        for key in keys { XCTAssertEqual(SyncKey(text: key.text), key) }
        XCTAssertEqual(SyncKey.book(book, .title).text, "book/aaaaaaaa-0000-0000-0000-000000000001/title")
        XCTAssertNil(SyncKey(text: "shelf/\(book.uuidString)/title"))
        XCTAssertNil(SyncKey(text: "book/not-an-id/title"))
        XCTAssertNil(SyncKey(text: "book/\(book.uuidString)/colour"))
    }
}
