import XCTest
@testable import TextMouth

/// NLS BARD braille books (FMT56): a package file (`.bopf`) of the form of a
/// DAISY 3 package, and the BRF volumes it lists, imported as one braille
/// book from the package file with its volumes beside it, from its folder,
/// and from a ZIP archive.
///
/// The fixture is made here, of TextMouth's own forward translation and text
/// written for the purpose, in the form of such a package: three short
/// volumes in contracted braille (English Braille, American Edition) and a
/// package with its own metadata. It holds nothing of the National Library
/// Service's. Each test works in folders of its own and imports into a
/// library folder of its own.
final class BardBrailleTests: XCTestCase {
    /// The hosted test root's library index, put back after each test.
    private var sandbox: LibraryIndexSandbox?
    /// The library folder the imports go into; each test has its own.
    private let folderPath = "Bard Braille \(UUID().uuidString.prefix(8))"

    override func setUpWithError() throws {
        sandbox = try LibraryIndexSandbox.capture()
    }

    override func tearDownWithError() throws {
        // Optional: tear-down also runs when set-up failed partway.
        sandbox?.restore()
        try? FileManager.default.removeItem(at: TextMouthPaths.libraryDir.appendingPathComponent(folderPath, isDirectory: true))
    }

    // MARK: - The Fixture

    /// The table the package names for the fixture's volumes: English
    /// Braille, American Edition, contracted.
    private let ebaeContracted = BrailleTableGuess.ebaeTableID

    /// The print of each volume: a heading and two paragraphs, written for
    /// this fixture. Each volume has a word no other has.
    private static let volumeBlocks: [[(heading: Bool, text: String)]] = [
        [(true, "The Salt Ledger"),
         (false, "Orsolya counted the barrels twice and wrote both numbers in her ledger."),
         (false, "The totals did not agree, so she counted a third time on the pier.")],
        [(true, "The Harbour Office"),
         (false, "Nobody at the harbour office could explain the missing barrel."),
         (false, "A letter arrived on Friday from a cousin in the lagoon villages.")],
        [(true, "The Answer"),
         (false, "The cousin had borrowed the barrel to carry a lamp across the water."),
         (false, "Orsolya laughed, signed the ledger, and closed the matter for the season.")],
    ]

    /// Volume `index`'s print blocks.
    private func blocks(ofVolume index: Int) -> [BraillePrintBlock] {
        Self.volumeBlocks[index].map { block in
            block.heading ? BraillePrintBlock.heading(level: 1, EmphasizedText(block.text)) : BraillePrintBlock.paragraph(EmphasizedText(block.text))
        }
    }

    /// The names of the volume files, in reading order.
    private let volumeNames = ["salt-v1.brf", "salt-v2.brf", "salt-v3.brf"]

    /// The BRF files of the three volumes, by file name, written by
    /// TextMouth's own forward translation with the table the package names.
    private func volumeFiles() throws -> [String: Data] {
        let folder = try makeSandboxDirectory("BardVolumes")
        var files: [String: Data] = [:]
        for (index, name) in volumeNames.enumerated() {
            files[name] = try BrailleDocumentWriter.brf(
                of: blocks(ofVolume: index), options: BrailleExportOptions(table: ebaeContracted), workingIn: folder
            )
        }
        return files
    }

    /// The package file's text: made-up metadata, the `brl:` values, a
    /// manifest of `manifest` (the file names, ids `vol1` and on) and the
    /// package itself, and a spine of `spine` (the manifest numbers, from 1).
    private func packageText(
        title: String = "The Salt Ledger",
        creator: String = "Brandvold, Henrik",
        code: String? = "EBAE",
        level: String? = "2",
        pages: String = "3",
        lineLength: String = "40",
        manifest: [String]? = nil,
        spine: [Int]? = nil
    ) -> Data {
        let names = manifest ?? volumeNames
        let order = spine ?? Array(1...names.count)
        var xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <package xmlns="http://openebook.org/namespaces/oeb-package/1.0/" xmlns:dc="http://purl.org/dc/elements/1.0/">
          <metadata>
            <dc-metadata>
              <dc:Title>\(title)</dc:Title>
              <dc:Creator role="aut">\(creator)</dc:Creator>
              <dc:Description>A short invented story, written for a test.</dc:Description>
              <dc:Publisher>Example Braille Press</dc:Publisher>
              <dc:Date>2026</dc:Date>
              <dc:Language>en</dc:Language>
              <dc:Subject>Fiction</dc:Subject>
              <dc:Subject>Tests</dc:Subject>
              <dc:Identifier id="uid" scheme="dtb">example-salt-ledger-1</dc:Identifier>
            </dc-metadata>
            <x-metadata>

        """
        if let code { xml += "      <meta name=\"brl:brailleCode\" content=\"\(code)\"/>\n" }
        if let level { xml += "      <meta name=\"brl:contractionLevel\" content=\"\(level)\"/>\n" }
        xml += """
              <meta name="brl:volumes" content="\(names.count)"/>
              <meta name="brl:pages" content="\(pages)"/>
              <meta name="brl:lineLength" content="\(lineLength)"/>
              <meta name="brl:pageLength" content="25"/>
            </x-metadata>
          </metadata>
          <manifest>

        """
        for (index, name) in names.enumerated() {
            xml += "    <item id=\"vol\(index + 1)\" href=\"\(name)\" media-type=\"text/brf\"/>\n"
        }
        xml += "    <item id=\"bopf\" href=\"salt.bopf\" media-type=\"text/xml\"/>\n  </manifest>\n  <spine>\n"
        for number in order { xml += "    <itemref idref=\"vol\(number)\"/>\n" }
        xml += "  </spine>\n</package>\n"
        return Data(xml.utf8)
    }

    /// A folder of its own holding the three volumes and `package` as
    /// `salt.bopf`, and the file's URL.
    private func packageFolder(
        _ package: Data? = nil, leaving left: Set<String> = []
    ) throws -> (folder: URL, file: URL) {
        let folder = try makeSandboxDirectory("BardPackage").appendingPathComponent("Salt Ledger", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, data) in try volumeFiles() where !left.contains(name) {
            try data.write(to: folder.appendingPathComponent(name))
        }
        let file = folder.appendingPathComponent("salt.bopf")
        try (package ?? self.packageText()).write(to: file)
        return (folder, file)
    }

    /// A ZIP archive holding the volumes and `package`, at its top level or
    /// inside `folder`.
    private func packageZip(_ package: Data? = nil, inFolder folder: String? = nil) throws -> URL {
        var entries: [String: Data] = [:]
        let prefix = folder.map { $0 + "/" } ?? ""
        for (name, data) in try volumeFiles() { entries[prefix + name] = data }
        entries[prefix + "salt.bopf"] = package ?? self.packageText()
        let archive = try makeTemporaryZip(prefix: "BardBraille", entries: entries)
        addTeardownBlock { try? FileManager.default.removeItem(at: archive) }
        return archive
    }

    /// The Markdown the braille book at `url` reads as with `table`, no pages.
    private func markdown(of url: URL, table: String? = nil) throws -> String {
        try BrailleBookReader.markdown(of: url, table: table ?? ebaeContracted)
    }

    /// What the reading of `volumes` (their files, in reading order) must be:
    /// each volume read as a plain BRF is, under a heading that names its
    /// place in the book.
    private func expectedMarkdown(ofVolumes volumes: [URL]) throws -> String {
        try volumes.enumerated().map { index, url in
            "# Volume \(index + 1)\n\n" + (try markdown(of: url))
        }.joined(separator: "\n\n")
    }

    /// The headings of the book `book` shows, as "level: text" lines.
    private func headings(of book: Book) throws -> [String] {
        headingLines(of: try openedContent(of: book))
    }

    // MARK: - Recognizing a Package

    /// A `.bopf` file, a folder holding one, and a ZIP holding one at its
    /// top level or in a folder are each a BARD braille book, and a braille
    /// book to the import: not a DAISY book, which has a package file of its
    /// own kind. A plain BRF, and a folder of DAISY's package file, are not.
    func testAPackageFileItsFolderAndItsZIPAreBrailleBooks() throws {
        let (folder, file) = try packageFolder()
        let topLevelZip = try packageZip()
        let nestedZip = try packageZip(inFolder: "Salt Ledger")
        for source in [file, folder, topLevelZip, nestedZip] {
            XCTAssertTrue(BardBraillePackage.isPackage(at: source), source.lastPathComponent)
            XCTAssertEqual(BookFormat.detect(from: source), .braille, source.lastPathComponent)
        }
        // A ZIP of a BARD book is one book to a batch import, as a DAISY ZIP is.
        XCTAssertTrue(DAISYParser.isDAISYZip(url: topLevelZip))
        XCTAssertTrue(DAISYParser.isDAISYZip(url: nestedZip))

        // A plain BRF is no package; a folder of DAISY's package file is a DAISY book.
        let plain = folder.appendingPathComponent("salt-v1.brf")
        XCTAssertFalse(BardBraillePackage.isPackage(at: plain))
        XCTAssertEqual(BookFormat.detect(from: plain), .braille)
        let daisy = try makeSandboxDirectory("BardDaisy")
        try Data("<package/>".utf8).write(to: daisy.appendingPathComponent("book.opf"))
        XCTAssertFalse(BardBraillePackage.isPackage(at: daisy))
        XCTAssertEqual(BookFormat.detect(from: daisy), .daisy)
        XCTAssertEqual(BookFormat.braille.fileExtensions.contains("bopf"), true)
    }

    /// Both apps offer the `.bopf` type: the Mac's and the iPhone's
    /// Info.plist each declare it, in a Viewer role, and the import panel
    /// lists its type.
    func testBothAppsDeclareTheBopfType() throws {
        let type = documentType(listing: "bopf")
        XCTAssertEqual(type?["CFBundleTypeRole"] as? String, "Viewer")
        XCTAssertEqual(type?["LSItemContentTypes"] as? [String], ["com.textmouth.bopf-package"])
        XCTAssertTrue(FileImportService.supportedTypes.contains { $0.identifier == "com.textmouth.bopf-package" })
    }

    // MARK: - Reading the Volumes

    /// The book reads as its three volumes in the spine's order, each under
    /// a heading "Volume N", and each volume's text is what a plain BRF
    /// import of that volume reads.
    func testTheVolumesReadInOrderEachUnderAHeading() throws {
        let (folder, file) = try packageFolder()
        let volumes = volumeNames.map { folder.appendingPathComponent($0) }
        let expected = try expectedMarkdown(ofVolumes: volumes)
        // A plain word of each volume came through, so the oracle is no
        // empty agreement.
        for word in ["barrels", "harbour", "lamp"] {
            XCTAssertTrue(expected.contains(word), word)
        }
        XCTAssertEqual(try markdown(of: file), expected)
        XCTAssertEqual(try markdown(of: folder), expected)
        XCTAssertEqual(try markdown(of: try packageZip()), expected)
        XCTAssertEqual(try markdown(of: try packageZip(inFolder: "Salt Ledger")), expected)
    }

    /// The spine decides the order, not the manifest's: with the spine
    /// listing the volumes backwards, the book begins with the third file
    /// under "Volume 1".
    func testTheSpineDecidesTheOrder() throws {
        let (folder, file) = try packageFolder(packageText(spine: [3, 2, 1]))
        let volumes = volumeNames.reversed().map { folder.appendingPathComponent($0) }
        XCTAssertEqual(try markdown(of: file), try expectedMarkdown(ofVolumes: volumes))
        // "Volume 1" is the first thing the book says, and the third file's
        // word comes before the first file's.
        let text = try markdown(of: file)
        XCTAssertTrue(text.hasPrefix("# Volume 1\n\n"))
        let lamp = try XCTUnwrap(text.range(of: "lamp"))
        let barrels = try XCTUnwrap(text.range(of: "barrels"))
        XCTAssertLessThan(lamp.lowerBound, barrels.lowerBound)
    }

    /// A file the spine leaves out is not read, and one volume gives a book
    /// with no volume heading, as a plain BRF reads.
    func testAFileTheSpineLeavesOutIsNotReadAndOneVolumeHasNoHeading() throws {
        let (folder, file) = try packageFolder(packageText(spine: [1, 3]))
        let expected = try expectedMarkdown(ofVolumes: [folder.appendingPathComponent("salt-v1.brf"),
                                                        folder.appendingPathComponent("salt-v3.brf")])
        XCTAssertEqual(try markdown(of: file), expected)
        XCTAssertFalse(try markdown(of: file).contains("harbour"))

        let single = try packageFolder(packageText(spine: [2]))
        XCTAssertEqual(try markdown(of: single.file), try markdown(of: single.folder.appendingPathComponent("salt-v2.brf")))
        XCTAssertFalse(try markdown(of: single.file).contains("# Volume"))
    }

    /// A package whose spine lists no volume is read in the manifest's order,
    /// as a DAISY book with no content file in its spine is.
    func testAPackageWithNoSpineIsReadInTheManifestsOrder() throws {
        let text = String(decoding: packageText(), as: UTF8.self)
            .replacingOccurrences(of: "<itemref idref=\"vol1\"/>", with: "")
            .replacingOccurrences(of: "<itemref idref=\"vol2\"/>", with: "")
            .replacingOccurrences(of: "<itemref idref=\"vol3\"/>", with: "")
        let (folder, file) = try packageFolder(Data(text.utf8))
        let volumes = volumeNames.map { folder.appendingPathComponent($0) }
        XCTAssertEqual(try markdown(of: file), try expectedMarkdown(ofVolumes: volumes))
    }

    /// A volume the package names that is not there fails the reading,
    /// naming the file, as a DAISY book's missing content file does; the
    /// import is refused, and leaves nothing in the library.
    func testAMissingVolumeFailsTheReadingAndTheImport() throws {
        let (_, file) = try packageFolder(leaving: ["salt-v2.brf"])
        XCTAssertThrowsError(try markdown(of: file)) {
            XCTAssertTrue($0.localizedDescription.contains("salt-v2.brf"), $0.localizedDescription)
        }
        XCTAssertThrowsError(try FileImportService.importFileWithReport(from: file, toFolder: folderPath))
        let folder = TextMouthPaths.libraryDir.appendingPathComponent(folderPath, isDirectory: true)
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [], [])
    }

    /// A damaged package, and one that lists no braille volume, are refused
    /// by name: the first as a damaged file, the second as missing content.
    func testABrokenPackageIsRefused() throws {
        let damaged = try packageFolder(Data("<package><metadata><dc-metadata><dc:Title>x".utf8))
        XCTAssertThrowsError(try BardBraillePackage.open(at: damaged.file)) {
            guard case DAISYParserError.malformedXML(let name, _) = $0 else { return XCTFail("\($0)") }
            XCTAssertEqual(name, "salt.bopf")
        }
        XCTAssertThrowsError(try markdown(of: damaged.file))
        XCTAssertThrowsError(try FileImportService.importFileWithReport(from: damaged.file, toFolder: folderPath))

        let empty = try packageFolder(packageText(manifest: []))
        XCTAssertThrowsError(try BardBraillePackage.open(at: empty.file)) {
            guard case DAISYParserError.missingContent = $0 else { return XCTFail("\($0)") }
        }
    }

    // MARK: - Pages

    /// The pages of the volumes are one book's, each volume marked, with the
    /// package's line length as the line width; the package's page count is
    /// only checked, so a count that is wrong refuses nothing.
    func testThePackagesLineLengthIsUsedAndItsPageCountOnlyChecked() throws {
        let (folder, file) = try packageFolder(packageText(pages: "9999"))
        let book = try BardBraillePackage.open(at: file)
        XCTAssertEqual(book.lineLength, 40)
        XCTAssertEqual(book.pageLength, 25)
        XCTAssertEqual(book.declaredPageCount, 9999)
        XCTAssertEqual(book.declaredVolumeCount, 3)

        let pages = try book.readPages(code: .northAmerican)
        XCTAssertEqual(pages.lineWidth, 40)
        XCTAssertEqual(pages.volumeStarts.count, 3)
        XCTAssertEqual(pages.volumeStarts.first, 0)
        XCTAssertTrue(pages.marksItsPages)
        // Each volume, taken out of the book, is what its file reads as alone.
        for (index, name) in volumeNames.enumerated() {
            let alone = try BrailleFileReader.read(folder.appendingPathComponent(name), as: .brf)
            XCTAssertEqual(pages.volume(at: index).pages, alone.pages, name)
        }
        XCTAssertNoThrow(try markdown(of: file))

        // A line length the analyzer could not use is not passed on.
        let odd = try BardBraillePackage.open(at: try packageFolder(packageText(lineLength: "7")).file)
        XCTAssertNil(odd.lineLength)
    }

    /// Each volume is laid out on its own: the structure names where each
    /// begins, at the heading each volume of the fixture opens with.
    func testEachVolumeIsLaidOutOnItsOwn() throws {
        let (_, file) = try packageFolder()
        let pages = try BardBraillePackage.open(at: file).readPages(code: .northAmerican)
        let structure = BraillePageAnalyzer.structure(of: pages)
        XCTAssertEqual(structure.volumeStarts.map(\.number), [1, 2, 3])
        XCTAssertEqual(structure.volumeStarts.first?.blockIndex, 0)
        for start in structure.volumeStarts {
            guard structure.blocks.indices.contains(start.blockIndex) else { return XCTFail("no block at \(start)") }
            if case .heading = structure.blocks[start.blockIndex] { continue }
            XCTFail("volume \(start.number) does not begin at a heading")
        }
    }

    // MARK: - The Table

    /// Each code and contraction level the package names reads with its
    /// table: EBAE contracted with TextMouth's EBAE table, UEB contracted
    /// and uncontracted with theirs, and any other with none.
    func testTheTableFollowsTheCodeAndTheContractionLevel() {
        XCTAssertEqual(BardBraillePackage.tableID(brailleCode: "EBAE", contractionLevel: 2), "en_US.tbl")
        XCTAssertEqual(BardBraillePackage.tableID(brailleCode: "EBAE", contractionLevel: 1), "en-us-g1.ctb")
        XCTAssertEqual(BardBraillePackage.tableID(brailleCode: "UEB", contractionLevel: 2), "en-ueb-g2.ctb")
        XCTAssertEqual(BardBraillePackage.tableID(brailleCode: "UEB", contractionLevel: 1), "en-ueb-g1.ctb")
        XCTAssertNil(BardBraillePackage.tableID(brailleCode: "ICEB", contractionLevel: 2))
        XCTAssertNil(BardBraillePackage.tableID(brailleCode: "EBAE", contractionLevel: 3))
        XCTAssertNil(BardBraillePackage.tableID(brailleCode: "EBAE", contractionLevel: nil))
        XCTAssertNil(BardBraillePackage.tableID(brailleCode: nil, contractionLevel: 2))
    }

    /// The package's table is the one the import chooses, whatever the
    /// Braille setting says, in any letter case; one that names no table
    /// TextMouth has falls back to the setting's, as a plain BRF does.
    func testThePackagesTableIsTheImportsChoiceAndAnUnknownOneFallsBack() throws {
        let setting = "en-ueb-g1.ctb"
        for (code, level, expected) in [("EBAE", "2", "en_US.tbl"), ("ebae", "2", "en_US.tbl"),
                                        ("UEB", "2", "en-ueb-g2.ctb"), ("UEB", "1", "en-ueb-g1.ctb")] {
            let (_, file) = try packageFolder(packageText(code: code, level: level))
            let reading = BraillePreferences.$tableForImports.withValue(setting) {
                FileImportService.brailleReading(ofImported: file)
            }
            XCTAssertEqual(reading.table, expected, "\(code) \(level)")
            XCTAssertEqual(reading.fileCode, BrailleFileCode.northAmerican.id)
            XCTAssertNil(reading.origin)
        }
        // Another code, a missing level, and a missing code: the setting's table.
        for (code, level) in [("ICEB", "2"), ("EBAE", nil), (nil, "2")] as [(String?, String?)] {
            let (_, file) = try packageFolder(packageText(code: code, level: level))
            let reading = BraillePreferences.$tableForImports.withValue(setting) {
                FileImportService.brailleReading(ofImported: file)
            }
            XCTAssertEqual(reading.table, setting, "\(code ?? "no code") \(level ?? "no level")")
        }
    }

    // MARK: - The Metadata

    /// The package names the book: its title, its author as a DAISY book's
    /// and an EPUB's are read, and the rest of what it says.
    func testThePackageNamesTheBook() throws {
        let (_, file) = try packageFolder()
        let book = try BardBraillePackage.open(at: file)
        XCTAssertEqual(book.title, "The Salt Ledger")
        XCTAssertEqual(book.author, "Brandvold, Henrik")
        XCTAssertEqual(book.package.description, "A short invented story, written for a test.")
        XCTAssertEqual(book.package.publisher, "Example Braille Press")
        XCTAssertEqual(book.package.date, "2026")
        XCTAssertEqual(book.package.language, "en")
        XCTAssertEqual(book.package.subjects, ["Fiction", "Tests"])
        XCTAssertEqual(book.package.identifier, "example-salt-ledger-1")
        XCTAssertEqual(book.brailleCode, "EBAE")
        XCTAssertEqual(book.contractionLevel, 2)
        XCTAssertEqual(book.table, "en_US.tbl")
        XCTAssertEqual(book.volumePaths, volumeNames)

        // A creator the package leaves as the placeholder names no one.
        let unknown = try BardBraillePackage.open(at: try packageFolder(packageText(creator: "Unknown")).file)
        XCTAssertEqual(unknown.author, "")
    }

    // MARK: - Importing

    /// The package file, its folder, and the ZIP import as the same braille
    /// book: titled and authored by the package, its table the package's
    /// whatever the setting says, its braille file characters North American
    /// ASCII, the publisher, date, language, and identifier kept, and its
    /// text the volumes' under their headings.
    func testEachWayOfImportingGivesTheSameBook() throws {
        let (folder, file) = try packageFolder()
        let volumes = volumeNames.map { folder.appendingPathComponent($0) }
        let expected = try expectedMarkdown(ofVolumes: volumes)
        let sources = [file, folder, try packageZip(), try packageZip(inFolder: "Salt Ledger")]
        for source in sources {
            let imported = try BraillePreferences.$tableForImports.withValue("en-ueb-g1.ctb") {
                try FileImportService.importFileWithReport(from: source, toFolder: folderPath)
            }
            addTeardownBlock { try? FileManager.default.removeItem(at: imported.book.tmbDirectory) }
            let book = imported.book
            let name = source.lastPathComponent
            XCTAssertEqual(book.format, .braille, name)
            XCTAssertEqual(book.title, "The Salt Ledger", name)
            XCTAssertEqual(book.author, "Brandvold, Henrik", name)
            XCTAssertEqual(book.brailleTable, "en_US.tbl", name)
            XCTAssertNil(book.brailleTableOrigin, name)
            XCTAssertEqual(book.brailleFileCode, BrailleFileCode.northAmerican.id, name)
            XCTAssertEqual(book.epubPublisher, "Example Braille Press", name)
            XCTAssertEqual(book.epubPublicationDate, "2026", name)
            XCTAssertEqual(book.epubLanguage, "en", name)
            XCTAssertEqual(book.epubIdentifier, "example-salt-ledger-1", name)
            XCTAssertEqual(try BookInfo.load(from: book.tmbDirectory).metadata.brailleTable, "en_US.tbl", name)

            // The book reads in full, from its own package, without its source.
            XCTAssertEqual(try BrailleBookReader.markdown(of: book.bookFileURL, table: "en_US.tbl"), expected, name)
            let volumeHeadings = try headings(of: book).filter { $0.hasPrefix("1: Volume") }
            XCTAssertEqual(volumeHeadings, ["1: Volume 1", "1: Volume 2", "1: Volume 3"], name)
        }
    }

    /// A package file imported with its volumes beside it keeps them in its
    /// package, and nothing else from its folder; the book then reads after
    /// the folder is gone.
    func testThePackageFileImportsWithItsVolumesAndNothingElse() throws {
        let (folder, file) = try packageFolder()
        try Data("an unrelated file".utf8).write(to: folder.appendingPathComponent("notes.txt"))
        let imported = try FileImportService.importFileWithReport(from: file, toFolder: folderPath)
        addTeardownBlock { try? FileManager.default.removeItem(at: imported.book.tmbDirectory) }
        try FileManager.default.removeItem(at: folder)

        let book = imported.book
        XCTAssertEqual(book.bookFileURL.lastPathComponent, "salt.bopf")
        XCTAssertTrue(imported.isFromFolder)
        let kept = try FileManager.default.contentsOfDirectory(atPath: book.tmbDirectory.path)
        for name in volumeNames + ["salt.bopf"] { XCTAssertTrue(kept.contains(name), name) }
        XCTAssertFalse(kept.contains("notes.txt"))
        XCTAssertEqual(try headings(of: book).filter { $0.hasPrefix("1: Volume") }.count, 3)
    }

    /// The book is known by its package's checksum, as a DAISY book is: the
    /// package file and its folder have the same one, wherever they lie, and
    /// a change to a volume changes it.
    func testTheBookIsKnownByItsPackagesChecksum() throws {
        let (folder, file) = try packageFolder()
        let same = try FileImportService.importHash(of: file)
        XCTAssertEqual(try FileImportService.importHash(of: folder), same)
        let (_, otherFile) = try packageFolder()
        XCTAssertEqual(try FileImportService.importHash(of: otherFile), same)

        let (changedFolder, changedFile) = try packageFolder()
        try Data("changed".utf8).write(to: changedFolder.appendingPathComponent("salt-v2.brf"))
        XCTAssertNotEqual(try FileImportService.importHash(of: changedFile), same)
    }

    // MARK: - The User's Own Package

    /// The user's War and Peace package, in `HumanFiles/` of the repository
    /// (gitignored, so it is on the user's Mac only), reads as one book in
    /// place: nothing of it is copied or imported. It runs in the
    /// orchestrator's suite on the user's Mac, and skips on GitHub's runners
    /// and anywhere the file is not.
    ///
    /// It has 14 volumes in order, a title and an author from its package,
    /// the EBAE contracted table chosen, about 3,142 pages, and a heading
    /// for each volume. Its checks print the volumes, the pages, and the
    /// seconds the reading took.
    func testThePrivateWarAndPeacePackageReadsAsOneBook() throws {
        try XCTSkipIf(TestMachine.isGitHubRunner, "the user's private sample is on the user's Mac only")
        let sample = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("HumanFiles", isDirectory: true)
            .appendingPathComponent("BR-Tolstoy_Leo_graf War and peace BR09710.zip")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: sample.path),
            "the user's War and Peace package is not in HumanFiles/ here"
        )

        XCTAssertEqual(BookFormat.detect(from: sample), .braille)
        let package = try BardBraillePackage.open(at: sample)
        XCTAssertEqual(package.volumePaths.count, 14)
        XCTAssertEqual(package.volumePaths, (1...14).map { String(format: "09710v%02d.brf", $0) })
        XCTAssertEqual(package.title, "War and peace")
        XCTAssertEqual(package.author, "Tolstoy, Leo")
        XCTAssertEqual(package.table, "en_US.tbl")
        let reading = FileImportService.brailleReading(ofImported: sample)
        XCTAssertEqual(reading.table, "en_US.tbl")

        let started = Date()
        let pages = try package.readPages(code: .northAmerican)
        XCTAssertEqual(pages.volumeStarts.count, 14)
        XCTAssertEqual(Double(pages.pageCount), 3142, accuracy: 3142 * 0.05)
        let text = try markdown(of: sample)
        let seconds = Date().timeIntervalSince(started)
        let volumeHeadings = text.components(separatedBy: "\n").filter { $0.hasPrefix("# Volume ") }
        XCTAssertEqual(volumeHeadings, (1...14).map { "# Volume \($0)" })
        XCTAssertGreaterThan(text.count, 1_000_000)
        print("BARD sample: \(package.volumePaths.count) volumes, \(pages.pageCount) pages, "
              + "\(text.count) characters, read in \(String(format: "%.1f", seconds)) s")
    }
}
