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
    /// The reading progress as the row speaks it, "42 percent", or nil
    /// when the book has no measured position.
    var progress: String?
    /// The time left at the current speed, or nil when it is unknown.
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
    /// Its address, or nil when the feed is no longer subscribed.
    var address: String?
}

/// The selected row's facts, of whichever kind the row is.
enum LibraryInfoSubject: Equatable {
    case book(BookInfoFacts)
    case folder(FolderInfoFacts)
    case feed(FeedInfoFacts)
}

/// The sentences Speak Info speaks (the I key, `LibraryInfoSpeaker`): a
/// brief summary on the first press, the full one on a quick second press,
/// as Where Am I speaks a position. Pure functions, so every sentence is
/// pinned by a test without a window; counts through `CountWording`, times
/// through `TimeFormatting`, dates through `FeedWording.moment`, and a
/// feed's counts through its row's own phrase, so nothing is spelled twice.
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
    /// nothing named one; its format; its folder, or that it is in none;
    /// its progress and time left as its row speaks them; and "Unopened"
    /// for a book never opened. Example: "Middlemarch. By George Eliot.
    /// EPUB. In Classics. 42 percent. 2 hours, 5 minutes remaining."
    static func briefParts(of book: BookInfoFacts) -> [String] {
        var parts = [book.title]
        if !Book.isUnknownAuthor(book.author) {
            parts.append("By \(book.author)")
        }
        parts.append(book.format)
        parts.append(book.folderPath.isEmpty ? noFolderNote : "In \(book.folderPath)")
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

    /// What a book's full summary adds: when it was added and last opened,
    /// its bookmarks counted, its file size when measured, its cloud note
    /// and whether it is kept on this Mac, and whether a reader window has
    /// it open. Example: "Added September 1 at 9:00 AM. Last opened today
    /// at 3:05 PM. 3 bookmarks. File size 1.2 MB. In Cloud. Kept on this
    /// Mac. Open in a reader window."
    static func fullParts(of book: BookInfoFacts, now: Date, calendar: Calendar, locale: Locale) -> [String] {
        var parts = ["Added \(FeedWording.moment(book.dateAdded, now: now, calendar: calendar, locale: locale))"]
        if let lastOpened = book.lastOpened {
            parts.append("Last opened \(FeedWording.moment(lastOpened, now: now, calendar: calendar, locale: locale))")
        }
        parts.append(CountWording.phrase(book.bookmarkCount, singular: "bookmark", plural: "bookmarks"))
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
        var parts = [folder.name, folderKind]
        var books = CountWording.books(folder.bookCount)
        if folder.unopenedCount > 0 {
            books += ", \(folder.unopenedCount) unopened"
        }
        parts.append(books)
        if folder.feedCount > 0 {
            parts.append(CountWording.phrase(folder.feedCount, singular: "feed", plural: "feeds"))
        }
        return parts
    }

    /// What a folder's full summary adds: its subfolders counted when it
    /// has any, and the time left in all its books when any is known.
    /// Example: "2 subfolders. 14 hours, 3 minutes remaining in total."
    static func fullParts(of folder: FolderInfoFacts) -> [String] {
        var parts: [String] = []
        if folder.subfolderCount > 0 {
            parts.append(CountWording.phrase(folder.subfolderCount, singular: "subfolder", plural: "subfolders"))
        }
        if let remaining = folder.timeRemaining {
            parts.append("\(TimeFormatting.spoken(remaining)) remaining in total")
        }
        return parts
    }

    // MARK: A Feed

    /// A feed's brief summary, in parts: its title, "Feed", "Folder
    /// missing" when its folder is gone, its items counted with its row's
    /// own phrase (`FeedWording.countsPhrase`), its size first and its
    /// unplayed items last, and its last check. Example: "Planet Money.
    /// Feed. 10 of 381 episodes kept, 3 downloaded, 2 new, 5 unplayed.
    /// Checked today at 3:05 PM."
    static func briefParts(of feed: FeedInfoFacts) -> [String] {
        var parts = [feed.title, FeedWording.feedNote]
        if feed.folderPath == nil {
            parts.append(FeedWording.folderMissingNote)
        }
        parts.append(FeedWording.countsPhrase(feed.counts))
        parts.append(feed.check)
        return parts
    }

    /// What a feed's full summary adds: its folder when it has one, and its
    /// address when it is still subscribed. Example: "In Podcasts/Planet
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
