import Foundation

/// The words of pictures of pages and comic book archives (FMT34): the
/// sentences an import says when it cannot read one, the reasons a page of a
/// longer book could not be read, the titles its chapters take, and the
/// limits those sentences name. They live here, as every format's words live
/// in a wording enum of their own, so the tests can name them.
///
/// Each refusal completes "Reading its text failed: ", as in "Could not
/// import “IMG_4821.heic”. Reading its text failed: No text was found in this
/// picture." Each page's reason completes the parenthesis of a page that
/// could not be read, as in "Text recognition could not read 1 of 12 pages:
/// page 3 (its picture could not be decoded)." (`pagesNotRead`).
enum PageImageWording {

    // MARK: - What Is Being Read

    /// How the sentences name the book being read.
    enum Subject: Equatable, Sendable {
        /// A picture file: PNG, JPEG, HEIC, or TIFF.
        case picture
        /// A comic book archive: a ZIP of pictures named .cbz.
        case archive

        /// The words that name it in a sentence: "this picture", "this comic
        /// book archive".
        var phrase: String {
            switch self {
            case .picture: return "this picture"
            case .archive: return "this comic book archive"
            }
        }

        /// How its report names it (`ExtractionReport.container`).
        var container: String { phrase }
    }

    // MARK: - Limits

    /// The most pixels a picture may say it holds before TextMouth decodes
    /// it, in megapixels: a 600 dpi scan of an A3 page is about 70, and the
    /// largest phone photographs are 48.
    static let maximumMegapixels = 100

    /// The most pages one book of pictures may have: the pages of a TIFF, or
    /// the pictures of a comic book archive. Text recognition took about a
    /// fifth of a second for a 2-megapixel page on the development Mac, and
    /// takes longer for a large photograph, so 2,000 pages is several minutes
    /// at the least; a comic has a few dozen, a scanned book a few hundred.
    static let maximumPages = 2_000

    // MARK: - Refusals of a Whole Book

    /// A picture, or every page of a book of them, in which text recognition
    /// found no text: "No text was found in this picture.", "No text was
    /// found in the one picture of this comic book archive.", or, for a book
    /// of several pages, "No text was found on any of the 3 pages of this
    /// picture." and "… of this comic book archive."
    static func noText(in subject: Subject, pageCount: Int) -> String {
        guard pageCount > 1 else {
            return subject == .archive
                ? "No text was found in the one picture of \(subject.phrase)."
                : "No text was found in \(subject.phrase)."
        }
        return "No text was found on any of the \(ArchiveFigures.count(pageCount)) pages of \(subject.phrase)."
    }

    /// Text recognition could not run at all, so nothing could be read, as a
    /// PDF without embedded text says it (`PDFParserError.ocrFailed`): "No
    /// text could be read from this picture: OCR could not run (text
    /// recognition is not available)."
    static func recognitionUnavailable(in subject: Subject, reason: String) -> String {
        "No text could be read from \(subject.phrase): OCR could not run (\(reason))."
    }

    /// Bytes in which ImageIO finds no picture at all, in the words the other
    /// formats use for a file that is not what its name says: "This file
    /// could not be read as a picture. It may be damaged, or another kind of
    /// file."
    static let notAPicture = "This file could not be read as a picture. It may be damaged, or another kind of file."

    /// A picture of a kind ImageIO knows but TextMouth does not decode,
    /// named by the system's description of its kind: "TextMouth can't read
    /// this kind of picture (DNG image). Save it as a PNG or JPEG picture,
    /// then import that copy."
    static func unreadableKind(_ kind: String) -> String {
        "TextMouth can't read this kind of picture (\(kind)). Save it as a PNG or JPEG picture, then import that copy."
    }

    /// What `unreadableKind(_:)` names a kind by when the system has no
    /// description of it.
    static let unnamedKind = "a kind the system does not name"

    /// A picture that says it holds more pixels than TextMouth decodes: "This
    /// picture is 30,000 by 30,000 pixels, larger than the 100 megapixels
    /// TextMouth reads in one picture."
    static func tooLarge(width: Int, height: Int) -> String {
        "This picture is \(dimensions(width: width, height: height)), larger than the "
            + "\(maximumMegapixels) megapixels TextMouth reads in one picture."
    }

    /// A picture ImageIO knows but could not decode: "This picture could not
    /// be decoded. It may be damaged."
    static let cannotDecode = "This picture could not be decoded. It may be damaged."

    /// A book of more pages than TextMouth reads: "This picture holds 3,000
    /// pages, more than the 2,000 TextMouth reads in one book.", or "This
    /// comic book archive holds 3,000 pictures, …".
    static func tooManyPages(_ count: Int, in subject: Subject) -> String {
        let held = subject == .archive ? "pictures" : "pages"
        let opening = subject == .archive ? "This comic book archive" : "This picture"
        return "\(opening) holds \(ArchiveFigures.count(count)) \(held), more than the "
            + "\(ArchiveFigures.count(maximumPages)) TextMouth reads in one book."
    }

    /// A comic book archive that is no ZIP archive, in the words the other
    /// formats use: "This file could not be read as a comic book archive. It
    /// may be damaged, or another kind of file."
    static let notAnArchive =
        "This file could not be read as a comic book archive. It may be damaged, or another kind of file."

    /// A comic book archive that holds no picture TextMouth reads: "This
    /// comic book archive holds no pictures TextMouth can read."
    static let noPictures = "This comic book archive holds no pictures TextMouth can read."

    /// The pages of a book of pictures that text recognition could not
    /// read, as an import's warning, and a refusal when no page could be,
    /// say them: "Text recognition could not read 1 of 3 pages: page 2 (its
    /// picture could not be decoded).", "… could not read any of the 2
    /// pages: pages 1 and 2 (…).", and, for a book of one page, "… could not
    /// read the only page: page 1 (…)." `pages` names the pages and why, as
    /// the report groups them (`PDFExtractionDiagnostics`).
    static func pagesNotRead(_ failed: Int, of total: Int, pages: String) -> String {
        let count: String
        if failed >= total {
            count = total == 1 ? "the only page" : "any of the \(ArchiveFigures.count(total)) pages"
        } else {
            count = "\(ArchiveFigures.count(failed)) of \(ArchiveFigures.count(total)) pages"
        }
        return "Text recognition could not read \(count): \(pages)."
    }

    // MARK: - Why One Page Could Not Be Read

    /// The page's file in the archive is no picture.
    static let pageNotAPicture = "its file could not be read as a picture"

    /// The page is a kind of picture TextMouth does not decode, named by the
    /// system's description of its kind: "it is a kind of picture TextMouth
    /// can't read (DNG image)".
    static func pageOfUnreadableKind(_ kind: String) -> String {
        "it is a kind of picture TextMouth can't read (\(kind))"
    }

    /// The page says it holds more pixels than TextMouth decodes: "it is
    /// 30,000 by 30,000 pixels, larger than 100 megapixels".
    static func pageTooLarge(width: Int, height: Int) -> String {
        "it is \(dimensions(width: width, height: height)), larger than \(maximumMegapixels) megapixels"
    }

    /// The page's picture could not be decoded.
    static let pageCannotDecode = "its picture could not be decoded"

    /// Why a page's file is damaged when its bytes do not match the checksum
    /// the archive stores for them, in the words an EPUB's damaged member
    /// gets; it completes "… is damaged or incomplete: …".
    static let failsChecksum = "its contents do not match the checksum stored with them"

    /// The page's file in the archive is damaged, for `reason`, which an
    /// archive entry gives (`ArchiveEntryReader`) or `failsChecksum` is: "its
    /// file is damaged or incomplete: its compressed data could not be
    /// decoded".
    static func pageFileDamaged(_ reason: String) -> String {
        "its file is damaged or incomplete: \(reason)"
    }

    /// What a damaged comic book archive's sentence tells the listener to get
    /// again (`PackageDamage.message`): "Get a fresh copy of the archive, then
    /// import it again."
    static let archiveToGetAgain = "the archive"

    // MARK: - Chapter Titles

    /// The title of a page's chapter in a book of several pages: "Page 3".
    static func pageTitle(_ number: Int) -> String {
        "Page \(number)"
    }

    /// The title of a comic book archive's page that its ComicInfo.xml calls
    /// a cover, by one value of its Type (`FrontCover`, `InnerCover`,
    /// `BackCover`); nil for any other value.
    static func coverTitle(forPageType type: String) -> String? {
        switch type {
        case "FrontCover": return "Front Cover"
        case "InnerCover": return "Inner Cover"
        case "BackCover": return "Back Cover"
        default: return nil
        }
    }

    /// The title of a comic book archive's page whose Type lists `types`
    /// (ComicInfo's Type is a list of values, as in "FrontCover Story"): the
    /// first cover among them; nil when none is a cover, and the page keeps
    /// its number.
    static func coverTitle(forPageTypes types: [String]) -> String? {
        types.lazy.compactMap(coverTitle(forPageType:)).first
    }

    // MARK: - Parts

    /// A picture's size in words: "1,224 by 1,584 pixels".
    private static func dimensions(width: Int, height: Int) -> String {
        "\(ArchiveFigures.count(width)) by \(ArchiveFigures.count(height)) pixels"
    }
}
