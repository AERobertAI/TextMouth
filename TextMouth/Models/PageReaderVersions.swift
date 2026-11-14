import Foundation
import os

/// Which formats write page markers into a book's content.md, and the
/// version of each one's page reader (PG09). A book records the version that
/// wrote its content.md (`Book.pageReaderVersion`); at launch, while the
/// launch re-read is switched on (`launchRereadIsOn`, on since PG16), a book
/// whose format has a newer page reader than the one recorded, or none, is
/// read again from its file so that it gains its pages
/// (`LibraryViewModel.booksNeedingCacheUpdate`), unless its text was
/// changed, which is kept as it is.
///
/// A format that gains pages later adds its line here (braille, PG12; plain
/// text's form feeds, PG13), which reads again only its own books, without
/// another pass over the rest of the library (V07). A format whose page
/// reader changes
/// raises its own version in the same way. Its books stamped by the reader
/// before, which read their pages (`notesSuccess(_:)`), are then read again
/// without PG16's compare (V05), so the bump keeps no copy of their text;
/// books from before pages, and books whose stamp notes a failure, are
/// compared as ever.
enum PageReaderVersions {
    /// The version of `format`'s page reader; nil for a format that writes
    /// no page markers. Each format's page reader started at "1.0.0" when
    /// the format gained its pages.
    ///
    /// The formats textutil reads (`.rtf`, `.rtfd`, `.doc`, `.odt`, and
    /// `.wordml`, PG11) gained their pages in the same release as EPUB, HTML,
    /// PDF, DOCX, and DAISY. Braille (PG12) and plain text (PG13) gained
    /// theirs later, each with a case of its own and its own version, which
    /// reads again only its own books (V07).
    ///
    /// EPUB is at "1.0.3", and HTML at "1.0.4" (below). At "1.0.1" the HTML converter they
    /// share stopped leaving a page-break element's number in the label of a
    /// heading that holds one ("Part 9Two" is "Part Two"), which changed the
    /// reading text of the books that have such a heading and of no others.
    /// At "1.0.2" a label that is only the word "Page" names no page
    /// (`MarkdownPageMarker.namesNoPage`), and an EPUB page list that labels
    /// none of its pages, such as one whose only entry is the id it links
    /// to, is passed over (`EPUBParser.readPageList`). That changes the
    /// pages of the books that have either, and their reading text only
    /// where such a book's page-break element holds its page's number,
    /// which is then the page's label and no longer read (ST02). At "1.0.3"
    /// a label's leading word "Page" is taken off ("Page 12" is the page
    /// "12", MarkdownPageMarker's normalization), so a number a page-break
    /// element holds under such a label is its page's own and no longer
    /// read. Every format's labels lose the word whenever their content.md
    /// is read, so only these two formats are read again: only their text
    /// can change.
    ///
    /// HTML is at "1.0.4", ahead of EPUB. At "1.0.4" the decoder every plain
    /// text and HTML book goes through (`TextFileDecoder`) recognizes UTF-16
    /// in an alphabet and in Chinese, Japanese, and Korean, and UTF-32,
    /// written without a byte-order mark, and reads an HTML file that
    /// declares ISO-2022-JP in it, unless the book recorded its encoding.
    /// That changes what a book of an HTML file in one of those makes, and no
    /// EPUB's, which has its own readers; so each HTML book is read again
    /// once, its content.md byte for byte as before unless it is one of
    /// those. A web archive's page and a .doc that is a web page keep the old
    /// steps (`TextFileDecoder.Evidence.legacy`), since they have no such
    /// version to raise.
    static func current(for format: BookFormat) -> String? {
        switch format {
        case .epub:
            return "1.0.3"
        case .html:
            return "1.0.4"
        case .pdf:
            return "1.0.0"
        case .daisy:
            // DAISY started at "1.0.0" with PDF. At "1.0.1" a DAISY 3 book
            // of several DTBook files numbers a page that holds no words by
            // its place in the whole book (1, 2, then 3, 4), where each file
            // began again at 1. The same bump fixes the order those files are
            // read in (the spine's, else the order its SMIL files point at
            // them, else the manifest's, where a dictionary's changed from
            // launch to launch). Every stamped DAISY book is read again once;
            // only a book of several DTBook files with a wordless page after
            // an earlier page, or one whose files were read out of order,
            // makes another text. The rest read byte for byte as before.
            return "1.0.1"
        case .docx:
            // The DOCX reader follows the policy every document reader of
            // TextMouth follows: hidden text (w:vanish) is not read, a
            // text box written twice is read once, and the footnotes and
            // endnotes are read after the text. Every .docx book is read
            // again once ("1.1.0"). At "1.2.0" the toggle rule for hidden
            // text takes in a table style's own w:vanish and the document
            // defaults' (not a table style's conditional formatting), so
            // every .docx book is read again once more. At "1.3.0" a symbol
            // (w:sym) and text typed in a symbol font (U+F020 to U+F0FF) are
            // read through the tables by font that the Word 97 reader uses,
            // so every .docx book is read again once more.
            return "1.3.0"
        case .rtf, .rtfd:
            // TextMouth's own reader reads rich text (FMT47) instead of
            // textutil: headings from the style sheet, bold and italic, and
            // pages at every \page, \pagebb, and page-starting \sect, so the
            // books of these two formats are read again once ("1.1.0"). At
            // "1.2.0" text a tracked change deleted or moved away is not
            // read, a list item inside a table cell is a list in the Markdown
            // (the reading text leaves every list's number out), footnotes
            // and endnotes are read after the text, and a shape's text box
            // right after the paragraph that holds it.
            return "1.2.0"
        case .doc:
            // Word 97-2003 is read by TextMouth's own reader (FMT47) from
            // "1.1.0", which finds the pages and the headings by the
            // document's own structure, so every .doc book is read again once.
            // At "1.2.0" it leaves hidden text out, reads the formatting
            // that a fast-saved document keeps in its pieces, makes Word's own
            // numbered and bulleted paragraphs list items (their numbers are
            // not heard while `WordDocumentReader.speaksListNumbers` is off),
            // and reads the main document's text boxes after the notes, so
            // every .doc book is read again once more. At "1.3.0" it reads
            // Word 6 and Word 95 documents too (which textutil read before on
            // the Mac): their headings from the style sheet, their hidden
            // text, tracked deletions, numbering and notes by the same
            // policy, and Far East and Cyrillic text in the code page their
            // fonts name, so every .doc book is read again once more.
            return "1.3.0"
        case .odt:
            // OpenDocument text (FMT27) is read by TextMouth's own reader from
            // "1.1.0": the document's own headings, the pages of its style
            // breaks, master pages, and soft page breaks, hidden text left
            // out, and notes after the text, so every such book is read again
            // once.
            return "1.1.0"
        case .wordml:
            // Word 2003 XML (FMT53) is read by TextMouth's own reader from
            // "1.1.0", with the same policy for hidden text and notes. At
            // "1.2.0" a row marked hidden (`w:trPr/w:hidden`) no longer hides
            // the visible words in it, which each run's own toggle decides
            // (the hidden row rule of `DOCXHiding`), so every such book is
            // read again once more. At "1.3.0" a symbol (w:sym) and text
            // typed in a symbol font are read through the tables by font
            // that the Word 97 reader uses, so every such book is read again
            // once more.
            return "1.3.0"
        case .braille:
            // Braille gained its pages later, each braille page of a BRF or
            // a PEF (PG12), so its own case reads again only braille books
            // (V07). A BRL, which has no pages, shares the format: it is read
            // again once, as every braille book from before pages is, and
            // then stamped. At "1.1.0" the page analyzer drops a running head
            // that repeats on three pages or more (and takes a braille page
            // number at its left), takes a Roman numeral print page change
            // line out of the text, and reads a centered "Chapter" row that
            // runs straight into an indented row as a heading, so every
            // braille book is read again once; a book with none of those
            // reads byte for byte as before. (The braille helper's own
            // fixes, `brfdecode`'s, ride on this bump.) At "1.1.1" a running
            // head that differs only by a part or volume number from the
            // repeating one is left out too ("life of pi. part2" among
            // "part1" pages); 1.1.0 shipped in 0.4.8, so books stamped
            // 1.1.0 are read again once more.
            return "1.1.1"
        case .txt:
            // Plain text's form feeds begin pages (PG13), and its own case
            // reads again only plain text books (V07). Most hold no form
            // feed between words: each is read again once, its content.md
            // byte for byte as before, and then stamped. At "1.0.1" the
            // decoder recognizes UTF-16 in an alphabet and in Chinese,
            // Japanese, and Korean, and UTF-32, written without a
            // byte-order mark (`TextFileDecoder.unmarkedUnicode(in:)`), so a
            // book of such a file, read before as UTF-8 with control
            // characters in it (Cyrillic UTF-16 is valid UTF-8) or as
            // Windows-1252, is read again once, and every other plain text
            // book a second time, byte for byte as before. (Markdown has no
            // page reader and no version: its books read the new way
            // whenever their text is built again, by Redo Text Extraction or
            // a stale cache, and a Markdown file imported from now on reads
            // so at once.)
            return "1.0.1"
        case .mobi:
            // A Kindle book of the MOBI family has pages when it is in KF8
            // (FMT48): that format keeps the page-break elements of the EPUB
            // it was made from, and they are read as pages. A MOBI 6 book
            // has none. A hybrid file is read from its KF8 half from
            // "1.0.0", which keeps the headings at the levels the author gave
            // them, so every .mobi book is read again once. At "1.1.0" a soft
            // hyphen is left out of a MOBI 6 book's words and contents too (a
            // KF8 book's already were; a soft hyphen hid a word from search, was
            // a hyphen in braille, and a pause in speech), a KF8 book's pieces
            // that calibre cut are joined into chapters by a rule that gives
            // an essay after a header its own chapter and a licence's opening
            // words their licence's chapter, so every .mobi book (.azw3
            // included) is read again once more.
            return "1.1.0"
        case .kfx:
            // A KFX book (FMT52) has pages when it carries a print page
            // list; one named APPROXIMATE_PAGE_LIST is a machine's guess and
            // is not read as pages. The format has its own case and version.
            return "1.0.0"
        default:
            return nil
        }
    }

    /// Whether a book of `format` that recorded `stored` as its page reader
    /// (nil when it recorded none) is behind the format's current one. False
    /// for a format without pages: such a book is never read again for them.
    ///
    /// A stamp's failure note is not part of its version (`stamp(for:pageRunFailed:previous:)`):
    /// "1.0.0+failed" is page reader 1.0.0, which tried and is not tried
    /// again, while "1.0.0+failed-once" is behind, so that the book is read
    /// once more, unless a newer TextMouth on another Mac wrote it (FR02).
    static func isOutdated(format: BookFormat, stored: String?) -> Bool {
        guard let current = current(for: format) else { return false }
        guard let stored else { return true }
        let version = String(stored.prefix { $0 != noteSeparator })
        if stored.hasSuffix(failedOnceNote) {
            // Tried once more by this reader or a newer one, never an older.
            return !SemanticVersion.isOutdated(stored: current, current: version)
        }
        return SemanticVersion.isOutdated(stored: version, current: current)
    }

    // MARK: - A Page Run That Failed (PG16)

    /// What begins a stamp's note, after its version.
    private static let noteSeparator: Character = "+"

    /// The note of a page run that failed once: the book is read again for
    /// its pages at the next launch.
    private static let failedOnceNote = "+failed-once"

    /// The note of a page run that failed again, or of a book whose file
    /// could not be read for its pages at all: it is not read again for
    /// them until its format's page reader changes, or Redo Text Extraction
    /// reads it.
    private static let failedNote = "+failed"

    /// The page reader a generation records for a book of `format` whose
    /// stamp was `previous` (PG16): the format's current one when its pages
    /// were read, nil for a format without pages. When the run that reads
    /// them failed or was stopped (`pageRunFailed`, textutil's second run),
    /// the book was read without pages, and the stamp notes it rather than
    /// record its pages as done: "1.0.0+failed-once" the first time, which
    /// the next launch reads again, and "1.0.0+failed" when that try fails
    /// too, so a document that always fails is not read at every launch.
    static func stamp(for format: BookFormat, pageRunFailed: Bool, previous: String?) -> String? {
        guard pageRunFailed else { return current(for: format) }
        return failureStamp(for: format, previous: previous)
    }

    /// The stamp of a book of `format`, stamped `previous`, that could not be
    /// read for its pages this time, by a run that may fail only for a
    /// moment (PG16): "1.0.0+failed-once" the first time, which the next
    /// launch reads again, and "1.0.0+failed" when that try failed too,
    /// which no launch reads again; nil for a format without pages.
    static func failureStamp(for format: BookFormat, previous: String?) -> String? {
        guard let current = current(for: format) else { return nil }
        return previous == current + failedOnceNote ? current + failedNote : current + failedOnceNote
    }

    /// The stamp of a book of `format` whose file could not be read for its
    /// pages at all, being missing or no longer readable (PG16): the
    /// current version, noting a failure that is not tried again; nil for a
    /// format without pages.
    static func failedStamp(for format: BookFormat) -> String? {
        current(for: format).map { $0 + failedNote }
    }

    /// Whether `stamp` notes a failure (`stamp(for:pageRunFailed:previous:)`).
    static func notesFailure(_ stamp: String?) -> Bool {
        stamp?.contains(noteSeparator) ?? false
    }

    /// Whether `stamp` names a page reader that read the book's pages (V05):
    /// it is set, and notes no failure. That reader wrote the book's
    /// content.md, so a build that records every edit Edit Text takes did
    /// (B12), and the launch re-read reads the book again without comparing
    /// its text with its file's, unless content.md changed since its record
    /// (`LibraryViewModel.pageUpgradeCheck(of:access:)`).
    ///
    /// Not so for a book with no stamp, whose text is from before pages, nor
    /// for one whose stamp notes a failure: "+failed" is also written for a
    /// book whose file was missing or no longer extracted, whose content.md
    /// is still its old text. Both are compared. A stamp lost in a round trip
    /// through an older TextMouth sends its book through the compare too,
    /// which is safe.
    static func notesSuccess(_ stamp: String?) -> Bool {
        stamp != nil && !notesFailure(stamp)
    }

    /// The line logged for `title`'s book when its run for pages failed and
    /// `stamp` notes it, saying whether the next launch reads it again.
    static func failedRunLogLine(title: String, stamp: String?) -> String {
        let next = stamp?.hasSuffix(failedOnceNote) == true
            ? "it is read again for them at the next launch"
            : "it keeps its text without them until Redo Text Extraction"
        return "PAGES_RUN_FAILED: \(title): its pages could not be read; \(next)"
    }

    /// Whether `book`'s content.md predates its format's page reader.
    static func isOutdated(_ book: Book) -> Bool {
        isOutdated(format: book.format, stored: book.pageReaderVersion)
    }

    // MARK: - The Launch Re-read's Switch

    /// Whether the startup batch reads the books already in the library
    /// again to give them their pages (PG09): **on** since PG16.
    ///
    /// A review of PG09 (October 21, 2026) found the re-read unsafe to run
    /// on a library the user has worked on, and kept it off until PG16 made
    /// it safe (`LibraryViewModel.pageUpgradeCheck(of:access:)`):
    /// 1. The whole content.md is compared, byte for byte, with the book's
    ///    file read again without pages, where only the chapters' reading
    ///    text was, so an Edit Text change made before B12 that only turned
    ///    a paragraph into a heading, changed a heading's level, or renamed a
    ///    chapter is found as surely as one that changed words. Nothing tells
    ///    such an edit from an extraction that changed since, so text the
    ///    compare cannot match, which no edit record names, is copied beside
    ///    content.md (`content.md.edited-<UTC time>`, `PAGES_REPLACED_TEXT`)
    ///    before the book is read again with pages.
    /// 2. A book whose differing text could not be copied is kept as it is
    ///    and recorded as edited (`editedText`, B12), so no later automatic
    ///    re-read, such as a cache-format bump, replaces its text either; a
    ///    book with an edit record is kept the same way.
    /// 3. A content.md that is exactly the file read with its pages is taken
    ///    for TextMouth's own, written by a batch that stopped before it
    ///    committed the record (a quit does not wait for the batch): only the
    ///    record is stamped, and the text is never taken for the user's edit.
    /// 7. When textutil's run for the pages fails or times out, the page
    ///    reader is not recorded as done: the next launch tries once more,
    ///    and a second failure is noted in the stamp
    ///    (`stamp(for:pageRunFailed:previous:)`).
    ///
    /// The compare in 1 is for text from before pages. A book an earlier
    /// page reader wrote, whose stamp notes no failure (`notesSuccess(_:)`)
    /// and whose content.md is as its record describes it, is read again
    /// without it (V05): its text would differ from what a newer reader
    /// writes, and every book of the format would keep a copy.
    ///
    /// A book whose file is missing, or no longer extracts, is stamped and
    /// logged once, and the batch ends with one summary line in the debug
    /// log (`PAGES_UPGRADE_SUMMARY`). Setting this to false turns the
    /// re-read off again: no book is then chosen, compared, or stamped for
    /// its pages, while books imported or read again from their files still
    /// gain theirs, since every generation writes them. Tests switch it with
    /// `_setLaunchRereadForTesting(_:)`.
    static let launchRereadIsOn = true

    /// Whether the startup batch is to read `book` again for its pages
    /// (PG09): its content.md predates its format's page reader, and the
    /// launch re-read is switched on (`launchRereadIsOn`). Every choice the
    /// re-read makes asks this, so while it is off the batch neither chooses
    /// a book for its pages, nor refuses to recover a record for them, nor
    /// compares a book's text with its file's, nor records a page reader for
    /// text it keeps.
    static func isDueForPages(_ book: Book) -> Bool {
        isDueForPages(format: book.format, stored: book.pageReaderVersion)
    }

    /// `isDueForPages(_:)` for a book of `format` whose record holds
    /// `stored` as its page reader (nil when it holds none).
    static func isDueForPages(format: BookFormat, stored: String?) -> Bool {
        launchRereadRuns.withLock { $0 } && isOutdated(format: format, stored: stored)
    }

    /// Whether the re-read runs now: `launchRereadIsOn` in the app, and what
    /// a test set with `_setLaunchRereadForTesting(_:)`. Held under a lock,
    /// since the batch asks on its worker threads.
    private static let launchRereadRuns = OSAllocatedUnfairLock(initialState: launchRereadIsOn)

    /// Switches the launch re-read on or off for a test, and returns how it
    /// was, for the test to put back. The app never calls it.
    @discardableResult
    static func _setLaunchRereadForTesting(_ isOn: Bool) -> Bool {
        launchRereadRuns.withLock { runs in
            let previous = runs
            runs = isOn
            return previous
        }
    }
}
