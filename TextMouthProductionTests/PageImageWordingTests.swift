import XCTest
@testable import TextMouth

/// The words of pictures of pages and comic book archives (FMT34), pinned:
/// each refusal completes "Reading its text failed: ", each page's reason
/// completes a page's parenthesis in its report, and the import overlay
/// counts pages as it counts tracks.
final class PageImageWordingTests: XCTestCase {

    // MARK: - Refusals of a Whole Book

    /// No text in a picture, in a picture of several pages, and in a comic
    /// book archive, whatever its count.
    func testNoTextSentences() {
        XCTAssertEqual(PageImageWording.noText(in: .picture, pageCount: 1), "No text was found in this picture.")
        XCTAssertEqual(
            PageImageWording.noText(in: .picture, pageCount: 3),
            "No text was found on any of the 3 pages of this picture."
        )
        XCTAssertEqual(
            PageImageWording.noText(in: .archive, pageCount: 24),
            "No text was found on any of the 24 pages of this comic book archive."
        )
        XCTAssertEqual(
            PageImageWording.noText(in: .archive, pageCount: 1),
            "No text was found in the one picture of this comic book archive."
        )
        XCTAssertEqual(
            PageImageWording.noText(in: .picture, pageCount: 2_500),
            "No text was found on any of the 2,500 pages of this picture."
        )
    }

    /// Text recognition that cannot run is said as a PDF without embedded
    /// text says it.
    func testRecognitionUnavailableSentence() {
        XCTAssertEqual(
            PageImageWording.recognitionUnavailable(in: .picture, reason: "text recognition is not available"),
            "No text could be read from this picture: OCR could not run (text recognition is not available)."
        )
        XCTAssertEqual(
            PageImageWording.recognitionUnavailable(in: .archive, reason: "text recognition is not available"),
            "No text could be read from this comic book archive: OCR could not run (text recognition is not available)."
        )
    }

    /// The refusals of a file that is no picture TextMouth reads.
    func testPictureRefusals() {
        XCTAssertEqual(
            PageImageWording.notAPicture,
            "This file could not be read as a picture. It may be damaged, or another kind of file."
        )
        XCTAssertEqual(
            PageImageWording.unreadableKind("DNG image"),
            "TextMouth can't read this kind of picture (DNG image). Save it as a PNG or JPEG, then import that copy."
        )
        XCTAssertEqual(
            PageImageWording.tooLarge(width: 30_000, height: 30_000),
            "This picture is 30,000 by 30,000 pixels, larger than the 100 megapixels TextMouth reads."
        )
        XCTAssertEqual(PageImageWording.cannotDecode, "This picture could not be decoded. It may be damaged.")
        XCTAssertEqual(
            PageImageWording.tooManyPages(3_000),
            "This picture holds 3,000 pages, more than the 2,000 TextMouth reads."
        )
        // An archive is refused at its first picture past the limit, so its pictures are never counted.
        XCTAssertEqual(
            PageImageWording.tooManyPictures,
            "This comic book archive holds more than the 2,000 pictures TextMouth reads."
        )
        XCTAssertEqual(PageImageError.tooManyPictures.errorDescription, PageImageWording.tooManyPictures)
    }

    /// The refusals of a comic book archive that is no archive of pictures.
    func testArchiveRefusals() {
        XCTAssertEqual(
            PageImageWording.notAnArchive,
            "This file could not be read as a comic book archive. It may be damaged, or another kind of file."
        )
        XCTAssertEqual(PageImageWording.noPictures, "This comic book archive holds no pictures TextMouth can read.")
    }

    /// The pages a book of pictures could not read are said without the
    /// PDF's clause about text in images, since every word of a picture is
    /// pictured; a PDF's pages keep their own sentence.
    func testUnreadPagesOfPicturesHaveTheirOwnSentence() {
        XCTAssertEqual(
            PageImageWording.pagesNotRead(1, of: 3, pages: "page 2 (its picture could not be decoded)"),
            "Text recognition could not read 1 of 3 pages: page 2 (its picture could not be decoded)."
        )
        XCTAssertEqual(
            PageImageWording.pagesNotRead(2, of: 2, pages: "pages 1 and 2 (its picture could not be decoded)"),
            "Text recognition could not read any of the 2 pages: pages 1 and 2 (its picture could not be decoded)."
        )
        XCTAssertEqual(
            PageImageWording.pagesNotRead(1, of: 1, pages: "page 1 (its picture could not be decoded)"),
            "Text recognition could not read the only page: page 1 (its picture could not be decoded)."
        )
        let pages = [
            PDFPageDiagnosis(pageNumber: 1, source: .recognized, recognition: .recognizedText),
            PDFPageDiagnosis(pageNumber: 2, source: .none, recognition: .couldNotRun(PageImageWording.pageCannotDecode)),
        ]
        XCTAssertEqual(
            PDFExtractionDiagnostics(pages: pages, medium: .pictures).problem,
            "Text recognition could not read 1 of 2 pages: page 2 (its picture could not be decoded)."
        )
        XCTAssertEqual(
            PDFExtractionDiagnostics(pages: pages).problem,
            "OCR could not run on 1 of 2 pages, so text found only in their images is missing: "
                + "page 2 (its picture could not be decoded).",
            "a PDF's sentence is as it was"
        )
    }

    // MARK: - Why One Page Could Not Be Read

    /// Each page's reason, as it completes the page's parenthesis.
    func testPageReasons() {
        XCTAssertEqual(PageImageWording.pageNotAPicture, "its file could not be read as a picture")
        XCTAssertEqual(
            PageImageWording.pageOfUnreadableKind("DNG image"), "it is a kind of picture TextMouth can't read (DNG image)"
        )
        XCTAssertEqual(
            PageImageWording.pageTooLarge(width: 20_000, height: 10_000),
            "it is 20,000 by 10,000 pixels, larger than 100 megapixels"
        )
        XCTAssertEqual(PageImageWording.pageCannotDecode, "its picture could not be decoded")
        XCTAssertEqual(
            PageImageWording.pageFileDamaged(PageImageWording.failsChecksum),
            "its file is damaged or incomplete: its contents do not match the checksum stored with them"
        )
    }

    /// Each error gives its sentence for a whole book, and its reason for a
    /// page of several.
    func testErrorsGiveTheirSentencesAndReasons() {
        let damaged = PageImageError.damagedPage(file: "pages/003.jpg", reason: "its data could not be read")
        XCTAssertEqual(
            damaged.errorDescription,
            "The file “pages/003.jpg” in this archive is damaged or incomplete: its data could not be read. "
                + "Get a fresh copy of the archive, then import it again."
        )
        XCTAssertEqual(damaged.pageReason, "its file is damaged or incomplete: its data could not be read")
        XCTAssertEqual(PageImageError.cannotDecode.pageReason, PageImageWording.pageCannotDecode)
        XCTAssertEqual(PageImageError.cannotDecode.errorDescription, PageImageWording.cannotDecode)
        XCTAssertEqual(PageImageError.notAPicture.pageReason, PageImageWording.pageNotAPicture)
        XCTAssertEqual(PageImageError.unreadableKind("GIF image").pageReason, PageImageWording.pageOfUnreadableKind("GIF image"))
        XCTAssertEqual(
            PageImageError.tooLarge(width: 2, height: 3).pageReason, PageImageWording.pageTooLarge(width: 2, height: 3)
        )
        XCTAssertEqual(PageImageError.noPageReadable("Every page failed.").errorDescription, "Every page failed.")
        XCTAssertEqual(
            PageImageError.noText(.archive, pageCount: 2).errorDescription, PageImageWording.noText(in: .archive, pageCount: 2)
        )
    }

    /// The sentence an import's alert says, whole: the file, the step, and
    /// the reason.
    func testTheImportSaysTheStepAndTheReason() {
        let failure = ImportFailure(
            fileName: "IMG_4821.heic", step: .readingText, underlying: PageImageError.noText(.picture, pageCount: 1)
        )
        XCTAssertEqual(
            failure.errorDescription,
            "Could not import “IMG_4821.heic”. Reading its text failed: No text was found in this picture."
        )
    }

    // MARK: - Chapter Titles

    /// A page's chapter is titled by its number, or by the cover a
    /// ComicInfo.xml says it is.
    func testChapterTitles() {
        XCTAssertEqual(PageImageWording.pageTitle(3), "Page 3")
        XCTAssertEqual(PageImageWording.coverTitle(forPageType: "FrontCover"), "Front Cover")
        XCTAssertEqual(PageImageWording.coverTitle(forPageType: "InnerCover"), "Inner Cover")
        XCTAssertEqual(PageImageWording.coverTitle(forPageType: "BackCover"), "Back Cover")
        XCTAssertNil(PageImageWording.coverTitle(forPageType: "Story"))
        XCTAssertNil(PageImageWording.coverTitle(forPageType: "frontcover"), "the schema's names are matched exactly")
    }
}
