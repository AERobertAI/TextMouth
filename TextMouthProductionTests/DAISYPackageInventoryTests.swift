import XCTest
@testable import TextMouth

/// A DAISY book kept as loose files is recognized by the file that stands
/// for it at the top of its folder: its package file (`.opf`) or its
/// navigation file (`ncc.html`) (TODO I02). A folder whose book lies in a
/// folder inside it is not itself a book, and an archive of several
/// packaged books is a batch of books rather than one. A book opens from
/// the file that stands for it.
final class DAISYPackageInventoryTests: XCTestCase {
    private typealias Fixtures = DAISYPackageFixtures

    // MARK: - Entry Files

    /// A folder's book is found by the file at its top level; the navigation
    /// file wins over a package file, as the reader prefers it; several
    /// package files are several books, in Finder's name order.
    func testEntryPointsAreTheFilesThatStandForBooksAtTheFolderTop() throws {
        let folder = try makeSandboxDirectory("daisy-entries")

        let navigationBook = try Fixtures.writeFolder(["ncc.html": "", "part1.smil": ""], named: "Navigation", in: folder)
        let packageBook = try Fixtures.writeFolder(["book.opf": "", "book.xml": ""], named: "Package", in: folder)
        let hybridBook = try Fixtures.writeFolder(["NCC.HTM": "", "book.opf": ""], named: "Hybrid", in: folder)
        let twoBooks = try Fixtures.writeFolder(["Volume 10.opf": "", "Volume 2.opf": ""], named: "Volumes", in: folder)

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
        let decoys = try Fixtures.writeFolder(["._book.opf": "", ".ncc.html": "", "notes.txt": ""], named: "Decoys", in: folder)
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
        let book = try Fixtures.writeFolder(Fixtures.navigationBook, named: "Rope Splicing", in: shelf)

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
        let zip = try makeTemporaryDAISYZip(entries: Fixtures.entries(Fixtures.navigationBook, inFolder: "Rope Splicing")
            .merging(Fixtures.entries(Fixtures.packageBook, inFolder: "Ferry Timetables")) { first, _ in first })
        addTeardownBlock { try? FileManager.default.removeItem(at: zip) }

        XCTAssertFalse(DAISYParser.isDAISYZip(url: zip))
    }

    /// An archive whose top level holds a book is that book, whatever its
    /// folders hold; macOS's `__MACOSX` copies never count as a second book.
    func testArchiveWithABookAtItsTopOrMacOSCopiesIsOneDAISYBook() throws {
        let topLevelBook = try makeTemporaryDAISYZip(entries: Fixtures.navigationBook
            .merging(Fixtures.entries(Fixtures.packageBook, inFolder: "Extras")) { first, _ in first })
        let withMacCopies = try makeTemporaryDAISYZip(entries: Fixtures.entries(Fixtures.navigationBook, inFolder: "Rope Splicing")
            .merging(["__MACOSX/Rope Splicing/._ncc.html": "", "__MACOSX/Other/._book.opf": ""]) { first, _ in first })
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
        let book = try Fixtures.writeFolder(Fixtures.navigationBook, named: "Rope Splicing", in: sandbox)
        let link = sandbox.appendingPathComponent("Link to Rope Splicing", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: book)

        for folder in [book, link] {
            XCTAssertEqual(DirectoryFileProvider(baseURL: folder).listFiles().sorted(), Fixtures.navigationBookFiles, folder.path)
            XCTAssertTrue(
                try Fixtures.spokenText(of: DAISYParser.extractMarkdown(from: folder))
                    .contains(Fixtures.navigationBookSentences[0]),
                folder.path
            )
        }
    }

    // MARK: - Opening a Book From Its Entry File

    /// A DAISY 2.02 book opens from its navigation file, which used to be
    /// refused as "not a DAISY book": its text, from every section, and its
    /// title and author are read from the files around it.
    func testBookOpensFromItsNavigationFile() throws {
        let book = try Fixtures.writeFolder(Fixtures.navigationBook, named: "Rope Splicing", in: makeSandboxDirectory("daisy-ncc"))
        let navigation = book.appendingPathComponent("ncc.html")

        let spoken = try Fixtures.spokenText(of: DAISYParser.extractMarkdown(from: navigation))
        let metadata = try XCTUnwrap(DAISYParser.readMetadata(from: navigation))

        for sentence in Fixtures.navigationBookSentences + Fixtures.navigationBookHeadings {
            XCTAssertTrue(spoken.contains(sentence), "missing “\(sentence)” in:\n\(spoken)")
        }
        XCTAssertEqual(metadata.title, "Notes on Rope Splicing")
        XCTAssertEqual(metadata.author, "Casimir Oyelaran")
        XCTAssertEqual(try BookParser.parse(url: navigation, format: .daisy).title, "Notes on Rope Splicing")
    }

    /// In a folder holding two books' package files, each book opens from
    /// its own package file, never from the other one beside it.
    func testBookOpensFromTheChosenPackageFile() throws {
        let almanac: [String: String] = [
            "almanac.opf": Fixtures.packageBook["book.opf", default: ""]
                .replacingOccurrences(of: "Ferry Timetables of the Outer Sound", with: "Harbor Almanac")
                .replacingOccurrences(of: "content/timetables.xml", with: "almanac.xml"),
            "almanac.xml": Fixtures.packageBook["content/timetables.xml", default: ""]
                .replacingOccurrences(of: "The first ferry leaves", with: "The almanac says the tide turns")
        ]
        let folder = try Fixtures.writeFolder(
            Fixtures.packageBook.merging(almanac) { first, _ in first },
            named: "Two Books",
            in: makeSandboxDirectory("daisy-two-opf")
        )

        for (package, title, sentence) in [
            ("book.opf", "Ferry Timetables of the Outer Sound", "The first ferry leaves"),
            ("almanac.opf", "Harbor Almanac", "The almanac says the tide turns")
        ] {
            let url = folder.appendingPathComponent(package)
            XCTAssertEqual(try DAISYParser.readMetadata(from: url)?.title, title, package)
            XCTAssertTrue(try Fixtures.spokenText(of: DAISYParser.extractMarkdown(from: url)).contains(sentence), package)
        }
    }

    // MARK: - Helpers

    /// The names of the files `DAISYParser.packageEntryPoints(in:)` finds in
    /// `folder`, in its order.
    private func entryNames(in folder: URL) -> [String] {
        DAISYParser.packageEntryPoints(in: folder).map(\.lastPathComponent)
    }
}
