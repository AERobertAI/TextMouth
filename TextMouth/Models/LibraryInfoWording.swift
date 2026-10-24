import Foundation

// MARK: - Speak Info's Words (October 7, 2026)

/// What Speak Info knows of a book: the facts its sentences are made of,
/// gathered by the Library window as the book's row shows them
/// (`BookInfoFacts.init(_:library:wordsPerMinute:cloudStates:keptBooks:measuresFileSize:)`).
struct BookInfoFacts: Equatable {
    /// The book's title.
    var title: String
    /// The book's author, or the placeholder `Book.unknownAuthor`, which
    /// the sentences leave out.
    var author: String
    /// The format's name as the row shows it: "EPUB", "Audio".
    var format: String
    /// The path of the book's folder, or "" for none.
    var folderPath: String
    /// The reading progress as the row speaks it, "42 percent", or
    /// "Finished" for a book resting at its end (TODO P07), or nil when the
    /// book has no measured position.
    var progress: String?
    /// The time left at the current speed, or nil when it is unknown, and
    /// for a book resting at its end, as its row says it.
    var timeRemaining: TimeInterval?
    /// Whether the book has never been opened.
    var isUnopened: Bool
    /// When the book was added.
    var dateAdded: Date
    /// When the book was last opened, or nil for never.
    var lastOpened: Date?
    /// How many bookmarks the book has.
    var bookmarkCount: Int
    /// The size of the book's file on disk, in bytes, or nil when it is
    /// unknown or was not measured.
    var fileSize: Int64?
    /// The book's cloud note as its row speaks it, "In Cloud", or nil for
    /// none, as in a library on this Mac.
    var cloudNote: String?
    /// Whether the book is kept on this Mac (Keep on This Mac).
    var isKeptOnThisMac: Bool
    /// Whether a reader window has the book open.
    var isOpenInWindow: Bool
    /// The title of the feed an episode or an article in its feed's folder
    /// belongs to (FR11), which Speak Info names where it names a book's
    /// folder; nil for a book of the library's own.
    var feedTitle: String? = nil
    /// The book's place in the reading list, counted as the Reading List
    /// shows it (FR09), or nil for a book not in it.
    var readingListPlace: ReadingListPlace? = nil
    /// The braille code a braille book was imported with, such as "Unified
    /// English Braille, contracted (Grade 2)" (`Book.brailleCodeDescription`,
    /// FMT21), which only the full summary says; nil for every other book.
    var brailleCode: String? = nil
    /// The encoding a text book's file was guessed to be in, in words, such
    /// as "Windows-1251 (Cyrillic), guessed" (`Book.textEncodingDescription`,
    /// FMT16), which only the full summary says; nil for every other book.
    var textEncoding: String? = nil
}

// MARK: - A Braille Book's Code (FMT21)

extension Book {
    /// The braille code this braille book is read in, in words: the
    /// description of the table it was imported with, or of the default
    /// table for a braille book whose row and record lack one, such as
    /// "Unified English Braille, contracted (Grade 2)"; one of this Mac's
    /// tables also names its language, as "French braille, contracted (Grade
    /// 2), in French" (`BrailleTableCatalog.description(ofTableID:)`). Nil
    /// for a book that is not braille. Book Information and Speak Info both
    /// say it, from this one expression.
    var brailleCodeDescription: String? {
        guard format == .braille else { return nil }
        return BrailleTableCatalog.description(ofTableID: brailleTable ?? BrailleTableCatalog.defaultTableID)
    }

    /// The words of Book Information's "Braille Code" row for this book: the
    /// label and the code, which VoiceOver reads as "Braille Code, Unified
    /// English Braille, contracted (Grade 2)". Nil for a book that is not
    /// braille, which has no such row. The sheet draws the row from this, so
    /// a test can pin the words without a hosted sheet.
    var bookInfoBrailleCodeRow: (label: String, value: String)? {
        brailleCodeDescription.map { (BrailleCodeWording.bookInfoLabel, $0) }
    }
}

/// The words around a braille book's code (FMT21), kept together so a test
/// pins them.
enum BrailleCodeWording {
    /// The label of Book Information's row that names a braille book's code.
    static let bookInfoLabel = "Braille Code"
}

// MARK: - A Text Book's Encoding (FMT16)

extension Book {
    /// The encoding this text book's file was guessed to be in, in words: the
    /// catalog's name for it and that it was guessed, such as "Windows-1251
    /// (Cyrillic), guessed". A file whose bytes named no encoding is read in
    /// one TextMouth chose, which the listener should be able to learn when
    /// a book's accents or letters read oddly. Nil for a book with no
    /// recorded encoding (its file named one, Windows-1252 read it right, or
    /// it was imported before guesses were recorded), and for a book of a
    /// format that has no use for one. Book Information and Speak Info both
    /// say it, from this one expression.
    var textEncodingDescription: String? {
        guard format.usesTextFileDecoder, let identifier = textEncoding else { return nil }
        return TextEncodingWording.description(ofEncodingNamed: identifier)
    }

    /// The words of Book Information's "Text Encoding" row for this book: the
    /// label and the encoding, which VoiceOver reads as "Text Encoding,
    /// Windows-1251 (Cyrillic), guessed". Nil for a book with no recorded
    /// encoding, which has no such row. The sheet draws the row from this, so
    /// a test can pin the words without a hosted sheet.
    var bookInfoTextEncodingRow: (label: String, value: String)? {
        textEncodingDescription.map { (TextEncodingWording.bookInfoLabel, $0) }
    }
}

/// The words around a text book's guessed encoding (FMT16), kept together so
/// a test pins them. The label names the thing ("Text Encoding", as Speak
/// Info's "Braille code" names a braille book's), and the value says that it
/// was guessed: a label such as "Read As" is heard as "reed as", the other
/// way to say "read", and sounds like a setting the listener can change.
enum TextEncodingWording {
    /// The label of Book Information's row that names the encoding.
    static let bookInfoLabel = "Text Encoding"
    /// What follows the encoding's name, since the file did not say it.
    static let guessNote = "guessed"

    /// The encoding recorded as `identifier` in words, such as "Windows-1251
    /// (Cyrillic), guessed": the catalog's name for it (`TextEncodingCatalog`;
    /// the identifier itself for one the catalog does not know), then that it
    /// was guessed.
    static func description(ofEncodingNamed identifier: String) -> String {
        "\(TextEncodingCatalog.name(forIdentifier: identifier)), \(guessNote)"
    }

    /// Speak Info's sentence for an encoding described as `description`
    /// ("Windows-1251 (Cyrillic), guessed"): "Text encoding: Windows-1251
    /// (Cyrillic), guessed".
    static func speakInfoPart(_ description: String) -> String {
        "Text encoding: \(description)"
    }
}

/// What Speak Info knows of a folder.
struct FolderInfoFacts: Equatable {
    /// The folder's name.
    var name: String
    /// How many books are in the folder and every folder below it, as its
    /// row counts them.
    var bookCount: Int
    /// How many of those have never been opened.
    var unopenedCount: Int
    /// How many feeds have their folders inside it.
    var feedCount: Int
    /// How many folders it holds directly.
    var subfolderCount: Int
    /// The time left in all its books at the current speed, or nil when
    /// none of them has a known time left.
    var timeRemaining: TimeInterval?
}

/// What Speak Info knows of a feed.
struct FeedInfoFacts: Equatable {
    /// The feed's title.
    var title: String
    /// Its items counted, as its row counts them.
    var counts: FeedItemCounts
    /// Its last check as its row shows it: "Checked today at 3:05 PM".
    var check: String
    /// The path of its folder, or nil when the folder is gone.
    var folderPath: String?
    /// Its address, or nil when the feed's record is gone (an unsubscribed
    /// feed keeps its record, FR11, branch D).
    var address: String?
}

/// The selected row's facts, of whichever kind the row is.
enum LibraryInfoSubject: Equatable {
    case book(BookInfoFacts)
    case folder(FolderInfoFacts)
    case feed(FeedInfoFacts)
}

/// The sentences Speak Info speaks (`LibraryInfoSpeaker`): the brief
/// summary for Speak Info, Shift-Command-I, and the full one for Speak
/// Full Info, Shift-Command-I twice (FR12), as Where Am I speaks a
/// position. Pure functions, so every sentence is pinned by a test
/// without a window; counts through
/// `CountWording`, times through `TimeFormatting`, dates through
/// `FeedWording.moment`, and a feed's counts through its row's own phrase,
/// so nothing is spelled twice.
enum LibraryInfoWording {
    /// What a press says when no row is selected.
    static let nothingSelected = "Nothing is selected."
    /// The kind a folder's summary names after the folder's name.
    static let folderKind = "Folder"
    /// What a book's summary says of a book never opened.
    static let unopenedNote = "Unopened"
    /// What a book's summary says of a book in no folder.
    static let noFolderNote = "Not in a folder"
    /// What a book's full summary says of a book a reader window has open.
    static let openInWindowNote = "Open in a reader window"

    // MARK: Summaries

    /// The brief summary of `subject`.
    static func brief(_ subject: LibraryInfoSubject) -> String {
        switch subject {
        case .book(let book): return sentences(briefParts(of: book))
        case .folder(let folder): return sentences(briefParts(of: folder))
        case .feed(let feed): return sentences(briefParts(of: feed))
        }
    }

    /// The full summary of `subject`: the brief one, then the rest. Its
    /// dates read relative to `now`, as "today at 3:05 PM", in `calendar`
    /// and `locale`.
    static func full(
        _ subject: LibraryInfoSubject,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        switch subject {
        case .book(let book):
            return sentences(briefParts(of: book) + fullParts(of: book, now: now, calendar: calendar, locale: locale))
        case .folder(let folder):
            return sentences(briefParts(of: folder) + fullParts(of: folder))
        case .feed(let feed):
            return sentences(briefParts(of: feed) + fullParts(of: feed))
        }
    }

    // MARK: A Book

    /// A book's brief summary, in parts: its title; "By" its author, unless
    /// nothing named one; its format; where it is (`placeNote(of:)`); its
    /// place in the reading list, for a book in it (`readingListNote(_:)`,
    /// FR09); its progress and time left as its row speaks them; and
    /// "Unopened" for a book never opened. Example: "Middlemarch. By George
    /// Eliot. EPUB. In Classics. In reading list, 3 of 12. 42 percent. 2
    /// hours, 5 minutes remaining."; for a finished book, "Dune. By Frank
    /// Herbert. EPUB. In Classics. Finished." (TODO P07).
    static func briefParts(of book: BookInfoFacts) -> [String] {
        var parts = [book.title]
        if !Book.isUnknownAuthor(book.author) {
            parts.append("By \(book.author)")
        }
        parts.append(book.format)
        parts.append(placeNote(of: book))
        if let place = book.readingListPlace {
            parts.append(readingListNote(place))
        }
        if let progress = book.progress {
            parts.append(progress)
        }
        if let timeLeft = book.timeRemaining {
            parts.append(remaining(timeLeft))
        }
        if book.isUnopened {
            parts.append(unopenedNote)
        }
        return parts
    }

    /// Where a book is, as its brief summary says it: in its feed, for an
    /// episode or an article in its feed's folder, which names no folder of
    /// its own (FR11): "In The Digital Antiquarian, a feed"; otherwise in its
    /// folder, "In Classics", or in none, "Not in a folder".
    static func placeNote(of book: BookInfoFacts) -> String {
        if let feedTitle = book.feedTitle {
            return "In \(feedTitle), a feed"
        }
        return book.folderPath.isEmpty ? noFolderNote : "In \(book.folderPath)"
    }

    /// Where a book in the reading list stands in it, as its brief summary
    /// says it, counted as the Reading List shows the list (FR09): "In
    /// reading list, 3 of 12". Said in every view, the Reading List's own
    /// included, where its rows say no more than the list's order does.
    static func readingListNote(_ place: ReadingListPlace) -> String {
        "In reading list, \(place.position) of \(place.count)"
    }

    /// What a book's full summary adds: when it was added and last opened,
    /// its bookmarks counted, its file size when measured, its cloud note
    /// and whether it is kept on this Mac, and whether a reader window has
    /// it open. Example: "Added September 1 at 9:00 AM. Last opened today
    /// at 3:05 PM. 3 bookmarks. File size 1.2 MB. In Cloud. Kept on this
    /// Mac. Open in a reader window." A braille book says its code right
    /// after its bookmarks: "3 bookmarks. Braille code: Unified English
    /// Braille, contracted (Grade 2). File size 1.2 MB." A text book whose
    /// encoding was guessed says it there too: "3 bookmarks. Text encoding:
    /// Windows-1251 (Cyrillic), guessed. File size 1.2 MB."
    static func fullParts(of book: BookInfoFacts, now: Date, calendar: Calendar, locale: Locale) -> [String] {
        var parts = ["Added \(FeedWording.moment(book.dateAdded, now: now, calendar: calendar, locale: locale))"]
        if let lastOpened = book.lastOpened {
            parts.append("Last opened \(FeedWording.moment(lastOpened, now: now, calendar: calendar, locale: locale))")
        }
        parts.append(CountWording.bookmarks(book.bookmarkCount))
        if let code = book.brailleCode {
            parts.append("Braille code: \(code)")
        }
        if let encoding = book.textEncoding {
            parts.append(TextEncodingWording.speakInfoPart(encoding))
        }
        if let size = book.fileSize {
            parts.append("File size \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")
        }
        if let note = book.cloudNote {
            parts.append(note)
        }
        if book.isKeptOnThisMac {
            parts.append(KeptOnThisMacNote.text)
        }
        if book.isOpenInWindow {
            parts.append(openInWindowNote)
        }
        return parts
    }

    // MARK: A Folder

    /// A folder's brief summary, in parts: its name, "Folder", its books
    /// counted with how many are unopened, and its feeds counted when it
    /// has any. Example: "Classics. Folder. 12 books, 3 unopened. 2 feeds."
    static func briefParts(of folder: FolderInfoFacts) -> [String] {
        var parts = [folder.name, folderKind, booksPhrase(of: folder)]
        if let feeds = feedsPhrase(of: folder) {
            parts.append(feeds)
        }
        return parts
    }

    /// What a folder's full summary adds: its subfolders counted when it
    /// has any, and the time left in all its books when any is known.
    /// Example: "2 subfolders. 14 hours, 3 minutes remaining in total."
    static func fullParts(of folder: FolderInfoFacts) -> [String] {
        return [subfoldersPhrase(of: folder), timeRemainingPhrase(of: folder)].compactMap { $0 }
    }

    /// A folder's books counted with how many are unopened. Shared by Speak
    /// Info and the Folder Settings sheet. Example: "12 books, 3 unopened".
    static func booksPhrase(of folder: FolderInfoFacts) -> String {
        var books = CountWording.books(folder.bookCount)
        if folder.unopenedCount > 0 {
            books += ", \(folder.unopenedCount) unopened"
        }
        return books
    }

    /// A folder's feeds counted, or nil when it has none. Example: "2 feeds".
    static func feedsPhrase(of folder: FolderInfoFacts) -> String? {
        guard folder.feedCount > 0 else { return nil }
        return CountWording.phrase(folder.feedCount, singular: "feed", plural: "feeds")
    }

    /// A folder's subfolders counted, or nil when it has none. Example:
    /// "2 subfolders".
    static func subfoldersPhrase(of folder: FolderInfoFacts) -> String? {
        guard folder.subfolderCount > 0 else { return nil }
        return CountWording.phrase(folder.subfolderCount, singular: "subfolder", plural: "subfolders")
    }

    /// The time left in all of a folder's books, or nil when none is known.
    /// Example: "14 hours, 3 minutes remaining in total".
    static func timeRemainingPhrase(of folder: FolderInfoFacts) -> String? {
        guard let remaining = folder.timeRemaining else { return nil }
        return "\(TimeFormatting.spoken(remaining)) remaining in total"
    }

    // MARK: A Feed

    /// A feed's brief summary, in parts: its title, "Feed", "Unsubscribed"
    /// while the listener is unsubscribed from it (FR11, branch D), "Folder
    /// missing" when its folder is gone, its items counted with its row's
    /// own phrase (`FeedWording.countsPhrase`), its size first and its
    /// unplayed items last, and its last check. Example: "Planet Money.
    /// Feed. 10 of 381 episodes listed, 3 downloaded, 2 new, 5 unplayed.
    /// Checked today at 3:05 PM."; "Finish It!. Feed. Unsubscribed. 10 of
    /// 381 episodes listed. Not checked since October 9 at 3:05 PM."
    static func briefParts(of feed: FeedInfoFacts) -> [String] {
        var parts = [feed.title, FeedWording.feedNote]
        if !feed.counts.isSubscribed {
            parts.append(FeedWording.unsubscribedNote)
        }
        if feed.folderPath == nil {
            parts.append(FeedWording.folderMissingNote)
        }
        parts.append(FeedWording.countsPhrase(feed.counts))
        parts.append(feed.check)
        return parts
    }

    /// What a feed's full summary adds: its folder when it has one, and its
    /// address while its record is here. Example: "In Podcasts/Planet
    /// Money. Address https://example.com/feed.xml."
    static func fullParts(of feed: FeedInfoFacts) -> [String] {
        var parts: [String] = []
        if let path = feed.folderPath {
            parts.append("In \(path)")
        }
        if let address = feed.address {
            parts.append("Address \(address)")
        }
        return parts
    }

    // MARK: Sentences

    /// `remaining` as a row speaks a time left: "2 hours, 5 minutes
    /// remaining".
    static func remaining(_ remaining: TimeInterval) -> String {
        "\(TimeFormatting.spoken(remaining)) remaining"
    }

    /// `parts` as spoken sentences, one space apart, each ended with a
    /// period unless it ends with one already, or with another mark that
    /// ends a sentence, as a title can and a feed's failure message does.
    /// Empty parts are left out, so a missing fact never becomes an audible
    /// pause.
    static func sentences(_ parts: [String]) -> String {
        parts.filter { !$0.isEmpty }.map { part in
            guard let last = part.last, ".!?…".contains(last) else { return part + "." }
            return part
        }.joined(separator: " ")
    }
}
