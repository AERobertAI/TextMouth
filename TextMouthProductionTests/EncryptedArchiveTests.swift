import XCTest
import ZIPFoundation
@testable import TextMouth

/// A ZIP archive with a password is refused in words that say so, never
/// imported empty or short (B27). ZIPFoundation 0.9.20 returns no entry for an
/// encrypted one and ends its listing there, so these tests make the archives
/// themselves, with the encrypted flag set on chosen members.
final class EncryptedArchiveTests: XCTestCase {

    /// The folder this test's files are made in, in the temporary directory.
    private var folder = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("EncryptedArchiveTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// A ZIP of stored text files named `names`, the ones in `locked` marked encrypted.
    private func makeZip(_ names: [String], locked: [String], file: String = "book.zip") throws -> URL {
        let made = try makeTemporaryZip(
            prefix: "encrypted",
            orderedEntries: names.map { TestZIPEntry($0, Data("words in \($0)".utf8)) }
        )
        let url = folder.appendingPathComponent(file)
        try FileManager.default.moveItem(at: made, to: url)
        try markEncrypted(locked, in: url)
        return url
    }

    // MARK: - Detection

    /// Every entry locked: the guard names them all, though ZIPFoundation lists none.
    func testAnArchiveWhoseEntriesAreAllLockedNamesThemAll() throws {
        let url = try makeZip(["a.txt", "b.txt"], locked: ["a.txt", "b.txt"])
        XCTAssertEqual(Array(try Archive(url: url, accessMode: .read)).count, 0, "the premise of B27: ZIPFoundation sees nothing")
        XCTAssertEqual(EncryptedArchiveGuard.encryptedNames(inFileAt: url), ["a.txt", "b.txt"])
    }

    /// A locked entry part way through: the entries after it are invisible to
    /// ZIPFoundation, and the guard still finds it.
    func testALockedEntryPartWayThroughIsFound() throws {
        let url = try makeZip(["one.txt", "two.txt", "three.txt"], locked: ["two.txt"])
        XCTAssertEqual(Array(try Archive(url: url, accessMode: .read)).count, 1, "the premise of B27: the listing is cut short")
        XCTAssertEqual(EncryptedArchiveGuard.encryptedNames(inFileAt: url), ["two.txt"])
    }

    /// An archive with no password passes, and the guard throws nothing.
    func testAnArchiveWithoutAPasswordPasses() throws {
        let url = try makeZip(["a.txt", "b.txt"], locked: [])
        XCTAssertEqual(EncryptedArchiveGuard.encryptedNames(inFileAt: url), [])
        XCTAssertNoThrow(try EncryptedArchiveGuard.refuseEncrypted(at: url))
    }

    /// A folder flagged encrypted counts too: ZIPFoundation ends its listing at it.
    func testAnEncryptedFolderEntryIsFound() throws {
        let made = try makeTemporaryZip(prefix: "encrypted", orderedEntries: [.folder("dir/"), TestZIPEntry("dir/a.txt", Data("x".utf8))])
        let url = folder.appendingPathComponent("folder.zip")
        try FileManager.default.moveItem(at: made, to: url)
        try markEncrypted(["dir/"], in: url)
        XCTAssertEqual(EncryptedArchiveGuard.encryptedNames(inFileAt: url), ["dir/"])
    }

    /// Bytes after the end record (padding, a signature) do not hide the directory.
    func testTrailingBytesAfterTheEndRecordDoNotHideIt() throws {
        let url = try makeZip(["a.txt"], locked: ["a.txt"])
        let padded = folder.appendingPathComponent("padded.zip")
        try (try Data(contentsOf: url) + Data(repeating: 0, count: 40)).write(to: padded)
        XCTAssertEqual(EncryptedArchiveGuard.encryptedNames(inFileAt: padded), ["a.txt"])
    }

    /// A file that is not a ZIP, a ZIP cut short, and a missing file name nothing and throw nothing:
    /// the readers report such files in their own words.
    func testFilesThatAreNotArchivesNameNothing() throws {
        let text = folder.appendingPathComponent("plain.zip")
        try Data("not a zip at all, only text".utf8).write(to: text)
        let tiny = folder.appendingPathComponent("tiny.zip")
        try Data([0x50, 0x4B]).write(to: tiny)
        let whole = try makeZip(["a.txt"], locked: ["a.txt"], file: "whole.zip")
        let cut = folder.appendingPathComponent("cut.zip")
        try Data(try Data(contentsOf: whole).dropLast(10)).write(to: cut)
        let missing = folder.appendingPathComponent("missing.zip")
        for url in [text, tiny, cut, missing] {
            XCTAssertEqual(EncryptedArchiveGuard.encryptedNames(inFileAt: url), [], url.lastPathComponent)
            XCTAssertNoThrow(try EncryptedArchiveGuard.refuseEncrypted(at: url), url.lastPathComponent)
        }
    }

    /// A central directory that claims more entries than its bytes hold,
    /// or one that lies about where it is, is refused without a trap.
    func testALyingDirectoryNamesNothing() throws {
        let url = try makeZip(["a.txt"], locked: ["a.txt"])
        var bytes = [UInt8](try Data(contentsOf: url))
        // The end record is the last 22 bytes (no comment); its total count
        // is 2 bytes at offset 10 and the directory's offset 4 bytes at 16.
        let end = bytes.count - 22
        bytes[end + 10] = 0xFE
        bytes[end + 11] = 0x00
        let lying = folder.appendingPathComponent("lying.zip")
        try Data(bytes).write(to: lying)
        XCTAssertEqual(EncryptedArchiveGuard.encryptedNames(inFileAt: lying), [])
        // The directory's offset pointing past the file's end.
        bytes[end + 10] = 0x01
        bytes[end + 16] = 0xFF
        bytes[end + 17] = 0xFF
        bytes[end + 18] = 0xFF
        bytes[end + 19] = 0x7F
        let beyond = folder.appendingPathComponent("beyond.zip")
        try Data(bytes).write(to: beyond)
        XCTAssertEqual(EncryptedArchiveGuard.encryptedNames(inFileAt: beyond), [])
    }

    /// A comment after the end record does not hide it.
    func testAnArchiveCommentDoesNotHideTheEndRecord() throws {
        let url = try makeZip(["a.txt"], locked: ["a.txt"])
        var bytes = [UInt8](try Data(contentsOf: url))
        let comment = Array("a comment, with PK look-alikes".utf8)
        // The comment's length is the last 2 bytes of the end record.
        let end = bytes.count - 22
        bytes[end + 20] = UInt8(comment.count)
        bytes += comment
        let commented = folder.appendingPathComponent("commented.zip")
        try Data(bytes).write(to: commented)
        XCTAssertEqual(EncryptedArchiveGuard.encryptedNames(inFileAt: commented), ["a.txt"])
    }

    // MARK: - The words

    /// The sentence names a few files, and counts the rest.
    func testTheRefusalNamesTheFilesItCouldNotRead() {
        let few = EncryptedArchiveError(names: ["a.txt", "b.txt"]).errorDescription ?? ""
        XCTAssertTrue(few.contains("password"), few)
        XCTAssertFalse(few.contains("can't open"), "it says the ZIP needs a password, not what TextMouth cannot do: \(few)")
        XCTAssertTrue(few.contains("“a.txt”") && few.contains("“b.txt”"), few)
        let many = EncryptedArchiveError(names: ["a", "b", "c", "d", "e"]).errorDescription ?? ""
        XCTAssertTrue(many.contains("“a”") && many.contains("“c”"), many)
        XCTAssertFalse(many.contains("“d”"), many)
        XCTAssertTrue(many.contains("and others"), many)
        XCTAssertFalse(few.contains("others"), few)
    }

    /// The debug log keeps the count, and no file's name.
    func testTheLogLineHoldsNoNames() {
        let line = EncryptedArchiveError(names: ["secret-plans.txt"]).logDescription
        XCTAssertFalse(line.contains("secret-plans"), line)
        XCTAssertTrue(line.contains("1"), line)
    }

    // MARK: - Every reader of a ZIP refuses

    /// An import's extraction refuses the archive, rather than extracting nothing.
    func testExtractionRefusesAnArchiveWithAPassword() throws {
        let url = try makeZip(["a.txt", "b.txt"], locked: ["b.txt"])
        let destination = folder.appendingPathComponent("out")
        XCTAssertThrowsError(try ArchiveExtractor.extract(archiveAt: url, into: destination, budget: ArchiveBudget())) { error in
            XCTAssertEqual((error as? EncryptedArchiveError)?.names, ["b.txt"])
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("a.txt").path), "nothing is half-imported")
    }

    /// An EPUB, a Word document, a DAISY ZIP, and a comic book archive with a
    /// password each refuse with the same words.
    func testEveryBookReaderRefusesAnArchiveWithAPassword() throws {
        let epub = try makeZip(["mimetype", "META-INF/container.xml"], locked: ["META-INF/container.xml"], file: "book.epub")
        XCTAssertThrowsError(try EPUBParser.readMetadata(url: epub)) { XCTAssertTrue($0 is EncryptedArchiveError, "\($0)") }
        let docx = try makeZip(["[Content_Types].xml", "word/document.xml"], locked: ["word/document.xml"], file: "book.docx")
        XCTAssertThrowsError(try DOCXParser.parse(url: docx)) { XCTAssertTrue($0 is PasswordProtectedDocument, "\($0)") }
        let daisy = try makeZip(["ncc.html", "a.smil"], locked: ["ncc.html"], file: "daisy.zip")
        XCTAssertThrowsError(try DAISYParser.parse(url: daisy)) { XCTAssertTrue($0 is EncryptedArchiveError, "\($0)") }
        let comic = try makeZip(["001.png", "002.png"], locked: ["001.png", "002.png"], file: "book.cbz")
        XCTAssertThrowsError(try PageImageArchive(url: comic)) { XCTAssertTrue($0 is EncryptedArchiveError, "\($0)") }
    }
}
