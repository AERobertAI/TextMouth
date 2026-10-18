import XCTest
@testable import TextMouth

/// A symbolic link to a document is sized and copied as the document it
/// points to (review item 5): the byte limit measures the target, so a link
/// to a huge file is refused before that file is read; textutil's sizing
/// measures the target, as textutil reads it; and an import stages the
/// target as a real file of the link's name, never the link, which would
/// point out of the package. Every file the tests link to is a copy in a
/// folder of the test's own.
final class DocumentLinkTests: XCTestCase {

    // MARK: - Helpers

    /// A symbolic link named `name` in a new folder of this test's own,
    /// pointing to `target` by its full path.
    private func link(named name: String, to target: URL) throws -> URL {
        let url = try makeSandboxDirectory("DocumentLink").appendingPathComponent(name)
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: target.path)
        return url
    }

    /// A symbolic link named `name` beside `target`, written as the target's
    /// bare name: a link of only a few bytes, shorter than any limit the
    /// tests bind, so only the target's size can show it too large.
    private func shortLink(named name: String, besides target: URL) throws -> URL {
        let url = target.deletingLastPathComponent().appendingPathComponent(name)
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: target.lastPathComponent)
        return url
    }

    /// A file named `name` holding `bytes`, in a new folder of its own.
    private func file(named name: String, holding bytes: Data) throws -> URL {
        let url = try makeSandboxDirectory("DocumentLinkTarget").appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    /// A file of `byteCount` bytes that nothing may read: the size of a file
    /// can be looked up without reading it, so a reader that sizes first
    /// refuses it with the limit's sentence, and one that reads first meets
    /// the file system's refusal instead. It is made readable again when the
    /// test ends, so the sandbox can be removed.
    private func unreadableFile(named name: String, byteCount: Int) throws -> URL {
        let url = try file(named: name, holding: Data(repeating: 65, count: byteCount))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        return url
    }

    // MARK: - The Byte Limit

    /// A link to a file past the limit is refused with the limit's sentence
    /// before the target is read. The link is a few bytes long, so only the
    /// target's size can refuse it; and the target cannot be read, so a
    /// reader that read it first would throw another error.
    func testALinkToAFilePastTheLimitIsRefusedBeforeTheTargetIsRead() throws {
        let target = try unreadableFile(named: "huge.ssml", byteCount: 100)
        let url = try shortLink(named: "s.ssml", besides: target)

        XCTAssertThrowsError(
            try DocumentByteLimit.$current.withValue(50) { try DocumentByteLimit.contents(of: url) }
        ) { error in
            XCTAssertEqual(error as? DocumentTooLargeError, DocumentTooLargeError(limit: 50))
            XCTAssertEqual(
                error.localizedDescription,
                "This document holds more than 50 bytes, the most TextMouth reads from one document."
            )
        }
    }

    /// A link to a file within the limit reads as that file, and a link to
    /// an empty file has no text to read, as the file itself has none.
    func testALinkReadsAsItsTarget() throws {
        let target = try file(named: "notes.ssml", holding: Data("0123456789".utf8))
        XCTAssertEqual(try DocumentByteLimit.contents(of: link(named: "notes.ssml", to: target)), Data("0123456789".utf8))

        let empty = try file(named: "empty.ssml", holding: Data())
        XCTAssertThrowsError(try DocumentByteLimit.contents(of: link(named: "empty.ssml", to: empty))) {
            XCTAssertEqual($0.localizedDescription, "This file has no text to read.")
        }
    }

    /// A link that points nowhere is a file that cannot be read, not one
    /// that reads as its own few bytes of path.
    func testALinkThatPointsNowhereCannotBeRead() throws {
        let missing = try makeSandboxDirectory("DocumentLinkMissing").appendingPathComponent("gone.ssml")
        let url = try link(named: "dangling.ssml", to: missing)

        XCTAssertThrowsError(try DocumentByteLimit.contents(of: url))
    }

    // MARK: - textutil's Sizing

    /// A link at the top is sized as its target, a file or a folder (an
    /// RTFD), since textutil follows it; a link inside a folder is still
    /// passed over.
    func testTextutilSizesALinkAsItsTarget() throws {
        let target = try file(named: "big.rtf", holding: Data(repeating: 65, count: 100))
        XCTAssertEqual(try TextutilConverter.documentSize(of: link(named: "short.rtf", to: target)), 100)

        let folder = try makeSandboxDirectory("DocumentLinkFolder").appendingPathComponent("doc.rtfd")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 66, count: 30).write(to: folder.appendingPathComponent("TXT.rtf"))
        // A link inside the folder to the big file is never counted.
        try FileManager.default.createSymbolicLink(
            atPath: folder.appendingPathComponent("Inner.rtf").path, withDestinationPath: target.path
        )
        XCTAssertEqual(try TextutilConverter.documentSize(of: link(named: "linked.rtfd", to: folder)), 30)
    }

    /// A link to a file past the limit is refused and textutil never runs:
    /// a stand-in that would leave a marker shows it did not.
    func testTextutilRefusesALinkToAFilePastTheLimitWithoutRunningIt() throws {
        let target = try file(named: "big.rtf", holding: Data(repeating: 65, count: 100))
        let url = try shortLink(named: "s.rtf", besides: target)
        let work = try makeSandboxDirectory("DocumentLinkWork")
        let marker = work.appendingPathComponent("marker")
        let spy = TextutilConverter.Tool(
            command: { _, _, _ in (URL(fileURLWithPath: "/usr/bin/touch"), [marker.path]) },
            limits: { TextutilConverter.limits(forBytes: $0) },
            residentMemory: { _ in nil }
        )

        try DocumentByteLimit.$current.withValue(50) {
            XCTAssertThrowsError(try TextutilConverter.html(of: url, as: .rtf, workingIn: work, using: spy)) {
                XCTAssertEqual($0 as? DocumentTooLargeError, DocumentTooLargeError(limit: 50))
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }
}
