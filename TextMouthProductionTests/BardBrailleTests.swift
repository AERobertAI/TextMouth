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

    /// The cells a line of the fixture's volumes holds: the 40 the package
    /// declares, unless a test lays them out narrower.
    private var cellsPerLine = 40

    /// The options the fixture's volumes are written with.
    private func writerOptions() -> BrailleExportOptions {
        var options = BrailleExportOptions(table: ebaeContracted)
        options.page = BraillePageFormat(cellsPerLine: cellsPerLine)
        return options
    }

    /// The BRF files of the three volumes, by file name, written by
    /// TextMouth's own forward translation with the table the package names.
    private func volumeFiles() throws -> [String: Data] {
        let folder = try makeSandboxDirectory("BardVolumes")
        var files: [String: Data] = [:]
        for (index, name) in volumeNames.enumerated() {
            files[name] = try BrailleDocumentWriter.brf(
                of: blocks(ofVolume: index), options: writerOptions(), workingIn: folder
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
        let order = spine ?? Array(0..<names.count).map { $0 + 1 }
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
        _ package: Data? = nil, leaving left: Set<String> = [], volumes: [String: Data]? = nil
    ) throws -> (folder: URL, file: URL) {
        let folder = try makeSandboxDirectory("BardPackage").appendingPathComponent("Salt Ledger", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, data) in try volumes ?? volumeFiles() where !left.contains(name) {
            let destination = folder.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destination)
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
        // Under volume headings (of several volumes) the book's own headings
        // are one level deeper than a plain BRF's.
        let deeper = volumes.count > 1
        return try volumes.enumerated().map { index, url in
            let plain = try markdown(of: url)
            let text = deeper
                ? plain.components(separatedBy: "\n").map { $0.hasPrefix("#") ? "#" + $0 : $0 }.joined(separator: "\n")
                : plain
            return (deeper ? "# Volume \(index + 1)\n\n" : "") + text
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

    /// Only the Mac's Info.plist, read from the source tree, declares the
    /// `.bopf` document type, in a Viewer role, and its imported type, and its
    /// import panel lists the type; the iPhone's has neither (it is generated
    /// from the Mac's less what the iPhone refuses,
    /// `Scripts/ios/sync-info-plist.py`). The iPhone's picker and
    /// "Open in" do not offer the file, since they copy only the file picked
    /// and a `.bopf` alone would arrive without its volumes. (The source tree is
    /// the Mac's: the test is skipped where it is not.)
    func testBothAppsDeclareTheBopfType() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for path in ["TextMouth/Resources/Info.plist", "TextMouth/Platform/iOS/Info.plist"] {
            let url = root.appendingPathComponent(path)
            guard let data = try? Data(contentsOf: url) else { throw XCTSkip("the source tree is not here") }
            let plist = try XCTUnwrap(
                PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any], path
            )
            let documentTypes = plist["CFBundleDocumentTypes"] as? [[String: Any]] ?? []
            let type = documentTypes.first { ($0["CFBundleTypeExtensions"] as? [String] ?? []).contains("bopf") }
            if path.contains("iOS") {
                // The iPhone is offered no lone .bopf by "Open in": it would arrive without its volumes.
                XCTAssertNil(type, path)
            } else {
                XCTAssertEqual(type?["CFBundleTypeRole"] as? String, "Viewer", path)
                XCTAssertEqual(type?["LSItemContentTypes"] as? [String], ["com.textmouth.bopf-package"], path)
            }
            let imported = plist["UTImportedTypeDeclarations"] as? [[String: Any]] ?? []
            let declared = imported.first { $0["UTTypeIdentifier"] as? String == "com.textmouth.bopf-package" }
            if path.contains("iOS") {
                // The declaration of a type no document type names goes with it.
                XCTAssertNil(declared, path)
            } else {
                let tags = declared?["UTTypeTagSpecification"] as? [String: Any]
                XCTAssertEqual(tags?["public.filename-extension"] as? [String], ["bopf"], path)
            }
        }
        #if os(macOS)
        XCTAssertTrue(FileImportService.supportedTypes.contains { $0.identifier == "com.textmouth.bopf-package" })
        #else
        XCTAssertFalse(FileImportService.supportedTypes.contains { $0.identifier == "com.textmouth.bopf-package" })
        #endif
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
        // The manifest's order is not the order of the files' names, so a
        // read in the names' order, or in any other, would fail the test.
        let manifest = ["salt-v2.brf", "salt-v3.brf", "salt-v1.brf"]
        let (folder, file) = try packageFolder(packageText(manifest: manifest, spine: []))
        XCTAssertFalse(String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("<itemref"))
        let volumes = manifest.map { folder.appendingPathComponent($0) }
        XCTAssertEqual(try markdown(of: file), try expectedMarkdown(ofVolumes: volumes))
    }

    /// What the damaged-file sentence of a book says of `file` and `reason`
    /// (the sentence every refusal of a BARD book is made of, so none needs
    /// a line of its own).
    private func damagedSentence(_ file: String, _ reason: String) -> String {
        "The file “\(file)” in this book is damaged or incomplete: \(reason). Get a fresh copy of the book, then import it again."
    }

    /// A volume the package names that is not there fails the reading,
    /// naming the file and saying why; the import is refused, and leaves
    /// nothing in the library.
    func testAMissingVolumeFailsTheReadingAndTheImport() throws {
        let (_, file) = try packageFolder(leaving: ["salt-v2.brf"])
        let sentence = damagedSentence("salt-v2.brf", "the book's package lists it, but it is not there")
        XCTAssertThrowsError(try markdown(of: file)) { XCTAssertEqual($0.localizedDescription, sentence) }
        XCTAssertThrowsError(try FileImportService.importFileWithReport(from: file, toFolder: folderPath)) {
            XCTAssertTrue($0.localizedDescription.contains(sentence), $0.localizedDescription)
        }
        let folder = TextMouthPaths.libraryDir.appendingPathComponent(folderPath, isDirectory: true)
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [], [])
    }

    /// A damaged package, one that lists no braille volume, and one of
    /// several package files at the same level are each refused by name with
    /// the damaged-file sentence; a damaged package in a folder is refused as
    /// it is, with no fallback to the folder's files.
    func testABrokenPackageIsRefused() throws {
        let damaged = try packageFolder(Data("<package><metadata><dc-metadata><dc:Title>x".utf8))
        XCTAssertThrowsError(try BardBraillePackage.open(at: damaged.file)) {
            guard case DAISYParserError.malformedXML(let name, _) = $0 else { return XCTFail("\($0)") }
            XCTAssertEqual(name, "salt.bopf")
        }
        XCTAssertThrowsError(try markdown(of: damaged.file))
        for source in [damaged.file, damaged.folder] {
            XCTAssertThrowsError(try FileImportService.importFileWithReport(from: source, toFolder: folderPath)) {
                XCTAssertTrue($0.localizedDescription.contains("“salt.bopf” in this book is damaged"), $0.localizedDescription)
            }
        }

        let empty = try packageFolder(packageText(manifest: []))
        XCTAssertThrowsError(try BardBraillePackage.open(at: empty.file)) {
            XCTAssertEqual($0.localizedDescription, damagedSentence("salt.bopf", "it lists no braille volume"))
        }

        // Two package files at one level: no one book is meant.
        let twin = try packageFolder()
        try packageText().write(to: twin.folder.appendingPathComponent("other.bopf"))
        XCTAssertThrowsError(try BardBraillePackage.open(at: twin.folder))
        XCTAssertTrue(BardBraillePackage.holdsPackage(inArchivePaths: ["a.bopf", "b.bopf", "a1.brf"]))
        XCTAssertTrue(BardBraillePackage.holdsPackage(inArchivePaths: ["a.bopf", "sub/b.bopf", "a1.brf"]))
        // The package file chosen is the book, whatever lies beside it.
        XCTAssertNoThrow(try BardBraillePackage.open(at: twin.file))
    }

    /// A volume that holds no braille, and one that is not braille in its
    /// code, are refused naming the volume, with the reason after it.
    func testAnEmptyVolumeAndOneThatIsNotBrailleAreRefusedByName() throws {
        let empty = try packageFolder(volumes: try volumeFiles().merging(["salt-v2.brf": Data()]) { _, new in new })
        XCTAssertThrowsError(try markdown(of: empty.file)) {
            XCTAssertEqual($0.localizedDescription, damagedSentence("salt-v2.brf", "it holds no braille"))
        }
        let notBraille = try packageFolder(volumes: try volumeFiles().merging(["salt-v3.brf": Data("caf\u{E9}\r\n".utf8)]) { _, new in new })
        XCTAssertThrowsError(try markdown(of: notBraille.file)) {
            let sentence = $0.localizedDescription
            XCTAssertTrue(sentence.hasPrefix("The file “salt-v3.brf” in this book is damaged or incomplete: "), sentence)
            XCTAssertFalse(sentence.contains("DAISY"), sentence)
        }
    }

    /// With page markers on, a volume's heading comes right after the marker
    /// of the volume's first page, so Go to Page lands on the heading; the
    /// volume's own headings are one level deeper than the heading; and each
    /// volume's last pages stay in their volume, ahead of the next heading.
    func testAVolumeHeadingFollowsItsFirstPagesMarkerAndTheBooksHeadingsGoDeeper() throws {
        let (_, file) = try packageFolder()
        let text = try BrailleBookReader.markdown(of: file, table: ebaeContracted, includesPages: true)
        let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
        for number in 1...3 {
            let index = try XCTUnwrap(lines.firstIndex(of: "# Volume \(number)"))
            XCTAssertTrue(index > 0 && lines[index - 1].hasPrefix(MarkdownPageMarker.prefix), "volume \(number): \(lines[max(index - 1, 0)])")
            // The next line is the volume's own first heading, a level deeper.
            XCTAssertTrue(lines[index + 1].hasPrefix("## "), lines[index + 1])
        }
        // No volume's heading is of the book's own level: every other heading is deeper.
        XCTAssertEqual(lines.filter { $0.hasPrefix("# ") }, ["# Volume 1", "# Volume 2", "# Volume 3"])
    }

    /// A page with a number and no text at the end of a volume begins at the
    /// next volume's first block, but stays in its own volume: its marker
    /// comes before the next heading, and the next volume's first page marker
    /// comes right before that heading.
    func testATrailingPageWithNoTextStaysInItsOwnVolume() throws {
        func start(_ label: String, block: Int, volume: Int) -> BrailleBookReader.PageStart {
            BrailleBookReader.PageStart(
                marker: MarkdownPageMarker(label: label, ordinal: 1), blockIndex: block, cellOffset: 0, volumeIndex: volume
            )
        }
        let translation = BrailleBookReader.PagedTranslation(
            blocks: [.paragraph(text: "\u{2801}"), .paragraph(text: "\u{2803}")],
            starts: [start("p1", block: 0, volume: 0), start("p2", block: 1, volume: 0), start("p3", block: 1, volume: 1)],
            volumeStarts: [BrailleVolumeStart(number: 1, index: 0, blockIndex: 0), BrailleVolumeStart(number: 2, index: 1, blockIndex: 1)]
        )
        let text = try XCTUnwrap(translation.markdown(from: [EmphasizedText("one"), EmphasizedText("two")]))
        let order = ["page: p1", "# Volume 1", "one", "page: p2", "page: p3", "# Volume 2", "two"]
        var from = text.startIndex
        for piece in order {
            let found = try XCTUnwrap(text.range(of: piece, range: from..<text.endIndex), "\(piece) in \(text)")
            from = found.upperBound
        }
    }

    /// Volumes together past the size one braille file may have are refused
    /// from the sizes the file system gives, before any is read: here two
    /// volumes of 17 MB each, which hold no braille, so reading either would
    /// have said so instead.
    func testVolumesTogetherPastTheLimitAreRefusedBeforeAnyIsRead() throws {
        let big = Data(count: 17 * 1_048_576)
        let (_, file) = try packageFolder(volumes: ["salt-v1.brf": big, "salt-v2.brf": big, "salt-v3.brf": Data(",A\r\n".utf8)])
        XCTAssertThrowsError(try BardBraillePackage.open(at: file).readPages(code: .northAmerican)) {
            XCTAssertEqual($0 as? BrailleFileError, .fileTooLarge)
        }
        // The code detector's read, with no table named, has the same bound.
        XCTAssertFalse(BrailleCodeDetector.looksLikeEBAE(fileAt: file, fileCode: nil))
    }

    /// Hrefs that are escaped (a space as %20) or nested in a folder find
    /// their volumes.
    func testEscapedAndNestedHrefsFindTheirVolumes() throws {
        let files = try volumeFiles()
        let first = try XCTUnwrap(files["salt-v1.brf"])
        let second = try XCTUnwrap(files["salt-v2.brf"])
        let third = try XCTUnwrap(files["salt-v3.brf"])
        let (_, file) = try packageFolder(
            packageText(manifest: ["vol%201.brf", "sub/vol2.brf", "salt-v3.brf"]),
            volumes: ["vol 1.brf": first, "sub/vol2.brf": second, "salt-v3.brf": third]
        )
        let package = try BardBraillePackage.open(at: file)
        XCTAssertEqual(package.volumePaths, ["vol 1.brf", "sub/vol2.brf", "salt-v3.brf"])
        XCTAssertEqual(try package.readPages(code: .northAmerican).volumeStarts.count, 3)
    }

    /// A volume's number is its place in the spine, whatever came before it.
    func testAVolumeIsNumberedByItsPlaceInTheSpine() throws {
        let rows = [String(String.UnicodeScalarView([0x2801, 0x2803, 0x2809].compactMap(Unicode.Scalar.init)))]
        var book = BrailleFilePages(kind: .brf)
        try book.append(volume: BrailleFilePages(kind: .brf, pages: [rows]), number: 2)
        try book.append(volume: BrailleFilePages(kind: .brf, pages: [rows]), number: 5)
        XCTAssertEqual(book.volumeNumbers, [2, 5])
        XCTAssertEqual(BraillePageAnalyzer.structure(of: book).volumeStarts.map(\.number), [2, 5])
    }

    /// A ZIP is one BARD book when it holds one package file, or one
    /// shallowest, and the table at import is that package's, never one found
    /// deeper; two package files at one level are no one book, and the import says so.
    func testSeveralPackagesInAZIP() throws {
        let deep = packageText(code: "UEB", level: "1")
        var entries: [String: Data] = ["salt.bopf": packageText(), "sub/deep.bopf": deep]
        for (name, data) in try volumeFiles() { entries[name] = data }
        let archive = try makeTemporaryZip(prefix: "BardSeveral", entries: entries)
        addTeardownBlock { try? FileManager.default.removeItem(at: archive) }
        XCTAssertTrue(BardBraillePackage.isPackageZip(url: archive))
        XCTAssertEqual(try BardBraillePackage.open(at: archive).entryPath, "salt.bopf")
        XCTAssertEqual(FileImportService.brailleReading(ofImported: archive).table, "en_US.tbl")

        entries["other.bopf"] = deep
        let twoAtOneLevel = try makeTemporaryZip(prefix: "BardTwo", entries: entries)
        addTeardownBlock { try? FileManager.default.removeItem(at: twoAtOneLevel) }
        // The archive is a BARD archive, so the import says what is wrong with
        // it, and names a package file, rather than calling it an unknown format.
        XCTAssertTrue(BardBraillePackage.isPackageZip(url: twoAtOneLevel))
        XCTAssertEqual(BookFormat.detect(from: twoAtOneLevel), .braille)
        XCTAssertThrowsError(try BardBraillePackage.open(at: twoAtOneLevel))
        XCTAssertThrowsError(try FileImportService.importFileWithReport(from: twoAtOneLevel, toFolder: folderPath)) {
            let text = $0.localizedDescription
            XCTAssertTrue(text.contains(".bopf” in this book is damaged or incomplete: it is one of 2 package files at the same level"), text)
        }
    }

    // MARK: - Pages

    /// The package's numbers are only checked, never used: its line length
    /// (40) is not the width the volumes are laid out in (30 here, as the
    /// review's sample is laid out at 38 under a declared 40), and its page
    /// count is wrong. The volumes measure their own width, so the book keeps
    /// every centered heading and no page number is left in its text.
    func testThePackagesNumbersAreOnlyCheckedNeverTheWidth() throws {
        cellsPerLine = 30
        let (folder, file) = try packageFolder(packageText(pages: "9999"))
        let book = try BardBraillePackage.open(at: file)
        XCTAssertEqual(book.lineLength, 40)
        XCTAssertEqual(book.pageLength, 25)
        XCTAssertEqual(book.declaredPageCount, 9999)
        XCTAssertEqual(book.declaredVolumeCount, 3)

        let pages = try book.readPages(code: .northAmerican)
        XCTAssertNil(pages.lineWidth)
        XCTAssertEqual(pages.volumeStarts.count, 3)
        XCTAssertEqual(pages.volumeStarts.first, 0)
        XCTAssertEqual(BraillePageAnalyzer.commonWidth(ofVolumesIn: pages), 30)
        // Each volume, taken out of the book, is what its file reads as alone.
        for (index, name) in volumeNames.enumerated() {
            let alone = try BrailleFileReader.read(folder.appendingPathComponent(name), as: .brf)
            XCTAssertEqual(pages.volume(at: index).pages, alone.pages, name)
        }
        assertEveryTitleIsAHeadingAndNoPageNumberRemains(in: try markdown(of: file))

        // A line length the package gives that is no width at all is not one.
        XCTAssertNil(try BardBraillePackage.open(at: try packageFolder(packageText(lineLength: "7")).file).lineLength)
    }

    /// A volume of 20 pages or more with one line of 39 cells on its third
    /// is read at the book's width (30), keeping every title as a heading.
    /// (The numbered pages decide the width here; the analyzer's own test
    /// pins the stray line's being left out where no page is numbered.)
    func testAVolumeWithAStrayLongLineKeepsItsHeadings() throws {
        cellsPerLine = 30
        var volumes = try volumeFiles()
        let scratch = try makeSandboxDirectory("BardStray")
        var long = [BraillePrintBlock.heading(level: 1, EmphasizedText("The Harbour Office"))]
        long += (0..<300).map { _ in
            BraillePrintBlock.paragraph(EmphasizedText("Nobody at the harbour office could explain the missing barrel."))
        }
        let data = try BrailleDocumentWriter.brf(of: long, options: writerOptions(), workingIn: scratch)
        var pages = String(decoding: data, as: UTF8.self).components(separatedBy: "\u{0C}")
        XCTAssertGreaterThanOrEqual(pages.count, 20)
        let firstRowEnd = try XCTUnwrap(pages[2].range(of: "\r\n"))
        pages[2].insert(contentsOf: "\r\n" + String(repeating: "x", count: 39), at: firstRowEnd.lowerBound)
        volumes["salt-v2.brf"] = Data(pages.joined(separator: "\u{0C}").utf8)

        let (_, file) = try packageFolder(volumes: volumes)
        let read = try BardBraillePackage.open(at: file).readPages(code: .northAmerican)
        XCTAssertEqual(BraillePageAnalyzer.commonWidth(ofVolumesIn: read), 30)
        assertEveryTitleIsAHeadingAndNoPageNumberRemains(in: try markdown(of: file))
    }

    /// Asserts that each of the fixture's three titles is a heading line of
    /// `text`, whatever its level, and that the text holds no digit: the
    /// fixture has none, so any is a braille page number left in it.
    private func assertEveryTitleIsAHeadingAndNoPageNumberRemains(
        in text: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let lines = text.components(separatedBy: "\n")
        for title in ["The Salt Ledger", "The Harbour Office", "The Answer"] {
            XCTAssertTrue(lines.contains { $0.hasPrefix("#") && $0.hasSuffix(" " + title) }, title, file: file, line: line)
        }
        // The volume headings have their numbers; the volumes' own text has none.
        let body = lines.filter { !($0.hasPrefix("#") && $0.contains(" Volume ")) }.joined(separator: "\n")
        XCTAssertNil(body.rangeOfCharacter(from: .decimalDigits), file: file, line: line)
    }

    /// Each volume is laid out on its own: the structure names where each
    /// begins, and a volume that begins in a paragraph, with no heading and
    /// the sentence the volume before it left unfinished, still begins a block
    /// of its own, so no paragraph runs from one volume into the next.
    func testEachVolumeIsLaidOutOnItsOwn() throws {
        // The second volume has no heading, and the first ends mid-sentence.
        let scratch = try makeSandboxDirectory("BardOwnLayout")
        var files = try volumeFiles()
        files["salt-v1.brf"] = try BrailleDocumentWriter.brf(
            of: [BraillePrintBlock.heading(level: 1, EmphasizedText("The Salt Ledger")),
                 BraillePrintBlock.paragraph(EmphasizedText("Orsolya counted the barrels twice and wrote both"))],
            options: writerOptions(), workingIn: scratch
        )
        files["salt-v2.brf"] = try BrailleDocumentWriter.brf(
            of: [BraillePrintBlock.paragraph(EmphasizedText("numbers in her ledger, and nobody at the harbour office could explain the missing barrel."))],
            options: writerOptions(), workingIn: scratch
        )
        let (_, file) = try packageFolder(volumes: files)
        let pages = try BardBraillePackage.open(at: file).readPages(code: .northAmerican)
        let structure = BraillePageAnalyzer.structure(of: pages)
        let firstVolume = BraillePageAnalyzer.structure(of: pages.volume(at: 0))
        XCTAssertEqual(structure.volumeStarts.map(\.number), [1, 2, 3])
        XCTAssertEqual(structure.volumeStarts.map(\.index), [0, 1, 2])
        XCTAssertEqual(structure.volumeStarts.first?.blockIndex, 0)
        // The second volume's first block follows every block of the first.
        XCTAssertEqual(structure.volumeStarts[1].blockIndex, firstVolume.blocks.count)
        guard structure.blocks.indices.contains(structure.volumeStarts[1].blockIndex) else { return XCTFail("no block") }
        if case .heading = structure.blocks[structure.volumeStarts[1].blockIndex] { XCTFail("the second volume has no heading") }
        // The headings above the book's own are the volumes'.
        XCTAssertEqual(try markdown(of: file).components(separatedBy: "\n").filter { $0.hasPrefix("# ") }, ["# Volume 1", "# Volume 2", "# Volume 3"])
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
            // The book's own headings are one level deeper than the volumes'.
            XCTAssertEqual(
                try headings(of: book),
                ["1: Volume 1", "2: The Salt Ledger", "1: Volume 2", "2: The Harbour Office", "1: Volume 3", "2: The Answer"], name
            )
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
        // The same book as a ZIP, at its top level or in a folder, has the
        // checksum of its folder: the two are found duplicates of each other
        // (the ZIP is checksummed as its package inventory would be).
        XCTAssertEqual(try FileImportService.importHash(of: try packageZip()), same)
        XCTAssertEqual(try FileImportService.importHash(of: try packageZip(inFolder: "Salt Ledger")), same)

        let (changedFolder, changedFile) = try packageFolder()
        try Data("changed".utf8).write(to: changedFolder.appendingPathComponent("salt-v2.brf"))
        XCTAssertNotEqual(try FileImportService.importHash(of: changedFile), same)
    }

    // MARK: - A BARD Package in HumanFiles

    /// A BARD package in `HumanFiles/` (gitignored, kept in the main checkout
    /// only, so found from a worktree too), read in place: nothing of it is
    /// copied or imported. It runs in the orchestrator's suite on the user's
    /// Mac, and skips on GitHub's runners and wherever no ZIP there holds a
    /// `.bopf`.
    ///
    /// Everything it expects comes from the package, read at run time: its
    /// declared volumes in order, its title and author, the table it names,
    /// and, of the text, that every volume has its heading, that the book has
    /// far more headings than volumes (a width taken from the package's line
    /// length once erased them all), and that few braille page numbers are
    /// left in the text (that width left two thousand; the numbers that stand
    /// in a long novel's own text are far fewer). It prints the volumes, the
    /// pages, the headings, and the seconds the reading took.
    func testAPackageInHumanFilesReadsAsOneBook() throws {
        try XCTSkipIf(TestMachine.isGitHubRunner, "the user's private samples are on the user's Mac only")
        #if os(macOS)
        guard let sample = humanFilesArchivesIfPresent().first(where: { BardBraillePackage.isPackageZip(url: $0) }) else {
            throw XCTSkip("no ZIP in HumanFiles/ holds a BARD package")
        }

        XCTAssertEqual(BookFormat.detect(from: sample), .braille)
        let package = try BardBraillePackage.open(at: sample)
        let volumes = package.volumePaths.count
        XCTAssertGreaterThan(volumes, 1)
        XCTAssertEqual(package.declaredVolumeCount, volumes)
        // The spine's order is the order of the names, as the package lists them.
        XCTAssertEqual(package.volumePaths, package.volumePaths.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        XCTAssertFalse(package.title.isEmpty)
        XCTAssertFalse(package.author.isEmpty)
        let table = try XCTUnwrap(package.table)
        XCTAssertEqual(FileImportService.brailleReading(ofImported: sample).table, table)

        let started = Date()
        let pages = try package.readPages(code: .northAmerican)
        XCTAssertEqual(pages.volumeStarts.count, volumes)
        if let declared = package.declaredPageCount {
            XCTAssertEqual(Double(pages.pageCount), Double(declared), accuracy: Double(declared) * 0.05)
        }
        let structure = BraillePageAnalyzer.structure(of: pages)
        XCTAssertEqual(structure.volumeStarts.map(\.number), Array(1...volumes))
        let headingCount = structure.blocks.filter { if case .heading = $0 { return true } else { return false } }.count
        XCTAssertGreaterThan(headingCount, volumes * 5)
        // Number words (the number sign and digit cells a to j) left in the blocks.
        let digitCells = Set("\u{2801}\u{2803}\u{2809}\u{2819}\u{2811}\u{280B}\u{281B}\u{2813}\u{280A}\u{281A}".unicodeScalars)
        let numberWords = structure.blocks.reduce(0) { count, block in
            count + block.text.split(separator: "\u{2800}").filter { word in
                let scalars = Array(word.unicodeScalars)
                return scalars.count > 1 && scalars[0] == "\u{283C}" && scalars.dropFirst().allSatisfy { digitCells.contains($0) }
            }.count
        }
        XCTAssertLessThan(numberWords, 700, "braille page numbers left in the text")
        let text = try markdown(of: sample, table: table)
        let seconds = Date().timeIntervalSince(started)
        let volumeHeadings = text.components(separatedBy: "\n").filter { $0.hasPrefix("# Volume ") }
        XCTAssertEqual(volumeHeadings, (1...volumes).map { "# Volume \($0)" })
        print("BARD package in HumanFiles: \(volumes) volumes, \(pages.pageCount) pages, \(headingCount) headings, "
              + "\(numberWords) number words left, \(text.count) characters, read in \(String(format: "%.1f", seconds)) s")
        #endif
    }

}
