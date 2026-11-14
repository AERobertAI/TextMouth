import Foundation

/// Shared proportional remaining-time calculation for library rows and reader
/// windows. Both surfaces must provide the same total duration and cursor.
enum ReadingTimeEstimator {
    static func remaining(
        totalDuration: TimeInterval,
        globalOffset: Int,
        totalCharacterCount: Int
    ) -> TimeInterval {
        guard totalDuration > 0, totalCharacterCount > 0 else { return 0 }
        let clampedOffset = min(max(globalOffset, 0), totalCharacterCount)
        let remainingFraction = 1 - Double(clampedOffset) / Double(totalCharacterCount)
        return totalDuration * remainingFraction
    }
}

enum BookFormat: String, Codable, CaseIterable {
    case epub
    case txt
    case markdown
    case html
    // A Safari web archive and an SSML file are read as text through the
    // HTML path (FMT03, FMT07). Like every raw value here, these are written
    // into the library index and never changed.
    case webarchive
    case ssml
    case docx
    // The next five are read through Apple's textutil in a child process
    // (FMT13). Their raw values are written into the library index, so they
    // are never changed.
    case rtf
    case rtfd
    case doc
    case odt
    case wordml
    // Braille books (FMT20): a BRF, a BRL, and a PEF, read through liblouis
    // in the braille helper (FMT21). Like every raw value here, written into
    // the library index and never changed: a TextMouth built before this case
    // refuses a library that holds a braille book. It keeps library.json and
    // a copy of it as they are, but still writes each book's package record,
    // which loses the fields it does not know (the records of edits and
    // pages, PLAN-0.2.0-2026-10-23.md, 1.1 and 1.2). The documentation
    // warns the user before they go back to an older build.
    case braille
    case daisy
    case pdf
    case audio
    // A Kindle book (MOBI 6, FMT42), read by TextMouth's own reader
    // (`MOBIParser`) on the Mac and on iOS. Like every raw value here, written
    // into the library index and never changed: a TextMouth built before this
    // case refuses a library that holds a Kindle book, as one built before
    // the braille case refuses a library that holds a braille book. The
    // documentation warns the user before they go back to an older build.
    case mobi
    // A DRM-free Kindle KFX book (FMT52), read by TextMouth's own reader
    // (`KFXParser`) on the Mac and on iOS. Like every raw value here, written
    // into the library index and never changed: a TextMouth built before this
    // case refuses a library that holds a KFX book, as with the MOBI case
    // before it. The documentation warns the user before they go back to an
    // older build.
    case kfx

    var displayName: String {
        switch self {
        case .epub: return "EPUB"
        case .txt: return "Plain Text"
        case .markdown: return "Markdown"
        case .html: return "HTML"
        case .webarchive: return "Web Archive"
        case .ssml: return "SSML"
        case .docx: return "Word Document"
        case .rtf: return "Rich Text"
        case .rtfd: return "Rich Text with Attachments"
        case .doc: return "Word 97-2003 Document"
        case .odt: return "OpenDocument Text"
        case .wordml: return "Word 2003 XML"
        case .braille: return "Braille"
        case .daisy: return "DAISY"
        case .pdf: return "PDF"
        case .audio: return "Audio"
        case .mobi: return "Kindle Book (MOBI)"
        case .kfx: return "Kindle Book (KFX)"
        }
    }

    /// The extensions of the files imported in this format. An audiobook
    /// may be a video file too (MPEG-4, M4V, or QuickTime), whose sound
    /// alone plays, as a video podcast's episode does (FR03): Open Book
    /// takes one, and a video episode's package imports again.
    ///
    /// Ogg audio (.ogg, .oga, and .opus, the extensions Core Audio itself
    /// lists for its Ogg file type) and the formats macOS decodes that
    /// TextMouth does not play as they are
    /// (`ImportAudioConverter.coreAudioExtensions`: AC-3, AMR, MP2, CAF,
    /// AIFC, AU, Wave64, 3GPP audio, and the like) are converted at import
    /// to an .m4a file, by afconvert in a child process
    /// (`ImportAudioConverter`), and only the converted file is played. A
    /// Mac whose afconvert cannot read a format (Ogg before macOS 15.4, for
    /// one) refuses such a file by name at "Converting its audio".
    ///
    /// A Word template (.dotx), a macro-enabled document (.docm), and a
    /// macro-enabled template (.dotm) are the same Office Open XML package
    /// as a .docx, only the main part's content type differs, so they share
    /// the `.docx` case and its reader. That reader opens only the XML parts
    /// it needs, so a macro project (word/vbaProject.bin) is never opened
    /// and no macro can run.
    var fileExtensions: [String] {
        switch self {
        case .epub: return ["epub"]
        case .txt: return ["txt"]
        case .markdown: return ["md", "markdown"]
        case .html: return ["html", "htm", "xhtml"]
        case .webarchive: return ["webarchive"]
        case .ssml: return ["ssml"]
        case .docx: return ["docx", "dotx", "docm", "dotm"]
        case .rtf: return ["rtf"]
        case .rtfd: return ["rtfd"]
        // A .dot is a .doc with its template bit set, read exactly as one.
        case .doc: return ["doc", "dot"]
        // A template (.ott) differs from a document only by its mimetype entry.
        case .odt: return ["odt", "ott"]
        // WordML is an .xml file, known by its root element through
        // `XMLDocumentSniffer` (see `detect(from:)`), never by an extension.
        case .wordml: return []
        case .braille: return ["brf", "brl", "pef"]
        case .daisy: return ["daisy", "opf"]
        case .pdf: return ["pdf"]
        case .audio:
            return ["mp3", "m4a", "m4b", "wav", "aiff", "aif", "flac", "alac", "aac", "ogg", "oga", "opus", "mp4", "m4v", "mov"]
                + ImportAudioConverter.coreAudioExtensions.sortedStably()
        // .prc is a Palm database, which a Kindle book of the first
        // generation was named, .azw is an Amazon Kindle book, and .azw3 is
        // one in the newer KF8 format (FMT48); all are read by the book's own
        // headers (`MOBIPalmDatabase`), not by the name.
        case .mobi: return ["mobi", "prc", "azw", "azw3"]
        // .kfx is a KFX container; .azw8 is the same container as Kindle for
        // iOS and Mac name it; .kfx-zip is calibre's bundle of a book's
        // containers. .kpf is a Kindle Create package, which is taken only
        // to be refused with its own sentence (`KFXError.kindleCreatePackage`)
        // rather than as an unknown type. An `.azw` file holding KFX bytes is
        // a MOBI-named file read by its bytes (`MOBIParser`), not listed here.
        case .kfx: return ["kfx", "kfx-zip", "azw8", "kpf"]
        }
    }

    /// The extensions, in lowercase, that a package's track scan takes as
    /// tracks: the audio list without the formats added on October 18, 2026
    /// (`ImportAudioConverter.coreAudioExtensions`: AIFC, AU, AC-3, CAF, and
    /// the rest of the formats macOS decodes that the import converts). A
    /// package holds the converted file of each such track, so one of them
    /// found in it is a stray, an older ZIP import's leftover or a file put
    /// there by hand, and is neither played nor counted as a chapter, as
    /// taking it would fail the book or shift the chapters after it under
    /// the listener's places. What Open Book, an import, a playlist, a feed,
    /// and Export accept is the whole audio list (`fileExtensions`), not
    /// this one. TextMouth's own CAF, the one of those formats it also
    /// writes, is taken by its name and place
    /// (`AudioBookParser.isOwnCAF(atPath:)`), never by this list.
    ///
    /// Ogg (`ImportAudioConverter.oggExtensions`) stays in the list, as it
    /// was before October 18: the library converts the Ogg books it already
    /// holds, and that conversion reads a book's index before converting it,
    /// which needs the book's Ogg tracks found. The reader's guards refuse
    /// an Ogg track by name and by content.
    static var packageTrackExtensions: Set<String> {
        Set(BookFormat.audio.fileExtensions).subtracting(ImportAudioConverter.coreAudioExtensions)
    }

    var isAudio: Bool { self == .audio }

    /// Whether the book's file is plain text that `TextFileDecoder` reads in
    /// an encoding the file may not name (FMT16): plain text, Markdown, and
    /// HTML. The other formats are read through their own readers, which
    /// know their encodings, so a recorded text encoding means nothing to them.
    var usesTextFileDecoder: Bool { self == .txt || self == .markdown || self == .html }

    /// Whether this format exposes format-specific fields in the rich metadata editor.
    /// Other document formats only support the shared title and author fields.
    var usesRichMetadataEditor: Bool { self == .epub || isAudio }

    /// The format a book imported from `url` has: from its extension, or
    /// for a DAISY book kept as loose files, from its navigation file's
    /// name or its folder's contents (TODO I02).
    static func detect(from url: URL) -> BookFormat? {
        // A DAISY 2.02 book's navigation file is always named ncc.html (or
        // ncc.htm). It stands for its whole book, not for one HTML page.
        if DAISYParser.isNCCFileName(url.lastPathComponent) {
            return .daisy
        }
        let ext = url.pathExtension.lowercased()
        // A loose XML file is read by what its root element says it is
        // (FMT04, FMT13), never by its extension alone: a DTBook is a
        // DAISY book, and any other XML file is no book. A folder that
        // happens to be named like an XML file is not a file, so it falls
        // through to the folder check below.
        if ext == "xml", let format = XMLDocumentSniffer.bookFormat(ofFileAt: url) {
            return format
        }
        for format in BookFormat.allCases {
            if format.fileExtensions.contains(ext) {
                return format
            }
        }
        // Check if a ZIP file is actually a DAISY package
        if ext == "zip" && DAISYParser.isDAISYZip(url: url) {
            return .daisy
        }
        // A folder with a DAISY book's package or navigation file at its top
        // level is that book. A TextMouth package is never imported as one:
        // it holds a book TextMouth already describes.
        if ext != "tmb" && DAISYParser.isDAISYDirectory(url: url) {
            return .daisy
        }
        return nil
    }
}

/// The record that a book's content.md holds text the user changed with
/// Edit Text (B12): the digest of the content.md bytes the edit left, and
/// when the edit was taken. An automatic re-read of the book's file (a
/// cache-format bump, the reader's rebuild of an outdated cache, a page
/// re-read) never replaces a content.md whose digest is this one; only
/// Redo Text Extraction does, and the record then goes
/// (`Book.applyContentAnalysis(_:cacheFormatVersion:)`). The record is kept
/// with the book's analysis fields (`Book.ContentAnalysisFields`), in its
/// library row and its package record, so a rebuilt library keeps it.
struct EditedText: Codable, Hashable, Sendable {
    /// The digest of the content.md bytes the edit left, as
    /// `BookTextEditSessions.check` computes it (`FingerprintHasher.digestOfData`).
    var cacheDigest: String
    /// When TextMouth took the edit as the book's text.
    var takenAt: Date
}

struct Book: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var author: String
    var format: BookFormat
    var filePath: String
    var md5Hash: String
    var folderPath: String  // e.g. "Fiction/Sci-Fi" or "" for root
    var dateAdded: Date
    var lastOpened: Date?
    /// A book is unopened while it has never been opened (`lastOpened` is
    /// nil). It is what the Unopened category lists, and what a row's "New"
    /// and `BookState.isNew` read.
    var isUnopened: Bool { lastOpened == nil }
    var readingPosition: ReadingPosition?
    var bookmarks: [Bookmark]
    /// Total word count — populated when the book is first opened and parsed
    var totalWordCount: Int?
    /// Total character count — populated when the book is first opened and parsed
    var totalCharacterCount: Int?
    /// Name of the .tmb directory (e.g. "Title-Author-123456.tmb")
    var tmbDirectoryName: String
    /// Path to the original source file this book was imported from
    var sourceFilePath: String?
    /// When playback was last started (for rewind-on-resume)
    var lastPlaybackStarted: Date?
    /// When playback was last stopped/paused (for rewind-on-resume)
    var lastPlaybackStopped: Date?
    /// Per-book voice ID override (nil = use global setting)
    var localVoiceID: String?
    /// Per-book WPM override (nil = use global setting)
    var localWPM: Double?
    /// Per-book pitch multiplier override (nil = use global setting, range 0.5–2.0)
    var localPitch: Double?
    /// Heading IDs that should be skipped during playback (`Heading.id`):
    /// what the reader matches against the book's headings, and all older
    /// builds read. Written from `skippedHeadings`, which the reader saves
    /// (`setSkippedHeadings(_:)`, T06's branch B). A caller that names
    /// skips by their IDs alone, as an older build's row does, may still
    /// set them: `skippedHeadings` then follows, keeping the anchor of each
    /// heading still named.
    var skippedHeadingIDs: [String]? {
        didSet { skippedHeadings = SkippedHeading.inStep(with: skippedHeadingIDs, keeping: skippedHeadings) }
    }
    /// The headings skipped during playback by their level, label, and
    /// place, with the text at their start (T06), so a skip can follow its
    /// heading when the book's text is read anew: what TextMouth saves,
    /// through `setSkippedHeadings(_:)`, which writes `skippedHeadingIDs`
    /// from them. A row or record holding IDs alone, as every one written
    /// before T06 does, has them made from its IDs, without anchors; one
    /// holding both keeps the anchor of each heading its IDs name, since
    /// the IDs, which every build writes, say which headings are skipped.
    private(set) var skippedHeadings: [SkippedHeading]?
    /// The headings skipped during playback for which a rebuild of the
    /// book's text found no heading (T06's branch D). Each waits, naming no
    /// heading, so neither this build's reader nor an older build skips
    /// anything for it, and it is kept so a later rebuild may find its
    /// heading. Never in `skippedHeadingIDs`; written with the moved places
    /// (`takeMovedPlaces(original:moved:)`). Nil when there are none, never
    /// an empty array.
    var waitingSkippedHeadings: [SkippedHeading]?
    /// Per-book end-of-book behavior override (nil = use global)
    var localEndOfBookBehavior: String?
    /// Per-book forward navigation unit (nil or invalid = use global).
    var localSkipForwardUnit: String?
    /// Per-book backward navigation unit (nil or invalid = use global).
    var localSkipBackwardUnit: String?
    /// Manual sort order within folder (lower = earlier)
    var manualSortOrder: Int?
    /// Total audio duration in seconds (for audio books only)
    var audioDuration: TimeInterval?
    /// Audio-specific metadata fields (album, genre, year) persisted in bookInfo.json
    var audioAlbum: String?
    var audioGenre: String?
    var audioYear: String?
    /// EPUB metadata is stored independently from optional file write-back so
    /// library-only edits survive reopening the editor and saving reading state.
    var epubPublisher: String?
    var epubPublicationDate: String?
    var epubISBN: String?
    var epubLanguage: String?
    var epubIdentifier: String?
    var epubVersion: String?
    /// Version of the content.md cache format. When this is lower than
    /// MarkdownCacheService.currentCacheVersion the cache will be regenerated
    /// on the next app launch to pick up parser improvements.
    var cacheFormatVersion: String?
    /// Compact validity marker for the full index stored in bookInfo.json.
    var contentIndexVersion: String?
    /// The fingerprints of the source and content.md the text cache was
    /// written from (see `TextCacheFingerprint`), recorded with the analysis
    /// that measured them; nil for audio and for a cache written before
    /// fingerprints. Startup maintenance compares them with the files.
    var textCacheFingerprint: TextCacheFingerprint?
    /// The edit of the book's text that content.md holds, if the user made
    /// one with Edit Text (`EditedText`, B12): nil for every book until an
    /// edit is taken, and again once content.md is no longer that edit. It
    /// is an analysis field, so it follows the fingerprints it describes.
    var editedText: EditedText?
    /// The version of the page reader (`PageReaderVersions`, PG09) that read
    /// the book's file into content.md: the version of its format when
    /// content.md was last written from the file with page markers, nil for
    /// every book written before pages and for a format without pages. A
    /// book whose format has a newer page reader is read again at launch
    /// (`LibraryViewModel.booksNeedingCacheUpdate`) while that re-read is
    /// switched on (`PageReaderVersions.launchRereadIsOn`, on since PG16),
    /// unless the user changed its text, which is kept as it is. A note
    /// after the version, as in "1.0.0+failed-once", says that reader could
    /// not read the book's pages (`PageReaderVersions.stamp(for:pageRunFailed:previous:)`).
    /// An analysis field, like the cache's own version.
    var pageReaderVersion: String?
    /// The version of the metadata reader (`ImportedFileMetadata.readerVersion`)
    /// that last read this book's file for its title and author: the
    /// import's, or the launch refresh's. A row stamped by an older reader,
    /// or by none, as every row was before readers were versioned, is read
    /// again at launch (`LibraryViewModel.refreshOutdatedMetadata`). Kept
    /// in the row and, from the book's next save on, in its record, so a
    /// library rebuilt from its records reads again only the books whose
    /// records were written before that.
    var metadataReaderVersion: String?
    /// Which of this book's metadata fields the user edited by hand, and
    /// since when (`HandEdits`); nil for a book nothing has recorded for:
    /// every row saved before October 7, 2026, and a book made since by an
    /// import that does not begin a record (a feed's download, a recording,
    /// New from Text, an audio or DAISY archive), until an editor's save
    /// begins one. A file imported since then begins an empty record kept
    /// since the import (`HandEdits.noneSinceImport`, `FileImportService`).
    /// Every editor's save records the fields it changed
    /// (`LibraryViewModel.updateBookMetadata`), Book Info says which
    /// values are the user's own, and the launch metadata refresh never
    /// replaces a recorded field (`LibraryViewModel.refreshedValues(of:from:)`).
    /// Kept in the row and in the book's record; a reader's copy takes the
    /// row's (`EditableMetadata`).
    var handEdits: HandEdits?
    /// The feed item this row's book was downloaded from (FR03): set for a
    /// podcast episode or an article while it belongs to its feed (FR11),
    /// nil for every other book. A row with a link is a feed item's: its
    /// package lives in its feed's own folder (`Feeds/<feed ID>/`, see
    /// `tmbDirectory`), its row is kept in that feed's index rather than in
    /// library.json (`FeedIndex`), and the library's lists and counts leave
    /// it out (`isFeedItem`). Read when present and written only when set,
    /// so library.json's rows are exactly as they were. The package's record
    /// keeps the link too (`BookMetadata.feedLink`), and keeps it when a
    /// row's link is cleared.
    var feedLink: FeedBookLink?

    /// The braille table this braille book's text was read with (FMT21), by
    /// its stored value (`BrailleTableSource`): a bundled table's file name,
    /// such as "en-ueb-g2.ctb", or "mac:" and the file name of one of this
    /// Mac's VoiceOver tables, such as "mac:fr-bfu-g2.ctb" (October 20,
    /// 2026): the Braille setting's table when the book was imported, which
    /// every later reading of the book uses, the Markdown cache's rebuild
    /// included, so a change of the setting never moves the book's text
    /// under its places. A Mac table a macOS update removes or changes is
    /// kept: the book keeps its text, and a rebuild that needs the table
    /// fails by name. Nil for every other book, and read as
    /// `BrailleTableCatalog.defaultTableID` for a braille book whose row and
    /// record lack one. Kept in the row and the record.
    var brailleTable: String?

    /// The liblouis version of this Mac's tables when this braille book was
    /// read with one of them (review R2, decision 8), such as "3.34.0", from
    /// the property list beside the Mac's tables. Apple installs liblouis's
    /// tables whole and unmodified, recording the release they come from, so
    /// a macOS update that changes a table changes this version. A rebuild
    /// that finds another version fails by name and keeps the book's text
    /// (`BrailleBookReader.requireUnchangedTable(_:recordedVersion:)`). Nil
    /// for a bundled table, for a book imported before it was recorded, and
    /// when the Mac's tables name no version. Kept in the row, the record,
    /// and the removal marker.
    var brailleTableVersion: String?

    /// The braille file characters this BRF or BRL book's file writes its
    /// cells in (braillecodes), by the code's id (`BrailleFileCode`), such
    /// as "ascii-na" for North American Braille ASCII, "ascii-eurobraille"
    /// for Eurobraille's six-dot code, or "unicode" for Unicode braille
    /// patterns: the code an import read the file with, or the one a re-read
    /// in other braille file characters in Book Information read it with,
    /// which every later reading of the book uses. Nil for a book that
    /// records none: every braille book imported before codes were recorded,
    /// every PEF, and every book of another format; a braille book's nil is
    /// read as North American Braille ASCII. An id this TextMouth does not
    /// know, as a later TextMouth's may be, is kept exactly as it is stored,
    /// through every save, and the book's reading refuses it by name, never
    /// reading it as another code. A value that cannot be read counts as
    /// none. A re-read writes its id into the package record first, with
    /// the new text, and the row takes it afterwards, so the record's code
    /// stands over the row's when it names one
    /// (`BrailleFileCodeRecord.standing(row:recorded:)`). An older TextMouth
    /// ignores the key, and drops it from both the row and the record at its
    /// next write: a Unicode book then heals at its next rebuild here, its
    /// bytes recognized (`brailleFileCodeForReading()`), but a Eurobraille
    /// book is read as North American Braille ASCII, which is why the
    /// changelog asks that such a library not be opened in an earlier
    /// TextMouth (the review of October 30, finding 1). Kept in the row, the
    /// record, and the removal marker.
    var brailleFileCode: String?

    /// The encoding TextMouth guessed this plain-text, Markdown, or HTML
    /// book's file is in (FMT16), by its identifier in `TextEncodingCatalog`,
    /// such as "windows-1251" or "koi8-r": set when the book is imported from
    /// a file whose bytes named no encoding (not UTF-8, no byte-order mark,
    /// no declaration) and `TextEncodingGuesser` found one that reads them
    /// better than the Windows-1252 default. Every later reading of the
    /// book uses it, the Markdown cache's rebuild included
    /// (`TextFileDecoder.EncodingPolicy.recorded(_:)`), so that a better
    /// guesser, or a macOS update, never moves the book's text under its
    /// reader's places. Nil for a book whose bytes named their encoding, for
    /// one Windows-1252 reads correctly, and for every book imported before
    /// guesses were recorded, which are read as they always were. Kept in the
    /// row, the record, and the removal marker.
    ///
    /// Since the listener can choose a book's encoding in Book Information
    /// (encodingchoice), it holds the choice too, and `textEncodingSource`
    /// says who decided it: the two travel together (`textEncodingRecord`).
    var textEncoding: String?

    /// Who decided `textEncoding` (encodingchoice): the listener's choice of
    /// an encoding, or of Automatic, in Book Information; nil for the
    /// import (FMT16), which is every book the listener has not chosen for,
    /// so their rows and records are written exactly as before. A value that
    /// cannot be read, as a later TextMouth's might be, is nil. Kept in the
    /// row, the record, and the removal marker.
    var textEncodingSource: TextEncodingSource?

    /// Whether this row is a feed item's download (FR11): its feed lists it,
    /// and the library's own lists, counts, and maintenance leave it out.
    var isFeedItem: Bool {
        feedLink != nil
    }

    /// The author a book is listed under when nothing names one: what every
    /// import, parser, and recording writes for it, which a reader leaves
    /// out of its window title and a metadata refresh may replace
    /// (`isUnknownAuthor(_:)`).
    static let unknownAuthor = "Unknown"

    /// Whether `author` is the placeholder for an author nothing named:
    /// empty, or `unknownAuthor`.
    static func isUnknownAuthor(_ author: String) -> Bool {
        author.isEmpty || author == unknownAuthor
    }

    init(
        id: UUID = UUID(),
        title: String,
        author: String = Book.unknownAuthor,
        format: BookFormat,
        filePath: String,
        md5Hash: String,
        folderPath: String = "",
        dateAdded: Date = Date(),
        lastOpened: Date? = nil,
        readingPosition: ReadingPosition? = nil,
        bookmarks: [Bookmark] = [],
        totalWordCount: Int? = nil,
        totalCharacterCount: Int? = nil,
        tmbDirectoryName: String = "",
        sourceFilePath: String? = nil,
        lastPlaybackStarted: Date? = nil,
        lastPlaybackStopped: Date? = nil,
        localVoiceID: String? = nil,
        localWPM: Double? = nil,
        localPitch: Double? = nil,
        skippedHeadingIDs: [String]? = nil,
        skippedHeadings: [SkippedHeading]? = nil,
        waitingSkippedHeadings: [SkippedHeading]? = nil,
        localEndOfBookBehavior: String? = nil,
        localSkipForwardUnit: String? = nil,
        localSkipBackwardUnit: String? = nil,
        manualSortOrder: Int? = nil,
        audioDuration: TimeInterval? = nil,
        audioAlbum: String? = nil,
        audioGenre: String? = nil,
        audioYear: String? = nil,
        epubPublisher: String? = nil,
        epubPublicationDate: String? = nil,
        epubISBN: String? = nil,
        epubLanguage: String? = nil,
        epubIdentifier: String? = nil,
        epubVersion: String? = nil,
        cacheFormatVersion: String? = nil,
        contentIndexVersion: String? = nil,
        textCacheFingerprint: TextCacheFingerprint? = nil,
        editedText: EditedText? = nil,
        pageReaderVersion: String? = nil,
        metadataReaderVersion: String? = nil,
        handEdits: HandEdits? = nil,
        feedLink: FeedBookLink? = nil,
        brailleTable: String? = nil,
        brailleTableVersion: String? = nil,
        brailleFileCode: String? = nil,
        textEncoding: String? = nil,
        textEncodingSource: TextEncodingSource? = nil
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.format = format
        self.filePath = filePath
        self.md5Hash = md5Hash
        self.folderPath = folderPath
        self.dateAdded = dateAdded
        self.lastOpened = lastOpened
        self.readingPosition = readingPosition
        self.bookmarks = bookmarks
        self.totalWordCount = totalWordCount
        self.totalCharacterCount = totalCharacterCount
        self.tmbDirectoryName = tmbDirectoryName
        self.sourceFilePath = sourceFilePath
        self.lastPlaybackStarted = lastPlaybackStarted
        self.lastPlaybackStopped = lastPlaybackStopped
        self.localVoiceID = localVoiceID
        self.localWPM = localWPM
        self.localPitch = localPitch
        self.skippedHeadingIDs = skippedHeadingIDs
        self.skippedHeadings = SkippedHeading.inStep(with: skippedHeadingIDs, keeping: skippedHeadings)
        self.waitingSkippedHeadings = SkippedHeading.stored(waitingSkippedHeadings)
        self.localEndOfBookBehavior = localEndOfBookBehavior
        self.localSkipForwardUnit = localSkipForwardUnit
        self.localSkipBackwardUnit = localSkipBackwardUnit
        self.manualSortOrder = manualSortOrder
        self.audioDuration = audioDuration
        self.audioAlbum = audioAlbum
        self.audioGenre = audioGenre
        self.audioYear = audioYear
        self.epubPublisher = epubPublisher
        self.epubPublicationDate = epubPublicationDate
        self.epubISBN = epubISBN
        self.epubLanguage = epubLanguage
        self.epubIdentifier = epubIdentifier
        self.epubVersion = epubVersion
        self.cacheFormatVersion = cacheFormatVersion
        self.contentIndexVersion = contentIndexVersion
        self.textCacheFingerprint = textCacheFingerprint
        self.editedText = editedText
        self.pageReaderVersion = pageReaderVersion
        self.metadataReaderVersion = metadataReaderVersion
        self.handEdits = handEdits
        self.feedLink = feedLink
        self.brailleTable = brailleTable
        self.brailleTableVersion = brailleTableVersion
        self.brailleFileCode = brailleFileCode
        self.textEncoding = textEncoding
        self.textEncodingSource = textEncodingSource
    }

    // Custom decoding to handle missing fields from old library.json.
    // Counts, speed, and pitch are validated with `SettingsPolicy` (and
    // positions and bookmarks validate themselves), so a hand-edited or
    // damaged value is repaired instead of failing the whole library.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fields = LenientFields(container, source: SettingsPolicy.bookStateSource)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        author = try container.decode(String.self, forKey: .author)
        format = try container.decode(BookFormat.self, forKey: .format)
        filePath = try container.decode(String.self, forKey: .filePath)
        md5Hash = try container.decode(String.self, forKey: .md5Hash)
        folderPath = try container.decode(String.self, forKey: .folderPath)
        dateAdded = try container.decode(Date.self, forKey: .dateAdded)
        lastOpened = try container.decodeIfPresent(Date.self, forKey: .lastOpened)
        readingPosition = try container.decodeIfPresent(ReadingPosition.self, forKey: .readingPosition)
        bookmarks = try container.decode([Bookmark].self, forKey: .bookmarks)
        totalWordCount = fields.count(.totalWordCount)
        totalCharacterCount = fields.count(.totalCharacterCount)
        tmbDirectoryName = try container.decodeIfPresent(String.self, forKey: .tmbDirectoryName) ?? ""
        sourceFilePath = try container.decodeIfPresent(String.self, forKey: .sourceFilePath)
        lastPlaybackStarted = try container.decodeIfPresent(Date.self, forKey: .lastPlaybackStarted)
        lastPlaybackStopped = try container.decodeIfPresent(Date.self, forKey: .lastPlaybackStopped)
        localVoiceID = try container.decodeIfPresent(String.self, forKey: .localVoiceID)
        // `localWPM` holds words per minute for text and a multiplier for audio.
        let isAudio = format.isAudio
        localWPM = fields.optionalValue(.localWPM) { SettingsPolicy.validatedLocalSpeed($0, isAudio: isAudio) }
        localPitch = fields.optionalValue(.localPitch, validate: SettingsPolicy.validatedLocalPitch)
        skippedHeadingIDs = try container.decodeIfPresent([String].self, forKey: .skippedHeadingIDs)
        // Skipped headings that cannot be read count as none; either way
        // they are put in step with the IDs, which an older build may have
        // changed alone.
        skippedHeadings = SkippedHeading.inStep(with: skippedHeadingIDs, keeping: fields.optionalValue(.skippedHeadings) { $0 })
        // Waiting skips that cannot be read count as none; an empty list is
        // none too.
        waitingSkippedHeadings = SkippedHeading.stored(fields.optionalValue(.waitingSkippedHeadings) { $0 })
        localEndOfBookBehavior = try container.decodeIfPresent(String.self, forKey: .localEndOfBookBehavior)
        localSkipForwardUnit = try container.decodeIfPresent(String.self, forKey: .localSkipForwardUnit)
        localSkipBackwardUnit = try container.decodeIfPresent(String.self, forKey: .localSkipBackwardUnit)
        manualSortOrder = try container.decodeIfPresent(Int.self, forKey: .manualSortOrder)
        audioDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .audioDuration)
        audioAlbum = try container.decodeIfPresent(String.self, forKey: .audioAlbum)
        audioGenre = try container.decodeIfPresent(String.self, forKey: .audioGenre)
        audioYear = try container.decodeIfPresent(String.self, forKey: .audioYear)
        epubPublisher = try container.decodeIfPresent(String.self, forKey: .epubPublisher)
        epubPublicationDate = try container.decodeIfPresent(String.self, forKey: .epubPublicationDate)
        epubISBN = try container.decodeIfPresent(String.self, forKey: .epubISBN)
        epubLanguage = try container.decodeIfPresent(String.self, forKey: .epubLanguage)
        epubIdentifier = try container.decodeIfPresent(String.self, forKey: .epubIdentifier)
        epubVersion = try container.decodeIfPresent(String.self, forKey: .epubVersion)
        // Decode as String, falling back to converting old Int values for compatibility
        if let str = try? container.decodeIfPresent(String.self, forKey: .cacheFormatVersion) {
            cacheFormatVersion = str
        } else if let intVal = try? container.decodeIfPresent(Int.self, forKey: .cacheFormatVersion) {
            cacheFormatVersion = "\(intVal).0.0"
        } else {
            cacheFormatVersion = nil
        }
        contentIndexVersion = try container.decodeIfPresent(String.self, forKey: .contentIndexVersion)
        // A fingerprint that cannot be read counts as none: the cache is then
        // checked as one written before fingerprints, instead of the whole
        // library failing over one damaged field.
        textCacheFingerprint = fields.optionalValue(.textCacheFingerprint) { $0 }
        // A record of an edit that cannot be read counts as none, as a
        // fingerprint does; older rows have none (B12).
        editedText = fields.optionalValue(.editedText) { $0 }
        // A version that cannot be read counts as none: the book is then
        // read again for its pages, which only keeps its text if it is
        // unchanged (PG09).
        pageReaderVersion = fields.optionalValue(.pageReaderVersion) { $0 }
        metadataReaderVersion = try container.decodeIfPresent(String.self, forKey: .metadataReaderVersion)
        // A record of hand edits that cannot be read counts as none, as a
        // fingerprint does: the row is then one nothing was recorded for,
        // which the metadata refresh treats with the most care.
        handEdits = fields.optionalValue(.handEdits) { $0 }
        // A feed link that cannot be read counts as none (FR11): the row is
        // then a book of the library's own rather than the whole library
        // failing over it.
        feedLink = fields.optionalValue(.feedLink) { $0 }
        // A braille table name that cannot be read counts as none (FMT21),
        // so the book reads with the default table instead of the whole
        // library failing over one damaged field.
        brailleTable = fields.optionalValue(.brailleTable) { $0 }
        brailleTableVersion = fields.optionalValue(.brailleTableVersion) { $0 }
        // A braille file code that cannot be read counts as none
        // (braillecodes), as a damaged table name does, instead of the whole
        // library failing over it; the package record's code, when it names
        // one, stands over it (`BrailleFileCodeRecord.standing(row:recorded:)`).
        brailleFileCode = fields.optionalValue(.brailleFileCode) { $0 }
        // A text encoding that cannot be read counts as none (FMT16): the book
        // is then read as every book was before guesses were recorded.
        textEncoding = fields.optionalValue(.textEncoding) { $0 }
        // Who decided it, when it cannot be read (a later TextMouth's value),
        // counts as the import: the encoding then reads as a guess.
        textEncodingSource = fields.optionalValue(.textEncodingSource) { $0 }
    }

    /// The .tmb package directory URL: in the library, or, while an import
    /// is staging this book's package, wherever the import builds it, which
    /// can be this Mac's Import Staging folder (`ImportStaging`, FR02).
    ///
    /// A feed item's package is in its feed's own folder, `Feeds/<feed
    /// ID>/`, outside the Library folder (FR11); every other book's is in its
    /// library folder. Every use of an existing package follows this one
    /// rule: record saves, package deletion, cloud state, transcripts, the
    /// reader's working copy, and Show in Finder.
    var tmbDirectory: URL {
        if let staged = ImportStaging.directory(ofStagedPackage: tmbDirectoryName) {
            return staged
        }
        return packageDirectory(inDataDirectory: TextMouthPaths.root)
    }

    /// Where this book's package is in the data directory at `root`, as
    /// `tmbDirectory` places it there: in its feed's folder for a feed item
    /// (FR11), and otherwise in its library folder, exactly where
    /// `TextMouthPaths.tmbPath(folderPath:tmbName:)` names it for the data
    /// directory in use. A data-directory move places each package of the
    /// copy it stages this way (`DataDirectoryMigrator`).
    func packageDirectory(inDataDirectory root: URL) -> URL {
        fileLocation.packageDirectory(inDataDirectory: root)
    }

    /// The actual book file URL inside the .tmb package
    var bookFileURL: URL {
        URL(fileURLWithPath: filePath)
    }

    /// The effective WPM for this book: local override if set, otherwise the provided fallback
    func effectiveWPM(fallback: Double) -> Double {
        localWPM ?? fallback
    }

    /// Resolve the saved forward unit, safely falling back for legacy or
    /// manually edited state containing no value or an unknown value.
    func effectiveSkipForwardUnit(fallback: SkipUnit) -> SkipUnit {
        localSkipForwardUnit.flatMap(SkipUnit.init(rawValue:)) ?? fallback
    }

    /// Resolve the saved backward unit with the same compatibility behavior.
    func effectiveSkipBackwardUnit(fallback: SkipUnit) -> SkipUnit {
        localSkipBackwardUnit.flatMap(SkipUnit.init(rawValue:)) ?? fallback
    }

    /// The fields of a book that content analysis owns: the word and
    /// character counts, the audio duration, the versions of the content
    /// index and text cache they were measured from, and the fingerprints of
    /// the files that text cache was written from, and the edit of the text
    /// that content.md holds (`EditedText`), if any. An analysis result
    /// changes these and nothing else, whether it lands in the package
    /// record or on the library row. Every other field of a book is user
    /// state or metadata, which only the user's own actions change.
    struct ContentAnalysisFields: Equatable, Sendable {
        var totalWordCount: Int?
        var totalCharacterCount: Int?
        var audioDuration: TimeInterval?
        var contentIndexVersion: String?
        var cacheFormatVersion: String?
        var textCacheFingerprint: TextCacheFingerprint? = nil
        var editedText: EditedText? = nil
        var pageReaderVersion: String? = nil
    }

    /// This book's analysis-owned fields. Setting them changes exactly those
    /// fields, so a record or a row that takes an analysis keeps every
    /// reading position, bookmark, setting, and edit it had.
    var contentAnalysisFields: ContentAnalysisFields {
        get {
            ContentAnalysisFields(
                totalWordCount: totalWordCount,
                totalCharacterCount: totalCharacterCount,
                audioDuration: audioDuration,
                contentIndexVersion: contentIndexVersion,
                cacheFormatVersion: cacheFormatVersion,
                textCacheFingerprint: textCacheFingerprint,
                editedText: editedText,
                pageReaderVersion: pageReaderVersion
            )
        }
        set {
            totalWordCount = newValue.totalWordCount
            totalCharacterCount = newValue.totalCharacterCount
            audioDuration = newValue.audioDuration
            contentIndexVersion = newValue.contentIndexVersion
            cacheFormatVersion = newValue.cacheFormatVersion
            textCacheFingerprint = newValue.textCacheFingerprint
            editedText = newValue.editedText
            pageReaderVersion = newValue.pageReaderVersion
        }
    }

    /// Records a completed analysis of this book: the statistics and version
    /// of `index` and, when the analysis vouches for one, the version of the
    /// text cache it read or wrote. A nil `cacheFormatVersion` keeps the
    /// book's own, since such an analysis says nothing about the cache. The
    /// cache's fingerprints always come from `index`, which carries those of
    /// the files it was made from, so a book never keeps fingerprints that
    /// describe another index than the one recorded with them.
    ///
    /// The record of an edit (`editedText`, B12) holds only while content.md
    /// is that edit: when `index` carries a text-cache fingerprint whose
    /// content.md digest is another than the edit's, the book's text is not
    /// the edit any more (Redo Text Extraction wrote the source's text, or
    /// another edit was taken), and the record goes. An index with no
    /// fingerprint says nothing about content.md, so the record stays.
    mutating func applyContentAnalysis(_ index: BookContentIndex, cacheFormatVersion: String?) {
        contentAnalysisFields = ContentAnalysisFields(
            totalWordCount: index.totalWordCount,
            totalCharacterCount: index.totalCharacterCount,
            audioDuration: index.totalAudioDuration,
            contentIndexVersion: index.version,
            cacheFormatVersion: cacheFormatVersion ?? self.cacheFormatVersion,
            textCacheFingerprint: index.textCacheFingerprint,
            editedText: editedText.flatMap { edit in
                guard let digest = index.textCacheFingerprint?.cache.digest else { return edit }
                return digest == edit.cacheDigest ? edit : nil
            },
            // An analysis says nothing about which page reader wrote
            // content.md: only a generation stamps it (PG09).
            pageReaderVersion: pageReaderVersion
        )
    }

    /// Records the statistics and version of `index`, keeping the book's text
    /// cache version (see `applyContentAnalysis(_:cacheFormatVersion:)`).
    mutating func applyContentIndexSummary(_ index: BookContentIndex) {
        applyContentAnalysis(index, cacheFormatVersion: nil)
    }

    /// Whether this book overrides any global voice, speed, or pitch setting.
    var hasLocalVoiceSettings: Bool {
        localVoiceID != nil || localWPM != nil || localPitch != nil
    }

    struct LocalVoiceSettings: Equatable {
        var voiceID: String? = nil
        var wordsPerMinute: Double? = nil
        var pitch: Double? = nil
    }

    /// Snapshot used when copying this book's overrides into global settings.
    var localVoiceSettings: LocalVoiceSettings {
        LocalVoiceSettings(voiceID: localVoiceID, wordsPerMinute: localWPM, pitch: localPitch)
    }

    /// Remove all per-book voice overrides atomically from the model.
    mutating func clearLocalVoiceSettings() {
        localVoiceID = nil
        localWPM = nil
        localPitch = nil
    }

    /// The metadata the library's and the reader's metadata editors change:
    /// the title and author, an audiobook's album, genre, and year, and an
    /// EPUB's publisher and publication date, together with the content
    /// hash, which changes when an edit is written into the book's EPUB
    /// file, and the record of which of them the user edited by hand
    /// (`handEdits`), which every save of them keeps.
    struct EditableMetadata: Equatable, Sendable {
        var title: String
        var author: String
        var md5Hash: String
        var audioAlbum: String?
        var audioGenre: String?
        var audioYear: String?
        var epubPublisher: String?
        var epubPublicationDate: String?
        var handEdits: HandEdits?
    }

    /// This book's editable metadata. Setting it changes exactly those
    /// fields, so the book's identity, files, and reading state stay as they
    /// were.
    var editableMetadata: EditableMetadata {
        get {
            EditableMetadata(
                title: title,
                author: author,
                md5Hash: md5Hash,
                audioAlbum: audioAlbum,
                audioGenre: audioGenre,
                audioYear: audioYear,
                epubPublisher: epubPublisher,
                epubPublicationDate: epubPublicationDate,
                handEdits: handEdits
            )
        }
        set {
            title = newValue.title
            author = newValue.author
            md5Hash = newValue.md5Hash
            audioAlbum = newValue.audioAlbum
            audioGenre = newValue.audioGenre
            audioYear = newValue.audioYear
            epubPublisher = newValue.epubPublisher
            epubPublicationDate = newValue.epubPublicationDate
            handEdits = newValue.handEdits
        }
    }

    /// Apply the metadata fields that can be edited by the library and reader
    /// metadata sheets (`EditableMetadata`). Keeping this mutation on Book
    /// makes the complete field set independently testable and prevents
    /// individual callers from silently dropping format-specific values.
    mutating func applyEditableMetadata(from updatedBook: Book) {
        editableMetadata = updatedBook.editableMetadata
    }

    /// Where a book's files are: the library folder holding its package, the
    /// package's name, and the path the book reads from inside it (its file,
    /// or its folder of audio tracks), and, for a feed item, the feed whose
    /// folder holds the package instead (FR11). Moving the book, renaming or
    /// moving a folder above it, moving it into its feed's folder, and moving
    /// the data directory change it.
    struct FileLocation: Equatable, Sendable {
        var folderPath: String
        var filePath: String
        var tmbDirectoryName: String
        /// The feed item a feed item's package belongs to, which puts the
        /// package in its feed's folder (`Book.tmbDirectory`); nil for every
        /// other book.
        var feedLink: FeedBookLink? = nil

        /// Where the package this location names is in the data directory
        /// at `root`: in its feed's folder for a feed item (FR11), and
        /// otherwise in its library folder, exactly where
        /// `TextMouthPaths.tmbPath(folderPath:tmbName:)` names it for the
        /// data directory in use. The one rule `Book.tmbDirectory` and every
        /// other user of a package's place follow.
        func packageDirectory(inDataDirectory root: URL) -> URL {
            if let feedLink {
                return FeedPaths.packageDirectory(named: tmbDirectoryName, of: feedLink.feedID, in: root)
            }
            let library = root.appendingPathComponent(TextMouthPaths.libraryFolderName, isDirectory: true)
            let folder = folderPath.isEmpty ? library : library.appendingPathComponent(folderPath, isDirectory: true)
            return folder.appendingPathComponent(tmbDirectoryName, isDirectory: true)
        }
    }

    /// This book's file location. Setting it changes exactly those fields,
    /// so a reader taking a moved row's location (`libraryFields`) finds the
    /// package wherever the library now places it, a feed's folder included.
    var fileLocation: FileLocation {
        get {
            FileLocation(folderPath: folderPath, filePath: filePath, tmbDirectoryName: tmbDirectoryName, feedLink: feedLink)
        }
        set {
            folderPath = newValue.folderPath
            filePath = newValue.filePath
            tmbDirectoryName = newValue.tmbDirectoryName
            feedLink = newValue.feedLink
        }
    }

    /// What a reader takes from the library's row of its book whenever the
    /// library changes that row while the reader has the book open (TODO
    /// P10): where the book's files are, its editable metadata, what content
    /// analysis measured, the encoding its text file is read in, with who
    /// decided it (encodingchoice), the braille file characters its BRF
    /// or BRL file is read in (braillecodes), and the braille table its
    /// braille is translated to print by, with the version of this Mac's
    /// tables it was read under (FMT21), so the reader's Book
    /// Information shows a new choice and any reading of the file the
    /// reader makes uses it.
    ///
    /// Everything else is the reader's own: its position and bookmarks, its
    /// voice, speed, pitch, navigation units, skipped sections, end-of-book
    /// behavior, and playback times, each of which it writes through to the
    /// library as it changes them. The library's own bookkeeping (when the
    /// book was added and last opened, its place in manual order) is nothing
    /// a reader shows or uses.
    struct LibraryFields: Equatable, Sendable {
        var location: FileLocation
        var metadata: EditableMetadata
        var analysis: ContentAnalysisFields
        var textEncoding: TextEncodingRecord
        var brailleFileCode: String?
        var brailleTable: String?
        var brailleTableVersion: String?
    }

    /// This book's library fields. Setting them changes exactly those
    /// fields, so a reader that takes them keeps all of its own state.
    var libraryFields: LibraryFields {
        get {
            LibraryFields(
                location: fileLocation,
                metadata: editableMetadata,
                analysis: contentAnalysisFields,
                textEncoding: textEncodingRecord,
                brailleFileCode: brailleFileCode,
                brailleTable: brailleTable,
                brailleTableVersion: brailleTableVersion
            )
        }
        set {
            fileLocation = newValue.location
            editableMetadata = newValue.metadata
            contentAnalysisFields = newValue.analysis
            textEncodingRecord = newValue.textEncoding
            brailleFileCode = newValue.brailleFileCode
            brailleTable = newValue.brailleTable
            brailleTableVersion = newValue.brailleTableVersion
        }
    }

    /// Overlay metadata kept by TextMouth onto values extracted from the EPUB.
    /// Optional fields distinguish an unedited legacy book from an intentional
    /// empty-string edit that clears publisher or publication date.
    func mergingEditableEPUBMetadata(_ extracted: EPUBMetadata) -> EPUBMetadata {
        var merged = extracted
        merged.title = title
        merged.author = author
        if let epubPublisher { merged.publisher = epubPublisher }
        if let epubPublicationDate { merged.publicationDate = epubPublicationDate }
        return merged
    }

    /// This EPUB's package metadata as the book's row keeps it, when the row
    /// keeps every field of it, as it does for each book imported since rows
    /// kept them: what the import read from the file, with the book's own
    /// edits. That is exactly what reading the file and laying those edits
    /// over it gives (`mergingEditableEPUBMetadata(_:)`), since the import
    /// copies the file as it read it, and writing an edit into the file
    /// (TODO A09) changes only the fields the row keeps the edit in.
    ///
    /// Nil for any other format, and for a row without one of the fields, as
    /// a book imported before rows kept them has: an unedited publisher or
    /// publication date, among others, is then known only to the file.
    var keptEPUBMetadata: EPUBMetadata? {
        guard format == .epub,
              epubPublisher != nil, epubPublicationDate != nil, epubISBN != nil,
              epubLanguage != nil, epubIdentifier != nil, epubVersion != nil else { return nil }
        // Every field is there, so none of the defaults for a missing one,
        // which Book Info shows for a book only in the cloud, applies.
        return storedEPUBMetadata
    }

    /// Overlay metadata kept by TextMouth onto values read from an audio
    /// file's tags: the title and author always, since they are the names
    /// the library gives the book, and the album, genre, and year once they
    /// have been edited. Nil means never edited, so the tag's value stands;
    /// an empty string is an edit that clears it.
    func mergingEditableAudioMetadata(_ extracted: AudioMetadata) -> AudioMetadata {
        var merged = extracted
        merged.title = title
        merged.artist = author
        if let audioAlbum { merged.album = audioAlbum }
        if let audioGenre { merged.genre = audioGenre }
        if let audioYear { merged.year = audioYear }
        return merged
    }

    /// Estimated time remaining in seconds, or nil if unknown.
    /// For audio books: uses actual duration adjusted by playback speed.
    /// For text books: uses WPM-based estimate with per-book override.
    func estimatedTimeRemaining(wpm: Double) -> TimeInterval? {
        if format.isAudio {
            guard let duration = audioDuration, duration.isFinite, duration > 0 else { return nil }
            // For audio, localWPM stores the multiplier. Normalize it exactly
            // as the reader and player do (clamped and snapped) before
            // division, including legacy zero-speed values.
            let speed = AudioSpeed.normalized(localWPM ?? AudioSpeed.normal)
            let adjustedDuration = duration / speed
            guard let pos = readingPosition else { return adjustedDuration }
            let globalOffset = pos.globalCharacterOffset ?? pos.characterOffset
            guard let totalChars = totalCharacterCount, totalChars > 0 else { return adjustedDuration }
            return ReadingTimeEstimator.remaining(
                totalDuration: adjustedDuration,
                globalOffset: globalOffset,
                totalCharacterCount: totalChars
            )
        }

        let effectiveSpeed = effectiveWPM(fallback: wpm)
        guard let totalWords = totalWordCount, let totalChars = totalCharacterCount,
              totalChars > 0, effectiveSpeed > 0 else { return nil }
        let totalTime = Double(totalWords) / effectiveSpeed * 60.0
        guard let pos = readingPosition else { return totalTime }
        let globalOffset = pos.globalCharacterOffset ?? pos.characterOffset
        return ReadingTimeEstimator.remaining(
            totalDuration: totalTime,
            globalOffset: globalOffset,
            totalCharacterCount: totalChars
        )
    }

    /// Percent of the book already read (0–100), or nil when the book has no
    /// saved position or has not been measured yet. Library rows hold only
    /// this model, never parsed content, so they report overall progress
    /// instead of a heading. The cursor and total match
    /// `estimatedTimeRemaining(wpm:)`, so a row's percent and time left agree.
    var percentComplete: Double? {
        guard let position = readingPosition,
              let totalChars = totalCharacterCount, totalChars > 0 else { return nil }
        let globalOffset = position.globalCharacterOffset ?? position.characterOffset
        let clampedOffset = min(max(globalOffset, 0), totalChars)
        return Double(clampedOffset) / Double(totalChars) * 100
    }

    /// Whether the book rests at its end, finished (TODO P07): its saved
    /// place is at or past the end of its text, where a book that played or
    /// was read to its end is saved (`ReaderViewModel.restAtEnd()`), its
    /// last chapter at its full length. The user decided on October 10,
    /// 2026 that such a book is saved exactly at its end and stays finished
    /// after TextMouth quits, which needs no field of its own: the place
    /// says it, so older files and older TextMouth builds read it as an
    /// ordinary place. A place short of the end, however near, is not the
    /// end: speech or a player saved there stopped before the book did.
    ///
    /// The cursor and the total are the ones `percentComplete` reads, so a
    /// book resting at its end reads 100 percent there too. False for a
    /// book with no saved place, or not measured yet.
    var restsAtEnd: Bool {
        guard let position = readingPosition, let totalChars = totalCharacterCount else { return false }
        // The one rule for the end of a book (`TextPlace.restsAtEnd`), which
        // the place relocator follows too.
        return TextPlace.restsAtEnd(globalOffset: position.globalCharacterOffset ?? position.characterOffset, bookLength: totalChars)
    }

    /// Save this book's data to its bookInfo.json
    func saveBookInfo() {
        try? saveBookInfoThrowing()
    }

    /// Throwing variant used by filesystem transactions that must roll back if
    /// metadata cannot be committed alongside a package move. Writes over the
    /// record now in the package as `bookInfo(replacing:contentIndex:revisionFloor:)`
    /// describes, reading bookInfo.json alone: the package keeps its content
    /// index file unless `contentIndex` replaces it (PERF15).
    func saveBookInfoThrowing(contentIndex: BookContentIndex? = nil) throws {
        try saveBookInfoThrowing(contentIndex: contentIndex, inPackageAt: tmbDirectory)
    }

    /// Writes this book's record over the record in the package at `tmbDir`,
    /// exactly as `saveBookInfoThrowing(contentIndex:)` writes over the one
    /// in the book's own package: for a copy of that package, as a
    /// data-directory move writes each staged copy's record
    /// (`DataDirectoryMigrator`). The record it replaces is read without its
    /// content index (`StoredBookRecord`), or is nil when there is none or
    /// it cannot be read, and the package keeps its content index file as
    /// it is unless `contentIndex` replaces it.
    func saveBookInfoThrowing(contentIndex: BookContentIndex? = nil, inPackageAt tmbDir: URL) throws {
        let stored = try? StoredBookRecord.read(from: tmbDir)
        try bookInfo(replacing: stored, contentIndex: contentIndex).saveRecord(to: tmbDir)
    }

    /// The record now in this book's package, with its content index, or
    /// nil when there is none or it cannot be read.
    func storedBookInfo() -> BookInfo? {
        try? BookInfo.load(from: tmbDirectory)
    }

    /// The encoding to read a text book's file in, and who decided it
    /// (FMT16, encodingchoice): the one that stands between the row's
    /// (`textEncodingRecord`) and the one the package's record keeps
    /// (`BookMetadata.textEncodingRecord`), as every save of the record
    /// keeps it (`TextEncodingRecord.standing(row:recorded:)`). The record's
    /// decision comes first, so a rebuild reads the text in the encoding
    /// its record will label it with, though the row lags behind a re-read
    /// (review of October 25, item 3); then the row's; then the record's,
    /// for a row that lost both. A value in library.json that cannot be read
    /// decodes as none, and so does a row an older build wrote, while
    /// bookInfo.json keeps the encoding through every save of the book;
    /// reading it here keeps a rebuild from reading the book as Windows-1252
    /// for want of a row. The record counts for nothing when it names
    /// another book, cannot be read, or is in the cloud (which is not
    /// downloaded for this), and is not read for a format that does not
    /// read text files, nor for a book without a package. Every reading of
    /// the book's file goes by its policy (`TextEncodingRecord.policy`).
    func recordedTextEncodingRecord() -> TextEncodingRecord {
        guard format.usesTextFileDecoder else { return textEncodingRecord }
        let recorded = ownStoredMetadata()?.textEncodingRecord ?? .unrecorded
        return .standing(row: textEncodingRecord, recorded: recorded)
    }

    /// The braille file characters to read a braille book's file in
    /// (braillecodes), by the code's id: the one that stands between the
    /// row's (`brailleFileCode`) and the one the package's record keeps
    /// (`BookMetadata.brailleFileCode`), as every save of the record keeps
    /// it (`BrailleFileCodeRecord.standing(row:recorded:)`). The record's
    /// code comes first, so a rebuild reads the file in the characters its
    /// record will label the new text with, though the row lags behind a
    /// re-read in other braille file characters; then the row's, nil
    /// included, which a later reading takes for North American Braille
    /// ASCII. A value in library.json that cannot be read decodes as none,
    /// and so does a row an older build wrote, while bookInfo.json keeps the
    /// code through every save of the book. The record counts for nothing
    /// when it names another book, cannot be read, or is in the cloud (which
    /// is not downloaded for this), and is not read for a book of another
    /// format, which returns its row's code, nor for a book without a
    /// package.
    func recordedBrailleFileCode() -> String? {
        guard format == .braille else { return brailleFileCode }
        return BrailleFileCodeRecord.standing(row: brailleFileCode, recorded: ownStoredMetadata()?.brailleFileCode)
    }

    /// The metadata of the record now in this book's package when that
    /// record is this book's own (its `bookID` is this row's `id`), read
    /// without downloading anything: what `recordedTextEncodingRecord()`
    /// and `recordedBrailleFileCode()` weigh against the row. Nil for a book
    /// without a package, and when the package holds no record, one that
    /// cannot be read, one only in the cloud, or another book's, as an old
    /// shared package's may: such a record must never give this row that
    /// book's encoding or braille file code, which every later reading of
    /// this book would then use.
    private func ownStoredMetadata() -> BookMetadata? {
        guard !tmbDirectoryName.isEmpty else { return nil }
        let stored = try? DatalessFiles.withoutDownloading { try StoredBookRecord.read(from: tmbDirectory) }
        // The record counts only when it is this book's.
        guard let metadata = stored?.info.metadata, metadata.bookID == id else { return nil }
        return metadata
    }

    /// The record this book writes over `stored`, the record now in its
    /// package (nil when there is none or it cannot be read).
    ///
    /// The content index and the analysis fields measured with it
    /// (`ContentAnalysisFields`) travel together. A write that carries
    /// `contentIndex` records it with this book's analysis fields, which
    /// describe it. A write without one, such as a position, bookmark, or
    /// metadata save, keeps the stored index together with the stored
    /// fields: a library row can lag behind an analysis committed moments
    /// earlier, and its older counts and versions must neither erase that
    /// analysis nor be recorded beside an index they do not describe. Only
    /// when no index is stored does such a write record its own fields.
    ///
    /// The result carries an index only when the write must put one in the
    /// package's contentIndex.json (`BookInfo.saveRecord(to:)`): `contentIndex`,
    /// or an index an older version kept inside the stored bookInfo.json,
    /// which this write moves into its own file. An index already in its own
    /// file is kept by writing nothing to it.
    ///
    /// The record's note of the book's transcript (`BookState.transcript`,
    /// FR05) belongs to the package alone: a library row never carries one.
    /// It follows the index it describes: a write carrying an index notes
    /// that index's transcript text, or none, and any other write keeps the
    /// note the stored record holds, as it keeps the stored index.
    ///
    /// The feed item a downloaded episode or article came from
    /// (`BookMetadata.feedLink`, FR03) is the row's when the row names one
    /// (FR11), and otherwise the one the stored record holds, so a row that
    /// never carried a link, or whose link was cleared, never erases it.
    ///
    /// A braille book's table (`BookMetadata.brailleTable`, FMT21) is kept
    /// the same way: the stored record's survives a row that lost it; and so
    /// is the Mac's liblouis version it was read with (review R2).
    ///
    /// A braille book's file code (`BookMetadata.brailleFileCode`,
    /// braillecodes) is the stored record's when it names one, and otherwise
    /// the row's (`BrailleFileCodeRecord.standing(row:recorded:)`): a re-read
    /// in other braille file characters writes its code into the record
    /// with the new text before the library row takes it, so only a write
    /// `decidingBrailleFileCode` (the next re-read's) replaces it, and a row
    /// that lags behind, with or without an index, never writes the old code
    /// back beside the new text.
    ///
    /// The encoding a text book's file is read in (`BookMetadata.textEncoding`,
    /// FMT16) and who decided it (`BookMetadata.textEncodingSource`,
    /// encodingchoice) are taken as one. A decision the stored record holds
    /// is a re-read's, which writes it with the new text before the library
    /// row takes it, so only a write `decidingTextEncoding` (the next
    /// re-read's) replaces it: a row that lags behind the re-read, as a
    /// reading checkpoint's can, with or without an index, never writes the
    /// old encoding back beside the new text (review of October 24,
    /// finding 5). Over a record that names no decision, a row that holds
    /// either writes its own, its nil encoding included; only a row that
    /// holds neither takes the stored record's. The rule is one
    /// (`TextEncodingRecord.standing(row:recorded:)`), which a recovered
    /// analysis and every reading of the book's file follow too.
    ///
    /// The revision is one more than the stored record's, or one more than
    /// `revisionFloor` when that is higher. The metadata queue passes the
    /// highest revision it has written for this book, so its revisions keep
    /// rising even when the stored record has lost its own.
    /// - Parameters:
    ///   - decidingTextEncoding: Whether the write records a new decision
    ///     about the encoding, this book's own: a re-read in another
    ///     encoding (`LibraryPersistenceService.saveContentAnalysis`'s
    ///     `textEncoding`).
    ///   - decidingBrailleFileCode: Whether the write records a new braille
    ///     file code, this book's own: a re-read in other braille file
    ///     characters (`LibraryPersistenceService.saveContentAnalysis`'s
    ///     `brailleFileCode`).
    func bookInfo(
        replacing stored: StoredBookRecord?,
        contentIndex: BookContentIndex?,
        revisionFloor: Int = 0,
        decidingTextEncoding: Bool = false,
        decidingBrailleFileCode: Bool = false
    ) -> BookInfo {
        var recorded = self
        var index = contentIndex
        if index == nil, let stored, stored.keepsContentIndex {
            index = stored.info.contentIndex
            recorded.contentAnalysisFields = stored.info.state.contentAnalysisFields
        }
        var info = recorded.makeBookInfo()
        info.contentIndex = index
        if let contentIndex {
            info.state.transcript = contentIndex.transcript?.transcript
        } else {
            info.state.transcript = stored?.info.state.transcript
        }
        info.state.revision = BookState.revision(after: max(stored?.info.state.revision ?? 0, revisionFloor))
        // The feed item: the row's, or else the stored record's (FR03, FR11).
        info.metadata.feedLink = feedLink ?? stored?.info.metadata.feedLink
        // The braille table: the row's, or else the stored record's (FMT21).
        // Its version is the row's, or else the stored record's only when
        // that describes the same table: a book read again from one of this
        // Mac's tables to a bundled one has no version, and keeps none of
        // the Mac table's.
        let storedTable = stored?.info.metadata.brailleTable
        info.metadata.brailleTable = brailleTable ?? storedTable
        info.metadata.brailleTableVersion = brailleTableVersion
            ?? (info.metadata.brailleTable == storedTable ? stored?.info.metadata.brailleTableVersion : nil)
        // The braille file code (braillecodes): this write's own when it
        // decides anew, and otherwise the one that stands between the row
        // and the stored record, the record's whenever it names one.
        info.metadata.brailleFileCode = decidingBrailleFileCode && brailleFileCode != nil
            ? brailleFileCode
            : BrailleFileCodeRecord.standing(row: brailleFileCode, recorded: stored?.info.metadata.brailleFileCode)
        // The text encoding and who decided it, as one (FMT16, encodingchoice):
        // this write's own when it decides anew, and otherwise the one that
        // stands between the row and the stored record.
        let storedEncoding = stored?.info.metadata.textEncodingRecord ?? .unrecorded
        info.metadata.textEncodingRecord = decidingTextEncoding && !textEncodingRecord.isEmpty
            ? textEncodingRecord
            : TextEncodingRecord.standing(row: textEncodingRecord, recorded: storedEncoding)
        return info
    }

    /// This book's metadata, state, and bookmarks as bookInfo.json records
    /// them, its feed link included, without a content index or revision:
    /// those depend on the record being replaced
    /// (`bookInfo(replacing:contentIndex:revisionFloor:)`).
    func makeBookInfo() -> BookInfo {
        var info = BookInfo(
            metadata: BookMetadata(
                title: title,
                author: author,
                format: format,
                md5Hash: md5Hash,
                dateAdded: dateAdded,
                lastOpened: lastOpened,
                originalFileName: bookFileURL.lastPathComponent,
                folderPath: folderPath,
                bookID: id,
                sourceFilePath: sourceFilePath,
                publisher: epubPublisher,
                publicationDate: epubPublicationDate,
                isbn: epubISBN,
                language: epubLanguage,
                epubIdentifier: epubIdentifier,
                epubVersion: epubVersion,
                audioAlbum: audioAlbum,
                audioGenre: audioGenre,
                audioYear: audioYear,
                metadataReaderVersion: metadataReaderVersion,
                handEdits: handEdits
            ),
            state: BookState(
                readingPosition: readingPosition,
                totalWordCount: totalWordCount,
                totalCharacterCount: totalCharacterCount,
                isNew: isUnopened,
                tmbDirectoryName: tmbDirectoryName,
                lastPlaybackStarted: lastPlaybackStarted,
                lastPlaybackStopped: lastPlaybackStopped,
                localVoiceID: localVoiceID,
                localWPM: localWPM,
                localPitch: localPitch,
                skippedHeadingIDs: skippedHeadingIDs,
                skippedHeadings: skippedHeadings,
                waitingSkippedHeadings: waitingSkippedHeadings,
                localEndOfBookBehavior: localEndOfBookBehavior,
                localSkipForwardUnit: localSkipForwardUnit,
                localSkipBackwardUnit: localSkipBackwardUnit,
                manualSortOrder: manualSortOrder,
                audioDuration: audioDuration,
                cacheFormatVersion: cacheFormatVersion,
                contentIndexVersion: contentIndexVersion,
                textCacheFingerprint: textCacheFingerprint,
                editedText: editedText,
                pageReaderVersion: pageReaderVersion
            ),
            bookmarks: bookmarks
        )
        info.metadata.feedLink = feedLink
        info.metadata.brailleTable = brailleTable
        info.metadata.brailleTableVersion = brailleTableVersion
        info.metadata.brailleFileCode = brailleFileCode
        info.metadata.textEncodingRecord = textEncodingRecord
        return info
    }

    /// The book a package record describes, the inverse of `makeBookInfo()`.
    /// Every field bookInfo.json keeps comes from `record`, the feed link
    /// included. The file path, folder, and package name come from where
    /// the caller found the package, because a record cannot vouch for
    /// where its package is now; a caller that found the package in the
    /// Library folder clears the link, since a package there is a book of
    /// the library's own (`placedInLibraryFolder()`, FR11).
    init(record: BookInfo, filePath: String, folderPath: String, tmbDirectoryName: String) {
        let metadata = record.metadata
        let state = record.state
        self.init(
            id: metadata.bookID,
            title: metadata.title,
            author: metadata.author,
            format: metadata.format,
            filePath: filePath,
            md5Hash: metadata.md5Hash,
            folderPath: folderPath,
            dateAdded: metadata.dateAdded,
            lastOpened: metadata.lastOpened,
            readingPosition: state.readingPosition,
            bookmarks: record.bookmarks,
            totalWordCount: state.totalWordCount,
            totalCharacterCount: state.totalCharacterCount,
            tmbDirectoryName: tmbDirectoryName,
            sourceFilePath: metadata.sourceFilePath,
            lastPlaybackStarted: state.lastPlaybackStarted,
            lastPlaybackStopped: state.lastPlaybackStopped,
            localVoiceID: state.localVoiceID,
            localWPM: state.localWPM,
            localPitch: state.localPitch,
            skippedHeadingIDs: state.skippedHeadingIDs,
            skippedHeadings: state.skippedHeadings,
            waitingSkippedHeadings: state.waitingSkippedHeadings,
            localEndOfBookBehavior: state.localEndOfBookBehavior,
            localSkipForwardUnit: state.localSkipForwardUnit,
            localSkipBackwardUnit: state.localSkipBackwardUnit,
            manualSortOrder: state.manualSortOrder,
            audioDuration: state.audioDuration,
            audioAlbum: metadata.audioAlbum,
            audioGenre: metadata.audioGenre,
            audioYear: metadata.audioYear,
            epubPublisher: metadata.publisher,
            epubPublicationDate: metadata.publicationDate,
            epubISBN: metadata.isbn,
            epubLanguage: metadata.language,
            epubIdentifier: metadata.epubIdentifier,
            epubVersion: metadata.epubVersion,
            cacheFormatVersion: state.cacheFormatVersion,
            contentIndexVersion: state.contentIndexVersion,
            textCacheFingerprint: state.textCacheFingerprint,
            editedText: state.editedText,
            pageReaderVersion: state.pageReaderVersion,
            metadataReaderVersion: metadata.metadataReaderVersion,
            handEdits: metadata.handEdits,
            feedLink: metadata.feedLink,
            brailleTable: metadata.brailleTable,
            brailleTableVersion: metadata.brailleTableVersion,
            brailleFileCode: metadata.brailleFileCode,
            textEncoding: metadata.textEncoding,
            textEncodingSource: metadata.textEncodingSource
        )
    }

    /// This book as a row of the library's own, for a package found in the
    /// Library folder (FR11): the same book without a feed link, whatever
    /// its record says, since only a package in its feed's folder is a feed
    /// item's. Its record keeps the link (`bookInfo(replacing:...)`), which
    /// says the book came from a feed.
    func placedInLibraryFolder() -> Book {
        var book = self
        book.feedLink = nil
        return book
    }
}

// MARK: - Hand Edits

extension Book {
    /// A field of a book's metadata the user can edit by hand: in the
    /// library's Book Info sheet (the title and author), the EPUB metadata
    /// editor (the title, author, publisher, and publication date), or the
    /// audio metadata editor (the title, the author as the artist, and the
    /// album, genre, and year). Named by its raw value in a row's and a
    /// record's `HandEdits`.
    enum MetadataField: String, Codable, CaseIterable, Sendable {
        case title
        case author
        case publisher
        case publicationDate
        case audioAlbum
        case audioGenre
        case audioYear

        /// The fields the launch metadata refresh may replace with what a
        /// book's file names (`LibraryViewModel.refreshedValues(of:from:)`):
        /// the ones every import reads. An audiobook's album, genre, and
        /// year are read once, at its import.
        static let refreshable: [MetadataField] = [.title, .author, .publisher, .publicationDate]

        /// `fields` in the order of `allCases`, the order the editors show
        /// them in, each once: the one list a set of fields is written as.
        static func ordered(_ fields: Set<MetadataField>) -> [MetadataField] {
            allCases.filter(fields.contains)
        }

        /// This field's value in `metadata`, or nil where the book keeps
        /// none: an EPUB keeps no album, and a row imported before rows
        /// kept an EPUB's publisher and publication date has neither until
        /// an editor saves them.
        func value(in metadata: EditableMetadata) -> String? {
            switch self {
            case .title: return metadata.title
            case .author: return metadata.author
            case .publisher: return metadata.epubPublisher
            case .publicationDate: return metadata.epubPublicationDate
            case .audioAlbum: return metadata.audioAlbum
            case .audioGenre: return metadata.audioGenre
            case .audioYear: return metadata.audioYear
            }
        }

        /// Sets this field of `book` to `value`.
        func set(_ value: String, in book: inout Book) {
            switch self {
            case .title: book.title = value
            case .author: book.author = value
            case .publisher: book.epubPublisher = value
            case .publicationDate: book.epubPublicationDate = value
            case .audioAlbum: book.audioAlbum = value
            case .audioGenre: book.audioGenre = value
            case .audioYear: book.audioYear = value
            }
        }

        /// The values of the fields `metadata` keeps, by field; a field it
        /// keeps none of is absent.
        static func values(in metadata: EditableMetadata) -> MetadataValues {
            var values: MetadataValues = [:]
            for field in allCases {
                values[field] = field.value(in: metadata)
            }
            return values
        }

        /// The values of the fields the EPUB editor changes, as `metadata`
        /// has them: what the editor opened with, or what it saved.
        static func values(in metadata: EPUBMetadata) -> MetadataValues {
            [
                .title: metadata.title,
                .author: metadata.author,
                .publisher: metadata.publisher,
                .publicationDate: metadata.publicationDate
            ]
        }

        /// The values of the fields the audio editor changes, as `metadata`
        /// has them, its artist as the author: what the editor opened with,
        /// or what it saved.
        static func values(in metadata: AudioMetadata) -> MetadataValues {
            [
                .title: metadata.title,
                .author: metadata.artist,
                .audioAlbum: metadata.album,
                .audioGenre: metadata.genre,
                .audioYear: metadata.year
            ]
        }
    }

    /// The values of some metadata fields, by field: what an editor opened
    /// with or saved, or what a book's file names. A field without a value
    /// is absent.
    typealias MetadataValues = [MetadataField: String]

    /// One save of a metadata editor (the Book Info sheet, or the EPUB or
    /// the audio editor): the values of the fields the editor shows, as it
    /// opened with them and as the user saved them.
    ///
    /// The fields the user changed are told from what the editor opened
    /// with, never from the book's row: the row may have changed while the
    /// editor was open (another window's save, the launch metadata
    /// refresh), and an editor shows the file's value for a field the row
    /// keeps none of. A save applies the changes alone to the row as it is
    /// by then (`Book.applyMetadataEdit(_:)`), so every other field keeps
    /// whatever value the row has.
    struct MetadataEdit: Equatable, Sendable {
        /// The values the editor opened with.
        var opened: MetadataValues
        /// The values the user saved.
        var saved: MetadataValues

        /// The edit of an editor that opened with `opened` and saved
        /// `saved`.
        init(opened: MetadataValues, saved: MetadataValues) {
            self.opened = opened
            self.saved = saved
        }

        /// The EPUB editor's edit: its title, author, publisher, and
        /// publication date, as it opened with them and as they were saved.
        init(opened: EPUBMetadata, saved: EPUBMetadata) {
            self.init(opened: MetadataField.values(in: opened), saved: MetadataField.values(in: saved))
        }

        /// The audio editor's edit: its title, artist as the author, album,
        /// genre, and year, as it opened with them and as they were saved.
        init(opened: AudioMetadata, saved: AudioMetadata) {
            self.init(opened: MetadataField.values(in: opened), saved: MetadataField.values(in: saved))
        }

        /// The fields the user changed, each with the value saved: every
        /// field saved with a value other than the one the editor opened
        /// with. A field saved as it opened is no change, nor is a field
        /// the save has no value for.
        ///
        /// An editor shows a field it has no value for, one nothing knew,
        /// as empty, so a field it opened without counts as opened empty:
        /// saved empty, it is no change and stays unknown (nil) on the row,
        /// so the book's file still gives its value later, as it does for
        /// a cloud-only book's EPUB publisher and date or an audiobook's
        /// album, genre, and year. Only a value typed into it is saved.
        ///
        /// A title of nothing but blanks is never a change: a book keeps
        /// the name it has, and a book with none is not given spaces, nor
        /// has its blank swapped for another (`clearsTitle(opened:edited:)`),
        /// whichever editor asks, so that the refusal an editor makes is not
        /// the only thing between a save and a book with no name.
        ///
        /// Every value is saved without the blanks around it, whichever
        /// editor typed it, so a field of nothing but blanks over an empty
        /// one is no change, and "Press " is saved as "Press". A field is
        /// a change only when what was typed differs from what the editor
        /// opened with, and so does the trimmed value: a value the editor
        /// opened with and the user left alone is never rewritten, even
        /// when it keeps blanks an earlier version saved.
        var changes: MetadataValues {
            var changed: MetadataValues = [:]
            for (field, typed) in saved {
                if field == .title, Self.isBlank(typed) { continue }
                let before = opened[field] ?? ""
                let value = Self.trimmed(typed)
                if typed != before, value != before { changed[field] = value }
            }
            return changed
        }

        /// `text` without the blanks and line breaks around it.
        private static func trimmed(_ text: String) -> String {
            text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// Whether `title` holds nothing but blanks, or nothing.
        private static func isBlank(_ title: String) -> Bool {
            trimmed(title).isEmpty
        }

        /// Whether saving `edited` as a title would leave the book without
        /// one: the editor opened with a title, and the edit holds nothing
        /// but blanks. A book that had no title to begin with may be saved
        /// without one, so a change to another field is never held back.
        static func clearsTitle(opened: String, edited: String) -> Bool {
            !isBlank(opened) && isBlank(edited)
        }
    }

    /// Which of a book's metadata fields the user edited by hand, and since
    /// when the record has been kept. Every editor's save adds the fields
    /// it changed (`Book.markEditedByHand(_:)`); nothing ever removes one,
    /// so a field edited back to an earlier value stays the user's own.
    struct HandEdits: Codable, Hashable, Sendable {
        /// The fields edited by hand, in `MetadataField.allCases` order and
        /// each once (`MetadataField.ordered(_:)`), so one record is always
        /// written as the same bytes.
        private(set) var fields: [MetadataField]
        /// Whether the record has been kept since the book was imported, so
        /// that every hand edit of the book is in `fields`. False for a
        /// book imported before edits were recorded (October 7, 2026),
        /// whose record began with its first edit since: its other fields
        /// may hold older edits nothing recorded, so the launch metadata
        /// refresh treats them as it treats a row without a record.
        var sinceImport: Bool

        /// The record of `fields`, kept since the import when `sinceImport`.
        init(fields: Set<MetadataField> = [], sinceImport: Bool) {
            self.fields = MetadataField.ordered(fields)
            self.sinceImport = sinceImport
        }

        /// The record of a book nothing has edited by hand since it was
        /// imported: what an import gives a new book.
        static let noneSinceImport = HandEdits(sinceImport: true)

        /// Decodes a record, keeping the fields this version knows: a name
        /// a newer version of TextMouth wrote for a field this one cannot
        /// edit is left out rather than failing the row, and a record
        /// without `sinceImport` counts as begun by an edit.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let names = try container.decodeIfPresent([String].self, forKey: .fields) ?? []
            fields = MetadataField.ordered(Set(names.compactMap(MetadataField.init(rawValue:))))
            sinceImport = try container.decodeIfPresent(Bool.self, forKey: .sinceImport) ?? false
        }

        /// Whether `field` was edited by hand.
        func contains(_ field: MetadataField) -> Bool {
            fields.contains(field)
        }

        /// Adds `edited` to the fields edited by hand.
        mutating func mark(_ edited: Set<MetadataField>) {
            fields = MetadataField.ordered(Set(fields).union(edited))
        }
    }

    /// Records `fields` as edited by hand: added to this book's record, or,
    /// for a book without one, begun as a record kept from this edit on
    /// (`HandEdits.sinceImport` false). Marking no field changes nothing,
    /// so a save that changes nothing leaves a row as it was.
    mutating func markEditedByHand(_ fields: Set<MetadataField>) {
        guard !fields.isEmpty else { return }
        var record = handEdits ?? HandEdits(sinceImport: false)
        record.mark(fields)
        handEdits = record
    }

    /// Applies `edit`, one save of a metadata editor, to this book: each
    /// field the user changed (`MetadataEdit.changes`) takes the value
    /// saved and is recorded as edited by hand; every other field keeps the
    /// value this book has, which may be newer than the one the editor
    /// opened with. An edit that changed nothing leaves the book as it was.
    mutating func applyMetadataEdit(_ edit: MetadataEdit) {
        let changes = edit.changes
        for (field, value) in changes {
            field.set(value, in: &self)
        }
        markEditedByHand(Set(changes.keys))
    }
}

struct ReadingPosition: Codable, Hashable {
    var chapterIndex: Int
    var headingIndex: Int?
    var characterOffset: Int
    /// Global character offset across all chapters (for library time estimation)
    var globalCharacterOffset: Int?
    var lastUpdated: Date
    /// The text around this place when it was saved (T06), by which it is
    /// found again when the book's text is read anew (`TextAnchorFinder`);
    /// nil for a place saved before anchors, or by a build without them.
    var anchor: TextAnchor?

    init(chapterIndex: Int = 0, headingIndex: Int? = nil, characterOffset: Int = 0, globalCharacterOffset: Int? = nil, anchor: TextAnchor? = nil) {
        self.chapterIndex = chapterIndex
        self.headingIndex = headingIndex
        self.characterOffset = characterOffset
        self.globalCharacterOffset = globalCharacterOffset
        self.lastUpdated = Date()
        self.anchor = anchor
    }

    /// Decodes a saved position, repairing indices and offsets no position
    /// can have (negative, or too large for an `Int`) instead of failing the
    /// book and, with it, the whole library. The reader still clamps the
    /// result against the loaded content. An anchor that cannot be read
    /// counts as none: the place keeps its numbers.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fields = LenientFields(container, source: SettingsPolicy.bookStateSource)
        chapterIndex = fields.position(.chapterIndex)
        headingIndex = fields.optionalPosition(.headingIndex)
        characterOffset = fields.position(.characterOffset)
        globalCharacterOffset = fields.optionalPosition(.globalCharacterOffset)
        lastUpdated = try container.decode(Date.self, forKey: .lastUpdated)
        anchor = fields.optionalValue(.anchor) { $0 }
    }
}

struct Bookmark: Identifiable, Codable, Hashable {
    let id: UUID
    var number: Int
    var chapterIndex: Int
    var characterOffset: Int
    var label: String
    var dateCreated: Date
    /// The text around the bookmark's place when it was made (T06), by
    /// which the place is found again when the book's text is read anew
    /// (`TextAnchorFinder`); nil for a bookmark made before anchors, or by a
    /// build without them.
    var anchor: TextAnchor?

    init(
        id: UUID = UUID(),
        number: Int,
        chapterIndex: Int,
        characterOffset: Int,
        label: String = "",
        dateCreated: Date = Date(),
        anchor: TextAnchor? = nil
    ) {
        self.id = id
        self.number = number
        self.chapterIndex = chapterIndex
        self.characterOffset = characterOffset
        self.label = label
        self.dateCreated = dateCreated
        self.anchor = anchor
    }

    /// Decodes a saved bookmark, repairing a location no bookmark can have
    /// (negative, or too large for an `Int`) instead of failing the book. An
    /// anchor that cannot be read counts as none: the bookmark keeps its
    /// numbers.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fields = LenientFields(container, source: SettingsPolicy.bookStateSource)
        id = try container.decode(UUID.self, forKey: .id)
        number = try container.decode(Int.self, forKey: .number)
        chapterIndex = fields.position(.chapterIndex)
        characterOffset = fields.position(.characterOffset)
        label = try container.decode(String.self, forKey: .label)
        dateCreated = try container.decode(Date.self, forKey: .dateCreated)
        anchor = fields.optionalValue(.anchor) { $0 }
    }

    /// Concise label shared by bookmark rows and the bookmarks rotor, such as
    /// "Bookmark 3, The Battle, Note: Check this, added October 9, 2026".
    /// `headingText` names the heading containing the bookmark. When it is
    /// unknown (content not loaded, or no heading at that point) the
    /// location is simply omitted: internal content-unit numbers are never
    /// shown in its place. The date is the one the row shows (`dateText`),
    /// which VoiceOver did not hear until TODO A10.
    func accessibilityLabel(headingText: String?) -> String {
        var parts = ["Bookmark \(number)"]
        if let headingText = headingText?.nonBlank {
            parts.append(headingText)
        }
        if !label.isEmpty { parts.append("Note: \(label)") }
        parts.append("added \(dateText)")
        return parts.joined(separator: ", ")
    }

    /// The day the bookmark was added, as its row shows it and its label
    /// speaks it: the long date of the user's locale, "October 9, 2026".
    var dateText: String {
        dateCreated.formatted(date: .long, time: .omitted)
    }
}

/// A heading the listener skips (T06): its level, its label, and where it
/// starts, with the text at its start, so the skip can follow its heading
/// when the book's text is read anew (`PlaceRelocator.relocate(_:)`).
///
/// A skip has been a heading ID (`Heading.id`,
/// "<chapter>-<offset>-<level>-<label>"), which changes whenever the text
/// before the heading or its label changes, and then names no heading, so
/// the section plays again: 456 of 735 skipped headings in the real
/// extraction changes measured (TEXT-ANCHORS-ADDENDUM-2026-10-10.md,
/// section 5). A book keeps both, in step (`Book.skippedHeadings`,
/// `Book.skippedHeadingIDs`): the IDs for older builds, which know nothing
/// else.
struct SkippedHeading: Codable, Hashable, Sendable {
    /// The heading's level, 1 to 6.
    var level: Int
    /// The heading's label, as the Headings sheet shows it.
    var label: String
    /// The chapter the heading starts in.
    var chapterIndex: Int
    /// Where the heading starts in its chapter's reading text, in UTF-16
    /// units.
    var characterOffset: Int
    /// The text at the heading's start when it was skipped; nil for a skip
    /// made before anchors.
    var anchor: TextAnchor?

    init(level: Int, label: String, chapterIndex: Int, characterOffset: Int, anchor: TextAnchor? = nil) {
        self.level = level
        self.label = label
        self.chapterIndex = chapterIndex
        self.characterOffset = characterOffset
        self.anchor = anchor
    }

    /// The skip of `heading`, with the text at its start.
    init(_ heading: Heading, anchor: TextAnchor? = nil) {
        self.init(
            level: heading.level,
            label: heading.text,
            chapterIndex: heading.chapterIndex,
            characterOffset: heading.characterOffset,
            anchor: anchor
        )
    }

    /// The skip a heading ID names, read from the ID's form,
    /// "<chapter>-<offset>-<level>-<label>" (a label may hold hyphens of its
    /// own); nil for an ID not exactly in that form, as a hand-edited or
    /// damaged one may be, which names no heading TextMouth makes.
    init?(id: String) {
        let parts = id.split(separator: "-", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count == 4,
              let chapterIndex = Int(parts[0]),
              let characterOffset = Int(parts[1]),
              let level = Int(parts[2])
        else { return nil }
        self.init(level: level, label: String(parts[3]), chapterIndex: chapterIndex, characterOffset: characterOffset)
        // Only an ID this skip writes back the same is in today's form
        // ("07-…" or "+7-…" would read as chapter 7 but is no heading's ID).
        guard self.id == id else { return nil }
    }

    /// The heading ID this skip has (`Heading.id`), which the reader and
    /// older builds match against the book's headings.
    var id: String {
        Heading(level: level, text: label, chapterIndex: chapterIndex, characterOffset: characterOffset).id
    }

    /// The skipped headings `ids` names, in their order and in step with
    /// them: each one of `kept` whose ID is among them, with its anchor, and
    /// each other read from its ID; an ID not in today's form is left out.
    /// Nil when none is left, as for no IDs.
    static func inStep(with ids: [String]?, keeping kept: [SkippedHeading]?) -> [SkippedHeading]? {
        guard let ids, !ids.isEmpty else { return nil }
        var keptByID: [String: SkippedHeading] = [:]
        for heading in kept ?? [] where keptByID[heading.id] == nil {
            keptByID[heading.id] = heading
        }
        let headings = ids.compactMap { keptByID[$0] ?? SkippedHeading(id: $0) }
        return stored(headings)
    }

    /// `headings` as a book keeps a list of skips: nil when there are
    /// none, never an empty list.
    static func stored(_ headings: [SkippedHeading]?) -> [SkippedHeading]? {
        headings.flatMap { $0.isEmpty ? nil : $0 }
    }
}

// MARK: - Saving Skipped Headings (T06)

extension Book {
    /// Saves `headings` as the headings this book skips during playback,
    /// each with the text at its start (T06's branch B): what the reader
    /// saves when a skip is toggled. `skippedHeadingIDs` is written from
    /// them, for the reader's filter and for older builds, which read the
    /// IDs alone. None, or nil, skips nothing and writes neither.
    mutating func setSkippedHeadings(_ headings: [SkippedHeading]?) {
        let skipped = SkippedHeading.stored(headings)
        // The IDs first: their observer puts the skipped headings in step
        // with them, keeping old anchors, and the headings saved then
        // replace those with their own.
        skippedHeadingIDs = skipped?.map(\.id)
        skippedHeadings = skipped
    }

    /// How many of this book's saved places keep no words yet (T06): its
    /// reading position, its bookmarks, and its skipped headings without
    /// anchors. An audiobook's places count time in its recording and need
    /// none (P08), so it has none.
    var placesWithoutAnchors: Int {
        guard !format.isAudio else { return 0 }
        let position = readingPosition.map { $0.anchor == nil ? 1 : 0 } ?? 0
        return position
            + bookmarks.filter { $0.anchor == nil }.count
            + (skippedHeadings ?? []).filter { $0.anchor == nil }.count
    }

    /// This book's saved places as `PlaceRelocator` takes them (T06's branch
    /// D): its reading position, its bookmarks, its skipped headings that
    /// name a heading, and those that wait.
    var relocatablePlaces: PlaceRelocator.Places {
        PlaceRelocator.Places(
            position: readingPosition,
            bookmarks: bookmarks,
            skippedHeadings: skippedHeadings ?? [],
            waitingSkippedHeadings: waitingSkippedHeadings ?? []
        )
    }

    /// Whether this book has a place a rebuild of its text could move: a
    /// reading position past the book's start, a bookmark, a skipped
    /// heading, or a waiting one. An audiobook has none, since its places
    /// count time in its recording (P08), and a position at the very start
    /// stays at the start of any text.
    var holdsPlacesToMove: Bool {
        guard !format.isAudio else { return false }
        let positionPastStart = readingPosition.map { $0.chapterIndex != 0 || $0.characterOffset != 0 } ?? false
        return positionPastStart
            || !bookmarks.isEmpty
            || !(skippedHeadings ?? []).isEmpty
            || !(waitingSkippedHeadings ?? []).isEmpty
    }

    /// Takes the places `PlaceRelocator` moved (`moved`), each only where
    /// this book still holds it exactly as it was when the moves were
    /// computed (`original`), and returns whether any of the book's places
    /// changed. The moves are computed from the places as they were when the
    /// old text was copied aside; by the time they are written, the listener
    /// may have saved a place again, and a place saved meanwhile wins. The
    /// moves are silent: nothing is spoken or shown, and nothing else of the
    /// book changes (no date, no last-opened time, no other field).
    ///
    /// - The reading position moves when it is still `original`'s, as it is
    ///   stored (`isAsStored`): the record keeps dates to the second.
    /// - Each bookmark moves when this book still holds it, by its `id`,
    ///   equal to `original`'s; a bookmark added, changed, or removed
    ///   meanwhile stays as this book has it, and the book's order is kept.
    /// - The skips move as one: only when both lists are still `original`'s,
    ///   since the relocator merges skips that come to name one heading, so
    ///   its lists do not match the old ones skip for skip. A skip toggled
    ///   meanwhile keeps the listener's whole choice.
    @discardableResult
    mutating func takeMovedPlaces(original: PlaceRelocator.Places, moved: PlaceRelocator.Places) -> Bool {
        let before = relocatablePlaces

        // The position, where it still is as it was.
        if Self.isAsStored(readingPosition, original.position) {
            readingPosition = moved.position
        }

        // Each bookmark, where it still is as it was. The first of any
        // bookmarks sharing an ID answers for it.
        let originalBookmarks = Dictionary(original.bookmarks.map { ($0.id, $0) }) { first, _ in first }
        let movedBookmarks = Dictionary(moved.bookmarks.map { ($0.id, $0) }) { first, _ in first }
        bookmarks = bookmarks.map { held in
            guard Self.isAsStored(held, originalBookmarks[held.id]), let now = movedBookmarks[held.id] else { return held }
            return now
        }

        // The skips, as one: both lists, or neither.
        if (skippedHeadings ?? []) == original.skippedHeadings,
           (waitingSkippedHeadings ?? []) == original.waitingSkippedHeadings {
            setSkippedHeadings(moved.skippedHeadings)
            waitingSkippedHeadings = SkippedHeading.stored(moved.waitingSkippedHeadings)
        }

        return relocatablePlaces != before
    }

    /// Whether the place `held` is `original` as the library index and the
    /// package record keep places: equal, or equal once both are written as
    /// those files write them, with ISO 8601 dates, to the second. A place
    /// saved during this run holds fractions of a second that its stored
    /// copy has lost, so without this the same place, read back from disk
    /// on one side, would never be "as it was", and would not move. Two
    /// nils are alike; a nil and a place are not. `MovedPlaces.taken(by:)`
    /// uses it too, to tell the moves a record took from the ones it refused.
    static func isAsStored<Place: Encodable & Equatable>(_ held: Place?, _ original: Place?) -> Bool {
        if held == original { return true }
        guard let held, let original else { return false }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        guard let heldForm = try? encoder.encode(held), let originalForm = try? encoder.encode(original) else { return false }
        return heldForm == originalForm
    }

    /// Gives each of this book's places that `captured` holds words for
    /// those words, when the place is still saved where they were captured
    /// and still has none (T06, question 6), and returns the words it gave.
    /// A place the listener moved meanwhile, or one given words meanwhile,
    /// keeps its own. Nothing else changes: a place's date stays, since it
    /// has not moved, and so do the skipped headings' IDs.
    @discardableResult
    mutating func adoptCapturedAnchors(_ captured: CapturedPlaceAnchors) -> CapturedPlaceAnchors {
        var adopted = CapturedPlaceAnchors()
        if let placed = captured.position, var position = readingPosition, position.anchor == nil,
           position.chapterIndex == placed.place.chapter, position.characterOffset == placed.place.offset {
            position.anchor = placed.anchor
            readingPosition = position
            adopted.position = placed
        }
        for index in bookmarks.indices {
            let bookmark = bookmarks[index]
            guard bookmark.anchor == nil, let placed = captured.bookmarks[bookmark.id],
                  bookmark.chapterIndex == placed.place.chapter,
                  bookmark.characterOffset == placed.place.offset else { continue }
            bookmarks[index].anchor = placed.anchor
            adopted.bookmarks[bookmark.id] = placed
        }
        if var skipped = skippedHeadings, !captured.skippedHeadings.isEmpty {
            for index in skipped.indices where skipped[index].anchor == nil {
                guard let anchor = captured.skippedHeadings[skipped[index].id] else { continue }
                skipped[index].anchor = anchor
                adopted.skippedHeadings[skipped[index].id] = anchor
            }
            // Set directly, not through `setSkippedHeadings(_:)`: the same
            // headings, now with their words, keep the IDs as they are.
            skippedHeadings = skipped
        }
        return adopted
    }
}
