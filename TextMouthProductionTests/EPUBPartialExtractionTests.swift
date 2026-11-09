import XCTest
import ZIPFoundation
@testable import TextMouth

/// EPUB books that cannot be read in full. A damaged file is named rather
/// than read as garbled text; every chapter left out is reported by number,
/// file, and reason while the rest are read; cache generation logs what is
/// missing; and an import that left chapters out warns once and keeps its
/// original, while one that found nothing readable fails and leaves nothing.
final class EPUBPartialExtractionTests: XCTestCase {

    // MARK: - Damaged Package Files

    /// A package document whose bytes no longer match their checksum is
    /// named as damaged rather than read as though it were intact.
    func testPackageDocumentFailingItsChecksumIsNamedAsDamaged() throws {
        let epub = try makeEPUB(chapters: Self.threeChapters)
        try damageData(of: "OEBPS/content.opf", in: epub)

        XCTAssertThrowsError(try EPUBParser.parse(url: epub)) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "The file “OEBPS/content.opf” in this EPUB book is damaged or incomplete: "
                    + "its contents do not match the checksum stored with them. "
                    + "Get a fresh copy of the book, then import it again."
            )
        }
    }

    /// A package document whose compressed data cannot be decoded is named
    /// the same way, instead of surfacing the ZIP library's own error.
    func testPackageDocumentThatCannotBeDecompressedIsNamedAsDamaged() throws {
        let epub = try makeEPUB(chapters: Self.threeChapters, compression: .deflate)
        try damageData(of: "OEBPS/content.opf", in: epub)

        XCTAssertThrowsError(try EPUBParser.parse(url: epub)) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "The file “OEBPS/content.opf” in this EPUB book is damaged or incomplete: "
                    + "its compressed data could not be decoded. "
                    + "Get a fresh copy of the book, then import it again."
            )
        }
    }

    /// Checksums are compared for real books, not only for fixtures: every
    /// file in the bundled EPUB, stored or compressed, passes.
    func testBundledEPUBPassesEveryChecksum() throws {
        let archive = try Archive(url: try requireFile("alice.epub"), accessMode: .read)
        var checked = 0
        for entry in archive where entry.type == .file {
            XCTAssertNoThrow(try EPUBParser.text(of: entry, in: archive), entry.path)
            checked += 1
        }
        XCTAssertEqual(checked, 22)
    }

    // MARK: - Chapters Left Out

    /// The acceptance case: a chapter deleted from the archive is named by
    /// its number and path, and the chapters on either side are still read,
    /// by the cache's preparation and by the direct reader alike.
    func testMissingMiddleChapterIsReportedAndTheOthersAreRead() throws {
        let epub = try makeEPUB(chapters: Self.threeChapters)
        try removeMember("OEBPS/ch02.xhtml", from: epub)

        let book = try EPUBParser.prepareBook(url: epub)

        XCTAssertEqual(book.chapters.map(\.chapter.title), ["Patching a Tube", "Adjusting the Brakes"])
        XCTAssertEqual(book.report.chapterCount, 3)
        XCTAssertEqual(book.report.blankChapterCount, 0)
        XCTAssertEqual(
            book.report.omissions,
            [ExtractionOmission(chapterNumber: 2, member: "OEBPS/ch02.xhtml", reason: .missingMember)]
        )
        XCTAssertEqual(
            book.report.message,
            "1 of 3 chapters could not be read: chapter 2 (“OEBPS/ch02.xhtml”) is missing from this EPUB book."
        )
        XCTAssertEqual(
            try EPUBParser.parse(url: epub).chapters.map(\.title),
            ["Patching a Tube", "Adjusting the Brakes"]
        )
    }

    // MARK: - Members Named in Another Case (ST09)

    /// A manifest that names "Text/Chapter1.xhtml" for the member
    /// "text/chapter1.xhtml" still has its chapter, and reports nothing missing.
    func testASpineMemberNamedInAnotherCaseIsRead() throws {
        let chapter = FixtureChapter(
            id: "ch1", href: "Text/Chapter1.xhtml",
            markup: Self.page("<h1>One</h1><p>Words of the first chapter.</p>"),
            storedAs: "OEBPS/text/chapter1.xhtml"
        )
        let epub = try makeEPUB(chapters: [chapter])

        let book = try EPUBParser.prepareBook(url: epub)

        XCTAssertEqual(book.chapters.count, 1)
        XCTAssertTrue(book.chapters.first?.chapter.text.contains("Words of the first chapter.") ?? false)
        XCTAssertEqual(book.report.omissions, [], "no missing-member warning")
        XCTAssertEqual(
            try EPUBParser.parse(url: epub).chapters.first?.text.contains("Words of the first chapter."), true
        )
    }

    /// With members "ch01.xhtml" and "CH01.xhtml", the manifest's exact spelling wins.
    func testAnExactMatchWinsOverACaseInsensitiveOne() throws {
        let wanted = Self.chapter(1, "Exact", "Words of the exact member.")
        // The package lists the other member too, under its own item, but
        // only the exact spelling is in the spine.
        let other = FixtureChapter(
            id: "other", href: "CH01.xhtml",
            markup: Self.page("<h1>Other</h1><p>Words of the other member.</p>")
        )
        let epub = try makeEPUB(chapters: [wanted, other], spine: ["ch01"])

        let book = try EPUBParser.prepareBook(url: epub)
        let text = book.chapters.map(\.chapter.text).joined(separator: "\n")

        XCTAssertTrue(text.contains("Words of the exact member."), text)
        XCTAssertFalse(text.contains("Words of the other member."), text)
    }

    /// container.xml naming "OEBPS/Content.opf" for the member
    /// "OEBPS/content.opf" still opens the book.
    func testThePackageDocumentNamedInAnotherCaseIsFound() throws {
        let epub = try makeEPUB(chapters: Self.threeChapters, rootfilePath: "OEBPS/Content.opf")

        let book = try EPUBParser.prepareBook(url: epub)

        XCTAssertEqual(book.chapters.map(\.chapter.title), ["Patching a Tube", "Truing a Wheel", "Adjusting the Brakes"])
    }

    /// A chapter whose compressed data cannot be decoded is reported as
    /// damaged, and the rest of the book is still read.
    func testUndecodableChapterIsReportedAsDamaged() throws {
        let epub = try makeEPUB(chapters: Self.threeChapters, compression: .deflate)
        try damageData(of: "OEBPS/ch02.xhtml", in: epub)

        let book = try EPUBParser.prepareBook(url: epub)

        XCTAssertEqual(book.chapters.map(\.chapter.title), ["Patching a Tube", "Adjusting the Brakes"])
        XCTAssertEqual(
            book.report.omissions,
            [ExtractionOmission(chapterNumber: 2, member: "OEBPS/ch02.xhtml", reason: .unreadableMember)]
        )
        XCTAssertEqual(
            book.report.message,
            "1 of 3 chapters could not be read: chapter 2 (“OEBPS/ch02.xhtml”) is damaged or incomplete."
        )
    }

    /// A stored chapter whose bytes no longer match its checksum is left out
    /// and reported, where it used to be read as garbled text.
    func testChapterFailingItsChecksumIsReportedRatherThanGarbled() throws {
        let epub = try makeEPUB(chapters: Self.threeChapters)
        try damageData(of: "OEBPS/ch02.xhtml", in: epub)

        let book = try EPUBParser.prepareBook(url: epub)

        XCTAssertEqual(book.chapters.map(\.chapter.title), ["Patching a Tube", "Adjusting the Brakes"])
        XCTAssertEqual(book.report.omissions.map(\.reason), [.unreadableMember])
    }

    /// A cover page without text is blank, not damaged: it is counted apart
    /// and never reported, and the book is complete.
    func testBlankCoverPageIsNotAnOmission() throws {
        let epub = try makeEPUB(chapters: [Self.blankPage("cover")] + Self.threeChapters)

        let book = try EPUBParser.prepareBook(url: epub)

        XCTAssertTrue(book.report.isComplete, book.report.message)
        XCTAssertEqual(book.report.chapterCount, 4)
        XCTAssertEqual(book.report.blankChapterCount, 1)
        XCTAssertEqual(book.chapters.map(\.chapter.title), ["Patching a Tube", "Truing a Wheel", "Adjusting the Brakes"])
    }

    /// A complete book has nothing to report and reads every chapter.
    func testCompleteBookHasAnEmptyReport() throws {
        let epub = try makeEPUB(chapters: Self.threeChapters)

        let book = try EPUBParser.prepareBook(url: epub)

        XCTAssertEqual(book.report, ExtractionReport(container: "this EPUB book", chapterCount: 3))
        XCTAssertEqual(book.chapters.count, 3)
        XCTAssertTrue(book.chapters[1].chapter.text.contains("Tighten the spoke opposite the wobble"))
    }

    /// The bundled book, a real EPUB, is complete: its fifteen spine
    /// documents are all counted and none is reported missing or damaged.
    func testBundledEPUBReportsNothingLeftOut() throws {
        let book = try EPUBParser.prepareBook(url: try requireFile("alice.epub"))

        XCTAssertTrue(book.report.isComplete, book.report.message)
        XCTAssertEqual(book.report.chapterCount, 15)
    }

    /// A spine entry naming an item the manifest does not list is reported
    /// by the name the spine gives it.
    func testSpineEntryWithoutAManifestItemIsReported() throws {
        let epub = try makeEPUB(chapters: Self.threeChapters, spine: ["ch01", "ch02", "appendix", "ch03"])

        let book = try EPUBParser.prepareBook(url: epub)

        XCTAssertEqual(book.chapters.count, 3)
        XCTAssertEqual(
            book.report.message,
            "1 of 4 chapters could not be read: chapter 3 (“appendix”) has no file listed in this EPUB book."
        )
    }

    /// An image in the reading order is a resource, not a chapter: it is not
    /// counted and not reported.
    func testImageInTheSpineIsNotAChapter() throws {
        let plate = FixtureChapter(id: "plate", href: "plate.jpg", markup: "JPEG bytes", mediaType: "image/jpeg")
        let epub = try makeEPUB(chapters: Self.threeChapters + [plate], spine: ["ch01", "plate", "ch02", "ch03"])

        let book = try EPUBParser.prepareBook(url: epub)

        XCTAssertTrue(book.report.isComplete, book.report.message)
        XCTAssertEqual(book.report.chapterCount, 3)
        XCTAssertEqual(book.chapters.count, 3)
    }

    /// A spine document of a type that cannot be read as text is a chapter
    /// left out, and is reported with its type, where it used to vanish.
    func testSpineDocumentOfAnUnreadableTypeIsReported() throws {
        let notes = FixtureChapter(
            id: "notes", href: "notes.txt", markup: "Carry a spare tube and two levers.", mediaType: "text/plain"
        )
        let epub = try makeEPUB(chapters: Self.threeChapters + [notes], spine: ["ch01", "notes", "ch02", "ch03"])

        let book = try EPUBParser.prepareBook(url: epub)

        XCTAssertEqual(book.chapters.count, 3)
        XCTAssertEqual(
            book.report.message,
            "1 of 4 chapters could not be read: chapter 2 (“OEBPS/notes.txt”) is a “text/plain” file, "
                + "which TextMouth cannot read."
        )
    }

    /// Stylesheets, fonts, sound, and images in the spine, whatever the case
    /// of their media types or any parameters, are resources: not counted.
    func testResourcesOfEveryKindInTheSpineAreNotChapters() throws {
        let resources = [
            FixtureChapter(id: "style", href: "style.css", markup: "p { margin: 0 }", mediaType: "text/css"),
            FixtureChapter(id: "face", href: "face.otf", markup: "font", mediaType: "application/vnd.ms-opentype"),
            FixtureChapter(id: "bell", href: "bell.mp3", markup: "sound", mediaType: "audio/mpeg"),
            FixtureChapter(id: "plan", href: "plan.png", markup: "image", mediaType: "IMAGE/PNG; q=0.9")
        ]
        let epub = try makeEPUB(
            chapters: Self.threeChapters + resources,
            spine: ["style", "ch01", "face", "ch02", "bell", "ch03", "plan"]
        )

        let book = try EPUBParser.prepareBook(url: epub)

        XCTAssertTrue(book.report.isComplete, book.report.message)
        XCTAssertEqual(book.report.chapterCount, 3)
        XCTAssertEqual(book.chapters.count, 3)
    }

    /// Media types ignore case, so a document declared in capitals is read
    /// as a chapter rather than passed over.
    func testDocumentTypesAreRecognizedWithoutRegardToCase() throws {
        var shouting = Self.threeChapters[1]
        shouting.mediaType = "Application/XHTML+XML"
        let epub = try makeEPUB(chapters: [Self.threeChapters[0], shouting, Self.threeChapters[2]])

        let book = try EPUBParser.prepareBook(url: epub)

        XCTAssertTrue(book.report.isComplete, book.report.message)
        XCTAssertEqual(book.chapters.map(\.chapter.title), ["Patching a Tube", "Truing a Wheel", "Adjusting the Brakes"])
    }

    /// With no chapter readable there is no book to open: both readers
    /// throw an error that names every chapter and says what to do.
    func testBookWithNoReadableChapterNamesEveryChapter() throws {
        let epub = try makeEPUB(chapters: Self.threeChapters)
        for chapter in Self.threeChapters {
            try removeMember(chapter.member, from: epub)
        }
        let expected = "None of the 3 chapters could be read: "
            + "chapter 1 (“OEBPS/ch01.xhtml”) is missing from this EPUB book; "
            + "chapter 2 (“OEBPS/ch02.xhtml”) is missing from this EPUB book; "
            + "chapter 3 (“OEBPS/ch03.xhtml”) is missing from this EPUB book. "
            + "Get a fresh copy of the book, then import it again."

        let readers: [() throws -> Void] = [
            { _ = try EPUBParser.prepareBook(url: epub) },
            { _ = try EPUBParser.parse(url: epub) }
        ]
        for read in readers {
            XCTAssertThrowsError(try read()) { error in
                XCTAssertEqual(error.localizedDescription, expected)
                XCTAssertEqual(Self.unreadableReport(error)?.omissions.count, 3)
            }
        }
    }

    /// Missing and blank chapters together leave nothing to read, and the
    /// error accounts for the blank ones as well.
    func testMissingAndBlankChaptersTogetherLeaveNothingToRead() throws {
        let chapters = [Self.blankPage("front"), Self.threeChapters[1], Self.blankPage("back")]
        let epub = try makeEPUB(chapters: chapters)
        try removeMember("OEBPS/ch02.xhtml", from: epub)

        XCTAssertThrowsError(try EPUBParser.prepareBook(url: epub)) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "1 of 3 chapters could not be read: chapter 2 (“OEBPS/ch02.xhtml”) is missing from this EPUB book. "
                    + "The other 2 chapters have no text. Get a fresh copy of the book, then import it again."
            )
        }
    }

    /// A book of blank pages has nothing damaged to replace; it simply has
    /// no text, and says so.
    func testBookOfBlankPagesHasNoTextToRead() throws {
        let epub = try makeEPUB(chapters: [Self.blankPage("front"), Self.blankPage("back")])

        XCTAssertThrowsError(try EPUBParser.parse(url: epub)) { error in
            XCTAssertEqual(error.localizedDescription, "This EPUB book has no text to read.")
            XCTAssertEqual(Self.unreadableReport(error)?.blankChapterCount, 2)
        }
    }

    // MARK: - Cache Generation

    /// The cache holds the chapters that could be read, and one line in the
    /// debug log names the book and what is missing from it.
    func testCacheKeepsTheReadableChaptersAndLogsTheReportOnce() throws {
        let title = Self.uniqueTitle()
        let epub = try makeEPUB(title: title, chapters: Self.threeChapters)
        try removeMember("OEBPS/ch02.xhtml", from: epub)

        let book = try importForTest(epub)

        let cached = try MarkdownCacheService.loadFromCache(for: book)
        XCTAssertEqual(cached.chapters.map(\.title), ["Patching a Tube", "Adjusting the Brakes"])
        let lines = debugLogLines(containing: "EPUB_INCOMPLETE_CONTENT: \(title): ")
        XCTAssertEqual(lines.count, 1, "\(lines)")
        XCTAssertTrue(lines.first?.hasSuffix(
            "EPUB_INCOMPLETE_CONTENT: \(title): "
                + "1 of 3 chapters could not be read: chapter 2 (“OEBPS/ch02.xhtml”) is missing from this EPUB book."
        ) == true, "\(lines)")
    }

    /// A title set on two lines is logged on one, so the entry is still one
    /// line that names the book.
    func testLogEntryStaysOnOneLineWhenTheTitleBreaks() throws {
        let secondLine = "Repairs \(UUID().uuidString.prefix(8))"
        let epub = try makeEPUB(title: "Roadside\n\(secondLine)", chapters: Self.threeChapters)
        try removeMember("OEBPS/ch02.xhtml", from: epub)

        let imported = try importWithReport(epub)

        XCTAssertTrue(imported.book.title.contains("\n"), imported.book.title)
        let lines = debugLogLines(
            containing: "EPUB_INCOMPLETE_CONTENT: Roadside \(secondLine): 1 of 3 chapters could not be read"
        )
        XCTAssertEqual(lines.count, 1, "\(lines)")
    }

    /// A cache rebuild still succeeds for a book with a chapter missing: the
    /// generated content carries the report, the rebuild path gets its index,
    /// and each generation logs the omission again rather than alerting.
    func testCacheRebuildCarriesTheReportAndStillSucceeds() throws {
        let title = Self.uniqueTitle()
        let epub = try makeEPUB(title: title, chapters: Self.threeChapters)
        try removeMember("OEBPS/ch02.xhtml", from: epub)
        var book = try importForTest(epub)

        let generated = try XCTUnwrap(MarkdownCacheService.generateReportedCacheAnalyzeAndStamp(for: &book))
        let rebuiltIndex = MarkdownCacheService.generateCacheAnalyzeAndStamp(for: &book)

        XCTAssertEqual(generated.content.chapters.count, 2)
        XCTAssertEqual(generated.report.omissions.map(\.chapterNumber), [2])
        // Indexes carry their generation time, so compare what they describe.
        XCTAssertEqual(rebuiltIndex?.chapters, generated.content.contentIndex.chapters)
        XCTAssertEqual(rebuiltIndex?.chapters.count, 2)
        XCTAssertEqual(book.cacheFormatVersion, MarkdownCacheService.currentCacheVersion)
        XCTAssertEqual(debugLogLines(containing: "EPUB_INCOMPLETE_CONTENT: \(title): ").count, 3)
    }

    /// A rebuild that finds no readable chapter fails without touching the
    /// cache an earlier generation wrote, so a book that was readable stays
    /// readable, and its version stays unstamped for a later retry.
    func testRebuildFindingNoReadableChapterKeepsTheEarlierCache() throws {
        let title = Self.uniqueTitle()
        var book = try importForTest(try makeEPUB(title: title, chapters: Self.threeChapters))
        let cachePath = TextMouthPaths.contentMarkdownPath(in: book.tmbDirectory)
        let earlierCache = try String(contentsOf: cachePath, encoding: .utf8)
        book.cacheFormatVersion = "3.0.0"
        // The package's own copy of the book then loses every chapter.
        for chapter in Self.threeChapters {
            try removeMember(chapter.member, from: URL(fileURLWithPath: book.filePath))
        }

        XCTAssertNil(MarkdownCacheService.generateCacheAnalyzeAndStamp(for: &book))

        XCTAssertEqual(try String(contentsOf: cachePath, encoding: .utf8), earlierCache)
        XCTAssertEqual(book.cacheFormatVersion, "3.0.0")
        let lines = debugLogLines(containing: "EPUB_INCOMPLETE_CONTENT: \(title): None of the 3 chapters could be read: ")
        XCTAssertEqual(lines.count, 1, "\(lines)")
    }

    /// Formats that do not report omissions yet generate an empty report.
    func testFormatsThatDoNotReportGenerateAnEmptyReport() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Notes.md")
        try Data("# Spokes\n\nCount them twice.".utf8).write(to: source)
        let book = try importForTest(source)

        let generated = try XCTUnwrap(MarkdownCacheService.generateReportedCacheContent(for: book))

        XCTAssertEqual(generated.report, ExtractionReport())
        XCTAssertEqual(generated.content.chapters.count, 1)
    }

    // MARK: - Importing

    /// An import returns what its book is missing, and the warning to give:
    /// the report's sentence, then that the original file was kept.
    func testImportReportsWhatTheBookIsMissing() throws {
        let epub = try makeEPUB(chapters: Self.threeChapters)
        try removeMember("OEBPS/ch02.xhtml", from: epub)

        let imported = try importWithReport(epub)

        XCTAssertTrue(imported.keepsOriginal)
        XCTAssertEqual(imported.report.omissions.map(\.member), ["OEBPS/ch02.xhtml"])
        XCTAssertEqual(
            imported.warning,
            "1 of 3 chapters could not be read: chapter 2 (“OEBPS/ch02.xhtml”) is missing from this EPUB book. "
                + "The original file was kept."
        )
        XCTAssertEqual(try MarkdownCacheService.loadFromCache(for: imported.book).chapters.count, 2)
    }

    /// A complete import has nothing to warn about and leaves the original
    /// to the "After Importing a Book" preference.
    func testCompleteImportHasNoWarning() throws {
        let imported = try importWithReport(try makeEPUB(chapters: Self.threeChapters))

        XCTAssertFalse(imported.keepsOriginal)
        XCTAssertNil(imported.warning)
        XCTAssertEqual(imported.report.chapterCount, 3)
        XCTAssertEqual(try MarkdownCacheService.loadFromCache(for: imported.book).chapters.count, 3)
    }

    /// An EPUB with no readable chapter is a failed import: the error names
    /// the file, the step, and every chapter, no package is left in the
    /// library, the source stays where it was, and the omissions are logged.
    func testImportOfBookWithNoReadableChapterFailsAndLeavesNothingBehind() throws {
        let title = Self.uniqueTitle()
        let epub = try makeEPUB(title: title, chapters: Self.threeChapters)
        for chapter in Self.threeChapters {
            try removeMember(chapter.member, from: epub)
        }
        let libraryBefore = try libraryEntries()

        XCTAssertThrowsError(try FileImportService.importFileWithReport(from: epub)) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.hasPrefix(
                "Could not import “book.epub”. Reading its text failed: "
                    + "None of the 3 chapters could be read: chapter 1 (“OEBPS/ch01.xhtml”)"
            ), message)
            XCTAssertTrue(message.hasSuffix("Get a fresh copy of the book, then import it again."), message)
        }

        XCTAssertEqual(try libraryEntries(), libraryBefore)
        XCTAssertTrue(FileManager.default.fileExists(atPath: epub.path))
        XCTAssertEqual(debugLogLines(containing: "EPUB_INCOMPLETE_CONTENT: \(title): None of the 3 chapters").count, 1)
    }

    /// An EPUB that cannot be opened is not imported as an unreadable book:
    /// the import fails naming the book, the step, and the damaged file
    /// inside it, and leaves no package.
    func testImportOfBookWithDamagedPackageDocumentFails() throws {
        let epub = try makeEPUB(chapters: Self.threeChapters)
        try damageData(of: "OEBPS/content.opf", in: epub)
        let libraryBefore = try libraryEntries()

        XCTAssertThrowsError(try FileImportService.importFileWithReport(from: epub)) { error in
            XCTAssertTrue(error.localizedDescription.hasPrefix(
                "Could not import “book.epub”. Reading its text failed: "
                    + "The file “OEBPS/content.opf” in this EPUB book is damaged or incomplete: "
            ), error.localizedDescription)
        }
        XCTAssertEqual(try libraryEntries(), libraryBefore)
    }

    // MARK: - Completing an Import in the Library

    /// The acceptance case end to end: a three-chapter EPUB whose middle
    /// chapter was deleted from the archive is added with its two readable
    /// chapters, announced once with a warning naming chapter 2 and its
    /// path, logged, and its original kept although the preference says to
    /// delete it.
    @MainActor
    func testIncompleteImportWarnsOnceAddsTheBookAndKeepsTheOriginal() throws {
        let title = Self.uniqueTitle()
        let epub = try makeEPUB(title: title, chapters: Self.threeChapters)
        try removeMember("OEBPS/ch02.xhtml", from: epub)

        try withImportDeleteBehavior(.deleteAfterImport) {
            let imported = try importWithReport(epub)
            let library = Self.emptyLibrary()

            library.completeSingleImportedBook(imported, originalURL: epub)

            XCTAssertEqual(library.library.books.map(\.id), [imported.book.id])
            XCTAssertEqual(try MarkdownCacheService.loadFromCache(for: imported.book).chapters.count, 2)
            XCTAssertTrue(FileManager.default.fileExists(atPath: epub.path))
            XCTAssertTrue(library.showError)
            // The book was added, so the alert is no error (review item 11).
            XCTAssertEqual(library.errorTitle, "Book Imported")
            XCTAssertEqual(
                library.errorMessage,
                "1 of 3 chapters could not be read: chapter 2 (“OEBPS/ch02.xhtml”) is missing from this EPUB book. "
                    + "The original file was kept."
            )
            XCTAssertTrue(library.importDecisions.isEmpty)
            XCTAssertEqual(debugLogLines(containing: "EPUB_INCOMPLETE_CONTENT: \(title): ").count, 1)
        }
    }

    /// The same with a chapter that cannot be decoded, under every "After
    /// Importing a Book" preference: the book is added with its two readable
    /// chapters, the warning names chapter 2 and its path, the original is
    /// neither deleted nor offered for deletion, and each import is logged.
    @MainActor
    func testUndecodableChapterImportKeepsTheOriginalUnderEveryPreference() throws {
        let title = Self.uniqueTitle()
        let epub = try makeEPUB(title: title, chapters: Self.threeChapters, compression: .deflate)
        try damageData(of: "OEBPS/ch02.xhtml", in: epub)

        for behavior in ImportDeleteBehavior.allCases {
            try withImportDeleteBehavior(behavior) {
                let imported = try importWithReport(epub)
                let library = Self.emptyLibrary()

                library.completeSingleImportedBook(imported, originalURL: epub)

                XCTAssertEqual(library.library.books.map(\.id), [imported.book.id], "\(behavior)")
                XCTAssertEqual(try MarkdownCacheService.loadFromCache(for: imported.book).chapters.count, 2)
                XCTAssertTrue(FileManager.default.fileExists(atPath: epub.path), "\(behavior)")
                XCTAssertTrue(library.importDecisions.isEmpty, "\(behavior)")
                XCTAssertTrue(library.showError, "\(behavior)")
                XCTAssertEqual(
                    library.errorMessage,
                    "1 of 3 chapters could not be read: chapter 2 (“OEBPS/ch02.xhtml”) is damaged or incomplete. "
                        + "The original file was kept."
                )
            }
        }
        XCTAssertEqual(
            debugLogLines(containing: "EPUB_INCOMPLETE_CONTENT: \(title): ").count,
            ImportDeleteBehavior.allCases.count
        )
    }

    /// A complete import is unchanged: no warning, and the preference still
    /// decides what happens to the original.
    @MainActor
    func testCompleteImportStillFollowsTheDeletePreference() throws {
        let asked = try makeEPUB(chapters: Self.threeChapters)
        try withImportDeleteBehavior(.askEachTime) {
            let library = Self.emptyLibrary()
            library.completeSingleImportedBook(try importWithReport(asked), originalURL: asked)

            XCTAssertFalse(library.showError)
            XCTAssertEqual(library.importDecisions.current?.originalFile?.url, asked)
        }

        let deleted = try makeEPUB(chapters: Self.threeChapters)
        try withImportDeleteBehavior(.deleteAfterImport) {
            let library = Self.emptyLibrary()
            // Deleting goes to the Trash when that preference is on: keep
            // this test's book out of the real Trash.
            try withTrashPreference(movesToTrash: false) {
                library.completeSingleImportedBook(try importWithReport(deleted), originalURL: deleted)
            }

            XCTAssertFalse(library.showError)
            XCTAssertFalse(FileManager.default.fileExists(atPath: deleted.path))
        }
    }

    /// A blank cover page leaves the import complete: no warning, and the
    /// original is offered for deletion as the preference asks.
    @MainActor
    func testImportWithABlankCoverIsComplete() throws {
        let epub = try makeEPUB(chapters: [Self.blankPage("cover")] + Self.threeChapters)

        try withImportDeleteBehavior(.askEachTime) {
            let imported = try importWithReport(epub)
            let library = Self.emptyLibrary()

            library.completeSingleImportedBook(imported, originalURL: epub)

            XCTAssertNil(imported.warning)
            XCTAssertEqual(imported.report.blankChapterCount, 1)
            XCTAssertFalse(library.showError)
            XCTAssertEqual(library.importDecisions.current?.originalFile?.url, epub)
        }
    }

    /// An incomplete copy of a book already in the library raises only the
    /// duplicate choice, which carries the warning, so two alerts never
    /// compete; keeping both copies still leaves the original untouched.
    @MainActor
    func testIncompleteDuplicateTellsItsWarningWithTheDuplicateChoice() throws {
        let epub = try makeEPUB(chapters: Self.threeChapters)
        try removeMember("OEBPS/ch02.xhtml", from: epub)

        try withImportDeleteBehavior(.deleteAfterImport) {
            let imported = try importWithReport(epub)
            let existing = Book(
                title: "Roadside Repairs", format: .epub, filePath: "/tmp/existing.epub", md5Hash: imported.book.md5Hash
            )
            let library = LibraryViewModel(initializeServices: false)
            library.library = Library(books: [existing])

            library.completeSingleImportedBook(imported, originalURL: epub)

            let duplicate = try XCTUnwrap(library.importDecisions.current?.duplicate)
            XCTAssertFalse(library.showError)
            XCTAssertEqual(duplicate.warning, imported.warning)
            XCTAssertNil(duplicate.originalURL)

            library.answerCurrentImportDecision(.keepBoth)

            XCTAssertEqual(library.library.books.map(\.id), [existing.id, imported.book.id])
            XCTAssertTrue(library.importDecisions.isEmpty, "keeping an incomplete copy asks nothing more")
            XCTAssertTrue(FileManager.default.fileExists(atPath: epub.path))
        }
    }

    /// A ZIP batch with one book missing a chapter: every book is added, the
    /// alert names the incomplete book's file and what it lacks, and the ZIP
    /// stays although the preference says to delete it.
    @MainActor
    func testZIPBatchListsTheBookMissingAChapterAndKeepsTheArchive() throws {
        let complete = try makeEPUB(chapters: Self.threeChapters, fileName: "complete.epub")
        let partial = try makeEPUB(chapters: Self.threeChapters, fileName: "partial.epub")
        try removeMember("OEBPS/ch02.xhtml", from: partial)
        let archive = partial.deletingLastPathComponent().appendingPathComponent("batch.zip")
        try Data("stands in for the ZIP the books came from".utf8).write(to: archive)
        let missing = "1 of 3 chapters could not be read: chapter 2 (“OEBPS/ch02.xhtml”) is missing from this EPUB book."

        let result = FileImportService.importSupportedFiles([complete, partial], toFolder: "")
        for package in result.books.map(\.tmbDirectory) {
            addTeardownBlock { try? FileManager.default.removeItem(at: package) }
        }

        XCTAssertEqual(result.books.count, 2)
        XCTAssertEqual(result.failures, [])
        XCTAssertEqual(result.incompleteBooks, [ZipImportFailure(fileName: "partial.epub", message: missing)])
        withImportDeleteBehavior(.deleteAfterImport) {
            let library = Self.emptyLibrary()

            library.completeZIPImport(result, originalURL: archive, folderPath: "")

            XCTAssertEqual(library.library.books.count, 2)
            XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
            XCTAssertTrue(library.showError)
            XCTAssertEqual(
                library.errorMessage,
                "Imported 2 books, but 1 book is missing chapters:\npartial.epub: \(missing)\nThe original file was kept."
            )
        }
    }

    /// Opening a book that is missing chapters would put its reader window
    /// over the warning, so an incomplete import is not opened automatically.
    @MainActor
    func testIncompleteImportIsNotOpenedOverItsWarning() throws {
        let epub = try makeEPUB(chapters: Self.threeChapters)
        try removeMember("OEBPS/ch02.xhtml", from: epub)
        let imported = try importWithReport(epub)
        let library = Self.emptyLibrary()
        let opened = OpenedBooks(recordingFor: library)

        library.completeSingleImportedBook(imported, originalURL: epub, request: ImportRequest(opensAfterImport: true))

        XCTAssertEqual(opened.ids, [])
        XCTAssertTrue(library.showError)
        XCTAssertEqual(library.library.books.map(\.id), [imported.book.id])
    }

    // MARK: - Fixture Books

    /// One document in a fixture EPUB, which the package lists in its
    /// manifest under `id` and stores at "OEBPS/" + `href`.
    private struct FixtureChapter {
        var id: String
        var href: String
        var markup: String
        var mediaType = "application/xhtml+xml"
        /// The path the archive stores the document at when that is not
        /// "OEBPS/" + `href`: a badly made book names a member in another case.
        var storedAs: String?

        /// The document's path inside the archive.
        var member: String { storedAs ?? "OEBPS/\(href)" }
    }

    /// A short repair manual, one chapter per file, each with its own words
    /// so a test can tell which chapters were read.
    private static let threeChapters = [
        chapter(1, "Patching a Tube", "Roughen the rubber around the puncture before the glue goes on."),
        chapter(2, "Truing a Wheel", "Tighten the spoke opposite the wobble by a quarter turn."),
        chapter(3, "Adjusting the Brakes", "Set each pad a coin's width from the rim.")
    ]

    /// Chapter `number` of the fixture manual, titled `heading`, reading `text`.
    private static func chapter(_ number: Int, _ heading: String, _ text: String) -> FixtureChapter {
        let id = String(format: "ch%02d", number)
        return FixtureChapter(id: id, href: "\(id).xhtml", markup: page("<h1>\(heading)</h1><p>\(text)</p>"))
    }

    /// A page with no text, such as a cover whose image its stylesheet sets.
    private static func blankPage(_ id: String) -> FixtureChapter {
        FixtureChapter(id: id, href: "\(id).xhtml", markup: page("<div class=\"cover\"></div>"))
    }

    /// The report carried by a `noReadableChapters` error, or nil for any
    /// other error.
    private static func unreadableReport(_ error: Error) -> ExtractionReport? {
        guard case .noReadableChapters(let report)? = error as? EPUBParserError else { return nil }
        return report
    }

    /// An XHTML document whose body is `body`.
    private static func page(_ body: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Roadside Repairs</title></head>
        <body>\(body)</body></html>
        """
    }

    /// A title no other test uses, so this test's log lines can be found.
    private static func uniqueTitle() -> String {
        "Roadside Repairs \(UUID().uuidString.prefix(8))"
    }

    /// Write an EPUB titled `title` (by default a unique title) that lists
    /// `chapters` in its manifest and reads `spine` (manifest ids, by default
    /// every chapter in order), to `fileName` in a new temporary directory
    /// that is removed when the test ends. `compression` says how the archive
    /// stores its files. `rootfilePath` is the package document's path as
    /// container.xml names it; the document itself is stored at
    /// "OEBPS/content.opf".
    private func makeEPUB(
        title: String? = nil,
        chapters: [FixtureChapter],
        spine: [String]? = nil,
        compression: CompressionMethod = .none,
        fileName: String = "book.epub",
        rootfilePath: String = "OEBPS/content.opf"
    ) throws -> URL {
        let title = title ?? Self.uniqueTitle()
        let manifest = chapters.map {
            "<item id=\"\($0.id)\" href=\"\($0.href)\" media-type=\"\($0.mediaType)\"/>"
        }.joined()
        let itemRefs = (spine ?? chapters.map(\.id)).map { "<itemref idref=\"\($0)\"/>" }.joined()
        var entries: [String: Data] = [
            "mimetype": Data("application/epub+zip".utf8),
            "META-INF/container.xml": Data("""
            <?xml version="1.0"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles><rootfile full-path="\(rootfilePath)" media-type="application/oebps-package+xml"/></rootfiles>
            </container>
            """.utf8),
            "OEBPS/content.opf": Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="id">urn:uuid:\(UUID().uuidString)</dc:identifier>
            <dc:title>\(title)</dc:title><dc:creator>Adaeze Kowalczyk</dc:creator><dc:language>en</dc:language>
            </metadata>
            <manifest>\(manifest)</manifest>
            <spine>\(itemRefs)</spine>
            </package>
            """.utf8)
        ]
        for chapter in chapters {
            entries[chapter.member] = Data(chapter.markup.utf8)
        }

        let zip = try makeTemporaryZip(prefix: "TextMouthEPUBTest", entries: entries, compressionMethod: compression)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let epub = directory.appendingPathComponent(fileName)
        try FileManager.default.moveItem(at: zip, to: epub)
        return epub
    }

    /// Import `source` through the production path into the hosted tests'
    /// isolated library, removing its package when the test ends.
    private func importWithReport(_ source: URL) throws -> ImportedBook {
        let imported = try FileImportService.importFileWithReport(from: source)
        let package = imported.book.tmbDirectory
        addTeardownBlock { try? FileManager.default.removeItem(at: package) }
        return imported
    }

    /// The book `source` imports as (see `importWithReport`).
    private func importForTest(_ source: URL) throws -> Book {
        try importWithReport(source).book
    }

    /// A library model with no books that starts no disk maintenance, so only
    /// the import under test can raise an alert.
    @MainActor
    private static func emptyLibrary() -> LibraryViewModel {
        let library = LibraryViewModel(initializeServices: false)
        library.library = Library()
        return library
    }

    /// Run `body` with the "After Importing a Book" preference set to
    /// `behavior`, restoring the previous preference afterwards.
    @MainActor
    private func withImportDeleteBehavior(_ behavior: ImportDeleteBehavior, _ body: () throws -> Void) rethrows {
        let config = ConfigService.shared
        let previous = config.config.importDeleteBehavior
        config.config.importDeleteBehavior = behavior
        defer { config.config.importDeleteBehavior = previous }
        try body()
    }

    /// The names at the top of the isolated library, where packages imported
    /// without a folder are staged.
    private func libraryEntries() throws -> Set<String> {
        try TextMouthPaths.ensureDirectoryStructure()
        return Set(try FileManager.default.contentsOfDirectory(atPath: TextMouthPaths.libraryDir.path))
    }

    /// Delete `member` from the ZIP at `url`, as a copy of a book can lack
    /// one of its files.
    private func removeMember(_ member: String, from url: URL) throws {
        let archive = try Archive(url: url, accessMode: .update)
        let entry = try XCTUnwrap(archive[member], "No member named \(member)")
        try archive.remove(entry)
    }
}
