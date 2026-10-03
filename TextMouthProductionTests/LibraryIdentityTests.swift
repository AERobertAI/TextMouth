import XCTest
@testable import TextMouth

/// The library identity marker (FR02): written once, never overwritten, and
/// read back as it was written.
final class LibraryIdentityTests: XCTestCase {

    /// A folder without a marker has no identity.
    func testAFolderWithoutAMarkerHasNoIdentity() throws {
        let root = try makeSandboxDirectory("NoMarker")

        XCTAssertNil(try LibraryIdentity.read(in: root))
    }

    /// Adopting gives a folder a new identity once; adopting again, and
    /// reading, return that same identity.
    func testAdoptingGivesAnIdentityOnceAndReadsItBack() throws {
        let root = try makeSandboxDirectory("Adopt")
        let now = Date(timeIntervalSince1970: 1_790_000_000)

        let first = try LibraryIdentity.adopt(in: root, now: now)
        let second = try LibraryIdentity.adopt(in: root, now: now.addingTimeInterval(60))

        XCTAssertTrue(first.isNew)
        XCTAssertEqual(first.identity.created, now)
        XCTAssertFalse(second.isNew)
        XCTAssertEqual(second.identity, first.identity)
        XCTAssertEqual(try LibraryIdentity.read(in: root), first.identity)
    }

    /// A marker already there is never replaced: adopting returns it and
    /// leaves its bytes exactly as they were.
    func testAdoptingNeverOverwritesAMarker() throws {
        let root = try makeSandboxDirectory("Existing")
        let marker = LibraryIdentity.markerURL(in: root)
        let theirs = LibraryIdentity(id: UUID(), created: Date(timeIntervalSince1970: 1_700_000_000))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let bytes = try encoder.encode(theirs)
        try bytes.write(to: marker)

        let adopted = try LibraryIdentity.adopt(in: root)

        XCTAssertFalse(adopted.isNew)
        XCTAssertEqual(adopted.identity, theirs)
        XCTAssertEqual(try Data(contentsOf: marker), bytes)
    }

    /// The marker names its two fields plainly, so a person reading the
    /// folder can tell what it is.
    func testTheMarkerHoldsItsIdentifierAndCreationDate() throws {
        let root = try makeSandboxDirectory("Fields")

        let identity = try LibraryIdentity.adopt(in: root).identity

        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: LibraryIdentity.markerURL(in: root)))
        let fields = try XCTUnwrap(object as? [String: String])
        XCTAssertEqual(Set(fields.keys), ["id", "created"])
        XCTAssertEqual(fields["id"], identity.id.uuidString)
        XCTAssertEqual(LibraryIdentity.markerURL(in: root).lastPathComponent, "library-identity.json")
    }

    /// A damaged marker is reported, not mistaken for a missing one, and
    /// adopting leaves it in place.
    func testADamagedMarkerIsReportedAndKept() throws {
        let root = try makeSandboxDirectory("Damaged")
        let marker = LibraryIdentity.markerURL(in: root)
        try Data("{\"id\": \"not a uuid\"".utf8).write(to: marker)

        XCTAssertThrowsError(try LibraryIdentity.read(in: root))
        XCTAssertThrowsError(try LibraryIdentity.adopt(in: root))
        XCTAssertEqual(try Data(contentsOf: marker), Data("{\"id\": \"not a uuid\"".utf8))
    }

    /// Adopting in a folder that doesn't exist fails and creates nothing.
    func testAdoptingInAMissingFolderCreatesNothing() throws {
        let missing = try makeSandboxDirectory("Missing").appendingPathComponent("Gone", isDirectory: true)

        XCTAssertThrowsError(try LibraryIdentity.adopt(in: missing))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }
}
