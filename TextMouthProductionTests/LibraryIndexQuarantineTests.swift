import XCTest
@testable import TextMouth

/// A library index that cannot be used is preserved beside the original,
/// verbatim, without the original ever being changed (TODO S01). Every test
/// works inside a disposable temporary directory.
final class LibraryIndexQuarantineTests: XCTestCase {
    private var directory: URL!
    private var indexURL: URL!
    /// A fixed moment, so copy names are predictable.
    private let moment = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TextMouthIndexQuarantine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        indexURL = directory.appendingPathComponent("library.json")
    }

    override func tearDownWithError() throws {
        // Tests remove read permission from fixtures; give it back so nothing
        // in the directory resists removal or inspection.
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names {
            chmod(directory.appendingPathComponent(name).path, 0o644)
        }
        try? FileManager.default.removeItem(at: directory)
    }

    /// Copy names carry a sortable ISO 8601 basic timestamp with no colons,
    /// and a numeric suffix when a second copy is made within the same second.
    func testCopyNamesUseSortableColonFreeTimestamps() {
        XCTAssertEqual(
            LibraryIndexQuarantine.copyURL(for: indexURL, at: moment).lastPathComponent,
            "library.json.unreadable-20260921T141320Z"
        )
        XCTAssertEqual(
            LibraryIndexQuarantine.copyURL(for: indexURL, at: moment, attempt: 2).lastPathComponent,
            "library.json.unreadable-20260921T141320Z-2"
        )
        XCTAssertEqual(
            LibraryIndexQuarantine.copyURL(for: indexURL, at: moment).deletingLastPathComponent().path,
            directory.path
        )
    }

    /// Bytes that were read are written verbatim to an independent sibling
    /// file, and the original is left exactly as it was.
    func testReadableBytesAreCopiedVerbatimBesideTheIndex() throws {
        let bytes = Data(#"{"books":[{"title":"Half a"#.utf8)
        try bytes.write(to: indexURL)
        let originalInode = try inode(of: indexURL)

        let copy = try XCTUnwrap(LibraryIndexQuarantine.preserve(indexURL, bytes: bytes, now: moment))

        XCTAssertEqual(copy, LibraryIndexQuarantine.copyURL(for: indexURL, at: moment))
        XCTAssertEqual(try Data(contentsOf: copy), bytes)
        XCTAssertEqual(try Data(contentsOf: indexURL), bytes)
        XCTAssertEqual(try inode(of: indexURL), originalInode)
        XCTAssertNotEqual(try inode(of: copy), originalInode, "the copy must not share the index's storage")
    }

    /// Relaunching or pressing Try Again against the same damaged file reuses
    /// the copy already made instead of piling up duplicates.
    func testIdenticalBytesReuseTheEarlierCopy() throws {
        let bytes = Data("not json".utf8)
        try bytes.write(to: indexURL)

        let first = LibraryIndexQuarantine.preserve(indexURL, bytes: bytes, now: moment)
        let second = LibraryIndexQuarantine.preserve(indexURL, bytes: bytes, now: moment.addingTimeInterval(60))

        XCTAssertNotNil(first)
        XCTAssertEqual(second, first)
        XCTAssertEqual(LibraryIndexQuarantine.existingCopies(of: indexURL), [first].compactMap { $0 })
    }

    /// Different damaged contents get their own copy, and a copy made in the
    /// same second never overwrites the earlier one.
    func testChangedBytesGetANewCopyWithoutOverwritingTheFirst() throws {
        let firstBytes = Data("first damage".utf8)
        let secondBytes = Data("second damage".utf8)
        try firstBytes.write(to: indexURL)
        let first = try XCTUnwrap(LibraryIndexQuarantine.preserve(indexURL, bytes: firstBytes, now: moment))

        try secondBytes.write(to: indexURL)
        let second = try XCTUnwrap(LibraryIndexQuarantine.preserve(indexURL, bytes: secondBytes, now: moment))

        XCTAssertEqual(second, LibraryIndexQuarantine.copyURL(for: indexURL, at: moment, attempt: 2))
        XCTAssertEqual(try Data(contentsOf: first), firstBytes)
        XCTAssertEqual(try Data(contentsOf: second), secondBytes)
        XCTAssertEqual(LibraryIndexQuarantine.existingCopies(of: indexURL), [first, second])
    }

    /// A file that cannot be read is preserved by a hard link, which needs no
    /// read access and keeps the original contents after the index is later
    /// replaced by an atomic write, as Rebuild Library Index does.
    func testUnreadableFileIsPreservedByALinkThatOutlivesReplacement() throws {
        let bytes = Data(#"{"books":[],"folders":[]}"#.utf8)
        try bytes.write(to: indexURL)
        XCTAssertEqual(chmod(indexURL.path, 0o000), 0)
        XCTAssertThrowsError(try Data(contentsOf: indexURL), "the fixture must really be unreadable")

        let link = try XCTUnwrap(LibraryIndexQuarantine.preserve(indexURL, bytes: nil, now: moment))
        let again = LibraryIndexQuarantine.preserve(indexURL, bytes: nil, now: moment.addingTimeInterval(60))

        XCTAssertEqual(again, link, "a second attempt reuses the existing link")
        XCTAssertEqual(try inode(of: link), try inode(of: indexURL))
        try Data("rebuilt index".utf8).write(to: indexURL, options: .atomic)
        XCTAssertEqual(chmod(link.path, 0o644), 0)
        XCTAssertEqual(try Data(contentsOf: link), bytes)
    }

    /// A link shares the index's storage, so once the bytes can be read they
    /// are preserved again in an independent copy rather than trusting it.
    func testLinkedCopyDoesNotCountAsPreservingReadableBytes() throws {
        let bytes = Data("damaged but readable later".utf8)
        try bytes.write(to: indexURL)
        XCTAssertEqual(chmod(indexURL.path, 0o000), 0)
        let link = try XCTUnwrap(LibraryIndexQuarantine.preserve(indexURL, bytes: nil, now: moment))
        XCTAssertEqual(chmod(indexURL.path, 0o644), 0)

        let copy = try XCTUnwrap(LibraryIndexQuarantine.preserve(indexURL, bytes: bytes, now: moment))

        XCTAssertNotEqual(copy, link)
        XCTAssertNotEqual(try inode(of: copy), try inode(of: indexURL))
        XCTAssertEqual(try Data(contentsOf: copy), bytes)
    }

    /// A file that vanished before it could be preserved has nothing to keep.
    func testMissingFileHasNothingToPreserve() {
        XCTAssertNil(LibraryIndexQuarantine.preserve(indexURL, bytes: nil, now: moment))
        XCTAssertEqual(LibraryIndexQuarantine.existingCopies(of: indexURL), [])
    }

    /// Only this index's copies are listed, oldest first.
    func testExistingCopiesListsOnlyThisIndexOldestFirst() throws {
        let names = [
            "library.json.unreadable-20260101T000000Z",
            "library.json.unreadable-20250101T000000Z",
            "config.json.unreadable-20250101T000000Z",
            "library.json"
        ]
        for name in names {
            try Data().write(to: directory.appendingPathComponent(name))
        }

        XCTAssertEqual(
            LibraryIndexQuarantine.existingCopies(of: indexURL).map(\.lastPathComponent),
            ["library.json.unreadable-20250101T000000Z", "library.json.unreadable-20260101T000000Z"]
        )
    }

    /// The inode number of the item at `url`, read without opening it.
    private func inode(of url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.systemFileNumber] as? NSNumber).uint64Value
    }
}
