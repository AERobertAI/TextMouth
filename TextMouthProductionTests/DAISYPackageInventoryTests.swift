import XCTest
@testable import TextMouth

/// A DAISY book kept as loose files is recognized by the file that stands
/// for it at the top of its folder: its package file (`.opf`) or its
/// navigation file (`ncc.html`) (TODO I02). A folder whose book lies in a
/// folder inside it is not itself a book, and an archive of several
/// packaged books is a batch of books rather than one.
final class DAISYPackageInventoryTests: XCTestCase {

    // MARK: - Entry Files

    /// A folder's book is found by the file at its top level; the navigation
    /// file wins over a package file, as the reader prefers it; several
    /// package files are several books, in Finder's name order.
    func testEntryPointsAreTheFilesThatStandForBooksAtTheFolderTop() throws {
        let folder = try makeSandboxDirectory("daisy-entries")

        let navigationBook = try write(["ncc.html": "", "part1.smil": ""], in: folder, "Navigation")
        let packageBook = try write(["book.opf": "", "book.xml": ""], in: folder, "Package")
        let hybridBook = try write(["NCC.HTM": "", "book.opf": ""], in: folder, "Hybrid")
        let twoBooks = try write(["Volume 10.opf": "", "Volume 2.opf": ""], in: folder, "Volumes")

        XCTAssertEqual(entryNames(in: navigationBook), ["ncc.html"])
        XCTAssertEqual(entryNames(in: packageBook), ["book.opf"])
        XCTAssertEqual(entryNames(in: hybridBook), ["NCC.HTM"])
        XCTAssertEqual(entryNames(in: twoBooks), ["Volume 2.opf", "Volume 10.opf"])
    }

    /// Hidden files (the `._book.opf` copies macOS leaves in archives) and
    /// folders named like package files are never books; neither is a file,
    /// nor a folder holding only other files.
    func testHiddenFilesAndFoldersNamedLikePackagesAreNotBooks() throws {
        let folder = try makeSandboxDirectory("daisy-not-entries")
        let decoys = try write(["._book.opf": "", ".ncc.html": "", "notes.txt": ""], in: folder, "Decoys")
        try FileManager.default.createDirectory(
            at: decoys.appendingPathComponent("folder.opf", isDirectory: true),
            withIntermediateDirectories: true
        )

        XCTAssertEqual(entryNames(in: decoys), [])
        XCTAssertEqual(entryNames(in: decoys.appendingPathComponent("notes.txt")), [])
        XCTAssertFalse(DAISYParser.isDAISYDirectory(url: decoys))
    }

    /// Only a folder with the book's file at its top level is a DAISY
    /// folder. The folder that holds it is not, so a folder of several books
    /// is never taken for one of them.
    func testOnlyTheFolderWithTheBookAtItsTopIsADAISYDirectory() throws {
        let shelf = try makeSandboxDirectory("daisy-shelf")
        let book = try write(["ncc.html": "", "part1.smil": ""], in: shelf, "Rope Splicing")

        XCTAssertTrue(DAISYParser.isDAISYDirectory(url: book))
        XCTAssertFalse(DAISYParser.isDAISYDirectory(url: shelf))
    }

    // MARK: - Archives

    /// Each bundled DAISY archive is one book, whether its files fill the
    /// archive's top level or a folder inside it.
    func testBundledDAISYArchivesAreEachOneBook() throws {
        for name in ["daisy202_test.zip", "hyperion_daisy.zip", "lathe_of_heaven_daisy.zip", "wipo-treaty-d202-text-only.zip"] {
            XCTAssertTrue(DAISYParser.isDAISYZip(url: try requireFile(name)), name)
        }
    }

    /// An archive holding two packaged books, each in a folder of its own,
    /// is a batch of books, not one DAISY book.
    func testArchiveOfTwoPackagedBooksIsNotOneDAISYBook() throws {
        let zip = try makeTemporaryDAISYZip(entries: [
            "Rope Splicing/ncc.html": Self.minimalNCC,
            "Ferry Timetables/book.opf": Self.minimalOPF
        ])
        addTeardownBlock { try? FileManager.default.removeItem(at: zip) }

        XCTAssertFalse(DAISYParser.isDAISYZip(url: zip))
    }

    /// An archive whose top level holds a book is that book, whatever its
    /// folders hold; macOS's `__MACOSX` copies never count as a second book.
    func testArchiveWithABookAtItsTopOrMacOSCopiesIsOneDAISYBook() throws {
        let topLevelBook = try makeTemporaryDAISYZip(entries: [
            "ncc.html": Self.minimalNCC,
            "Extras/book.opf": Self.minimalOPF
        ])
        let withMacCopies = try makeTemporaryDAISYZip(entries: [
            "Rope Splicing/ncc.html": Self.minimalNCC,
            "__MACOSX/Rope Splicing/._ncc.html": "",
            "__MACOSX/Other/._book.opf": ""
        ])
        addTeardownBlock {
            try? FileManager.default.removeItem(at: topLevelBook)
            try? FileManager.default.removeItem(at: withMacCopies)
        }

        XCTAssertTrue(DAISYParser.isDAISYZip(url: topLevelBook))
        XCTAssertTrue(DAISYParser.isDAISYZip(url: withMacCopies))
    }

    // MARK: - Listing a Folder

    /// A folder's files are listed by their paths inside it wherever the
    /// folder lies, even when its path passes through a symbolic link (the
    /// sandbox's own path does, through /var), and a book there reads.
    func testFolderListsItsFilesRelativeToItselfThroughSymbolicLinks() throws {
        let sandbox = try makeSandboxDirectory("daisy-listing")
        let book = try write([
            "ncc.html": Self.minimalNCC,
            "part1.smil": Self.minimalSMIL,
            "text/part1.html": Self.minimalText
        ], in: sandbox, "Rope Splicing")
        let link = sandbox.appendingPathComponent("Link to Rope Splicing", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: book)

        for folder in [book, link] {
            XCTAssertEqual(
                DirectoryFileProvider(baseURL: folder).listFiles().sorted(),
                ["ncc.html", "part1.smil", "text/part1.html"],
                folder.path
            )
            XCTAssertTrue(try DAISYParser.extractMarkdown(from: folder).contains("Unlay the strands"), folder.path)
        }
    }

    // MARK: - Fixtures

    /// The smallest DAISY 2.02 navigation file: a title and one heading.
    static let minimalNCC = """
    <html><head><meta name="dc:title" content="Notes on Rope Splicing"/></head>
    <body><h1><a href="part1.smil#p1">Short Splice</a></h1></body></html>
    """

    /// The smallest SMIL file: the heading's one text fragment.
    static let minimalSMIL = """
    <?xml version="1.0" encoding="utf-8"?>
    <smil><body><seq><par id="p1"><text src="text/part1.html#t1"/></par></seq></body></smil>
    """

    /// The smallest DAISY 2.02 text file: the fragment the SMIL file names.
    static let minimalText = """
    <html><body><p id="t1">Unlay the strands for twelve turns before tucking them against the lay.</p></body></html>
    """

    /// The smallest DAISY 3 package file: a title and one DTBook.
    static let minimalOPF = """
    <?xml version="1.0" encoding="UTF-8"?>
    <package xmlns="http://openebook.org/namespaces/oeb-package/1.0/">
    <metadata><dc-metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:Title>Ferry Timetables of the Outer Sound</dc:Title>
    </dc-metadata></metadata>
    <manifest><item id="text" href="book.xml" media-type="application/x-dtbook+xml"/></manifest>
    <spine><itemref idref="text"/></spine>
    </package>
    """

    /// Writes `files` (path inside the folder → text) into a new folder
    /// named `name` inside `parent`, and returns the folder.
    @discardableResult
    func write(_ files: [String: String], in parent: URL, _ name: String) throws -> URL {
        let folder = parent.appendingPathComponent(name, isDirectory: true)
        for (path, text) in files {
            let file = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(text.utf8).write(to: file)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// The names of the files `DAISYParser.packageEntryPoints(in:)` finds in
    /// `folder`, in its order.
    private func entryNames(in folder: URL) -> [String] {
        DAISYParser.packageEntryPoints(in: folder).map(\.lastPathComponent)
    }
}
