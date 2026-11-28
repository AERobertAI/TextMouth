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
///
/// Every sentence is a whole localized string for each subject (FR34): a
/// picture and a comic book archive each have their own, so a language
/// agrees the noun and its article. A number the sentence names as a limit
/// is formatted first and is a `%@`, so a sentence holds at most one count
/// that its plural forms vary on.
enum PageImageWording {

    // MARK: - What Is Being Read

    /// How the sentences name the book being read.
    enum Subject: Equatable, Sendable {
        /// A picture file: PNG, JPEG, HEIC, or TIFF.
        case picture
        /// A comic book archive: a ZIP of pictures named .cbz.
        case archive

        /// The words that name it in a sentence: "this picture", "this comic
        /// book archive". English only: `ExtractionReport`'s English
        /// sentences (a parser's damage reasons) glue it in; this type's own
        /// sentences are whole.
        var phrase: String {
            switch self {
            case .picture: return "this picture" // l10n: no (inside ExtractionReport's English sentences)
            case .archive: return "this comic book archive" // l10n: no (inside ExtractionReport's English sentences)
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
                // Translators: Why a comic book archive of one picture was refused at import: text recognition found no text in it.
                ? InterfaceText.line("pageImage.noText.oneArchive", "No text was found in the one picture of this comic book archive.")
                // Translators: Why a picture was refused at import: text recognition found no text in it.
                : InterfaceText.line("pageImage.noText.picture", "No text was found in this picture.")
        }
        return subject == .archive
            // Translators: Why a comic book archive of several pictures was refused at import: text recognition found no text on any page. %lld is the number of pages, always more than one.
            ? InterfaceText.line("pageImage.noText.archive", "No text was found on any of the \(number: pageCount) pages of this comic book archive.")
            // Translators: Why a picture of several pages, such as a TIFF, was refused at import: text recognition found no text on any page. %lld is the number of pages, always more than one.
            : InterfaceText.line("pageImage.noText.pages", "No text was found on any of the \(number: pageCount) pages of this picture.")
    }

    /// Text recognition could not run at all, so nothing could be read, as a
    /// PDF without embedded text says it (`PDFParserError.ocrFailed`): "No
    /// text could be read from this picture: OCR could not run (text
    /// recognition is not available)."
    static func recognitionUnavailable(in subject: Subject, reason: String) -> String {
        // The reason is a parser's English (question 3).
        subject == .archive
            // Translators: Why a comic book archive was refused at import: text recognition (OCR) could not run. %@ is the reason, a phrase in English.
            ? InterfaceText.line("pageImage.recognitionUnavailable.archive", "No text could be read from this comic book archive: OCR could not run (\(reason)).")
            // Translators: Why a picture was refused at import: text recognition (OCR) could not run. %@ is the reason, a phrase in English.
            : InterfaceText.line("pageImage.recognitionUnavailable.picture", "No text could be read from this picture: OCR could not run (\(reason)).")
    }

    /// Bytes in which ImageIO finds no picture at all, in the words the other
    /// formats use for a file that is not what its name says: "This file
    /// could not be read as a picture. It may be damaged, or another kind of
    /// file."
    static var notAPicture: String {
        // Translators: Why a file was refused at import: its bytes are no picture at all. Two sentences.
        InterfaceText.line("pageImage.notAPicture", "This file could not be read as a picture. It may be damaged, or another kind of file.")
    }

    /// A picture of a kind ImageIO knows but TextMouth does not decode,
    /// named by the system's description of its kind: "TextMouth can't read
    /// this kind of picture (DNG image). Save it as a PNG or JPEG picture,
    /// then import that copy."
    static func unreadableKind(_ kind: String) -> String {
        // Translators: Why a picture was refused at import: a kind of picture the system knows but TextMouth does not decode. %@ is the system's description of the kind, such as "DNG image".
        InterfaceText.line("pageImage.unreadableKind", "TextMouth can't read this kind of picture (\(kind)). Save it as a PNG or JPEG, then import that copy.")
    }

    /// What `unreadableKind(_:)` names a kind by when the system has no
    /// description of it.
    static var unnamedKind: String {
        // Translators: Stands for the system's description of a kind of picture it has no description for, inside parentheses: "TextMouth can't read this kind of picture (a kind the system does not name)."
        InterfaceText.line("pageImage.unnamedKind", "a kind the system does not name")
    }

    /// A picture that says it holds more pixels than TextMouth decodes: "This
    /// picture is 30,000 by 30,000 pixels, larger than the 100 megapixels
    /// TextMouth reads in one picture."
    static func tooLarge(width: Int, height: Int) -> String {
        // Translators: Why a picture was refused at import: it says it holds more pixels than TextMouth decodes. %1$@ is its size, such as "30,000 by 30,000 pixels", and %2$lld the limit in megapixels.
        InterfaceText.line("pageImage.tooLarge", "This picture is \(dimensions(width: width, height: height)), larger than the \(number: maximumMegapixels) megapixels TextMouth reads.")
    }

    /// A picture ImageIO knows but could not decode: "This picture could not
    /// be decoded. It may be damaged."
    static var cannotDecode: String {
        // Translators: Why a picture was refused at import: the system could not decode it. Two sentences.
        InterfaceText.line("pageImage.cannotDecode", "This picture could not be decoded. It may be damaged.")
    }

    /// A TIFF of more pages than TextMouth reads, by its count: "This picture
    /// holds 3,000 pages, more than the 2,000 TextMouth reads in one book."
    static func tooManyPages(_ count: Int) -> String {
        // Translators: Why a picture of many pages, such as a TIFF, was refused at import. %1$lld is the number of pages it holds and %2$@ the limit, already formatted.
        InterfaceText.line("pageImage.tooManyPages", "This picture holds \(number: count) pages, more than the \(ArchiveFigures.count(maximumPages)) TextMouth reads.")
    }

    /// A comic book archive of more pictures than TextMouth reads, refused at
    /// the first picture past the limit, so never counted in full: "This
    /// comic book archive holds more than the 2,000 pictures TextMouth reads
    /// in one book."
    static var tooManyPictures: String {
        // Translators: Why a comic book archive was refused at import: it holds more pictures than TextMouth reads. %@ is the limit, already formatted.
        InterfaceText.line("pageImage.tooManyPictures", "This comic book archive holds more than the \(ArchiveFigures.count(maximumPages)) pictures TextMouth reads.")
    }

    /// A comic book archive that is no ZIP archive, in the words the other
    /// formats use: "This file could not be read as a comic book archive. It
    /// may be damaged, or another kind of file."
    static var notAnArchive: String {
        // Translators: Why a file was refused at import: it is no ZIP archive, so it cannot be a comic book archive. Two sentences.
        InterfaceText.line("pageImage.notAnArchive", "This file could not be read as a comic book archive. It may be damaged, or another kind of file.")
    }

    /// A comic book archive that holds no picture TextMouth reads: "This
    /// comic book archive holds no pictures TextMouth can read."
    static var noPictures: String {
        // Translators: Why a comic book archive was refused at import: it holds no picture TextMouth reads.
        InterfaceText.line("pageImage.noPictures", "This comic book archive holds no pictures TextMouth can read.")
    }

    /// The pages of a book of pictures that text recognition could not
    /// read, as an import's warning, and a refusal when no page could be,
    /// say them: "Text recognition could not read 1 of 3 pages: page 2 (its
    /// picture could not be decoded).", "… could not read any of the 2
    /// pages: pages 1 and 2 (…).", and, for a book of one page, "… could not
    /// read the only page: page 1 (…)." `pages` names the pages and why, as
    /// the report groups them (`PDFExtractionDiagnostics`), in English.
    static func pagesNotRead(_ failed: Int, of total: Int, pages: String) -> String {
        if failed >= total {
            return total == 1
                // Translators: Why a book of one page of a picture was refused at import: text recognition could not read its only page. %@ names the page and why, such as "page 1 (its picture could not be decoded)".
                ? InterfaceText.line("pageImage.pagesNotRead.only", "Text recognition could not read the only page: \(pages).")
                // Translators: Why a book of several pages of pictures was refused at import: text recognition could not read any page. %1$lld is the number of pages and %2$@ names the pages and why, such as "pages 1 and 2 (its picture could not be decoded)".
                : InterfaceText.line("pageImage.pagesNotRead.recognitionAny", "Text recognition could not read any of the \(number: total) pages: \(pages).")
        }
        // Translators: Warning after a book of pictures was imported: text recognition could not read some pages. %1$@ is how many of how many, such as "1 of 12 pages", and %2$@ names the pages and why, such as "page 3 (its picture could not be decoded)".
        return InterfaceText.line("pageImage.pagesNotRead.recognition", "Text recognition could not read \(ImportProgressWording.pages(done: failed, of: total)): \(pages).")
    }

    // MARK: - Why One Page Could Not Be Read

    // Each reason completes the parenthesis after a page's number in the
    // sentences of `PDFExtractionDiagnostics`: "page 3 (its picture could
    // not be decoded)". Each starts in lowercase and has no full stop.

    /// The page's file in the archive is no picture.
    static var pageNotAPicture: String {
        // Translators: Why one page of a comic book archive could not be read, inside parentheses after the page's number: its file is no picture. Starts with a lowercase letter, with no full stop.
        InterfaceText.line("pageImage.pageNotAPicture", "its file could not be read as a picture")
    }

    /// The page is a kind of picture TextMouth does not decode, named by the
    /// system's description of its kind: "it is a kind of picture TextMouth
    /// can't read (DNG image)".
    static func pageOfUnreadableKind(_ kind: String) -> String {
        // Translators: Why one page of a comic book archive could not be read, inside parentheses after the page's number: a kind of picture TextMouth does not decode. %@ is the system's description of the kind, such as "DNG image". Starts with a lowercase letter, with no full stop.
        InterfaceText.line("pageImage.pageOfUnreadableKind", "it is a kind of picture TextMouth can't read (\(kind))")
    }

    /// The page says it holds more pixels than TextMouth decodes: "it is
    /// 30,000 by 30,000 pixels, larger than 100 megapixels".
    static func pageTooLarge(width: Int, height: Int) -> String {
        // Translators: Why one page of a comic book archive could not be read, inside parentheses after the page's number: it holds more pixels than TextMouth decodes. %1$@ is its size, such as "30,000 by 30,000 pixels", and %2$lld the limit in megapixels. Starts with a lowercase letter, with no full stop.
        InterfaceText.line("pageImage.pageTooLarge", "it is \(dimensions(width: width, height: height)), larger than \(number: maximumMegapixels) megapixels")
    }

    /// The page's picture could not be decoded.
    static var pageCannotDecode: String {
        // Translators: Why one page of a comic book archive could not be read, inside parentheses after the page's number: the system could not decode its picture. Starts with a lowercase letter, with no full stop.
        InterfaceText.line("pageImage.pageCannotDecode", "its picture could not be decoded")
    }

    /// Why a page's file is damaged when its bytes do not match the checksum
    /// the archive stores for them, in the words an EPUB's damaged member
    /// gets; it completes "… is damaged or incomplete: …".
    static var failsChecksum: String {
        // Translators: Why a page's file in a comic book archive is damaged, after "its file is damaged or incomplete:": its bytes do not match the checksum the archive stores for them. Starts with a lowercase letter, with no full stop.
        InterfaceText.line("pageImage.failsChecksum", "its contents do not match the checksum stored with them")
    }

    /// The page's file in the archive is damaged, for `reason`, which an
    /// archive entry gives (`ArchiveEntryReader`) or `failsChecksum` is: "its
    /// file is damaged or incomplete: its compressed data could not be
    /// decoded".
    static func pageFileDamaged(_ reason: String) -> String {
        // Translators: Why one page of a comic book archive could not be read, inside parentheses after the page's number: its file is damaged. %@ is the reason, which the archive reader gives in English or `failsChecksum`. Starts with a lowercase letter, with no full stop.
        InterfaceText.line("pageImage.pageFileDamaged", "its file is damaged or incomplete: \(reason)")
    }

    // MARK: - Chapter Titles

    /// The title of a page's chapter in a book of several pages: "Page 3".
    static func pageTitle(_ number: Int) -> String {
        // Translators: Title of the chapter of one page of a book of pictures, made at import. %@ is the page's number, an identifier written without digit grouping.
        InterfaceText.line("common.pageValue", "Page \(String(number))")
    }

    /// The title of a comic book archive's page that its ComicInfo.xml calls
    /// a cover, by one value of its Type (`FrontCover`, `InnerCover`,
    /// `BackCover`); nil for any other value.
    static func coverTitle(forPageType type: String) -> String? {
        switch type {
        // Translators: Title of the chapter of a comic book archive's page that its ComicInfo.xml calls the front cover, made at import. Title case.
        case "FrontCover": return InterfaceText.line("pageImage.coverTitle.front", "Front Cover")
        // Translators: Title of the chapter of a comic book archive's page that its ComicInfo.xml calls an inner cover, made at import. Title case.
        case "InnerCover": return InterfaceText.line("pageImage.coverTitle.inner", "Inner Cover")
        // Translators: Title of the chapter of a comic book archive's page that its ComicInfo.xml calls the back cover, made at import. Title case.
        case "BackCover": return InterfaceText.line("pageImage.coverTitle.back", "Back Cover")
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
        // Translators: A picture's size. %1$lld is its width and %2$lld its height, both in pixels, such as "1,224 by 1,584 pixels".
        InterfaceText.line("pageImage.dimensions", "\(number: width) by \(number: height) pixels")
    }
}
