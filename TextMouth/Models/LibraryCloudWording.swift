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
        guard forSelection else {
            // Translators: Library menu command that downloads the one book a row's menu is for, or the selected book.
            return InterfaceText.line("libraryCloud.downloadTitle.downloadNow", "Download Now")
        }
        // Translators: Library menu command that downloads the selected books. %lld is the number of books selected.
        return InterfaceText.line("libraryCloud.downloadTitle.books", "Download \(number: count) Books")
    }

    /// Remove Download's title: "Remove Download" for the one book a menu is
    /// for, or "Remove Downloads of 3 Books" for `count` books of a
    /// selection ("Remove Download of 1 Book" for one).
    static func removeDownloadTitle(count: Int, forSelection: Bool) -> String {
        guard forSelection else {
            // Translators: Library menu command that removes the downloaded files of the one book a row's menu is for; the book stays in the cloud.
            return InterfaceText.line("libraryCloud.removeDownloadTitle.one", "Remove Download")
        }
        // Translators: Library menu command that removes the downloaded files of the selected books; they stay in the cloud. %lld is the number of books selected.
        return InterfaceText.line("libraryCloud.removeDownloadTitle.downloads", "Remove Downloads of \(number: count) Books")
    }

    /// Keep on This Mac's name: its title in the Library menu, and for the
    /// one book a row's menu is for.
    static var keepName: String {
        // Translators: Library menu command that keeps a book's files downloaded on this Mac. Also the name other sentences use for the command.
        InterfaceText.line("libraryCloud.keepName", "Keep on This Mac")
    }

    /// Stop Keeping on This Mac's name: its title in the Library menu, and
    /// for the one book a row's menu is for.
    static var stopKeepingName: String {
        // Translators: Library menu command that stops keeping a book's files downloaded on this Mac. Also the name other sentences use for the command.
        InterfaceText.line("libraryCloud.stopKeepingName", "Stop Keeping on This Mac")
    }

    /// Keep on This Mac's title: "Keep on This Mac" for the one book a menu
    /// is for, or "Keep 3 Books on This Mac" for `count` books of a
    /// selection.
    static func keepTitle(count: Int, forSelection: Bool) -> String {
        guard forSelection else { return keepName }
        // Translators: Library menu command that keeps the selected books' files downloaded on this Mac. %lld is the number of books selected.
        return InterfaceText.line("libraryCloud.keepTitle", "Keep \(number: count) Books on This Mac")
    }

    /// Stop Keeping on This Mac's title: "Stop Keeping on This Mac" for the
    /// one book a menu is for, or "Stop Keeping 3 Books on This Mac" for
    /// `count` books of a selection.
    static func stopKeepingTitle(count: Int, forSelection: Bool) -> String {
        guard forSelection else { return stopKeepingName }
        // Translators: Library menu command that stops keeping the selected books' files downloaded on this Mac. %lld is the number of books selected.
        return InterfaceText.line("libraryCloud.stopKeepingTitle", "Stop Keeping \(number: count) Books on This Mac")
    }

    /// Show in Finder's title: "Show in Finder" for the one book a menu is
    /// for, or "Show 3 Books in Finder" for `count` books of a selection.
    static func showInFinderTitle(count: Int, forSelection: Bool) -> String {
        guard forSelection else {
            // Translators: Library menu command that shows the one book's files in the Finder.
            return InterfaceText.line("common.showInFinder", "Show in Finder")
        }
        // Translators: Library menu command that shows the selected books' files in the Finder. %lld is the number of books selected.
        return InterfaceText.line("libraryCloud.showInFinderTitle", "Show \(number: count) Books in Finder")
    }

    // MARK: - Download Now

    /// What Download Now announces as it starts: "Downloading Moby-Dick"
    /// for one book, "Downloading 3 books" for several.
    static func downloadStarted(titles: [String]) -> String {
        // Translators: Announcement when Download Now starts. %@ is the book's title, or a count of books such as "3 books".
        InterfaceText.line("common.downloadingValue", "Downloading \(subject(titles))")
    }

    // MARK: - Keep on This Mac

    /// What Keep on This Mac announces: "Keeping Moby-Dick on this Mac" for
    /// one book, or "Keeping 3 books on this Mac" for several, and then,
    /// when `downloading` of them start downloading now, being only in the
    /// cloud, "Downloading it now", "Downloading them now", or "Downloading
    /// 2 of them now".
    static func keepStarted(titles: [String], downloading: Int) -> String {
        // Translators: Announcement when Keep on This Mac starts. %@ is the book's title, or a count of books such as "3 books".
        let keeping = InterfaceText.line("libraryCloud.keepStarted.keeping", "Keeping \(subject(titles)) on this Mac")
        guard downloading > 0 else { return keeping }
        // Which of the books start downloading now, said whole.
        let downloadingNow: String
        if titles.count == 1 {
            // Translators: Second part of the Keep on This Mac announcement for one book that is only in the cloud: it starts downloading.
            downloadingNow = InterfaceText.line("libraryCloud.keepStarted.downloadingNow", "Downloading it now")
        } else if downloading == titles.count {
            // Translators: Second part of the Keep on This Mac announcement when every kept book is only in the cloud: they start downloading.
            downloadingNow = InterfaceText.line("libraryCloud.keepStarted.downloadingThem", "Downloading them now")
        } else {
            // Translators: Second part of the Keep on This Mac announcement when some kept books are only in the cloud. %lld is how many start downloading.
            downloadingNow = InterfaceText.line("libraryCloud.keepStarted.downloadingCount", "Downloading \(number: downloading) of them now")
        }
        return clausesJoined([keeping, downloadingNow])
    }

    // MARK: - The Reading List's Books

    /// What VoiceOver hears, once, when this Mac starts downloading the
    /// reading list's books in a cloud library, or finds no room for some
    /// (the user, November 13, 2026: this Mac keeps them downloaded). It is
    /// said at medium priority, so it waits for what the listener's own
    /// command just said rather than cutting it off.
    ///
    /// "Downloading Moby-Dick, a reading list book" for one book (the notice
    /// names the list, which the title alone does not), "Downloading 7 books"
    /// for several; with `quietly`, the books came without a command of the
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
            // Translators: Announcement when the reading list's book starts downloading. %@ is the book's title.
            sentences.append(InterfaceText.line("libraryCloud.readingListStarted.one", "Downloading \(title), a reading list book"))
        } else if !titles.isEmpty {
            // Quietly, no command of the listener's started them, so the sentence names the list.
            sentences.append(quietly
                // Translators: Announcement when the reading list's books start downloading with no command of the listener's. %lld is the number of books.
                ? InterfaceText.line("libraryCloud.readingListStarted.many", "Downloading \(number: titles.count) reading list books")
                // Translators: Announcement when the reading list's books start downloading after a command of the listener's. %@ is a count of books, such as "3 books".
                : InterfaceText.line("common.downloadingValue", "Downloading \(CountWording.books(titles.count))"))
        }
        if short > 0 {
            if titles.isEmpty {
                // Translators: Announcement when no reading list book can start downloading for want of space. %lld is the number of books left out.
                sentences.append(InterfaceText.line("libraryCloud.readingListStarted.noRoomForAll", "There isn't enough free space to download \(number: short) reading list books"))
            } else {
                // Translators: Announcement when some reading list books start downloading and others are left out for want of space. %lld is the number of books left out.
                sentences.append(InterfaceText.line("libraryCloud.readingListStarted.noRoomForMore", "There isn't enough free space for \(number: short) more books"))
            }
        }
        return Self.clausesJoined(sentences)
    }

    /// What Stop Keeping on This Mac announces: "Stopped keeping Moby-Dick
    /// on this Mac" for one book, "Stopped keeping 3 books on this Mac" for
    /// several; and, when the reading list keeps books among them
    /// (`stillKept`, a count), that it does: "The reading list still keeps
    /// it downloaded", "... them downloaded", or "... 2 of them downloaded".
    /// The listener's choice is let go, but the list's keep is not theirs to
    /// stop here.
    static func stoppedKeeping(titles: [String], stillKept: Int = 0) -> String {
        // Translators: Announcement when Stop Keeping on This Mac ran. %@ is the book's title, or a count of books such as "3 books".
        let stopped = InterfaceText.line("libraryCloud.stoppedKeeping.onThisMac", "Stopped keeping \(subject(titles)) on this Mac")
        guard stillKept > 0 else { return stopped }
        // Which of the books the reading list still keeps, said whole.
        let stillKeeps: String
        if titles.count == 1 {
            // Translators: Second part of the Stop Keeping on This Mac announcement for one book that the reading list keeps downloaded.
            stillKeeps = InterfaceText.line("libraryCloud.stoppedKeeping.downloaded", "The reading list still keeps it downloaded")
        } else if stillKept >= titles.count {
            // Translators: Second part of the Stop Keeping on This Mac announcement when the reading list keeps every one of the books downloaded.
            stillKeeps = InterfaceText.line("libraryCloud.stoppedKeeping.readingList", "The reading list still keeps them downloaded")
        } else {
            // Translators: Second part of the Stop Keeping on This Mac announcement when the reading list keeps some of the books downloaded. %lld is how many.
            stillKeeps = InterfaceText.line("libraryCloud.stoppedKeeping.readingListStill", "The reading list still keeps \(number: stillKept) of them downloaded")
        }
        return clausesJoined([stopped, stillKeeps])
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
            // Translators: Why Keep on This Mac or Stop Keeping on This Mac changed nothing: the library is not in a cloud folder.
            return InterfaceText.line("libraryCloud.isntFolderBooks", "The library isn't in a cloud folder, so its books are always on this Mac.")
        }
        guard !titles.isEmpty else { return noBooksSelected }
        if !keeping, keptOnlyForReadingList > 0 {
            return stopKeepingRefusalForReadingListBooks(
                selected: titles,
                keptOnlyForReadingList: keptOnlyForReadingList
            )
        }
        if titles.count == 1, let title = titles.first {
            return keeping
                // Translators: Why Keep on This Mac changed nothing: the selected book is already kept. %@ is the book's title.
                ? InterfaceText.line("libraryCloud.alreadyKeptMac", "\(title) is already kept on this Mac.")
                // Translators: Why Stop Keeping on This Mac changed nothing: the selected book is not kept. %@ is the book's title.
                : InterfaceText.line("libraryCloud.isntKeptMac", "\(title) isn't kept on this Mac.")
        }
        return keeping
            // Translators: Why Keep on This Mac changed nothing: every selected book is already kept. %lld is the number of books selected.
            ? InterfaceText.line("libraryCloud.selectedBooksAlready", "The \(number: titles.count) selected books are already kept on this Mac.")
            // Translators: Why Stop Keeping on This Mac changed nothing: none of the selected books is kept. %lld is the number of books selected.
            : InterfaceText.line("libraryCloud.noneSelectedBooksKeptMac", "None of the \(number: titles.count) selected books is kept on this Mac.")
    }

    // MARK: - Letting the Reading List's Books Go

    /// The sentence that tells what lets one book kept for the reading list
    /// go, ending with "first": the cloud refusals begin with it.
    static var letGoOfOneBookFirst: String {
        // Translators: Last sentence of why Remove Download was refused for a book the reading list keeps downloaded: what to do first. %@ is the name of the Reading List's option that keeps its books downloaded, as the option shows it.
        InterfaceText.line("libraryCloud.letGoOfOneBookFirst", "Take it off the reading list, or clear \(ReadingListWording.keepBooksLabel) in the Reading List's options first.")
    }

    /// The sentence that tells what to do next, after the listener chose
    /// Stop Keeping on This Mac: it follows another sentence's "first".
    static var thenLetGoOfOneBook: String {
        // Translators: Last sentence of why Remove Download was refused for a book the listener keeps and the reading list keeps too: what to do after choosing Stop Keeping on This Mac. %@ is the name of the Reading List's option that keeps its books downloaded, as the option shows it.
        InterfaceText.line("libraryCloud.thenLetGoOfOneBook", "Then take it off the reading list, or clear \(ReadingListWording.keepBooksLabel) in the Reading List's options.")
    }

    /// How to let `plural` books, or one book, go from the reading list's keep.
    private static func howToLetGo(plural: Bool) -> String {
        plural
            // Translators: Last sentence of why Stop Keeping on This Mac cannot let several books go: the reading list keeps them. %@ is the name of the Reading List's option that keeps its books downloaded, as the option shows it.
            ? InterfaceText.line("libraryCloud.howToLetGo.them", "To let them go, take them off the reading list, or clear \(ReadingListWording.keepBooksLabel) in the Reading List's options.")
            // Translators: Last sentence of why Stop Keeping on This Mac cannot let a book go: the reading list keeps it. %@ is the name of the Reading List's option that keeps its books downloaded, as the option shows it.
            : InterfaceText.line("libraryCloud.howToLetGo.reading", "To let it go, take it off the reading list, or clear \(ReadingListWording.keepBooksLabel) in the Reading List's options.")
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
        if titles.count == 1, let title = titles.first {
            return SentenceWording.joined([
                // Translators: First sentence of why Stop Keeping on This Mac changed nothing for one book: the reading list keeps it. %@ is the book's title.
                InterfaceText.line("libraryCloud.keptMacReading", "\(title) is kept on this Mac for the reading list."),
                howToLetGo(plural: false),
            ])
        }
        if all {
            return SentenceWording.joined([
                // Translators: First sentence of why Stop Keeping on This Mac changed nothing: the reading list keeps every selected book. %lld is the number of books selected.
                InterfaceText.line("libraryCloud.selectedBooksKept", "The \(number: titles.count) selected books are kept on this Mac for the reading list."),
                howToLetGo(plural: plural),
            ])
        }
        // The selection has several books, so only the count kept for the list varies its noun.
        return SentenceWording.joined([
            // Translators: First sentence of why Stop Keeping on This Mac changed nothing: none of the selected books is kept by the listener's choice, and some are kept for the reading list. %1$@ is the number of books selected, already formatted; %2$lld is how many are kept for the reading list.
            InterfaceText.line("libraryCloud.noneSelectedBooksKeptMacChoice", "None of the \(titles.count.interfaceFormatted()) selected books is kept on this Mac by your choice, and \(number: keptOnlyForReadingList) are kept for the reading list."),
            howToLetGo(plural: plural),
        ])
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
            // Translators: Announcement that Download Now brought one book to this Mac. %@ is the book's title.
            sentences.append(InterfaceText.line("libraryCloud.downloadFinished.value", "\(title) downloaded"))
        } else if downloaded.count > 1 {
            // Translators: Announcement that Download Now brought several books to this Mac. %@ is a count of books, such as "3 books".
            sentences.append(InterfaceText.line("libraryCloud.downloadFinished.downloaded", "Downloaded \(CountWording.books(downloaded.count))"))
        }
        if failed.count == 1, let failure = failed.first {
            // Translators: Announcement that Download Now could not bring one book to this Mac. %@ is the book's title.
            sentences.append(InterfaceText.line("libraryCloud.downloadFinished.wasnt", "\(failure.title) wasn't downloaded"))
        } else if failed.count > 1 {
            // Translators: Announcement that Download Now could not bring several books to this Mac. %1$lld is how many; %2$@ is their titles as a list.
            sentences.append(InterfaceText.line("libraryCloud.downloadFinished.werent", "\(number: failed.count) books weren't downloaded: \(CountWording.list(failed.map(\.title)))"))
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
        let service = DataDirectoryUnavailability.service(provider)
        var sentences: [String] = []
        if removed.count == 1, let title = removed.first {
            // Translators: Announcement that Remove Download removed one book's downloaded files. %@ is the book's title.
            sentences.append(InterfaceText.line("libraryCloud.removedDownload", "Removed the download of \(title)"))
            // Translators: Announcement after Remove Download removed one book's files from this Mac: the book is still in the cloud. %@ is the cloud service's name, or "the cloud" when it is unknown.
            sentences.append(InterfaceText.line("libraryCloud.stays", "It stays in \(service)"))
        } else if removed.count > 1 {
            // Translators: Announcement that Remove Download removed several books' downloaded files. %@ is a count of books, such as "3 books".
            sentences.append(InterfaceText.line("libraryCloud.removedDownloads", "Removed the downloads of \(CountWording.books(removed.count))"))
            // Translators: Announcement after Remove Download removed several books' files from this Mac: the books are still in the cloud. %@ is the cloud service's name, or "the cloud" when it is unknown.
            sentences.append(InterfaceText.line("libraryCloud.theyStay", "They stay in \(service)"))
        }
        if refused.count == 1, let refusal = refused.first {
            // Translators: Announcement that Remove Download did not remove one book's files. %@ is the book's title.
            sentences.append(InterfaceText.line("libraryCloud.downloadWasntRemoved", "The download of \(refusal.title) wasn't removed"))
        } else if refused.count > 1 {
            // Translators: Announcement that Remove Download did not remove several books' files. %1$@ is a count of books, such as "3 books"; %2$@ is their titles as a list.
            sentences.append(InterfaceText.line("libraryCloud.downloadsWerentRemoved", "The downloads of \(CountWording.books(refused.count)) weren't removed: \(CountWording.list(refused.map(\.title)))"))
        }
        // A removal alone ends with a full stop, as a full sentence about where
        // the book stays.
        guard let text = summary(sentences, explanations: refused.map(\.explanation)) else { return nil }
        return refused.isEmpty ? Self.fullStopped(text) : text
    }

    /// The title of the alert that shows Remove Download's refusals, for
    /// `refusedCount` books.
    static func removalRefusedTitle(refusedCount: Int) -> String {
        refusedCount == 1
            // Translators: Title of the alert that says Remove Download did not remove one book's files.
            ? InterfaceText.line("libraryCloud.removalRefusedTitle.download", "Download Not Removed")
            // Translators: Title of the alert that says Remove Download did not remove several books' files.
            : InterfaceText.line("libraryCloud.removalRefusedTitle.downloads", "Downloads Not Removed")
    }

    // MARK: - No Selection

    /// Why a Library menu command acting on the selected books did nothing:
    /// none is selected. Keep on This Mac and Export (FR05) say it.
    static var noBooksSelected: String {
        // Translators: Why a Library menu command did nothing: no book is selected.
        InterfaceText.line("libraryCloud.noBooksSelected", "No books are selected.")
    }

    // MARK: - Books Not Downloaded

    /// What to do about `count` books only in the cloud before an operation
    /// that never downloads can take them, naming the list's own command:
    /// "Download it first: select it in the library, then choose Download
    /// Now." for one book, "Download them first: select them in the
    /// library, then choose Download Now." for several. A move of the
    /// library and Export (FR05) both refuse such books with it.
    static func downloadFirst(count: Int) -> String {
        let command = downloadTitle(count: count, forSelection: false)
        return count == 1
            // Translators: What to do about a book only in the cloud before an operation that never downloads. %@ is the name of the Library menu command Download Now.
            ? InterfaceText.line("libraryCloud.downloadFirst.select", "Download it first: select it in the library, then choose \(command).")
            // Translators: What to do about several books only in the cloud before an operation that never downloads. %@ is the name of the Library menu command Download Now.
            : InterfaceText.line("libraryCloud.downloadFirst.them", "Download them first: select them in the library, then choose \(command).")
    }

    /// Why the books `titles` were left as they are by an operation that
    /// never downloads (FR02), such as Export or Edit Text (FR05): their
    /// files are only in the cloud. Worded as a move of the library words
    /// the same refusal: "Moby-Dick isn't downloaded. Download it first:
    /// select it in the library, then choose Download Now." Up to three
    /// books are named; more are counted.
    static func notDownloaded(titles: [String]) -> String {
        let state: String
        switch titles.count {
        case 1:
            // Translators: Why an operation left one book as it is: its files are only in the cloud. %@ is the book's title.
            state = InterfaceText.line("common.valueIsntDownloaded", "\(titles[0]) isn't downloaded.")
        case 2...3:
            // Translators: Why an operation left two or three books as it is: their files are only in the cloud. %@ is the books' titles as a list.
            state = InterfaceText.line("libraryCloud.arentDownloaded", "\(CountWording.list(titles)) aren't downloaded.")
        default:
            // Translators: Why an operation left several books as it is: their files are only in the cloud. %@ is a count of books, such as "5 books".
            state = InterfaceText.line("libraryCloud.arentDownloaded", "\(CountWording.books(titles.count)) aren't downloaded.")
        }
        return SentenceWording.joined([state, downloadFirst(count: titles.count)])
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
        let text = clausesJoined(sentences)
        // The explanations end with their own full stops, so they follow whole.
        return distinct.isEmpty ? text : SentenceWording.joined([fullStopped(text)] + distinct)
    }

    /// `clauses` of an announcement, none ending with a full stop, joined as
    /// the language joins spoken clauses: English ends each with a full stop
    /// and a space, and leaves the last without one.
    private static func clausesJoined(_ clauses: [String]) -> String {
        clauses.dropFirst().reduce(clauses.first ?? "") { text, next in
            // Translators: Joins two spoken clauses of an announcement. %1$@ is the clauses so far and %2$@ the next one. English ends the first with a full stop and a space; a language that writes no full stop, or another mark, changes only that.
            InterfaceText.line("common.valuePeriodValue", "\(text). \(next)")
        }
    }

    /// `clause` ended the way an announcement's last clause is ended when a
    /// whole sentence follows it or when it stands alone as a sentence.
    private static func fullStopped(_ clause: String) -> String {
        // Translators: A spoken clause of an announcement ended with a full stop. %@ is the clause. English adds a full stop; change only the mark.
        InterfaceText.line("common.valuePeriod", "\(clause).")
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
