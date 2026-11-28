import XCTest
@testable import TextMouth

/// The advice for the formats TextMouth refuses (FMT02): one table of
/// extensions and sentences, pinned word for word, used for a single file
/// and for an archive or folder that held no book.
final class RefusedFormatAdviceTests: XCTestCase {

    /// Every refused extension has its sentence, in any capitals and with or
    /// without a dot, and an extension nobody refused has none.
    func testEveryRefusedExtensionHasItsSentence() {
        let expected: [(String, String)] = [
            ("pages", "Export Pages documents from Pages as Word documents or EPUB books, then import those."),
            ("key", "Export Keynote presentations from Keynote as PDF files, then import those."),
            ("numbers", "Export Numbers spreadsheets from Numbers as PDF files, then import those."),
            ("wpd", "Save WordPerfect documents as Word or HTML files in a program that reads them, such as LibreOffice, then import those."),
            ("chm", "Convert Compiled HTML Help files to HTML files or PDF files, then import those."),
            ("djvu", "Convert DjVu documents to PDF files, then import those."),
            ("xps", "Convert XPS documents to PDF files, then import those."),
            ("cbr", "Repack the pages of RAR comics as CBZ comics, then import those."),
            ("rar", "TextMouth does not open RAR archives. Unpack them, then import what they hold."),
            ("aax", "TextMouth cannot open copy-protected files.")
        ]
        for (ext, sentence) in expected {
            XCTAssertEqual(RefusedFormatAdvice.advice(forExtension: ext), sentence, ext)
        }
        XCTAssertEqual(RefusedFormatAdvice.advice(forExtension: "PAGES"), expected[0].1)
        XCTAssertEqual(RefusedFormatAdvice.advice(forExtension: ".Pages"), expected[0].1)
        XCTAssertNil(RefusedFormatAdvice.advice(forExtension: "xyz"))
        XCTAssertNil(RefusedFormatAdvice.advice(forExtension: ""))
    }

    /// Extensions that share a kind share its sentence, and the
    /// copy-protected audio extensions all say it.
    func testKindsThatShareASentence() {
        for ext in ["aa", "aax", "aaxc", "m4p"] {
            XCTAssertEqual(RefusedFormatAdvice.advice(forExtension: ext), RefusedFormatAdvice.copyProtected, ext)
        }
        XCTAssertEqual(RefusedFormatAdvice.advice(forExtension: "wp"), RefusedFormatAdvice.wordPerfect)
        XCTAssertEqual(RefusedFormatAdvice.advice(forExtension: "djv"), RefusedFormatAdvice.djVu)
        XCTAssertEqual(RefusedFormatAdvice.advice(forExtension: "oxps"), RefusedFormatAdvice.xps)
    }

    /// No sentence holds a symbol VoiceOver would read by name, and each
    /// ends as a sentence does.
    func testSentencesAreSpeakable() {
        for sentence in Set(RefusedFormatAdvice.sentencesByExtension.values) {
            XCTAssertTrue(sentence.hasSuffix("."), sentence)
            XCTAssertNil(sentence.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\_*#<>()&@")), sentence)
        }
    }

    /// A single refused file says what it is and then how to convert it,
    /// and a file with no advice says what it said before.
    func testASingleFileHasItsAdviceAfterTheOldSentence() {
        XCTAssertEqual(
            FileImportError.unsupportedFormat("pages").errorDescription,
            "Unsupported file format: .pages. " + RefusedFormatAdvice.pages
        )
        XCTAssertEqual(
            FileImportError.unsupportedFormat("m4p").errorDescription,
            "Unsupported file format: .m4p. TextMouth cannot open copy-protected files."
        )
        XCTAssertEqual(FileImportError.unsupportedFormat("xyz").errorDescription, "Unsupported file format: .xyz")
        // A transcript keeps its own hint.
        XCTAssertTrue(FileImportError.unsupportedFormat("vtt").errorDescription?.contains("Attach Transcript…") == true)
    }

    /// An archive's alert keeps its old sentence and adds the advice after
    /// it, once for kinds that share a sentence, in the order the kinds are
    /// listed; kinds without advice add nothing.
    func testAnArchiveSaysTheAdviceAfterWhatItHolds() {
        func found(_ counts: [String: Int]) -> String {
            ImportProgressWording.noBooksFound(in: "Docs.zip", holding: NonBookFiles(countsByExtension: counts))
        }
        XCTAssertEqual(
            found(["pages": 2]),
            "No books were found in “Docs.zip”. It holds 2 .pages files, which TextMouth does not import. "
                + RefusedFormatAdvice.pages
        )
        XCTAssertEqual(
            found(["aax": 3, "aa": 1, "jpg": 2]),
            "No books were found in “Docs.zip”. It holds 3 .aax files, 2 .jpg files, and 1 .aa file, "
                + "which TextMouth does not import. TextMouth cannot open copy-protected files."
        )
        XCTAssertEqual(
            found(["exe": 176]),
            "No books were found in “Docs.zip”. It holds 176 .exe files, which TextMouth does not import."
        )
        // Advice for a kind past the named three is still given.
        XCTAssertTrue(found(["a": 9, "b": 8, "c": 7, "d": 6, "xps": 1]).hasSuffix(RefusedFormatAdvice.xps))
    }

    /// A folder's alert gives the advice the same way.
    func testAFolderSaysTheAdviceAfterWhatItHolds() {
        XCTAssertEqual(
            ImportProgressWording.noBookInFolder(named: "Scans", holding: NonBookFiles(countsByExtension: ["djvu": 1])),
            "“Scans” holds no DAISY book and no audio tracks to import as one book. It holds 1 .djvu file. "
                + RefusedFormatAdvice.djVu
        )
    }

    /// The RAR comic advice sends the reader to CBZ, so TextMouth must read
    /// a .cbz. This passes once the CBZ reader (formats/page-images, FMT34)
    /// is on main; the advice is merged after it on purpose.
    func testTheCBZTheRARAdviceNamesIsAFormatTextMouthReads() {
        XCTAssertTrue(RefusedFormatAdvice.rarComic.contains("CBZ"))
        XCTAssertNotNil(BookFormat.detect(from: URL(fileURLWithPath: "/tmp/a-comic.cbz")))
        XCTAssertNotNil(BookFormat.detect(from: URL(fileURLWithPath: "/tmp/A-COMIC.CBZ")))
    }

    /// The real Pages and WordPerfect samples are no book TextMouth reads,
    /// and their extensions have advice.
    func testTheRealSamplesAreRefusedWithAdvice() throws {
        let samples = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TestData/format-samples")
        for name in ["pages/Pages_4.pages", "pages/Pages_5.pages", "wpd/WP6.wpd"] {
            let url = samples.appendingPathComponent(name)
            try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "sample missing: \(name)")
            XCTAssertNil(BookFormat.detect(from: url), name)
            XCTAssertNotNil(RefusedFormatAdvice.advice(forExtension: url.pathExtension), name)
        }
    }
}
