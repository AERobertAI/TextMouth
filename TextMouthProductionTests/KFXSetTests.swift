import XCTest
import ZIPFoundation
@testable import TextMouth

/// Sets of KFX containers (FMT52, layer 5): a `.kfx-zip`, and a `.kfx` with
/// the folder Kindle keeps beside it. Every container of a set is checked for
/// protection, the containers' local symbols differ and meet by name, and a
/// hostile archive or folder is refused or left alone, never followed.
final class KFXSetTests: XCTestCase {

    private static let protectedSentence =
        "This Kindle book is copy-protected, and TextMouth can't read copy-protected books."

    // MARK: - Helpers

    /// A one-section book with the words "Alpha one." and "Beta two.".
    private func smallBook(title: String? = "Real Title") -> KFXTestBook {
        var book = KFXTestBook()
        book.title = title
        book.sections = [("c0", [.text("Alpha one."), .text("Beta two.")])]
        return book
    }

    /// A container that holds only a book's metadata (title and author),
    /// with a local symbol table of its own.
    private func metadataContainer(title: String) -> [UInt8] {
        var builder = KFXContainerBuilder()
        builder.localSymbols = ["unrelated", "also_unrelated"]
        builder.add(type: 490, .structure([(491, .list([.structure([
            (495, .string("kindle_title_metadata")),
            (258, .list([
                .structure([(492, .string("title")), (307, .string(title))]),
                .structure([(492, .string("author")), (307, .string("Sidecar Author"))]),
            ])),
        ])]))]))
        return builder.build()
    }

    /// The main container of `smallBook` without its metadata.
    private func mainWithoutMetadata() -> [UInt8] {
        var book = smallBook()
        return book.build { builder in builder.entities.removeAll { $0.type == 490 } }
    }

    /// A folder of the test's own, created and removed with it.
    private func folder(_ label: String) throws -> URL {
        try makeSandboxDirectory(label)
    }

    private func write(_ bytes: [UInt8], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes).write(to: url)
    }

    /// A `.kfx-zip` holding `members`.
    private func makeSet(_ members: [(String, [UInt8])], named name: String = "set.kfx-zip", compression: CompressionMethod = .none) throws -> URL {
        let made = try makeTemporaryZip(
            prefix: "kfx-set", orderedEntries: members.map { TestZIPEntry($0.0, Data($0.1)) }, compressionMethod: compression)
        addTeardownBlock { try? FileManager.default.removeItem(at: made) }
        let url = try folder("KFXZip").appendingPathComponent(name)
        try FileManager.default.copyItem(at: made, to: url)
        return url
    }

    private func words(_ book: MOBIParser.PreparedBook) -> [String] {
        book.chapters.flatMap { $0.chapter.text.split(whereSeparator: \.isWhitespace).map(String.init) }
    }

    // MARK: - A .kfx-zip

    func testASetOfOneContainerReadsAsTheContainerDoes() throws {
        var book = smallBook()
        let bytes = book.build()
        let looseURL = try folder("Loose").appendingPathComponent("book.kfx")
        try write(bytes, to: looseURL)
        let direct = try KFXParser.prepareBook(url: looseURL)
        let set = try KFXParser.prepareBook(url: makeSet([("book.kfx", bytes)]))
        XCTAssertEqual(words(set), words(direct))
        XCTAssertEqual(words(set), ["Alpha", "one.", "Beta", "two."])
        XCTAssertEqual(set.title, "Real Title")
    }

    func testTheRealFeatureBookInASetReadsAsItsContainerDoes() throws {
        let bytes = [UInt8](try Data(contentsOf: formatSampleURL("kfx/kfx-features.kfx")))
        let set = try KFXParser.prepareBook(url: makeSet([("kfx-features.kfx", bytes), ("readme.txt", Array("note".utf8))]))
        let direct = try KFXParser.prepareBook(url: formatSampleURL("kfx/kfx-features.kfx"))
        XCTAssertEqual(words(set), words(direct))
        XCTAssertEqual(set.chapters.count, 3)
    }

    func testTheContainersOfASetMeetByNameWhateverTheirLocalSymbolNumbers() throws {
        // The text lives in a second container, whose symbol table lists its
        // names in another order: content_1 is 861 there and 860 in the main.
        var book = smallBook()
        let main = book.build { builder in builder.entities.removeAll { $0.type == 145 || $0.type == 490 } }
        var second = KFXContainerBuilder()
        second.localSymbols = ["zzz_first", "content_1"]
        second.add(type: 145, name: "content_1", .structure([
            (4, .symbol(second.id(of: "content_1"))), (146, .list([.string("Alpha one."), .string("Beta two.")])),
        ]))
        let set = try KFXParser.prepareBook(url: makeSet([("main.kfx", main), ("text.kfx", second.build()), ("meta.kfx", metadataContainer(title: "From Meta"))]))
        XCTAssertEqual(words(set), ["Alpha", "one.", "Beta", "two."])
        XCTAssertEqual(set.title, "From Meta")
        XCTAssertEqual(set.author, "Sidecar Author")
    }

    func testAFragmentTheFirstContainerHoldsIsTheOneReadWhateverALaterOneSays() throws {
        let set = try KFXParser.prepareBook(url: makeSet([
            ("main.kfx", smallBookBytes(title: "Real Title")), ("forged.kfx", metadataContainer(title: "Forged Title")),
        ]))
        XCTAssertEqual(set.title, "Real Title")
    }

    private func smallBookBytes(title: String?) -> [UInt8] {
        var book = smallBook(title: title)
        return book.build()
    }

    func testASetWhoseOnlyContainersHoldNoTextIsPartOfABook() throws {
        let url = try makeSet([("meta.kfx", metadataContainer(title: "Only Metadata"))])
        XCTAssertThrowsError(try KFXParser.prepareBook(url: url)) {
            XCTAssertEqual($0 as? KFXError, .partOfABook)
        }
        XCTAssertEqual(try KFXParser.readMetadata(url: url).title, "Only Metadata")
    }

    func testASetWithAProtectedContainerOrAVoucherIsRefusedWholeEvenWhenTheMainFileIsPlain() throws {
        let plain = smallBookBytes(title: "Real Title")
        let protected = KFXSignature.protectedMagic + [UInt8](repeating: 1, count: 32)
        for members in [
            [("main.kfx", plain), ("other.kfx", protected)],
            [("other.kfx", protected), ("main.kfx", plain)],
            [("main.kfx", plain), ("voucher", Array("key".utf8))],
            [("main.kfx", plain), ("B0ABC_EBOK.voucher", Array("key".utf8))],
        ] {
            XCTAssertThrowsError(try KFXParser.prepareBook(url: makeSet(members))) {
                XCTAssertEqual($0 as? MOBIError, .copyProtected)
                XCTAssertEqual($0.localizedDescription, Self.protectedSentence)
            }
            XCTAssertThrowsError(try KFXParser.readMetadata(url: makeSet(members))) { XCTAssertEqual($0 as? MOBIError, .copyProtected) }
        }
    }

    func testARealKindleCreatePackageIsRefusedAndNeverRead() throws {
        let url = try copyOfFormatSample("kfx/kfx-features.kpf")
        XCTAssertThrowsError(try KFXParser.prepareBook(url: url)) {
            XCTAssertEqual($0 as? KFXError, .kindleCreatePackage)
            XCTAssertEqual($0.localizedDescription, "This file is a Kindle Create package, which TextMouth can't read yet.")
        }
        XCTAssertThrowsError(try KFXParser.readMetadata(url: url)) { XCTAssertEqual($0 as? KFXError, .kindleCreatePackage) }
    }

    // MARK: - Hostile archives

    func testAnArchiveWithMoreContainersThanASetHoldsIsRefusedQuickly() throws {
        let container = smallBookBytes(title: nil)
        let url = try makeSet((0...KFXPackage.maximumContainers).map { ("part\($0).kfx", container) })
        assertRefusedQuickly("65 containers") { try KFXParser.prepareBook(url: url) }
    }

    func testAnArchiveWithMoreMembersThanASetCouldHoldIsRefusedQuickly() throws {
        let url = try makeSet((0...KFXPackage.maximumMembers).map { ("f\($0).txt", [UInt8]()) })
        assertRefusedQuickly("4,097 members") { try KFXParser.prepareBook(url: url) }
    }

    func testAMemberFarLargerThanTheLimitIsRefusedBeforeItIsInflated() throws {
        // 70 MB of zeros deflates to a few dozen KB; the member declares its size.
        let size = Int(DocumentByteLimit.standard) + 6_000_000
        let bomb = KFXSignature.containerMagic + [2, 0] + [UInt8](repeating: 0, count: size)
        let url = try makeSet([("bomb.kfx", bomb)], compression: .deflate)
        XCTAssertLessThan(try XCTUnwrap(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize), 1_000_000)
        let error = assertRefusedQuickly("zip bomb") { try KFXParser.prepareBook(url: url) }
        XCTAssertEqual(error as? DocumentTooLargeError, DocumentTooLargeError(limit: DocumentByteLimit.standard))
    }

    func testAMemberThatStartsLikeAContainerButIsNotOneIsDamageNotACrash() throws {
        let url = try makeSet([("main.kfx", smallBookBytes(title: nil)), ("junk.kfx", KFXSignature.containerMagic + [2, 0, 9, 9, 9])])
        assertRefusedQuickly("junk member") { try KFXParser.prepareBook(url: url) }
    }

    func testAnArchiveThatIsNotAnArchiveAtAllIsRefused() throws {
        let url = try folder("NotZip").appendingPathComponent("broken.kfx-zip")
        try write(KFXSignature.zipMagic + [UInt8](repeating: 7, count: 100), to: url)
        assertRefusedQuickly("broken zip") { try KFXParser.prepareBook(url: url) }
    }

    // MARK: - The folder beside a book

    func testTheFolderBesideABookGivesItsMetadataWhenTheMainFileHasNone() throws {
        let root = try folder("Sdr")
        let main = root.appendingPathComponent("Book.kfx")
        try write(mainWithoutMetadata(), to: main)
        try write(metadataContainer(title: "Title From The Folder"), to: root.appendingPathComponent("Book.sdr/metadata.kfx"))
        let book = try KFXParser.prepareBook(url: main)
        XCTAssertEqual(book.title, "Title From The Folder")
        XCTAssertEqual(book.author, "Sidecar Author")
        XCTAssertEqual(words(book), ["Alpha", "one.", "Beta", "two."])
        XCTAssertEqual(try KFXParser.readMetadata(url: main).title, "Title From The Folder")
    }

    func testWhatTheMainFileSaysIsNotChangedByTheFolder() throws {
        let root = try folder("SdrForged")
        let main = root.appendingPathComponent("Book.kfx")
        try write(smallBookBytes(title: "Real Title"), to: main)
        try write(metadataContainer(title: "Forged Title"), to: root.appendingPathComponent("Book.sdr/metadata.kfx"))
        XCTAssertEqual(try KFXParser.prepareBook(url: main).title, "Real Title")
    }

    func testAVoucherOrAProtectedFileInTheFolderRefusesTheBook() throws {
        for (path, bytes) in [
            ("Book.sdr/voucher", Array("key".utf8)),
            ("Book.sdr/assets/deeper/x.voucher", Array("key".utf8)),
            ("Book.sdr/part.kfx", KFXSignature.protectedMagic + [UInt8](repeating: 3, count: 20)),
            ("Book.voucher", Array("key".utf8)),
        ] {
            let root = try folder("SdrProtected")
            let main = root.appendingPathComponent("Book.kfx")
            try write(smallBookBytes(title: "Real Title"), to: main)
            try write(bytes, to: root.appendingPathComponent(path))
            XCTAssertThrowsError(try KFXParser.prepareBook(url: main), path) { XCTAssertEqual($0 as? MOBIError, .copyProtected, path) }
            XCTAssertThrowsError(try KFXParser.readMetadata(url: main), path) { XCTAssertEqual($0 as? MOBIError, .copyProtected, path) }
            // The same book named .azw, as Kindle's apps name it, is refused through the MOBI reader.
            let azw = root.appendingPathComponent("Book.azw")
            try FileManager.default.copyItem(at: main, to: azw)
            XCTAssertThrowsError(try MOBIParser.prepareBook(url: azw), path) { XCTAssertEqual($0 as? MOBIError, .copyProtected, path) }
        }
    }

    func testALinkInTheFolderIsNeverFollowed() throws {
        let root = try folder("SdrLink")
        let outside = try folder("Outside").appendingPathComponent("secret.kfx")
        try write(metadataContainer(title: "Title From Outside"), to: outside)
        let main = root.appendingPathComponent("Book.kfx")
        try write(mainWithoutMetadata(), to: main)
        let sdr = root.appendingPathComponent("Book.sdr")
        try FileManager.default.createDirectory(at: sdr, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: sdr.appendingPathComponent("link.kfx"), withDestinationURL: outside)
        // A whole folder that is a link is not scanned either.
        let linked = root.appendingPathComponent("Other.kfx")
        try write(mainWithoutMetadata(), to: linked)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Other.sdr"), withDestinationURL: outside.deletingLastPathComponent())
        XCTAssertEqual(try KFXParser.prepareBook(url: main).title, "Book", "the file's own name: the linked file named nothing")
        XCTAssertEqual(try KFXParser.prepareBook(url: linked).title, "Other")
    }

    func testTheFolderIsScannedOnlyToAFixedDepthAndAFixedNumberOfNames() throws {
        let root = try folder("SdrBounds")
        let main = root.appendingPathComponent("Book.kfx")
        try write(mainWithoutMetadata(), to: main)
        // Four levels down is past the depth limit.
        try write(metadataContainer(title: "Too Deep"), to: root.appendingPathComponent("Book.sdr/a/b/c/d/metadata.kfx"))
        XCTAssertEqual(try KFXParser.prepareBook(url: main).title, "Book")
        // Three levels down is read.
        try write(metadataContainer(title: "Deep Enough"), to: root.appendingPathComponent("Book.sdr/a/b/c/metadata.kfx"))
        XCTAssertEqual(try KFXParser.prepareBook(url: main).title, "Deep Enough")

        // More names than the scan visits: the container sorted last is not reached.
        let crowded = try folder("SdrCrowded")
        let crowdedMain = crowded.appendingPathComponent("Book.kfx")
        try write(mainWithoutMetadata(), to: crowdedMain)
        for index in 0..<(KFXSidecar.maximumEntries + 20) {
            try write([], to: crowded.appendingPathComponent(String(format: "Book.sdr/f%04d.txt", index)))
        }
        try write(metadataContainer(title: "Past The Cap"), to: crowded.appendingPathComponent("Book.sdr/zzz.kfx"))
        XCTAssertEqual(try KFXParser.prepareBook(url: crowdedMain).title, "Book")
    }

    func testAFolderContainerThatDoesNotReadIsLeftOut() throws {
        let root = try folder("SdrDamaged")
        let main = root.appendingPathComponent("Book.kfx")
        try write(smallBookBytes(title: "Real Title"), to: main)
        try write(KFXSignature.containerMagic + [2, 0, 1, 2, 3], to: root.appendingPathComponent("Book.sdr/broken.kfx"))
        XCTAssertEqual(try KFXParser.prepareBook(url: main).title, "Real Title")
    }

    // MARK: - The Kindle apps' names

    func testAnAzwHoldingARealKFXBookReadsThroughTheMOBIReaderAsKFXWithoutPages() throws {
        let url = try copyOfFormatSample("kfx/kfx-features.kfx", named: "Handbook.azw")
        let book = try MOBIParser.prepareBook(url: url)
        XCTAssertEqual(book.title, "The Tool Library Handbook")
        XCTAssertEqual(book.chapters.count, 3)
        XCTAssertTrue(book.chapters.allSatisfy { $0.chapter.pages.isEmpty }, "a Kindle (MOBI) book has no pages")
        XCTAssertEqual(try MOBIParser.readMetadata(url: url).title, "The Tool Library Handbook")
        XCTAssertEqual(BookFormat.detect(from: url), .mobi)
    }

    func testAnAzw8FileIsAKFXBook() throws {
        let url = try copyOfFormatSample("kfx/kfx-features.kfx", named: "Handbook.azw8")
        XCTAssertEqual(BookFormat.detect(from: url), .kfx)
        XCTAssertEqual(try KFXParser.prepareBook(url: url).chapters.count, 3)
    }

    // MARK: - Import

    func testTheFeatureBookImportsWithItsNamesChaptersAndPages() throws {
        let imported = try importedForTest(try copyOfFormatSample("kfx/kfx-features.kfx"))
        XCTAssertEqual(imported.book.format, .kfx)
        XCTAssertEqual(imported.book.title, "The Tool Library Handbook")
        XCTAssertEqual(imported.book.author, "Test Author")
        XCTAssertTrue(imported.report.isComplete)
        let content = try openedContent(of: imported.book)
        XCTAssertEqual(content.chapters.map(\.title), [
            "Chapter One: Headings and Emphasis", "Chapter Two: Lists and Tables", "Chapter Three: Notes, Links and Pictures",
        ])
        XCTAssertEqual(content.pages.breaks.count, 5)
        XCTAssertEqual(imported.book.pageReaderVersion, PageReaderVersions.current(for: .kfx))
    }

    func testAnImportedKFXBookReadsTheSameFromItsSourceAfterItsTextIsRemoved() throws {
        let imported = try importedForTest(try copyOfFormatSample("kfx/kfx-features.kfx"))
        let before = try openedContent(of: imported.book)
        try FileManager.default.removeItem(at: MarkdownCacheService.cacheURL(for: imported.book))
        let after = try BookContentAnalysisService.load(book: imported.book, regenerateTextCache: true).content
        XCTAssertEqual(allText(of: after), allText(of: before))
        XCTAssertEqual(headingLines(of: after), headingLines(of: before))
        XCTAssertEqual(after.pages.breaks.count, before.pages.breaks.count)
    }

    func testImportingAProtectedOrPartialOrCreatePackageFailsWithItsSentence() throws {
        let root = try folder("ImportRefusals")
        let protected = root.appendingPathComponent("Bought.azw8")
        try write(KFXSignature.protectedMagic + [UInt8](repeating: 9, count: 40), to: protected)
        let partial = root.appendingPathComponent("Part.kfx")
        try write(metadataContainer(title: "Only Metadata"), to: partial)
        let create = try copyOfFormatSample("kfx/kfx-features.kpf")
        for (url, sentence) in [
            (protected, Self.protectedSentence),
            (partial, "This file holds only part of a Kindle book. Open the book's main .kfx file."),
            (create, "This file is a Kindle Create package, which TextMouth can't read yet."),
        ] {
            XCTAssertThrowsError(try FileImportService.importFileWithReport(from: url), url.lastPathComponent) {
                XCTAssertTrue($0.localizedDescription.hasSuffix(sentence), $0.localizedDescription)
            }
        }
    }
}
