import Foundation

// MARK: - The Words of Compare Libraries (Phase 0 of the local-first design)

/// Every sentence of Compare Libraries and of Use This Library's account of
/// which copy is newer, built in one place so the sheet, VoiceOver, a braille
/// display, and the tests all read the same words. Each difference is one
/// full sentence that makes sense heard alone, as VoiceOver reads a list row
/// by row. Every sentence is whole in each case, or joined from whole
/// sentences by `SentenceWording.joined` (FR34).
enum LibraryComparisonWording {
    /// The sheet's title, and the command's.
    static var title: String {
        String(localized: "Compare Libraries",
               comment: "Title of the Compare Libraries sheet, and the name of the command in Storage settings that opens it. The sheet lists what differs between this library and another copy of it.")
    }

    /// The title the sheet speaks when it opens, naming what it compares.
    static var sheetLabel: String {
        String(localized: "Compare Libraries, results",
               comment: "Spoken label of the Compare Libraries sheet when it opens: its title, then the word results.")
    }

    /// What the Storage settings button says to VoiceOver it does.
    static var buttonHint: String {
        String(localized: "Chooses a folder holding another copy of this library and lists what differs. Nothing in either copy is changed.",
               comment: "VoiceOver hint of the Compare Libraries button in Storage settings.")
    }

    /// What this copy and the other are called in a sentence.
    struct Names: Sendable {
        /// The library in use.
        var this: String
        /// The folder compared with it.
        var other: String

        /// The sheet's own names: "this copy" and "the other copy".
        static var sheet: Names {
            Names(
                this: String(localized: "this copy",
                             comment: "What the Compare Libraries sheet calls the library in use inside a sentence, in lower case: \"Book only in this copy\"."),
                other: String(localized: "the other copy",
                              comment: "What the Compare Libraries sheet calls the folder compared with the library in use, inside a sentence, in lower case: \"Book only in the other copy\"."))
        }
        /// The names Use This Library's confirmation uses, as it speaks of
        /// a library to switch to.
        static var useThisLibrary: Names {
            Names(
                this: String(localized: "the library in use",
                             comment: "What the Use This Library confirmation calls the library TextMouth is using now, inside a sentence, in lower case."),
                other: String(localized: "the copy in this folder",
                              comment: "What the Use This Library confirmation calls the copy in the folder the listener chose, inside a sentence, in lower case."))
        }

        /// The name of `side`.
        func callSide(_ side: LibraryCopySide) -> String {
            side == .thisCopy ? this : other
        }
    }

    /// "on" or "off", for an option's value.
    static func onOrOff(_ value: Bool) -> String {
        value
            ? String(localized: "on",
                     comment: "The value of a Reading List option that is switched on, in lower case, inside a sentence of Compare Libraries: \"Reading list: “Skip finished books” is on in this copy and off in the other copy.\"")
            : String(localized: "off",
                     comment: "The value of a Reading List option that is switched off, in lower case, inside a sentence of Compare Libraries: \"Reading list: “Skip finished books” is on in this copy and off in the other copy.\"")
    }

    /// What a reading list book that neither copy's library holds is called.
    static var unknownBookTitle: String {
        String(localized: "a book that is not in the library",
               comment: "What Compare Libraries calls a Reading List book that neither copy's library holds, in lower case, inside a sentence.")
    }

    // MARK: Counts

    /// The count the list begins with, which VoiceOver reads first.
    /// - Parameter folder: The other copy's folder, by its path.
    static func countSentence(differences: Int, unread: Int, folder: String) -> String {
        let counted = differences == 0
            ? String(localized: "No differences between this library and the copy in \(folder).",
                     comment: "First sentence of the results of Compare Libraries when the two copies do not differ. %@ is the other copy's folder path.")
            : String(localized: "\(differences) differences between this library and the copy in \(folder).",
                     comment: "First sentence of the results of Compare Libraries. %1$lld is how many differences there are, a count; %2$@ is the other copy's folder path.")
        guard unread > 0 else { return counted }
        return SentenceWording.joined([counted, unreadCountSentence(unread)])
    }

    /// What the files not read mean for the list.
    static func unreadCountSentence(_ count: Int) -> String {
        SentenceWording.joined([
            String(localized: "\(count) files couldn't be read, so the comparison may be missing differences.",
                   comment: "Sentence of the results of Compare Libraries: some files could not be read. %lld is how many files, a count."),
            String(localized: "They are listed after the differences.",
                   comment: "Sentence of the results of Compare Libraries that follows the count of unread files: the files are listed after the differences."),
        ])
    }

    /// The sentence that opens the results when the library index of a copy
    /// could not be read, so nothing could be compared.
    static func nothingComparedSentence(folder: String) -> String {
        SentenceWording.joined([
            String(localized: "Nothing could be compared with the copy in \(folder), because a file the comparison needs couldn't be read.",
                   comment: "First sentence of the results of Compare Libraries when the other copy's library index could not be read. %@ is the other copy's folder path."),
            String(localized: "The files that couldn't be read are listed.",
                   comment: "Sentence of the results of Compare Libraries saying the unread files are listed below."),
        ])
    }

    /// What the sheet says while it works, naming the folder.
    static func comparingSentence(folder: String) -> String {
        SentenceWording.joined([
            String(localized: "Comparing this library with the copy in \(folder).",
                   comment: "First sentence of what the Compare Libraries sheet says while it works. %@ is the other copy's folder path."),
            String(localized: "A library in the cloud can take a while: files that are only in the cloud are brought to this Mac to be read.",
                   comment: "Sentence of what the Compare Libraries sheet says while it works: a library kept in a cloud drive is slow because files that are only in the cloud are downloaded first."),
            String(localized: "Nothing is changed.",
                   comment: "Last sentence of what the Compare Libraries sheet says while it works: the comparison changes nothing in either copy."),
        ])
    }

    /// What is spoken now and then during a long comparison.
    static func progressSentence(seconds: Int) -> String {
        String(localized: "Still comparing: \(seconds) seconds so far. Press Escape to stop.",
               comment: "VoiceOver announcement now and then during a long Compare Libraries comparison. %lld is how many seconds it has taken so far, a count. Escape is the key that stops it.")
    }

    /// The label of the list of files that were not read.
    static var unreadListLabel: String {
        String(localized: "Files not read",
               comment: "Label of the list of files the Compare Libraries comparison could not read.")
    }

    /// What the sheet says when the folder holds another library.
    static func differentLibrarySentence(folder: String) -> String {
        String(localized: "The folder \(folder) holds a different library, so nothing was compared.",
               comment: "What the Compare Libraries sheet says when the chosen folder holds a different library. %@ is the folder's path.")
    }

    /// What the sheet says once the listener stopped it.
    static var stoppedSentence: String {
        String(localized: "Comparing stopped. Nothing was changed.",
               comment: "What the Compare Libraries sheet says once the listener stopped the comparison.")
    }

    /// The folder panel's title, message, and prompt, for choosing the copy.
    static var panelTitle: String {
        String(localized: "Choose the Copy to Compare",
               comment: "Title of the folder panel in which the listener chooses the other copy of the library to compare.")
    }
    static var panelMessage: String {
        String(localized: "Choose the folder that holds another copy of this library. Nothing in it is changed.",
               comment: "Message of the folder panel in which the listener chooses the other copy of the library to compare.")
    }
    static var panelPrompt: String {
        String(localized: "Compare",
               comment: "Button of the folder panel that starts comparing the library with the chosen copy.")
    }

    /// The words for a button that copies every sentence of the results.
    static var copyLabel: String {
        String(localized: "Copy Results",
               comment: "Button of the Compare Libraries sheet that copies the results to the clipboard.")
    }
    static var copyHint: String {
        String(localized: "Copies the count and every difference as text, one to a line.",
               comment: "VoiceOver hint of the Copy Results button of the Compare Libraries sheet.")
    }
    /// What is announced once the results are on the clipboard.
    static var copiedSentence: String {
        String(localized: "Results copied to the clipboard.",
               comment: "VoiceOver announcement once the Compare Libraries results are on the clipboard.")
    }
    /// The Storage settings button that opens the sheet, and what VoiceOver calls it.
    static var buttonTitle: String {
        String(localized: "Compare Libraries…",
               comment: "Button in Storage settings that opens the Compare Libraries sheet. The ellipsis shows that a choice follows.")
    }
    /// The button that closes the sheet.
    static var doneLabel: String {
        String(localized: "Done",
               comment: "Button that closes the Compare Libraries sheet.")
    }
    /// The button that stops the comparison.
    static var stopLabel: String {
        String(localized: "Stop",
               comment: "Button of the Compare Libraries sheet that stops the comparison.")
    }
    static var stopHint: String {
        String(localized: "Stops comparing. Nothing in either copy has been changed.",
               comment: "VoiceOver hint of the Stop button of the Compare Libraries sheet.")
    }

    /// How many unread files the list names one by one.
    static let unreadListed = 20

    /// The sentence that ends a list of unread files cut short.
    static func moreUnreadSentence(_ count: Int) -> String {
        String(localized: "And \(count) more files couldn't be read.",
               comment: "Last line of the list of unread files in Compare Libraries when the list is cut short. %lld is how many more files could not be read, a count.")
    }

    // MARK: Rows

    /// The sentence for one difference, with `names` for the copies.
    static func sentence(for difference: LibraryDifference, names: Names = .sheet) -> String {
        switch difference {
        case .bookOnlyIn(let side, let book):
            let place = names.callSide(side)
            let phrase = bookPhrase(book)
            return String(localized: "Book only in \(place): \(phrase).",
                          comment: "A difference found by Compare Libraries. %1$@ is a copy of the library (this copy or the other copy), %2$@ is a book's title and, when known, its author.")
        case .bookFiledDifferently(let book, let thisFolder, let otherFolder):
            let title = book.title
            let here = folderPhrase(thisFolder)
            let there = folderPhrase(otherFolder)
            return String(localized: "\(title) is filed \(here) in \(names.this) and \(there) in \(names.other).",
                          comment: "A difference found by Compare Libraries. %1$@ is a book's title, %2$@ says where this copy files it (at the top of the library, or in a folder), %3$@ is this copy, %4$@ says where the other copy files it, %5$@ is the other copy.")
        case .positionNewer(let book, let side, let newer, let older):
            let title = book.title
            let newerSide = names.callSide(side)
            let newerPlace = placePhrase(newer)
            let olderName = names.callSide(side.opposite).capitalizedFirst
            // The older copy either has an older place or none at all.
            let olderWords = older.map { place in
                String(localized: "\(olderName) has \(placePhrase(place)).",
                       comment: "Second sentence of a position difference found by Compare Libraries. %1$@ is a copy of the library, capitalized, and %2$@ is the place it has saved, such as \"chapter 3, 41%\".")
            } ?? String(localized: "\(olderName) has no place saved.",
                        comment: "Second sentence of a position difference found by Compare Libraries. %@ is a copy of the library, capitalized, that has no place saved for the book.")
            return SentenceWording.joined([
                String(localized: "Position in \(title): newer in \(newerSide), \(newerPlace).",
                       comment: "First sentence of a position difference found by Compare Libraries. %1$@ is a book's title, %2$@ is the copy that has the newer place, and %3$@ is that place, such as \"chapter 3, 41%\"."),
                olderWords,
            ])
        case .positionDiffersAtOnce(let book, let this, let other):
            let title = book.title
            return SentenceWording.joined([
                String(localized: "Position in \(title): differs, and both were saved at the same time.",
                       comment: "First sentence of a position difference found by Compare Libraries when both copies saved their places at the same moment. %@ is a book's title."),
                hasPair(names.this, placePhrase(this), names.other, placePhrase(other)),
            ])
        case .bookmarkOnlyIn(let side, let book, let bookmark):
            let number = String(bookmark.number)
            let title = book.title
            let place = names.callSide(side)
            let phrase = bookmarkPhrase(bookmark)
            return String(localized: "Bookmark \(number) in \(title): only in \(place), \(phrase).",
                          comment: "A difference found by Compare Libraries. %1$@ is the bookmark's number, an identifier written without digit grouping; %2$@ is a book's title; %3$@ is the copy of the library that has it; %4$@ is the bookmark's place and note, such as \"chapter 3, with no note\".")
        case .bookmarkDiffers(let book, let this, let other):
            let number = String(this.number)
            let title = book.title
            return SentenceWording.joined([
                String(localized: "Bookmark \(number) in \(title): differs.",
                       comment: "First sentence of a bookmark difference found by Compare Libraries. %1$@ is the bookmark's number, an identifier written without digit grouping, and %2$@ is a book's title."),
                hasPair(names.this, bookmarkPhrase(this), names.other, bookmarkPhrase(other)),
            ])
        case .readingListBookOnlyIn(let side, let book, let place):
            let title = book.title
            let owner = names.callSide(side)
            let number = String(place)
            return String(localized: "Reading list: \(title) is only on \(owner)'s list, at place \(number).",
                          comment: "A difference found by Compare Libraries. %1$@ is a book's title, %2$@ is the copy of the library whose Reading List holds it, and %3$@ is its place in that list, an identifier written without digit grouping.")
        case .readingListOrderDiffers(let thisTitles, let otherTitles):
            return SentenceWording.joined([
                String(localized: "Reading list: the order differs.",
                       comment: "First sentence of a Reading List difference found by Compare Libraries: the two copies hold the same books in a different order."),
                hasPair(names.this, CountWording.list(thisTitles), names.other, CountWording.list(otherTitles)),
            ])
        case .readingListOptionDiffers(let label, let this, let other):
            return String(localized: "Reading list: “\(label)” is \(this) in \(names.this) and \(other) in \(names.other).",
                          comment: "A difference found by Compare Libraries. %1$@ is the name of a Reading List option, %2$@ is its value (on or off) in this copy, %3$@ is this copy, %4$@ is its value in the other copy, and %5$@ is the other copy.")
        case .folderOnlyIn(let side, let path):
            let place = names.callSide(side)
            return String(localized: "Folder “\(path)” is only in \(place).",
                          comment: "A difference found by Compare Libraries. %1$@ is a library folder's path and %2$@ is the copy of the library that has it.")
        case .folderPathDiffers(let thisPath, let otherPath):
            return String(localized: "Folder “\(thisPath)” in \(names.this) is “\(otherPath)” in \(names.other).",
                          comment: "A difference found by Compare Libraries: the same folder has two paths. %1$@ is its path in this copy, %2$@ is this copy, %3$@ is its path in the other copy, and %4$@ is the other copy.")
        }
    }

    /// "<this> has <a>; <other> has <b>." with each copy's name capitalized:
    /// the second sentence of a difference that two copies hold differently.
    private static func hasPair(_ this: String, _ thisValue: String, _ other: String, _ otherValue: String) -> String {
        let first = this.capitalizedFirst
        return String(localized: "\(first) has \(thisValue); \(other) has \(otherValue).",
                      comment: "Second sentence of a difference found by Compare Libraries. %1$@ is this copy of the library, capitalized, %2$@ is what it holds, %3$@ is the other copy, and %4$@ is what it holds.")
    }

    /// The sentence for one file that was not read, as the list ends with.
    /// A file not read is unread, never missing: nothing is known of it.
    static func sentence(for file: LibraryUnreadFile, names: Names = .sheet) -> String {
        let where_ = names.callSide(file.side)
        let what: String
        let consequence: String
        switch file.subject {
        case .identityMarker:
            what = String(localized: "the identity marker of the library in \(where_)",
                          comment: "A phrase naming a file Compare Libraries could not read, inside a sentence that starts \"Unread:\". %@ is a copy of the library.")
            consequence = String(localized: "so TextMouth can't tell whether the two copies are one library, and compared nothing.",
                                 comment: "Last clause of a sentence about an unread file in Compare Libraries: the consequence for the identity marker, after a comma.")
        case .libraryIndex:
            what = String(localized: "the library index in \(where_)",
                          comment: "A phrase naming a file Compare Libraries could not read, inside a sentence that starts \"Unread:\". %@ is a copy of the library.")
            consequence = String(localized: "so nothing in \(where_) was compared.",
                                 comment: "Last clause of a sentence about an unread file in Compare Libraries: the consequence for the library index, after a comma. %@ is a copy of the library.")
        case .record(_, let title):
            what = String(localized: "the record of \(title) in \(where_)",
                          comment: "A phrase naming a file Compare Libraries could not read, inside a sentence that starts \"Unread:\". %1$@ is a book's title and %2$@ is a copy of the library.")
            consequence = String(localized: "so its place and bookmarks there were taken from the library index alone.",
                                 comment: "Last clause of a sentence about an unread file in Compare Libraries: the consequence for a book's record, after a comma.")
        }
        switch file.reason {
        case .notArrived(let seconds):
            return String(localized: "Unread: \(what) hasn't arrived from the cloud after \(seconds) seconds, \(consequence)",
                          comment: "A file Compare Libraries could not read. %1$@ names the file, %2$lld is how many seconds TextMouth waited for it, a count, and %3$@ is the clause that says what follows from it.")
        case .cannotBeRead(let reason):
            // The reason is a parser's or the system's own English sentence (question 3).
            return String(localized: "Unread: \(what) couldn't be read (\(reason)), \(consequence)",
                          comment: "A file Compare Libraries could not read. %1$@ names the file, %2$@ is the reason in English, as the file's reader worded it, and %3$@ is the clause that says what follows from it.")
        case .timeRanOut(let seconds):
            return String(localized: "Unread: \(what) wasn't read, because TextMouth stopped waiting after \(seconds) seconds in all, \(consequence)",
                          comment: "A file Compare Libraries could not read. %1$@ names the file, %2$lld is how many seconds TextMouth waited in all, a count, and %3$@ is the clause that says what follows from it.")
        case .stillBeingFetched:
            return String(localized: "Unread: \(what) wasn't asked for again, because the drive hasn't answered an earlier read, \(consequence)",
                          comment: "A file Compare Libraries could not read. %1$@ names the file and %2$@ is the clause that says what follows from it.")
        }
    }

    /// Why a file was not read, in a clause that follows "couldn't tell which
    /// copy is newer": "the library index in the copy in this folder couldn't
    /// be read (its contents are damaged)".
    static func shortReason(for file: LibraryUnreadFile, names: Names = .useThisLibrary) -> String {
        let where_ = names.callSide(file.side)
        let what: String
        switch file.subject {
        case .identityMarker:
            what = String(localized: "the identity marker of \(where_)",
                          comment: "A phrase naming a file that could not be read, inside Use This Library's account of why it can't tell which copy is newer. %@ is a copy of the library.")
        case .libraryIndex:
            what = String(localized: "the library index of \(where_)",
                          comment: "A phrase naming a file that could not be read, inside Use This Library's account of why it can't tell which copy is newer. %@ is a copy of the library.")
        case .record(_, let title):
            what = String(localized: "the record of \(title) in \(where_)",
                          comment: "A phrase naming a file that could not be read, inside Use This Library's account of why it can't tell which copy is newer. %1$@ is a book's title and %2$@ is a copy of the library.")
        }
        switch file.reason {
        case .notArrived(let seconds):
            return String(localized: "\(what) hadn't arrived from the cloud after \(seconds) seconds",
                          comment: "Why a file could not be read, in Use This Library's account. %1$@ names the file and %2$lld is how many seconds TextMouth waited, a count.")
        case .cannotBeRead(let reason):
            // The reason is a parser's or the system's own English sentence (question 3).
            return String(localized: "\(what) couldn't be read: \(reason)",
                          comment: "Why a file could not be read, in Use This Library's account. %1$@ names the file and %2$@ is the reason in English, as the file's reader worded it.")
        case .timeRanOut(let seconds):
            return String(localized: "\(what) wasn't read within \(seconds) seconds",
                          comment: "Why a file could not be read, in Use This Library's account. %1$@ names the file and %2$lld is how many seconds TextMouth waited, a count.")
        case .stillBeingFetched:
            return String(localized: "\(what) wasn't asked for again, because the drive hasn't answered an earlier read",
                          comment: "Why a file could not be read, in Use This Library's account. %@ names the file.")
        }
    }

    /// What Storage settings says while it compares the copy in a chosen
    /// folder with the library in use, to say which is newer.
    static var comparingForUseSentence: String {
        String(localized: "Comparing the library in use with the copy in the folder you chose, to say which is newer. This can take up to a minute. Choose Stop Comparing to skip it.",
               comment: "What Storage settings says while it compares the library in use with a chosen folder's copy before Use This Library. \"Stop Comparing\" is the name of the button that skips it.")
    }
    /// The button that stops that comparison.
    static var stopForUseLabel: String {
        String(localized: "Stop Comparing",
               comment: "Button in Storage settings that stops the comparison made before Use This Library.")
    }

    // MARK: Pieces

    /// A book as a row names it: its title and, when known, its author.
    private static func bookPhrase(_ book: LibraryBookName) -> String {
        guard let author = book.author else { return book.title }
        let title = book.title
        return String(localized: "\(title) by \(author)",
                      comment: "A book named in a row of Compare Libraries. %1$@ is its title and %2$@ its author.")
    }

    /// Where a folder path puts a book: at the top of the library, or in the
    /// folder.
    private static func folderPhrase(_ path: String) -> String {
        path.isEmpty
            ? String(localized: "at the top of the library",
                     comment: "Where a copy of the library files a book, inside a sentence of Compare Libraries: not in any folder.")
            : String(localized: "in the folder “\(path)”",
                     comment: "Where a copy of the library files a book, inside a sentence of Compare Libraries. %@ is the folder's path.")
    }

    /// A place as "chapter 3, 41%".
    static func placePhrase(_ place: LibraryPlaceName) -> String {
        let chapter = String(place.chapter)
        guard let percent = place.percent else {
            return String(localized: "chapter \(chapter)",
                          comment: "A reading place inside a sentence of Compare Libraries. %@ is the chapter's number, an identifier written without digit grouping.")
        }
        return String(localized: "chapter \(chapter), \(percent)%",
                      comment: "A reading place inside a sentence of Compare Libraries. %1$@ is the chapter's number, an identifier written without digit grouping, and %2$lld is how far into the book it is, a percentage from 0 to 100.")
    }

    /// A bookmark's place and note: "chapter 3, with the note “Check this”".
    private static func bookmarkPhrase(_ bookmark: LibraryBookmarkName) -> String {
        let chapter = String(bookmark.chapter)
        if bookmark.note.isEmpty {
            return String(localized: "chapter \(chapter), with no note",
                          comment: "A bookmark's place inside a sentence of Compare Libraries, when it has no note. %@ is the chapter's number, an identifier written without digit grouping.")
        }
        let note = bookmark.note
        return String(localized: "chapter \(chapter), with the note “\(note)”",
                      comment: "A bookmark's place and note inside a sentence of Compare Libraries. %1$@ is the chapter's number, an identifier written without digit grouping, and %2$@ is the note the listener wrote.")
    }

    // MARK: Which Copy Is Newer

    /// What Use This Library says of the folder chosen, which holds another
    /// copy of the library in use: which copy has the newer places and
    /// what only each holds, from the same comparison Compare Libraries
    /// lists. It replaces the words "may not have its latest changes".
    ///
    /// - Parameter comparison: The result, or nil when it could not be made.
    /// - Parameter reason: Why it could not, in words, when `comparison` is nil.
    static func newerCopySentence(_ comparison: LibraryComparison?, reason: String?, names: Names = .useThisLibrary) -> String {
        let pointer = String(localized: "Compare Libraries in Storage settings lists every difference.",
                             comment: "Last sentence of Use This Library's account of which copy is newer: it points to the Compare Libraries command in Storage settings.")
        let lead = String(localized: "This folder holds another copy of the library TextMouth is using.",
                          comment: "First sentence of Use This Library's account of the folder the listener chose.")
        guard let comparison else {
            // The reason, when there is one, is the system's or a parser's English (question 3).
            let couldNotTell = reason.map { why in
                String(localized: "TextMouth couldn't tell which copy is newer (\(why)).",
                       comment: "Second sentence of Use This Library's account when the comparison could not be made. %@ is the reason in English.")
            } ?? String(localized: "TextMouth couldn't tell which copy is newer.",
                        comment: "Second sentence of Use This Library's account when the comparison could not be made and no reason is known.")
            return SentenceWording.joined([lead, couldNotTell, pointer])
        }
        let here = changesOnly(in: .thisCopy, comparison)
        let there = changesOnly(in: .otherCopy, comparison)
        // The sentence about unread files is left out when every file was read.
        let unread: [String] = comparison.unread.isEmpty ? [] : [
            String(localized: "TextMouth couldn't read \(comparison.unread.count) files, so this may be incomplete.",
                   comment: "Sentence of Use This Library's account: some files could not be read. %lld is how many files, a count."),
        ]
        switch (here, there) {
        case (nil, nil) where comparison.differences.isEmpty:
            return SentenceWording.joined([lead,
                String(localized: "It has the same books, places, bookmarks, reading list, and folders.",
                       comment: "Sentence of Use This Library's account: the other copy matches the library in use exactly.")] + unread)
        case (nil, nil):
            return SentenceWording.joined([lead,
                String(localized: "Neither has newer places or books the other lacks, but they differ in other ways.",
                       comment: "Sentence of Use This Library's account: the copies differ, but neither has newer places or books the other lacks.")] + unread + [pointer])
        case (let here?, nil):
            return SentenceWording.joined([lead, isNewer(names.this, has: here)] + unread + [pointer])
        case (nil, let there?):
            return SentenceWording.joined([lead, isNewer(names.other, has: there)] + unread + [pointer])
        case (let here?, let there?):
            return SentenceWording.joined([lead,
                String(localized: "Neither is newer: each has changes the other lacks.",
                       comment: "Sentence of Use This Library's account: each copy has changes the other lacks."),
                hasSentence(names.this, here), hasSentence(names.other, there)] + unread + [pointer])
        }
    }

    /// "<name> is the newer. It has <changes>." with the name capitalized.
    private static func isNewer(_ name: String, has changes: String) -> String {
        let capitalized = name.capitalizedFirst
        return String(localized: "\(capitalized) is the newer. It has \(changes).",
                      comment: "Sentence of Use This Library's account of which copy is newer. %1$@ is a copy of the library, capitalized, and %2$@ lists what only it has, such as \"newer places in 3 books and 2 books the other lacks\".")
    }

    /// "<name> has <changes>." with the name capitalized.
    private static func hasSentence(_ name: String, _ changes: String) -> String {
        let capitalized = name.capitalizedFirst
        return String(localized: "\(capitalized) has \(changes).",
                      comment: "Sentence of Use This Library's account when neither copy is newer. %1$@ is a copy of the library, capitalized, and %2$@ lists what only it has, such as \"newer places in 3 books and 2 books the other lacks\".")
    }

    /// What only `side` has, as a phrase such as "newer places in 3 books,
    /// 2 books the other lacks, and 1 bookmark the other lacks"; nil when it
    /// has nothing the other lacks.
    private static func changesOnly(in side: LibraryCopySide, _ comparison: LibraryComparison) -> String? {
        var parts: [String] = []
        let places = comparison.newerPositions(in: side)
        if places > 0 {
            parts.append(String(localized: "newer places in \(places) books",
                                comment: "Part of a list in Use This Library's account of which copy is newer. %lld is how many books have a newer place in this copy, a count."))
        }
        let books = comparison.booksOnlyIn(side)
        if books > 0 {
            parts.append(String(localized: "\(books) books the other lacks",
                                comment: "Part of a list in Use This Library's account of which copy is newer. %lld is how many books only this copy has, a count."))
        }
        let bookmarks = comparison.bookmarksOnlyIn(side)
        if bookmarks > 0 {
            parts.append(String(localized: "\(bookmarks) bookmarks the other lacks",
                                comment: "Part of a list in Use This Library's account of which copy is newer. %lld is how many bookmarks only this copy has, a count."))
        }
        return parts.isEmpty ? nil : CountWording.list(parts)
    }
}

private extension String {
    /// The string with its first letter capitalized, the rest as it is.
    var capitalizedFirst: String {
        prefix(1).uppercased() + dropFirst()
    }
}
