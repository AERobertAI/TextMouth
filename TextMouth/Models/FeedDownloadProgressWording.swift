import Foundation

// MARK: - Downloads Waiting Apart (FR10)

/// The newest-N rule's downloads that wait rather than run (FR11), counted
/// apart from the downloads under way by their reason (FR10): those put off
/// until this Mac is on a network without data limits, and those waiting
/// for room on this Mac. Each such item's row says "Waiting to Download"
/// and why (`FeedItemState.waiting`).
struct FeedDownloadWaits: Equatable, Sendable {
    /// The downloads waiting until this Mac is on a network without data
    /// limits: offline, or on a network with them.
    var network = 0
    /// The downloads waiting for room on this Mac.
    var room = 0

    /// Whether no download waits.
    var isEmpty: Bool {
        network == 0 && room == 0
    }
}

// MARK: - What Cancel Stopped Comes Back (REV14 Feeds 5)

/// How the downloads the feed downloads section's Cancel stops come back
/// (`FeedCenter.comingBack(of:)`): those the newest-N rule downloads again
/// by itself once their feeds' next checks have ended, and those only the
/// listener's Download brings back, as a feed that downloads by hand, or
/// one unsubscribed from, never downloads by itself, nor does any feed an
/// item outside its newest, or one the listener made theirs.
struct FeedCancelReturn: Equatable, Sendable {
    /// The downloads the rule downloads again by itself.
    var byItself = 0
    /// The downloads only Download brings back.
    var byDownload = 0
}

// MARK: - The Words (FR10)

/// The words of the feed downloads under way (FR10), kept in one place so
/// the Library window's feed downloads section, VoiceOver's announcements,
/// Speak Download Progress, and the tests say the same thing. Sizes and the
/// time left are worded as the import overlay words them
/// (`ImportProgressWording`).
enum FeedDownloadProgressWording {
    /// The section's title, which VoiceOver reads first.
    static var title: String {
        // Translators: Title of the Library window's section that shows the feed downloads under way, which VoiceOver reads first. Title case.
        InterfaceText.line("feedDownloadProgress.title", "Feed Downloads")
    }
    /// How often the section shows its downloads' progress anew, in
    /// seconds: the bytes of the download under way come many times a
    /// second, and what a braille display shows and VoiceOver reads should
    /// change every few seconds, as the import overlay's time on a book
    /// does (`ImportProgressWording.timeOnBookStep`).
    static let refreshInterval: TimeInterval = ImportProgressWording.timeOnBookStep

    // MARK: The Section's Lines

    /// The downloads done of the total, as the section's count says it,
    /// with those that failed: "3 of 9 done", "3 of 9 done, 1 failed".
    static func count(done: Int, of total: Int, failed: Int) -> String {
        // A download that failed is done too.
        // Translators: The feed downloads section's count: how many downloads are done of the run's total. A download that failed is done too. The first %lld is the number done, the second the total.
        let count = InterfaceText.line("feedDownloadProgress.count", "\(number: done) of \(number: total) done")
        guard failed > 0 else { return count }
        // Translators: How many of the feed downloads of a run failed, after the count of those done: "3 of 9 done, 1 failed". %lld is the number that failed.
        let failedCount = InterfaceText.line("common.countFailed", "\(number: failed) failed")
        return SentenceWording.commaJoined([count, failedCount])
    }

    /// The download under way, its number among the run's downloads, its
    /// feed, and what it is doing, when there is something to say: "Download
    /// 3 of 9: “Ep. 368” from Finish It!, 40% of 63 MB".
    static func item(_ title: String, feed feedTitle: String, number: Int, of total: Int, doing activity: String?) -> String {
        // Translators: The feed download under way, in the feed downloads section: its number among the run's downloads, its title, and its feed. The first %lld is its number; the second is the run's total; the first %@ is the episode's or article's title; the second is the feed's title.
        let item = InterfaceText.line("feedDownloadProgress.item", "Download \(number: number) of \(number: total): “\(title)” from \(feedTitle)")
        guard let activity else { return item }
        return SentenceWording.commaJoined([item, activity])
    }

    /// How far a download's file has come: its percent of the size the
    /// server gives, or, before it does, the size its feed gives, "40% of
    /// 63 MB"; the bytes alone when neither gives a size, "12 MB so far";
    /// nil before any byte of a file of unknown size. VoiceOver reads "40%"
    /// as 40 percent.
    static func transfer(_ progress: BookDownloadProgress) -> String? {
        if progress.totalBytes > 0 {
            // Translators: How far a feed download's file has come, when its size is known. %lld is the percent done; %@ is the file's size with its unit, such as 63 MB.
            return InterfaceText.line("feedDownloadProgress.transfer.count", "\(number: progress.percent)% of \(ImportProgressWording.size(progress.totalBytes))")
        }
        if progress.completedBytes > 0 {
            // Translators: How far a feed download's file has come, when its size is not known. %@ is the bytes received so far with their unit, such as 12 MB.
            return InterfaceText.line("feedDownloadProgress.transfer.value", "\(ImportProgressWording.size(progress.completedBytes)) so far")
        }
        return nil
    }

    /// What a download is doing once its file has come, or its article's
    /// page has been read: its book is being imported.
    static var addingToLibrary: String {
        // Translators: What a feed download is doing once its file has come: it is being imported as a book. Follows the download's progress line after a comma. Lower case, without a full stop.
        InterfaceText.line("feedDownloadProgress.addingToLibrary", "adding it to the library")
    }

    /// What the section says once Cancel is pressed, in place of the time
    /// left, while the download under way, already being added to the
    /// library, finishes: the import overlay's words for the same moment.
    static let cancelling = ImportProgressWording.cancellingLine

    /// The downloads waiting apart, a line for each reason with any: "2
    /// waiting until this Mac is on a network without data limits", which
    /// covers a Mac offline too (REV13 item 4), "1 waiting for room on this
    /// Mac".
    /// On an iPhone (`isPhone`) the lines name "this iPhone".
    static func waits(_ waits: FeedDownloadWaits, isPhone: Bool = ThisDevice.isPhone) -> [String] {
        var lines: [String] = []
        if waits.network > 0, isPhone {
            // Translators: A line of the iPhone's feed downloads section: how many downloads wait for a network without data limits, which includes an iPhone that is offline. %lld is the number waiting.
            lines.append(InterfaceText.line("feedDownloadProgress.waits.networkPhone", "\(number: waits.network) waiting until this iPhone is on a network without data limits"))
        } else if waits.network > 0 {
            // Translators: A line of the feed downloads section: how many downloads wait for a network without data limits, which includes a Mac that is offline. %lld is the number waiting.
            lines.append(InterfaceText.line("feedDownloadProgress.waits.network", "\(number: waits.network) waiting until this Mac is on a network without data limits"))
        }
        if waits.room > 0, isPhone {
            // Translators: A line of the iPhone's feed downloads section: how many downloads wait for room in the iPhone's storage. %lld is the number waiting.
            lines.append(InterfaceText.line("feedDownloadProgress.waits.roomPhone", "\(number: waits.room) waiting for room on this iPhone"))
        } else if waits.room > 0 {
            // Translators: A line of the feed downloads section: how many downloads wait for room on this Mac's disk. %lld is the number waiting.
            lines.append(InterfaceText.line("feedDownloadProgress.waits.room", "\(number: waits.room) waiting for room on this Mac"))
        }
        return lines
    }

    /// The waiting downloads' lines as sentences, to follow another.
    private static func waitSentences(_ waits: FeedDownloadWaits) -> [String] {
        Self.waits(waits).map {
            // Translators: Ends a line about waiting downloads as a sentence of its own. %@ is the line, such as "2 waiting for room on this Mac".
            InterfaceText.line("common.valuePeriod", "\($0).")
        }
    }

    // MARK: What VoiceOver Reads

    /// What VoiceOver reads for the section: the title, then each line it
    /// shows, as sentences, "Feed Downloads: 2 of 9 done. Download 3 of 9:
    /// “Ep. 368” from Finish It!, 40% of 63 MB. About 4 minutes left. 2
    /// waiting until this Mac is on a network without data limits."
    static func spokenStatus(_ lines: [String]) -> String {
        ImportProgressWording.spokenStatus(title: title, lines: lines)
    }

    /// What Speak Download Progress says while no download runs, with the
    /// downloads waiting apart, if any: "No feed download is under way. 2
    /// waiting until this Mac is on a network without data limits."
    static func noneUnderWay(waits: FeedDownloadWaits) -> String {
        SentenceWording.joined([noDownloadUnderWay] + waitSentences(waits))
    }

    /// The first sentence of what Speak Download Progress says while no
    /// download runs.
    static var noDownloadUnderWay: String {
        // Translators: What Speak Download Progress says while no feed download runs.
        InterfaceText.line("feedDownloadProgress.noDownloadUnderWay", "No feed download is under way.")
    }

    // MARK: What VoiceOver Hears Unasked

    /// Announced as a run of downloads that has run long passes a quarter
    /// of its downloads: "Feed downloads: 3 of 12 done, about 4 minutes
    /// left." The time left is said when there is an estimate.
    static func quarter(done: Int, of total: Int, failed: Int, secondsLeft: TimeInterval?) -> String {
        let counted = count(done: done, of: total, failed: failed)
        guard let timeLeft = timeLeftPhrase(secondsLeft) else {
            // Translators: Announced as a long run of feed downloads passes a quarter of its downloads. %@ is the count, such as "3 of 12 done".
            return InterfaceText.line("feedDownloadProgress.quarter.count", "Feed downloads: \(counted).")
        }
        // Translators: Announced as a long run of feed downloads passes a quarter of its downloads. The first %@ is the count, such as "3 of 12 done"; the second is the time left, begun in lower case, such as "about 4 minutes left".
        return InterfaceText.line("feedDownloadProgress.quarter.countAndTimeLeft", "Feed downloads: \(counted), \(timeLeft).")
    }

    /// Announced once as a run TextMouth started by itself, which nobody
    /// heard begin, has run long, before any of its quarters: "Feed
    /// downloads: 9 under way, about 4 minutes left." (feed review item 17).
    /// `count` counts the downloads not yet done, the one under way among
    /// them; the time left is said when there is an estimate.
    static func underWay(_ count: Int, secondsLeft: TimeInterval?) -> String {
        guard let timeLeft = timeLeftPhrase(secondsLeft) else {
            // Translators: Announced once as a long run of feed downloads that TextMouth started itself is under way. %lld is how many downloads are not yet done.
            return InterfaceText.line("feedDownloadProgress.underWay.downloadsCount", "Feed downloads: \(number: count) under way.")
        }
        // Translators: Announced once as a long run of feed downloads that TextMouth started itself is under way. %lld is how many downloads are not yet done; %@ is the time left, begun in lower case, such as "about 4 minutes left".
        return InterfaceText.line("feedDownloadProgress.underWay.downloads", "Feed downloads: \(number: count) under way, \(timeLeft).")
    }

    /// "about 4 minutes left" for an estimate of `secondsLeft`, and nil
    /// without one.
    private static func timeLeftPhrase(_ secondsLeft: TimeInterval?) -> String? {
        secondsLeft.map { ImportProgressWording.lowercasedFirst(ImportProgressWording.timeLeft($0)) }
    }

    /// Announced as a run of downloads that ran long ends: "Feed downloads
    /// finished: 8 downloaded, 1 failed." Only the counts that are not 0
    /// are said, or "none downloaded" when both are, and the downloads left
    /// waiting follow. Each failed item's row says why.
    static func finished(downloaded: Int, failed: Int, waits: FeedDownloadWaits) -> String {
        var counts: [String] = []
        if downloaded > 0 {
            // Translators: How many feed downloads of a run finished, in the announcement that the run ended. %lld is the number downloaded.
            counts.append(InterfaceText.line("common.countDownloaded", "\(number: downloaded) downloaded"))
        }
        if failed > 0 {
            // Translators: How many of the feed downloads of a run failed, after the count of those done: "3 of 9 done, 1 failed". %lld is the number that failed.
            counts.append(InterfaceText.line("common.countFailed", "\(number: failed) failed"))
        }
        let what = counts.isEmpty
            // Translators: What the announcement that a run of feed downloads ended says when no download finished. Lower case.
            ? InterfaceText.line("feedDownloadProgress.finished.downloaded", "none downloaded")
            : SentenceWording.commaJoined(counts)
        // Translators: Announced as a long run of feed downloads ends. %@ is the counts, such as "8 downloaded, 1 failed", or "none downloaded".
        let finished = InterfaceText.line("feedDownloadProgress.finished.downloads", "Feed downloads finished: \(what).")
        return SentenceWording.joined([finished] + waitSentences(waits))
    }

    /// Announced as a run of one download that ran long ends: "Finished
    /// downloading “Ep. 368”.", or, when it failed, "Could not download
    /// “Ep. 368”.", whose row says why; the downloads left waiting follow.
    static func finished(download title: String, failed: Bool, waits: FeedDownloadWaits) -> String {
        let ending = failed
            // Translators: Announced as a long run of one feed download ends in failure. %@ is the episode's or article's title. Its row says why.
            ? InterfaceText.line("feedDownloadProgress.finished.failed", "Could not download “\(title)”.")
            // Translators: Announced as a long run of one feed download ends. %@ is the episode's or article's title.
            : InterfaceText.line("feedDownloadProgress.finished.downloading", "Finished downloading “\(title)”.")
        return SentenceWording.joined([ending] + waitSentences(waits))
    }

    /// Announced as Cancel stops the downloads (FR14), once VoiceOver's
    /// focus has moved to the list (REV13 item 3): the one stopped by its
    /// title, as Cancel Download says it ("Stopped downloading
    /// “Ep. 368”."), or how many ("Stopped 6 feed downloads."), the rule's
    /// waiting ones among them; then the download that finishes all the
    /// same, `finishing`, because its book was already being added to the
    /// library; then, with anything stopped, how what stopped comes back,
    /// as `comingBack` counts it (`comingBack(_:)`, REV14 feeds 5). With
    /// nothing stopped and nothing finishing, no download was under way.
    static func cancelled(stopped titles: [String], finishing: String?, comingBack: FeedCancelReturn) -> String {
        var sentences: [String] = []
        switch titles.count {
        case 0:
            if finishing == nil {
                sentences.append(noDownloadUnderWay)
            }
        case 1:
            sentences.append(FeedWording.downloadCancelled(title: titles[0]))
        default:
            // Translators: Announced as Cancel stops several feed downloads. %lld is how many, the rule's waiting downloads among them.
            sentences.append(InterfaceText.line("feedDownloadProgress.cancelled.other", "Stopped \(number: titles.count) feed downloads."))
        }
        if let finishing {
            // As Cancel Download says it when it comes too late.
            sentences.append(FeedWording.alreadyBeingAdded(title: finishing))
        }
        if let back = Self.comingBack(comingBack) {
            sentences.append(back)
        }
        return SentenceWording.joined(sentences)
    }

    /// How the downloads Cancel stops come back, as `comingBack` counts them
    /// (REV14 feeds 5), said only of what will happen: when the newest-N
    /// rule downloads every one again by itself, that it does
    /// (`retryAfterCancel`); when it downloads none, that Download gets them
    /// back; when it downloads some, how many, and that Download gets back
    /// the others; nil when nothing stopped.
    static func comingBack(_ comingBack: FeedCancelReturn) -> String? {
        // The name of the command the listener chooses, as its menu shows it.
        let downloadName = FeedWording.title(of: .download, isArticle: false)
        switch (comingBack.byItself, comingBack.byDownload) {
        case (0, 0):
            return nil
        case (_, 0):
            return retryAfterCancel
        case (0, let byDownload):
            return byDownload == 1
                // Translators: After Cancel stops one feed download that only the listener's Download brings back. %@ is the name of the Download command.
                ? InterfaceText.line("feedDownloadProgress.comingBack.chooseRow", "To download it again, choose \(downloadName) on its row.")
                // Translators: After Cancel stops several feed downloads that only the listener's Download brings back. %@ is the name of the Download command.
                : InterfaceText.line("feedDownloadProgress.comingBack.rows", "To download them again, choose \(downloadName) on their rows.")
        case let (byItself, byDownload):
            let again = byItself == 1
                // Translators: After Cancel stops feed downloads, exactly one of which TextMouth downloads again by itself.
                ? InterfaceText.line("feedDownloadProgress.comingBack.check", "TextMouth downloads 1 of them again at its feed's next check, or the next time it opens.")
                // Translators: After Cancel stops feed downloads, several of which TextMouth downloads again by itself. %lld is how many of them it downloads again.
                : InterfaceText.line("feedDownloadProgress.comingBack.checks", "TextMouth downloads \(number: byItself) of them again at their feeds' next checks, or the next time it opens.")
            let others = byDownload == 1
                // Translators: After Cancel stops feed downloads, the one other of which only the listener's Download brings back. %@ is the name of the Download command.
                ? InterfaceText.line("feedDownloadProgress.comingBack.otherOne", "To download the other one again, choose \(downloadName) on its row.")
                // Translators: After Cancel stops feed downloads, the rest of which only the listener's Download brings back. The first %lld is how many; %@ is the name of the Download command.
                : InterfaceText.line("feedDownloadProgress.comingBack.other", "To download the other \(number: byDownload) again, choose \(downloadName) on their rows.")
            return SentenceWording.joined([again, others])
        }
    }

    /// When TextMouth downloads again by itself what Cancel stopped (FR14),
    /// when the newest-N rule downloads every one of them by itself: the
    /// rule's next pass after each feed's next check, never sooner, or the
    /// first pass when TextMouth next opens.
    static var retryAfterCancel: String {
        // Translators: After Cancel stops feed downloads that the newest-N rule downloads again by itself.
        InterfaceText.line("feedDownloadProgress.retryAfterCancel", "TextMouth downloads each feed's newest again at its next check, or the next time it opens.")
    }

    // MARK: The Section's Controls

    /// The Cancel button's title, beside the section's title.
    static var cancelButtonTitle: String {
        // Translators: Title of the feed downloads section's button that stops the feed downloads.
        InterfaceText.line("common.cancel", "Cancel")
    }
    /// What VoiceOver calls the Cancel button: the import overlay has a
    /// Cancel too, so the name says what it cancels.
    static var cancelButtonLabel: String {
        // Translators: What VoiceOver calls the Cancel button of the feed downloads section; the import overlay has a Cancel too, so the name says what it cancels. Title case.
        InterfaceText.line("feedDownloadProgress.cancelButtonLabel", "Cancel Feed Downloads")
    }

    /// What VoiceOver says the Cancel button does (FR14): it stops every
    /// feed download, whoever asked for it, the rule's waiting for a network
    /// or for room too, and deletes what they had downloaded; then how what
    /// it would stop now comes back, as `comingBack` counts it and Cancel
    /// would say it (`comingBack(_:)`, REV14 feeds 5).
    static func cancelButtonHint(_ comingBack: FeedCancelReturn) -> String {
        // Translators: What VoiceOver says the feed downloads section's Cancel button does: it stops every feed download and deletes what they had downloaded.
        let stops = InterfaceText.line("feedDownloadProgress.cancelButtonHint", "Stops every feed download, including those waiting, and deletes what they had downloaded.")
        guard let back = Self.comingBack(comingBack) else { return stops }
        return SentenceWording.joined([stops, back])
    }

    /// What VoiceOver calls the section's bar, which counts every download
    /// of the run, the one under way by its bytes.
    static var overallBarLabel: String {
        // Translators: What VoiceOver calls the feed downloads section's bar, which counts every download of the run.
        InterfaceText.line("feedDownloadProgress.overallBarLabel", "All feed downloads")
    }
}
