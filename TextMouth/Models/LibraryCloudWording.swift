import Foundation

/// The words of the library list's cloud commands (FR02): their titles,
/// which are also their VoiceOver action names, and what they announce.
///
/// The words for a book's state and for why an operation failed belong to
/// the contract (`BookCloudState`, `BookCloudError.explanation(in:)`); these
/// only name the commands and say what a command did with the books it
/// acted on.
enum LibraryCloudWording {
    // MARK: - Titles

    /// Download Now's title: "Download Now" for the one book a menu is for,
    /// or "Download 3 Books" for `count` books of a selection.
    static func downloadTitle(count: Int, forSelection: Bool) -> String {
        forSelection ? "Download \(titleCount(count))" : "Download Now"
    }

    /// Remove Download's title: "Remove Download" for the one book a menu is
    /// for, or "Remove Downloads of 3 Books" for `count` books of a
    /// selection ("Remove Download of 1 Book" for one).
    static func removeDownloadTitle(count: Int, forSelection: Bool) -> String {
        guard forSelection else { return "Remove Download" }
        return "Remove \(count == 1 ? "Download" : "Downloads") of \(titleCount(count))"
    }

    /// Keep on This Mac's name: its title in the Library menu, and for the
    /// one book a row's menu is for.
    static let keepName = "Keep on This Mac"

    /// Stop Keeping on This Mac's name: its title in the Library menu, and
    /// for the one book a row's menu is for.
    static let stopKeepingName = "Stop Keeping on This Mac"

    /// Keep on This Mac's title: "Keep on This Mac" for the one book a menu
    /// is for, or "Keep 3 Books on This Mac" for `count` books of a
    /// selection.
    static func keepTitle(count: Int, forSelection: Bool) -> String {
        forSelection ? "Keep \(titleCount(count)) on This Mac" : keepName
    }

    /// Stop Keeping on This Mac's title: "Stop Keeping on This Mac" for the
    /// one book a menu is for, or "Stop Keeping 3 Books on This Mac" for
    /// `count` books of a selection.
    static func stopKeepingTitle(count: Int, forSelection: Bool) -> String {
        forSelection ? "Stop Keeping \(titleCount(count)) on This Mac" : stopKeepingName
    }

    /// Show in Finder's title: "Show in Finder" for the one book a menu is
    /// for, or "Show 3 Books in Finder" for `count` books of a selection.
    static func showInFinderTitle(count: Int, forSelection: Bool) -> String {
        forSelection ? "Show \(titleCount(count)) in Finder" : "Show in Finder"
    }

    /// `count` books in a command's title: "1 Book", "3 Books".
    private static func titleCount(_ count: Int) -> String {
        CountWording.phrase(count, singular: "Book", plural: "Books")
    }

    // MARK: - Download Now

    /// What Download Now announces as it starts: "Downloading Moby-Dick"
    /// for one book, "Downloading 3 books" for several.
    static func downloadStarted(titles: [String]) -> String {
        "Downloading \(subject(titles))"
    }

    // MARK: - Keep on This Mac

    /// What Keep on This Mac announces: "Keeping Moby-Dick on this Mac" for
    /// one book, or "Keeping 3 books on this Mac" for several, and then,
    /// when `downloading` of them start downloading now, being only in the
    /// cloud, "Downloading it now", "Downloading them now", or "Downloading
    /// 2 of them now".
    static func keepStarted(titles: [String], downloading: Int) -> String {
        let keeping = "Keeping \(subject(titles)) on this Mac"
        guard downloading > 0 else { return keeping }
        let which: String
        if titles.count == 1 {
            which = "it"
        } else if downloading == titles.count {
            which = "them"
        } else {
            which = "\(downloading) of them"
        }
        return "\(keeping). Downloading \(which) now"
    }

    // MARK: - The Reading List's Books

    /// What VoiceOver hears, once, when this Mac starts downloading the
    /// reading list's books in a cloud library, or finds no room for some
    /// (the user, November 13, 2026: this Mac keeps them downloaded). It is
    /// said at medium priority, so it waits for what the listener's own
    /// command just said rather than cutting it off.
    ///
    /// "Downloading Moby-Dick" for one book, "Downloading 7 books" for
    /// several; with `quietly`, the books came without a command of the
    /// listener's (a first refresh after an update, the choice turned on, a
    /// sync from another Mac), so the sentence names the list:
    /// "Downloading 7 reading list books". Then, for the `short` books that
    /// do not fit in the space free: "There isn't enough free space for 3
    /// more books", or, when none starts, "There isn't enough free space to
    /// download 3 reading list books".
    /// - Parameters:
    ///   - titles: The titles of the books starting to download.
    ///   - short: How many more books were left out for want of space.
    ///   - quietly: Whether no command of the listener's started them.
    static func readingListDownloadsStarted(titles: [String], short: Int, quietly: Bool) -> String {
        var sentences: [String] = []
        if titles.count == 1, let title = titles.first {
            sentences.append("Downloading \(title)")
        } else if !titles.isEmpty {
            let books = quietly ? "\(titles.count) reading list books" : CountWording.books(titles.count)
            sentences.append("Downloading \(books)")
        }
        if short > 0 {
            if titles.isEmpty {
                let books = CountWording.phrase(short, singular: "reading list book", plural: "reading list books")
                sentences.append("There isn't enough free space to download \(books)")
            } else {
                sentences.append("There isn't enough free space for \(short) more \(short == 1 ? "book" : "books")")
            }
        }
        return sentences.joined(separator: ". ")
    }

    /// What Stop Keeping on This Mac announces: "Stopped keeping Moby-Dick
    /// on this Mac" for one book, "Stopped keeping 3 books on this Mac" for
    /// several; and, when the reading list keeps books among them
    /// (`stillKept`, a count), that it does: "The reading list still keeps
    /// it downloaded", "... them downloaded", or "... 2 of them downloaded".
    /// The listener's choice is let go, but the list's keep is not theirs to
    /// stop here.
    static func stoppedKeeping(titles: [String], stillKept: Int = 0) -> String {
        let stopped = "Stopped keeping \(subject(titles)) on this Mac"
        guard stillKept > 0 else { return stopped }
        let which: String
        if titles.count == 1 {
            which = "it"
        } else if stillKept >= titles.count {
            which = "them"
        } else {
            which = "\(stillKept) of them"
        }
        return "\(stopped). The reading list still keeps \(which) downloaded"
    }

    /// Why Keep on This Mac (`keeping`) or Stop Keeping on This Mac, chosen
    /// in the Library menu for the books selected, `titles`, changed nothing:
    /// the library isn't in the cloud, no book is selected, or every one is
    /// already as asked.
    ///
    /// Stop Keeping names the books the reading list alone keeps
    /// (`keptOnlyForReadingList`, a count among those selected): they are
    /// kept, though not by the listener's choice, so it says so and how to
    /// let them go, never that they aren't kept.
    static func keepMenuRefusal(
        keeping: Bool,
        selected titles: [String],
        inCloudLibrary: Bool,
        keptOnlyForReadingList: Int = 0
    ) -> String {
        guard inCloudLibrary else {
            return "The library isn't in a cloud folder, so its books are always on this Mac."
        }
        guard !titles.isEmpty else { return noBooksSelected }
        if !keeping, keptOnlyForReadingList > 0 {
            return stopKeepingRefusalForReadingListBooks(
                selected: titles,
                keptOnlyForReadingList: keptOnlyForReadingList
            )
        }
        if titles.count == 1, let title = titles.first {
            return keeping ? "\(title) is already kept on this Mac." : "\(title) isn't kept on this Mac."
        }
        return keeping
            ? "The \(titles.count) selected books are already kept on this Mac."
            : "None of the \(titles.count) selected books is kept on this Mac."
    }

    /// Why Stop Keeping on This Mac changed nothing when the reading list
    /// keeps the selected books, `keptOnlyForReadingList` of them: they are
    /// kept for the reading list, and the way to let them go. A selection
    /// with others not kept at all says that none is kept by the listener's
    /// choice.
    private static func stopKeepingRefusalForReadingListBooks(
        selected titles: [String],
        keptOnlyForReadingList: Int
    ) -> String {
        let all = keptOnlyForReadingList >= titles.count
        let plural = all ? titles.count > 1 : keptOnlyForReadingList > 1
        let advice = ReadingListWording.letGoOfBooksAdvice(plural: plural, capitalized: false)
        if titles.count == 1, let title = titles.first {
            return "\(title) is kept on this Mac for the reading list. To let it go, \(advice)."
        }
        if all {
            return "The \(titles.count) selected books are kept on this Mac for the reading list. To let them go, \(advice)."
        }
        let verb = keptOnlyForReadingList == 1 ? "is" : "are"
        return "None of the \(titles.count) selected books is kept on this Mac by your choice, "
            + "and \(keptOnlyForReadingList) \(verb) kept for the reading list. To let \(plural ? "them" : "it") go, \(advice)."
    }

    /// What Download Now announces once every book it started has ended:
    /// one summary, such as "Moby-Dick downloaded" or "Downloaded 3 books",
    /// then the books that weren't downloaded and why. Nil when nothing
    /// ended, which happens only when every book left the library first.
    /// - Parameters:
    ///   - downloaded: The titles of the books now on this Mac, in list order.
    ///   - failed: The books whose download failed, with the explanation of
    ///     each failure, in list order.
    static func downloadFinished(downloaded: [String], failed: [(title: String, explanation: String)]) -> String? {
        var sentences: [String] = []
        if downloaded.count == 1, let title = downloaded.first {
            sentences.append("\(title) downloaded")
        } else if downloaded.count > 1 {
            sentences.append("Downloaded \(CountWording.books(downloaded.count))")
        }
        if failed.count == 1, let failure = failed.first {
            sentences.append("\(failure.title) wasn't downloaded")
        } else if failed.count > 1 {
            let books = CountWording.phrase(failed.count, singular: "book wasn't", plural: "books weren't")
            sentences.append("\(books) downloaded: \(CountWording.list(failed.map(\.title)))")
        }
        return summary(sentences, explanations: failed.map(\.explanation))
    }

    // MARK: - Remove Download

    /// What Remove Download announces, and shows when anything was refused.
    /// A single book refused hears only the explanation, since the book is
    /// the one just chosen; otherwise the removed books come first, then the
    /// refused ones and why. Nil when nothing was attempted.
    /// - Parameters:
    ///   - removed: The titles of the books whose downloads were removed.
    ///   - refused: The books whose downloads stay, with the explanation of
    ///     each refusal.
    ///   - provider: The sync service the books stay in, when known.
    static func removalFinished(
        removed: [String],
        refused: [(title: String, explanation: String)],
        provider: CloudProvider?
    ) -> String? {
        if removed.isEmpty, refused.count == 1, let refusal = refused.first {
            return refusal.explanation
        }
        let service = provider?.displayName ?? "the cloud"
        var sentences: [String] = []
        if removed.count == 1, let title = removed.first {
            sentences.append("Removed the download of \(title)")
            sentences.append("It stays in \(service)")
        } else if removed.count > 1 {
            sentences.append("Removed the downloads of \(CountWording.books(removed.count))")
            sentences.append("They stay in \(service)")
        }
        if refused.count == 1, let refusal = refused.first {
            sentences.append("The download of \(refusal.title) wasn't removed")
        } else if refused.count > 1 {
            sentences.append(
                "The downloads of \(CountWording.books(refused.count)) weren't removed: "
                    + CountWording.list(refused.map(\.title))
            )
        }
        // A removal alone ends with a period, as a full sentence about where
        // the book stays.
        guard let text = summary(sentences, explanations: refused.map(\.explanation)) else { return nil }
        return refused.isEmpty ? text + "." : text
    }

    /// The title of the alert that shows Remove Download's refusals, for
    /// `refusedCount` books.
    static func removalRefusedTitle(refusedCount: Int) -> String {
        refusedCount == 1 ? "Download Not Removed" : "Downloads Not Removed"
    }

    // MARK: - No Selection

    /// Why a Library menu command acting on the selected books did nothing:
    /// none is selected. Keep on This Mac and Export (FR05) say it.
    static let noBooksSelected = "No books are selected."

    // MARK: - Books Not Downloaded

    /// What to do about `count` books only in the cloud before an operation
    /// that never downloads can take them, naming the list's own command:
    /// "Download it first: select it in the library, then choose Download
    /// Now." for one book, "Download them first: select them in the
    /// library, then choose Download Now." for several. A move of the
    /// library and Export (FR05) both refuse such books with it.
    static func downloadFirst(count: Int) -> String {
        let them = count == 1 ? "it" : "them"
        return "Download \(them) first: select \(them) in the library, then choose "
            + "\(downloadTitle(count: count, forSelection: false))."
    }

    /// Why the books `titles` were left as they are by an operation that
    /// never downloads (FR02), such as Export or Edit Text (FR05): their
    /// files are only in the cloud. Worded as a move of the library words
    /// the same refusal: "Moby-Dick isn't downloaded. Download it first:
    /// select it in the library, then choose Download Now." Up to three
    /// books are named; more are counted.
    static func notDownloaded(titles: [String]) -> String {
        let subject: String
        switch titles.count {
        case 1:
            subject = "\(titles[0]) isn't"
        case 2...3:
            subject = "\(CountWording.list(titles)) aren't"
        default:
            subject = "\(CountWording.books(titles.count)) aren't"
        }
        return "\(subject) downloaded. \(downloadFirst(count: titles.count))"
    }

    // MARK: - Helpers

    /// `sentences` joined into one announcement, followed by each distinct
    /// explanation once, in the order they first came; nil when there is
    /// nothing to say. The explanations end with their own periods.
    private static func summary(_ sentences: [String], explanations: [String]) -> String? {
        guard !sentences.isEmpty else { return nil }
        var distinct: [String] = []
        for explanation in explanations where !distinct.contains(explanation) {
            distinct.append(explanation)
        }
        let text = sentences.joined(separator: ". ")
        return distinct.isEmpty ? text : text + ". " + distinct.joined(separator: " ")
    }

    /// The books an announcement is about, named by `titles`: the one
    /// book's title, or how many books there are ("3 books").
    private static func subject(_ titles: [String]) -> String {
        if titles.count == 1, let title = titles.first {
            return title
        }
        return CountWording.books(titles.count)
    }
}
