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
            key: .book(UUID(uuidString: "11111111-1111-1111-1111-111111111111")!, .title),
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

    /// The stub folder access lists nothing and reports no upload state.
    func testPlainFolderAccessStubIsInert() throws {
        let access = PlainSyncFolderAccess(bookmark: Data())
        XCTAssertTrue(try access.list(URL(fileURLWithPath: "/Users/reader/none")).isEmpty)
        XCTAssertEqual(access.uploadState(of: URL(fileURLWithPath: "/Users/reader/none")), .notReported)
    }

    /// The status of a library that never set up sync is off and empty.
    @MainActor
    func testStatusStartsOff() {
        XCTAssertEqual(SyncCenter.shared.status, SyncStatus())
        XCTAssertFalse(SyncCenter.shared.status.isOn)
    }
}
