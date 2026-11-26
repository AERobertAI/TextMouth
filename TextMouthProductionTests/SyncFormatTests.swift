import XCTest
@testable import TextMouth

/// The stored formats of syncing the library (FR43) and the stubs at
/// `sync/base`: each format reads back what it wrote, and the stubs return
/// empty or default values without trapping. sync-core adds the format
/// pins to this class.
final class SyncFormatTests: XCTestCase {
    /// An encoder with the formats' fixed settings: sorted keys, dates to the second.
    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// A decoder matching `encoder()`.
    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// A change file with one entry reads back equal.
    func testChangeFileRoundTrips() throws {
        let entry = SyncEntry(
            key: .book(try XCTUnwrap(UUID(uuidString: "11111111-1111-1111-1111-111111111111")), .title),
            value: .string("A Title"),
            stamp: SyncStamp(wall: 1_000, counter: 2, device: "dev"),
            byHand: true
        )
        let file = SyncChangeFile(
            formatVersion: 1, deviceID: "dev", incarnation: UUID(), seq: 1, kind: .changes, count: 1, entries: [entry]
        )
        let data = try encoder().encode(file)
        XCTAssertEqual(try decoder().decode(SyncChangeFile.self, from: data), file)
    }

    /// Registers holding an entry read back equal (the entries travel as a list).
    func testRegistersRoundTrip() throws {
        let key = SyncKey.readingListOption(.continuation)
        let entry = SyncEntry(key: key, value: .bool(true), stamp: SyncStamp(wall: 5, counter: 0, device: "d"), byHand: false)
        let registers = SyncRegisters(entries: [key: entry], throughSeq: 3)
        let data = try encoder().encode(registers)
        XCTAssertEqual(try decoder().decode(SyncRegisters.self, from: data), registers)
    }

    /// The pointer's file name is the dotted one that keeps it out of a package's content.
    func testPointerFileName() {
        XCTAssertEqual(StorePointer.fileName, ".storeCopy.json")
    }

    /// Stamps order by wall time, then counter, then device.
    func testStampOrder() {
        let early = SyncStamp(wall: 1, counter: 9, device: "z")
        XCTAssertLessThan(early, SyncStamp(wall: 2, counter: 0, device: "a"))
        XCTAssertLessThan(SyncStamp(wall: 2, counter: 0, device: "a"), SyncStamp(wall: 2, counter: 1, device: "a"))
        XCTAssertLessThan(SyncStamp(wall: 2, counter: 1, device: "a"), SyncStamp(wall: 2, counter: 1, device: "b"))
    }

    /// The inert merge returns an empty change set and the library as it was.
    func testInertMergeChangesNothing() {
        let library = Library()
        let application = SyncMerge.apply(SyncRegisters(), to: library, voices: nil)
        XCTAssertEqual(application.library, library)
        XCTAssertTrue(application.booksToAdd.isEmpty)
        XCTAssertTrue(SyncMerge.changes(from: .of(library, contents: [:]), to: .of(library, contents: [:]), atLaunch: true).isEmpty)
    }

    /// The status of a library that never set up sync is off and empty.
    @MainActor
    func testStatusStartsOff() {
        // Its own center, so no other test's set-up is seen.
        let center = SyncCenter()
        XCTAssertEqual(center.status, SyncStatus())
        XCTAssertFalse(center.status.isOn)
    }

    // MARK: - Reading the files

    /// A change file that has the entries it says reads back.
    func testChangeFileReadsWithItsCount() throws {
        let entry = SyncEntry(
            key: .book(UUID(), .title), value: .string("A"), stamp: SyncStamp(wall: 1, counter: 0, device: "d"), byHand: false
        )
        let file = SyncChangeFile(formatVersion: 1, deviceID: "d", incarnation: UUID(), seq: 7, kind: .snapshot, count: 1, entries: [entry])
        let read = try SyncFormats.decodeChangeFile(try SyncFormats.encode(file), named: "000000000007.snapshot.json")
        XCTAssertEqual(read, file)
    }

    /// A change file that holds other than `count` entries is not all here yet.
    func testChangeFileWithTheWrongCountIsDamaged() throws {
        let entry = SyncEntry(
            key: .book(UUID(), .title), value: .string("A"), stamp: SyncStamp(wall: 1, counter: 0, device: "d"), byHand: false
        )
        let file = SyncChangeFile(formatVersion: 1, deviceID: "d", incarnation: UUID(), seq: 1, kind: .changes, count: 2, entries: [entry])
        XCTAssertThrowsError(try SyncFormats.decodeChangeFile(try SyncFormats.encode(file), named: "x")) {
            XCTAssertEqual($0 as? SyncProblem, .damaged(file: "x"))
        }
        XCTAssertThrowsError(try SyncFormats.decodeChangeFile(Data("{\"formatVersion\":1".utf8), named: "half")) {
            XCTAssertEqual($0 as? SyncProblem, .damaged(file: "half"))
        }
    }

    /// A file of a later version is left alone, with the later-version problem.
    func testLaterVersionIsRefused() {
        let data = Data(#"{"formatVersion":2,"storeID":"x"}"#.utf8)
        XCTAssertThrowsError(try SyncFormats.decodeStoreFile(data)) {
            XCTAssertEqual($0 as? SyncProblem, .laterVersion)
        }
    }

    /// An entry whose key a later TextMouth added is skipped, and still counted.
    func testEntryOfAnUnknownKeyIsSkipped() throws {
        let known = SyncEntry(
            key: .book(UUID(), .title), value: .string("A"), stamp: SyncStamp(wall: 1, counter: 0, device: "d"), byHand: false
        )
        let knownJSON = String(decoding: try SyncFormats.encode(known), as: UTF8.self)
        let text = #"{"formatVersion":1,"deviceID":"d","incarnation":"11111111-1111-1111-1111-111111111111","seq":1,"kind":"changes","count":2,"entries":[\#(knownJSON),{"key":"shelf/x","value":1,"stamp":{"wall":1,"counter":0,"device":"d"},"byHand":false}]}"#
        let read = try SyncFormats.decodeChangeFile(Data(text.utf8), named: "f")
        XCTAssertEqual(read.entries, [known])
        XCTAssertEqual(read.count, 2)
    }

    /// A store file reads back, and the same file is always the same bytes.
    func testStoreFileRoundTripsInFixedBytes() throws {
        let file = SyncStoreFile(
            formatVersion: 1, storeID: UUID(), created: Date(timeIntervalSince1970: 1_700_000_000.9),
            createdBy: "Mac", createdByVersion: "0.6.0"
        )
        let data = try SyncFormats.encode(file)
        XCTAssertEqual(try SyncFormats.encode(file), data)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"created\":\"2023-11-14T22:13:20Z\""), "dates to the second")
        XCTAssertEqual(try SyncFormats.decodeStoreFile(data).storeID, file.storeID)
    }
}
