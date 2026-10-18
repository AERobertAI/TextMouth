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
    /// The hosted test root's library index, put back after each test.
    private var sandbox: LibraryIndexSandbox?
    /// The library folder the import tests import into; each test has its own.
    private let folderPath = "Document Link \(UUID().uuidString.prefix(8))"

    override func setUpWithError() throws {
        sandbox = try LibraryIndexSandbox.capture()
    }

    override func tearDownWithError() throws {
        // Optional: tear-down also runs when set-up failed partway.
        sandbox?.restore()
        try? FileManager.default.removeItem(at: TextMouthPaths.libraryDir.appendingPathComponent(folderPath, isDirectory: true))
    }

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

    // MARK: - Importing a Linked Document

    /// The kind of file system item at `url`, never following a link: a
    /// link reports as a link, whatever it points to.
    private func itemType(at url: URL) throws -> FileAttributeType? {
        try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
    }

    /// Every symbolic link anywhere inside `folder`, hidden ones included,
    /// as paths relative to it.
    private func links(inside folder: URL) -> [String] {
        // The enumerator's paths are relative to the folder, so they do not
        // depend on how the temporary directory's own path is spelled.
        let paths = FileManager.default.enumerator(atPath: folder.path)?.allObjects as? [String] ?? []
        return paths.filter { (try? itemType(at: folder.appendingPathComponent($0))) == .typeSymbolicLink }.sorted()
    }

    /// A link to an RTF imports as the RTF: the package holds a real file,
    /// named as the link was, with the RTF's own bytes, and the book opens
    /// with the RTF's headings.
    func testALinkToAnRTFImportsAsARegularFileWithTheRTFsBytes() throws {
        let target = try copyOfFormatSample("rtf/headings.rtf")
        let linked = try link(named: "Linked Notes.rtf", to: target)

        let book = try importedForTest(linked).book

        let staged = URL(fileURLWithPath: book.filePath)
        XCTAssertEqual(staged.lastPathComponent, "Linked Notes.rtf")
        XCTAssertEqual(try itemType(at: staged), .typeRegular)
        XCTAssertEqual(try Data(contentsOf: staged), try Data(contentsOf: target))
        XCTAssertEqual(links(inside: book.tmbDirectory), [])
        XCTAssertEqual(
            headingLines(of: try openedContent(of: book)),
            ["1: Harbour Notes", "2: Morning Tides", "2: Timetable"]
        )
    }

    /// A link to an SSML file imports with the file's words, held as a real
    /// file in the package.
    func testALinkToAnSSMLFileImportsWithItsWords() throws {
        let target = try copyOfFormatSample("ssml/passage.ssml")
        let linked = try link(named: "Linked Passage.ssml", to: target)

        let book = try importedForTest(linked).book

        XCTAssertEqual(try itemType(at: URL(fileURLWithPath: book.filePath)), .typeRegular)
        let text = allText(of: try openedContent(of: book))
        XCTAssertTrue(text.contains("The ferry leaves at 9:30am."), text)
        XCTAssertTrue(text.contains("World Wide Web Consortium"), text)
    }

    /// An RTFD that holds a link to a file outside it still imports, and
    /// its staged copy holds no link: the link may point anywhere on the
    /// disk, and the package must hold only what is in it.
    func testAnRTFDWithALinkToAFileOutsideImportsWithoutTheLink() throws {
        let copy = try copyOfFormatSample("rtfd/headings.rtfd")
        let outside = try file(named: "Outside.txt", holding: Data("not part of the book".utf8))
        try FileManager.default.createSymbolicLink(
            atPath: copy.appendingPathComponent("Outside.txt").path, withDestinationPath: outside.path
        )
        // The copy that is imported does hold the link, or the test shows nothing.
        XCTAssertEqual(links(inside: copy), ["Outside.txt"])

        let book = try importedForTest(copy).book

        XCTAssertEqual(links(inside: book.tmbDirectory), [])
        XCTAssertEqual(try itemType(at: URL(fileURLWithPath: book.filePath)), .typeDirectory)
        XCTAssertEqual(
            headingLines(of: try openedContent(of: book)),
            ["1: Harbour Notes", "2: Morning Tides", "2: Timetable"]
        )
    }

    /// A link to a document past the limit is refused as the document is,
    /// with the import's words and the limit's sentence, and leaves nothing
    /// in the library.
    func testALinkToADocumentPastTheLimitIsRefusedByTheImport() throws {
        let target = try copyOfFormatSample("rtf/headings.rtf")
        let linked = try shortLink(named: "s.rtf", besides: target)

        XCTAssertThrowsError(
            try DocumentByteLimit.$current.withValue(100) {
                try FileImportService.importFileWithReport(from: linked, toFolder: folderPath)
            }
        ) {
            XCTAssertEqual(
                $0.localizedDescription,
                "Could not import “s.rtf”. Reading its text failed: "
                    + "This document holds more than 100 bytes, the most TextMouth reads from one document."
            )
        }
        let folder = TextMouthPaths.libraryDir.appendingPathComponent(folderPath, isDirectory: true)
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [], [])
    }
}
