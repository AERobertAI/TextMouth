import CryptoKit
import XCTest
import ZIPFoundation
@testable import TextMouth

/// A DAISY book kept as loose files is recognized by the file that stands
/// for it at the top of its folder: its package file (`.opf`) or its
/// navigation file (`ncc.html`) (TODO I02). A folder whose book lies in a
/// folder inside it is not itself a book, and an archive of several
/// packaged books is a batch of books rather than one. A book opens from
/// the file that stands for it, and its inventory lists exactly the files
/// it needs, all inside its folder.
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

    /// A file that cannot be opened as a ZIP archive, whether it holds
    /// something else (here a navigation file on its own) or is not there at
    /// all, is never a DAISY archive: the check answers false rather than
    /// failing (TODO Q06 pins this before the archive is opened through
    /// another initializer).
    func testFileThatCannotBeOpenedAsAnArchiveIsNotADAISYArchive() throws {
        let folder = try makeSandboxDirectory("daisy-not-archives")
        let notAnArchive = folder.appendingPathComponent("Rope Splicing.zip")
        try Data(Fixtures.navigationBook["ncc.html", default: ""].utf8).write(to: notAnArchive)

        XCTAssertFalse(DAISYParser.isDAISYZip(url: notAnArchive))
        XCTAssertFalse(DAISYParser.isDAISYZip(url: folder.appendingPathComponent("Missing.zip")))
    }

    /// A file whose extension is neither an archive's nor a DAISY entry
    /// file's is tried as an archive, since some DAISY archives carry other
    /// names: one that opens is read as the book it holds, and one that does
    /// not open is not a DAISY book (TODO Q06 pins this before the archive
    /// is opened through another initializer).
    func testFileWithAnotherExtensionIsReadAsAnArchiveOnlyWhenItIsOne() throws {
        let folder = try makeSandboxDirectory("daisy-other-extensions")
        let zip = try makeTemporaryDAISYZip(entries: Fixtures.navigationBook)
        addTeardownBlock { try? FileManager.default.removeItem(at: zip) }
        let archive = folder.appendingPathComponent("Rope Splicing.dtb")
        try FileManager.default.copyItem(at: zip, to: archive)
        let notAnArchive = folder.appendingPathComponent("Harbor Notes.dtb")
        try Data("Unlay the strands for twelve turns.".utf8).write(to: notAnArchive)

        XCTAssertEqual(try DAISYParser.readMetadata(from: archive)?.title, "Notes on Rope Splicing")
        XCTAssertThrowsError(try DAISYParser.readMetadata(from: notAnArchive)) { error in
            guard case DAISYParserError.notDAISYBook = error else {
                return XCTFail("expected notDAISYBook, got \(error)")
            }
        }
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
        let folder = try Fixtures.writeFolder(Fixtures.twoBooksFolder, named: "Two Books", in: makeSandboxDirectory("daisy-two-opf"))

        for (package, title, sentence) in [
            ("book.opf", "Ferry Timetables of the Outer Sound", "The first ferry leaves"),
            ("almanac.opf", "Harbor Almanac", Fixtures.almanacSentence)
        ] {
            let url = folder.appendingPathComponent(package)
            XCTAssertEqual(try DAISYParser.readMetadata(from: url)?.title, title, package)
            XCTAssertTrue(try Fixtures.spokenText(of: DAISYParser.extractMarkdown(from: url)).contains(sentence), package)
        }
    }

    // MARK: - Inventory

    /// A DAISY 3 book's files are its package file and what its manifest
    /// lists, with `%20` decoded, whether the book is chosen by its folder
    /// or by its package file. The notes, the DTD, the audio nothing lists,
    /// and the hidden file beside it are not the book's.
    func testPackageFileInventoryIsWhatTheManifestLists() throws {
        let book = try Fixtures.writeFolder(
            Fixtures.files(Fixtures.packageBook, changing: Fixtures.unrelatedFiles),
            named: "Ferry Timetables",
            in: makeSandboxDirectory("daisy-opf-inventory")
        )

        for source in [book, book.appendingPathComponent("book.opf")] {
            let inventory = try DAISYPackageInventory.make(for: source)

            XCTAssertEqual(inventory.paths, Fixtures.packageBookFiles, source.lastPathComponent)
            XCTAssertEqual(inventory.entryPath, "book.opf")
            XCTAssertEqual(inventory.root.path, book.path)
            XCTAssertEqual(inventory.missingPaths, [])
            XCTAssertNil(inventory.wholeFolderReason)
            XCTAssertNil(inventory.untitledName)
        }
    }

    /// A DAISY 2.02 book's files are its navigation file, the SMIL files it
    /// links to (a page number's link included), the text and audio files
    /// they synchronize, and the style sheets and images those files use.
    /// A web address in the navigation is no file, and a book named only by
    /// its ncc.html is listed under its folder's name.
    func testNavigationFileInventoryFollowsTheBooksReferences() throws {
        let book = try Fixtures.writeFolder(
            Fixtures.files(Fixtures.navigationBook, changing: Fixtures.unrelatedFiles),
            named: "Rope Splicing",
            in: makeSandboxDirectory("daisy-ncc-inventory")
        )

        for source in [book, book.appendingPathComponent("ncc.html")] {
            let inventory = try DAISYPackageInventory.make(for: source)

            XCTAssertEqual(inventory.paths, Fixtures.navigationBookFiles, source.lastPathComponent)
            XCTAssertEqual(inventory.entryPath, "ncc.html")
            XCTAssertEqual(inventory.missingPaths, [])
            XCTAssertNil(inventory.wholeFolderReason)
            XCTAssertEqual(inventory.untitledName, "Rope Splicing")
        }
    }

    /// The bundled DAISY books' inventories, pinned: each lists exactly the
    /// files its book needs. Neither DAISY 3 manifest lists the DTBook DTD
    /// lying beside it, and no reader loads that DTD.
    func testBundledBookInventoriesArePinned() throws {
        let shelf = try makeSandboxDirectory("daisy-bundled")
        let books: [(archive: String, folder: String, entry: String, files: [String])] = [
            (
                "daisy202_test.zip", "", "ncc.html",
                ["ncc.html", "content001.smil", "content002.smil", "content.html", "content2.html"]
            ),
            (
                "wipo-treaty-d202-text-only.zip", "WIPO-Treaty-D202Fileset", "ncc.html",
                ["ncc.html", "default.css", "WIPOTreatyForVisuallyImpaired.html"] + (1...23).map { "d202_\($0).smil" }
            ),
            (
                "hyperion_daisy.zip", "", "hyperion_Dan_Simmons_202109_daisy.opf",
                [
                    "hyperion_Dan_Simmons_202109_daisy.opf", "hyperion_Dan_Simmons_202109_daisy.xml",
                    "hyperion_Dan_Simmons_202109_daisy.ncx", "hyperion_Dan_Simmons_202109_daisy.smil",
                    "daisyTransform.xsl", "daisy.css", "html.css", "resource.res"
                ]
            ),
            (
                "lathe_of_heaven_daisy.zip", "", "The_Lathe_of_Heaven.opf",
                [
                    "The_Lathe_of_Heaven.opf", "The_Lathe_of_Heaven.xml", "The_Lathe_of_Heaven.ncx",
                    "The_Lathe_of_Heaven00001.smil", "The_Lathe_of_Heaven00002.smil", "The_Lathe_of_Heaven00003.smil",
                    "images/twitter.png", "images/facebook.png", "images/newsletter.png",
                    "images/thelatheofheaven_1400.jpg", "daisyTransform.xsl", "daisy.css", "html.css"
                ]
            )
        ]

        for book in books {
            let extracted = shelf.appendingPathComponent(book.archive, isDirectory: true)
            try FileManager.default.unzipItem(at: try requireFile(book.archive), to: extracted)
            let folder = book.folder.isEmpty ? extracted : extracted.appendingPathComponent(book.folder, isDirectory: true)

            let inventory = try DAISYPackageInventory.make(for: folder)

            XCTAssertEqual(inventory.entryPath, book.entry, book.archive)
            XCTAssertEqual(inventory.paths, book.files.sorted(), book.archive)
            XCTAssertEqual(inventory.missingPaths, [], book.archive)
            XCTAssertNil(inventory.wholeFolderReason, book.archive)
        }
    }

    /// A file the book refers to that does not exist is noted and left out,
    /// and so is what only a missing SMIL file would have led to; the rest
    /// of the book is listed as usual.
    func testMissingReferencedFilesAreNotedAndLeftOut() throws {
        let book = try Fixtures.writeFolder(
            Fixtures.files(Fixtures.navigationBook, removing: ["images/eye splice.png", "smil/part2.smil"]),
            named: "Rope Splicing",
            in: makeSandboxDirectory("daisy-missing")
        )

        let inventory = try DAISYPackageInventory.make(for: book)

        XCTAssertEqual(
            inventory.paths,
            Fixtures.navigationBookFiles.filter { !["images/eye splice.png", "smil/part2.smil", "audio/part2.mp3"].contains($0) }
        )
        XCTAssertEqual(inventory.missingPaths, ["images/eye splice.png", "smil/part2.smil"])
        XCTAssertNil(inventory.wholeFolderReason)
    }

    /// A book whose files cannot be listed from its references is taken
    /// whole: a package file cut short, a manifest naming no DTBook (the
    /// reader then searches the folder for one), or a damaged SMIL file.
    /// Hidden files stay out, and the reason names what could not be read.
    func testBookWhoseFilesCannotBeListedIsTakenWhole() throws {
        let shelf = try makeSandboxDirectory("daisy-whole-folder")
        let opf = Fixtures.packageBook["book.opf", default: ""]
        let cases: [(name: String, files: [String: String], reason: String)] = [
            (
                "Package Cut Short",
                Fixtures.files(Fixtures.packageBook, changing: ["book.opf": Fixtures.truncated(opf, before: "<spine>")]),
                "“book.opf”"
            ),
            (
                "Manifest Without DTBook",
                Fixtures.files(Fixtures.packageBook, changing: [
                    "book.opf": opf.replacingOccurrences(of: "application/x-dtbook+xml", with: "text/xml")
                ]),
                "lists no DTBook content file"
            ),
            (
                "Damaged SMIL",
                Fixtures.files(Fixtures.navigationBook, changing: [
                    "smil/part2.smil": Fixtures.truncated(Fixtures.navigationBook["smil/part2.smil", default: ""], before: "</par>")
                ]),
                "“smil/part2.smil”"
            )
        ]

        for (name, files, reason) in cases {
            let allFiles = Fixtures.files(files, changing: Fixtures.unrelatedFiles)
            let book = try Fixtures.writeFolder(allFiles, named: name, in: shelf)

            let inventory = try DAISYPackageInventory.make(for: book)

            XCTAssertEqual(inventory.paths, allFiles.keys.filter { !$0.hasPrefix(".") }.sorted(), name)
            XCTAssertTrue(inventory.wholeFolderReason?.contains(reason) == true, "\(name): \(inventory.wholeFolderReason ?? "nil")")
            XCTAssertEqual(inventory.missingPaths, [], name)
        }
    }

    /// A book's copy in a TextMouth package has the book's own inventory and
    /// checksum, whether its files were listed or taken whole: the record,
    /// text cache, audio cache, and removal marker TextMouth keeps beside a
    /// book, and hidden files, are never part of it.
    func testLibraryCopyOfABookHasTheBooksInventoryAndChecksum() throws {
        let shelf = try makeSandboxDirectory("daisy-library-copy")
        let opf = Fixtures.packageBook["book.opf", default: ""]
        let books: [(name: String, files: [String: String])] = [
            ("Ferry Timetables", Fixtures.files(Fixtures.packageBook, changing: Fixtures.unrelatedFiles)),
            ("Rope Splicing", Fixtures.files(Fixtures.navigationBook, changing: Fixtures.unrelatedFiles)),
            ("Cut Short", Fixtures.files(
                Fixtures.packageBook,
                changing: Fixtures.unrelatedFiles.merging(["book.opf": Fixtures.truncated(opf, before: "<spine>")]) { _, cut in cut }
            ))
        ]

        for (name, files) in books {
            let source = try Fixtures.writeFolder(files, named: name, in: shelf)
            let inventory = try DAISYPackageInventory.make(for: source)
            let package = shelf.appendingPathComponent("\(name).tmb", isDirectory: true)
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)

            let copiedEntry = try inventory.copyFiles(into: package)
            try Fixtures.writeFolder([
                "bookInfo.json": "{}",
                "content.md": "# Cached text",
                "cachedAudio/0001.caf": "rendered speech",
                TextMouthPaths.removedFromLibraryMarkerName: "{}",
                ".DS_Store": "Finder's view settings"
            ], named: package.lastPathComponent, in: shelf)
            let copied = try DAISYPackageInventory.make(for: copiedEntry)

            XCTAssertEqual(copiedEntry.lastPathComponent, inventory.entryPath, name)
            XCTAssertEqual(copied.paths, inventory.paths, name)
            XCTAssertEqual(try copied.contentHash(), try inventory.contentHash(), name)
        }
    }

    /// The checksum follows its stated rule: the MD5 digest of the entry
    /// file's MD5 digest, followed for each file in path order by a NUL, the
    /// path, a NUL, and the size. A copy elsewhere has the same checksum;
    /// changing the entry file, or a file's size, changes it.
    func testContentHashFollowsTheStatedRule() throws {
        let shelf = try makeSandboxDirectory("daisy-checksum")
        let book = try Fixtures.writeFolder(Fixtures.packageBook, named: "Ferry Timetables", in: shelf)
        let inventory = try DAISYPackageInventory.make(for: book)

        var text = try FileImportService.md5Hash(of: book.appendingPathComponent("book.opf"))
        for path in Fixtures.packageBookFiles {
            text += "\u{0}\(path)\u{0}\(Data(Fixtures.packageBook[path, default: ""].utf8).count)"
        }
        let expected = Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02hhx", $0) }.joined()
        XCTAssertEqual(try inventory.contentHash(), expected)

        let elsewhere = try Fixtures.writeFolder(Fixtures.packageBook, named: "Another Copy", in: shelf)
        XCTAssertEqual(try DAISYPackageInventory.make(for: elsewhere).contentHash(), expected)

        let resized = try Fixtures.writeFolder(
            Fixtures.files(Fixtures.packageBook, changing: ["images/harbor map.png": "a larger stand-in image of the harbor"]),
            named: "Resized Image",
            in: shelf
        )
        let retitled = try Fixtures.writeFolder(
            Fixtures.files(Fixtures.packageBook, changing: [
                "book.opf": Fixtures.packageBook["book.opf", default: ""].replacingOccurrences(of: "Outer", with: "Inner")
            ]),
            named: "Retitled",
            in: shelf
        )
        XCTAssertNotEqual(try DAISYPackageInventory.make(for: resized).contentHash(), expected)
        XCTAssertNotEqual(try DAISYPackageInventory.make(for: retitled).contentHash(), expected)
    }

    // MARK: - References

    /// References resolve as the reader resolves them: relative to the file
    /// that makes them, "." and ".." applied, percent escapes decoded, and
    /// "/" starting at the book's folder. Fragments of the same file, the
    /// folder itself, and web or mail addresses name no file of the book.
    func testReferencesResolveToPathsInsideTheFolder() throws {
        let resolved: [(reference: String, file: String, path: String?)] = [
            ("text/splices.html#t1", "ncc.html", "text/splices.html"),
            ("../audio/part1.mp3", "smil/part1.smil", "audio/part1.mp3"),
            ("./content/./timetables.xml", "book.opf", "content/timetables.xml"),
            ("/styles/text.css", "text/splices.html", "styles/text.css"),
            ("harbor%20map.png", "images/index.html", "images/harbor map.png"),
            ("#t2", "text/splices.html", nil),
            ("", "ncc.html", nil),
            ("content/..", "book.opf", nil),
            ("http://www.daisy.org/", "ncc.html", nil),
            ("mailto:library@example.org", "ncc.html", nil)
        ]
        for (reference, file, path) in resolved {
            XCTAssertEqual(try DAISYPackageInventory.packagePath(of: reference, in: file), path, "\(reference) in \(file)")
        }

        for (reference, file) in [
            ("../shared.xml", "book.opf"),
            ("content/../../shared.xml", "book.opf"),
            ("../../outside.mp3", "smil/part1.smil"),
            ("file:///etc/hosts", "text/splices.html")
        ] {
            XCTAssertThrowsError(try DAISYPackageInventory.packagePath(of: reference, in: file), reference) { error in
                XCTAssertEqual(error as? DAISYPackageError, .referenceOutsidePackage(reference: reference, file: file))
            }
        }
    }

    /// A manifest entry climbing out of the book's folder is refused,
    /// naming the entry and the file making it, in words a listener can act
    /// on; the same holds for a SMIL file's audio and a text file's image.
    func testReferencesLeavingTheFolderAreRefusedByName() throws {
        let shelf = try makeSandboxDirectory("daisy-escape")
        try Data("outside the book".utf8).write(to: shelf.appendingPathComponent("shared.xml"))
        let opf = Fixtures.packageBook["book.opf", default: ""]
        let smil = Fixtures.navigationBook["smil/part1.smil", default: ""]
        let text = Fixtures.navigationBook["text/splices.html", default: ""]
        let cases: [(name: String, files: [String: String], reference: String, file: String)] = [
            (
                "Manifest",
                Fixtures.files(Fixtures.packageBook, changing: [
                    "book.opf": opf.replacingOccurrences(of: "images/harbor%20map.png", with: "../shared.xml")
                ]),
                "../shared.xml", "book.opf"
            ),
            (
                "SMIL Audio",
                Fixtures.files(Fixtures.navigationBook, changing: [
                    "smil/part1.smil": smil.replacingOccurrences(of: "../audio/part1.mp3", with: "../../shared.mp3")
                ]),
                "../../shared.mp3", "smil/part1.smil"
            ),
            (
                "Text Image",
                Fixtures.files(Fixtures.navigationBook, changing: [
                    "text/splices.html": text.replacingOccurrences(of: "../images/eye%20splice.png", with: "file:///etc/hosts")
                ]),
                "file:///etc/hosts", "text/splices.html"
            )
        ]

        for (name, files, reference, file) in cases {
            let book = try Fixtures.writeFolder(files, named: name, in: shelf)
            XCTAssertThrowsError(try DAISYPackageInventory.make(for: book), name) { error in
                XCTAssertEqual(error as? DAISYPackageError, .referenceOutsidePackage(reference: reference, file: file), name)
                XCTAssertEqual(
                    error.localizedDescription,
                    "The file “\(file)” in this DAISY book refers to “\(reference)”, which is outside the book's folder. "
                        + "Only files inside the folder can be imported.",
                    name
                )
            }
        }
    }

    /// A symbolic link that leads out of the book's folder is refused like
    /// a reference leading out, while one leading to another file inside
    /// the folder is listed under its own path and read from that file.
    func testSymbolicLinksMustStayInsideTheFolder() throws {
        let shelf = try makeSandboxDirectory("daisy-links")
        let dtbook = Fixtures.packageBook["content/timetables.xml", default: ""]
        let outside = shelf.appendingPathComponent("outside.xml")
        try Data(dtbook.utf8).write(to: outside)
        let book = try Fixtures.writeFolder(
            Fixtures.files(Fixtures.packageBook, changing: ["content/real.xml": dtbook], removing: ["content/timetables.xml"]),
            named: "Ferry Timetables",
            in: shelf
        )
        let link = book.appendingPathComponent("content/timetables.xml")

        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try DAISYPackageInventory.make(for: book)) { error in
            XCTAssertEqual(error as? DAISYPackageError, .referenceOutsidePackage(reference: "content/timetables.xml", file: "book.opf"))
        }

        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "real.xml")
        let inventory = try DAISYPackageInventory.make(for: book)
        let linked = try XCTUnwrap(inventory.files.first { $0.path == "content/timetables.xml" })
        XCTAssertEqual(linked.source.lastPathComponent, "real.xml")
        XCTAssertEqual(linked.size, Data(dtbook.utf8).count)
        XCTAssertEqual(inventory.paths, Fixtures.packageBookFiles)
    }

    /// Only a folder holding exactly one book at its top level, or a book's
    /// OPF or ncc.html, has an inventory: other folders are refused, saying
    /// why, and any other item chosen for import is not a package at all.
    func testOnlyOneBooksFolderOrEntryFileHasAnInventory() throws {
        let shelf = try makeSandboxDirectory("daisy-not-one-book")
        let empty = try Fixtures.writeFolder(["notes.txt": "Nothing to read here."], named: "Notes", in: shelf)
        let twoBooks = try Fixtures.writeFolder(["b.opf": "", "a.opf": ""], named: "Two Books", in: shelf)
        let tmb = try Fixtures.writeFolder(Fixtures.navigationBook, named: "Rope Splicing.tmb", in: shelf)

        for folder in [empty, twoBooks] {
            XCTAssertThrowsError(try DAISYPackageInventory.ofSource(folder), folder.lastPathComponent)
        }
        XCTAssertThrowsError(try DAISYPackageInventory.make(for: empty)) { error in
            XCTAssertEqual(error as? DAISYPackageError, .notAPackage)
            XCTAssertEqual(
                error.localizedDescription,
                "The folder is not a DAISY book: it has no ncc.html or .opf file at its top level."
            )
        }
        XCTAssertThrowsError(try DAISYPackageInventory.make(for: twoBooks)) { error in
            XCTAssertEqual(error as? DAISYPackageError, .severalPackages(["a.opf", "b.opf"]))
            XCTAssertEqual(
                error.localizedDescription,
                "The folder holds 2 DAISY books (a.opf, b.opf). Import each book's .opf file on its own."
            )
        }
        XCTAssertThrowsError(try DAISYPackageInventory.make(for: empty.appendingPathComponent("notes.txt"))) { error in
            XCTAssertEqual(error as? DAISYPackageError, .notAPackage)
        }

        XCTAssertNil(try DAISYPackageInventory.ofSource(empty.appendingPathComponent("notes.txt")))
        XCTAssertNil(try DAISYPackageInventory.ofSource(try requireFile("alice.epub")))
        XCTAssertNil(try DAISYPackageInventory.ofSource(try requireFile("daisy202_test.zip")))
        XCTAssertNil(try DAISYPackageInventory.ofSource(tmb))
    }

    // MARK: - Helpers

    /// The names of the files `DAISYParser.packageEntryPoints(in:)` finds in
    /// `folder`, in its order.
    private func entryNames(in folder: URL) -> [String] {
        DAISYParser.packageEntryPoints(in: folder).map(\.lastPathComponent)
    }
}
