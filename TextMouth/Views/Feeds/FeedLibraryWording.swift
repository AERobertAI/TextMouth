import Foundation

// MARK: - How the Library Words Feeds and Their Items (FR03)

extension FeedWording {
    // MARK: Notes

    /// The note after a feed's title in the Feeds section, and after its
    /// folder's name in the Folders list and the Folders rotor.
    static let feedNote = "Feed"
    /// The note on an item that played to its end, or was marked played.
    static func playedNote(isArticle: Bool) -> String {
        isArticle ? "Read" : "Played"
    }
    /// The note on an item that is new: published since the subscription
    /// began, and neither played nor opened.
    static let newNote = "New"
    /// What a feed row says when its folder is no longer in the library.
    static let folderMissingNote = "Folder missing"
    /// The note after a feed's title, or its folder's name, while the
    /// listener is unsubscribed from it (FR11, branch D), which TextMouth
    /// then does not check; spoken in lower case after "Feed", as in
    /// "Finish It!, Feed, unsubscribed, 10 of 381 episodes listed".
    static let unsubscribedNote = "Unsubscribed"

    /// The notes that follow "Feed" for a feed counted as `counts`: the
    /// note "unsubscribed" while the listener is unsubscribed from it,
    /// spoken in lower case, as in the middle of a sentence.
    private static func notesAfterFeed(_ counts: FeedItemCounts) -> [String] {
        counts.isSubscribed ? [] : [unsubscribedNote.lowercased()]
    }

    // MARK: Counts

    /// A feed's items counted, as its row, its folder's summary bar, its
    /// Feed Info, Speak Info, and entering its folder all say: its size
    /// (`sizePhrase(_:)`), then the downloads, the new items, and the items
    /// not yet played (of articles, not yet read), "10 of 381 episodes
    /// listed, 3 downloaded, 1 downloading, 2 new, 5 unplayed", leaving out
    /// the counts that are 0, but never the size.
    static func countsPhrase(_ counts: FeedItemCounts) -> String {
        var parts = [sizePhrase(counts)]
        if counts.downloaded > 0 { parts.append("\(counts.downloaded) downloaded") }
        if counts.downloading > 0 { parts.append("\(counts.downloading) downloading") }
        if counts.new > 0 { parts.append("\(counts.new) new") }
        if counts.unplayed > 0 { parts.append("\(counts.unplayed) \(unplayedNote(counts.noun))") }
        return parts.joined(separator: ", ")
    }

    /// What a feed's counts call the items not yet played: "unread" for
    /// articles, "unplayed" for episodes and for a feed mixing the two.
    static func unplayedNote(_ noun: ItemNoun) -> String {
        noun == .article ? "unread" : "unplayed"
    }

    /// The heading of a feed's folder's items, which counts the rows under
    /// it: "Episodes (12)". While those rows are every entry the library
    /// lists of a feed that lists more, it says the feed's size as the
    /// feed's row does, "Episodes (10 of 381 listed)", "Articles (10 of more
    /// than 2000 listed)"; while a search narrows them (`total` nil), the
    /// rows alone. VoiceOver reads it in one stop, as it shows it.
    static func sectionTitle(_ noun: ItemNoun, count: Int, total: FeedEntryTotal? = nil) -> String {
        let name = noun.plural.capitalized
        guard let total, total.exceeds(count) else { return "\(name) (\(count))" }
        return "\(name) (\(count) of \(entriesPhrase(total, noun: nil)) \(listedNote))"
    }

    /// The heading of a feed's folder's books that came from no item of the
    /// feed, as every folder's books are headed: "Books (2)".
    static func otherBooksTitle(count: Int) -> String {
        "Books (\(count))"
    }

    /// The heading of the Feeds section.
    static let feedsSectionTitle = "Feeds"

    // MARK: Checks

    /// How a feed's last check reads, as its row shows it and VoiceOver
    /// speaks it, the spoken form starting in lower case to follow a comma.
    struct Check: Equatable, Sendable {
        /// The words shown: "Checked today at 3:05 PM".
        let visible: String
        /// The words spoken: "checked today at 3:05 PM".
        let spoken: String
        /// Whether the last check failed.
        let failed: Bool
    }

    /// How the feed's last check reads: being checked now, never checked
    /// on this Mac, failed (with the reason, which names the feed's host,
    /// never its address), or the day and time of the last check, given as
    /// a time of day so nothing redraws on a clock. For a feed the listener
    /// is not subscribed to (`isSubscribed` false, FR11, branch D), that it
    /// is not checked, since the day and time of the last check when this
    /// Mac made one: "Not checked since October 9 at 3:05 PM", or "Not
    /// checked".
    static func check(
        _ fetch: FeedFetchState,
        isRefreshing: Bool,
        isSubscribed: Bool = true,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> Check {
        guard isSubscribed else {
            let since = fetch.lastCheck.map { " since \(moment($0, now: now, calendar: calendar, locale: locale))" } ?? ""
            return Check(visible: "Not checked\(since)", spoken: "not checked\(since)", failed: false)
        }
        if isRefreshing {
            return Check(visible: "Checking now", spoken: "checking now", failed: false)
        }
        if let failure = fetch.lastError {
            return Check(
                visible: "Last check failed: \(failure.message)",
                spoken: "last check failed: \(failure.message)",
                failed: true
            )
        }
        guard let checked = fetch.lastCheck else {
            return Check(visible: "Not checked yet", spoken: "not checked yet", failed: false)
        }
        let when = moment(checked, now: now, calendar: calendar, locale: locale)
        return Check(visible: "Checked \(when)", spoken: "checked \(when)", failed: false)
    }

    /// `date` as "today at 3:05 PM", "yesterday at 9:00 AM", "October 1 at
    /// 3:05 PM", or, in another year, "October 1, 2025 at 3:05 PM".
    static func moment(_ date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let time = DateFormatter()
        time.locale = locale
        time.timeZone = calendar.timeZone
        time.dateStyle = .none
        time.timeStyle = .short
        let clock = time.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) {
            return "today at \(clock)"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday at \(clock)"
        }
        let day = DateFormatter()
        day.locale = locale
        day.timeZone = calendar.timeZone
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        day.setLocalizedDateFormatFromTemplate(sameYear ? "MMMMd" : "MMMMdy")
        return "\(day.string(from: date)) at \(clock)"
    }

    // MARK: Feed Rows

    /// A feed's row as VoiceOver speaks it, in one sentence: "Planet Money,
    /// Feed, 10 of 381 episodes listed, 3 downloaded, 2 new, checked today
    /// at 3:05 PM", with "unsubscribed" after the note while the listener is
    /// unsubscribed (FR11, branch D), "Finish It!, Feed, unsubscribed, 10 of
    /// 381 episodes listed, not checked since October 9 at 3:05 PM", and
    /// "Folder missing" after the notes when its folder is gone.
    static func feedRowLabel(title: String, counts: FeedItemCounts, check: Check, folderMissing: Bool) -> String {
        var parts = [title, feedNote] + notesAfterFeed(counts)
        if folderMissing { parts.append(folderMissingNote) }
        parts.append(countsPhrase(counts))
        parts.append(check.spoken)
        return parts.joined(separator: ", ")
    }

    /// A feed row's spoken hint.
    static let feedRowHint = "Opens the feed's folder"

    /// What VoiceOver hears when a feed's row is opened and its folder is
    /// no longer in the library.
    static func folderMissing(title: String) -> String {
        "The folder of \(title) is no longer in the library."
    }

    /// What VoiceOver hears when an item not downloaded is opened: it
    /// downloads, and then opens.
    static func downloadingToOpen(title: String) -> String {
        "Downloading “\(title)”. It opens once it has downloaded."
    }

    /// What entering a feed's folder says, and its folder's row and Folders
    /// rotor entry: "Planet Money, Feed, 10 of 381 episodes listed, 3
    /// downloaded, 2 new", with "unsubscribed" after "Feed" while the
    /// listener is unsubscribed (FR11, branch D).
    static func folderAnnouncement(name: String, counts: FeedItemCounts) -> String {
        ([name, feedNote] + notesAfterFeed(counts) + [countsPhrase(counts)]).joined(separator: ", ")
    }

    // MARK: Item Rows

    /// An item's date as its row shows and speaks it: "October 1, 2026".
    static func itemDate(_ date: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    /// An item's row as VoiceOver speaks it, in one sentence, putting first
    /// what matters most on a braille display: the title, Played (or Read),
    /// the state with why it failed or waits, the place and bookmarks kept
    /// after its file went (FR11), New, the date, and the duration. "How the
    /// Fed sets rates, Not Downloaded, New, October 1, 2026, 28 minutes";
    /// "…, Played, Downloading, …" (how far it has got is the feed downloads
    /// section's, FR10); "…, Download Failed, the
    /// server says the file is gone, …"; "…, Waiting to Download, it
    /// downloads once this Mac is on a network without data limits, …";
    /// "Ep. 368, Not Downloaded, 42 percent, 16 minutes remaining, 2
    /// bookmarks, July 17, 2026, 1 hour, 4 minutes"; and, moved into the
    /// library (FR11, branch D), "Ep. 368, In Library, July 17, 2026, 1
    /// hour, 4 minutes", each duration as `TimeFormatting.spoken` says it
    /// (#1936). A played item says no progress, only its bookmarks.
    static func itemRowLabel(_ row: FeedItemRowContent) -> String {
        // The title as the row shows it (the Leading articles setting).
        var parts = [row.rowTitle]
        if row.isPlayed { parts.append(playedNote(isArticle: row.isArticle)) }
        parts.append(row.state.spokenNote)
        if let reason = row.state.reason { parts.append(reason) }
        if let kept = row.kept { parts += kept.spokenParts }
        if row.isNew { parts.append(newNote) }
        if let date = row.dateText { parts.append(date) }
        if let duration = row.duration { parts.append(TimeFormatting.spoken(duration)) }
        return parts.joined(separator: ", ")
    }

    /// An item row's spoken hint, which says what its default action does:
    /// "Opens it" for a downloaded item; "Opens its book in your library" for
    /// one moved into the library (FR11, branch D); for one whose place was
    /// kept after its file went (`keptPlace`, FR11), "Downloads it again,
    /// then opens it where you left off"; for any other, "Downloads it, then
    /// opens it".
    static func itemRowHint(_ state: FeedItemState, keptPlace: Bool = false) -> String {
        if state.bookID != nil { return "Opens it" }
        if state.libraryBookID != nil { return "Opens its book in your library" }
        return keptPlace ? "Downloads it again, then opens it where you left off" : "Downloads it, then opens it"
    }

    // MARK: The Summary Bar

    /// What a feed's folder's summary bar shows and says before the time
    /// left in its downloads: the feed's items counted, and its last check.
    struct FolderSummary: Equatable, Sendable {
        /// The items counted: "10 of 381 episodes listed, 3 downloaded, 2
        /// new".
        let counts: String
        /// The last check.
        let check: Check
    }
}
