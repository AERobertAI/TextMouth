import Foundation

// MARK: - Downloads Waiting Apart (FR10)

/// The newest-N rule's downloads that wait rather than run (FR11), counted
/// apart from the downloads under way by their reason (FR10): those put off
/// for a network without data limits, and those waiting for room on this
/// Mac. Each such item's row says "Waiting to Download" and why
/// (`FeedItemState.waiting`).
struct FeedDownloadWaits: Equatable, Sendable {
    /// The downloads waiting for a network without data limits.
    var network = 0
    /// The downloads waiting for room on this Mac.
    var room = 0

    /// Whether no download waits.
    var isEmpty: Bool {
        network == 0 && room == 0
    }
}

// MARK: - The Words (FR10)

/// The words of the feed downloads under way (FR10), kept in one place so
/// the Library window's feed downloads section, VoiceOver's announcements,
/// Speak Download Progress, and the tests say the same thing. Sizes and the
/// time left are worded as the import overlay words them
/// (`ImportProgressWording`).
enum FeedDownloadProgressWording {
    /// The section's title, which VoiceOver reads first.
    static let title = "Feed Downloads"
    /// What the section's count counts, after the downloads done of the
    /// total: "3 of 9 done". A download that failed is done too.
    static let countNoun = "done"
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
        let count = CountWording.progress(done, of: total, countNoun)
        return failed > 0 ? "\(count), \(failed) failed" : count
    }

    /// The download under way, its number among the run's downloads, its
    /// feed, and what it is doing, when there is something to say: "Download
    /// 3 of 9: “Ep. 368” from Finish It!, 40% of 63 MB".
    static func item(_ title: String, feed feedTitle: String, number: Int, of total: Int, doing activity: String?) -> String {
        let item = "Download \(number) of \(total): “\(title)” from \(feedTitle)"
        guard let activity else { return item }
        return "\(item), \(activity)"
    }

    /// How far a download's file has come: its percent of the size the
    /// server gives, or, before it does, the size its feed gives, "40% of
    /// 63 MB"; the bytes alone when neither gives a size, "12 MB so far";
    /// nil before any byte of a file of unknown size. VoiceOver reads "40%"
    /// as 40 percent.
    static func transfer(_ progress: BookDownloadProgress) -> String? {
        if progress.totalBytes > 0 {
            return "\(progress.percent)% of \(ImportProgressWording.size(progress.totalBytes))"
        }
        if progress.completedBytes > 0 {
            return "\(ImportProgressWording.size(progress.completedBytes)) so far"
        }
        return nil
    }

    /// What a download is doing once its file has come, or its article's
    /// page has been read: its book is being imported.
    static let addingToLibrary = "adding it to the library"

    /// What the section says once Cancel is pressed, in place of the time
    /// left, while the download under way, already being added to the
    /// library, finishes: the import overlay's words for the same moment.
    static let cancelling = ImportProgressWording.cancellingLine

    /// The downloads waiting apart, a line for each reason with any: "2
    /// waiting for a network without data limits", "1 waiting for room on
    /// this Mac".
    static func waits(_ waits: FeedDownloadWaits) -> [String] {
        waitLines(waits, still: false)
    }

    /// The waiting downloads' lines, with "still" before "waiting" when
    /// `still`, as said after Cancel, which leaves them waiting.
    private static func waitLines(_ waits: FeedDownloadWaits, still: Bool) -> [String] {
        let waiting = still ? "still waiting" : "waiting"
        var lines: [String] = []
        if waits.network > 0 {
            lines.append("\(waits.network) \(waiting) for a network without data limits")
        }
        if waits.room > 0 {
            lines.append("\(waits.room) \(waiting) for room on this Mac")
        }
        return lines
    }

    /// The waiting downloads' lines as sentences, to follow another.
    private static func waitSentences(_ waits: FeedDownloadWaits, still: Bool = false) -> [String] {
        waitLines(waits, still: still).map { "\($0)." }
    }

    // MARK: What VoiceOver Reads

    /// What VoiceOver reads for the section: the title, then each line it
    /// shows, as sentences, "Feed Downloads: 2 of 9 done. Download 3 of 9:
    /// “Ep. 368” from Finish It!, 40% of 63 MB. About 4 minutes left. 2
    /// waiting for a network without data limits."
    static func spokenStatus(_ lines: [String]) -> String {
        ImportProgressWording.spokenStatus(title: title, lines: lines)
    }

    /// What Speak Download Progress says while no download runs, with the
    /// downloads waiting apart, if any: "No feed download is under way. 2
    /// waiting for a network without data limits."
    static func noneUnderWay(waits: FeedDownloadWaits) -> String {
        ([noDownloadUnderWay] + waitSentences(waits)).joined(separator: " ")
    }

    /// The first sentence of what Speak Download Progress says while no
    /// download runs.
    static let noDownloadUnderWay = "No feed download is under way."

    // MARK: What VoiceOver Hears Unasked

    /// Announced as a run of downloads that has run long passes a quarter
    /// of its downloads: "Feed downloads: 3 of 12 done, about 4 minutes
    /// left." The time left is said when there is an estimate.
    static func quarter(done: Int, of total: Int, failed: Int, secondsLeft: TimeInterval?) -> String {
        "Feed downloads: \(count(done: done, of: total, failed: failed))\(timeLeftClause(secondsLeft))."
    }

    /// Announced once as a run TextMouth started by itself, which nobody
    /// heard begin, has run long, before any of its quarters: "Feed
    /// downloads: 9 under way, about 4 minutes left." (feed review item 17).
    /// `count` counts the downloads not yet done, the one under way among
    /// them; the time left is said when there is an estimate.
    static func underWay(_ count: Int, secondsLeft: TimeInterval?) -> String {
        "Feed downloads: \(count) under way\(timeLeftClause(secondsLeft))."
    }

    /// ", about 4 minutes left" for an estimate of `secondsLeft`, and
    /// nothing without one.
    private static func timeLeftClause(_ secondsLeft: TimeInterval?) -> String {
        secondsLeft.map { ", " + ImportProgressWording.lowercasedFirst(ImportProgressWording.timeLeft($0)) } ?? ""
    }

    /// Announced as a run of downloads that ran long ends: "Feed downloads
    /// finished: 8 downloaded, 1 failed." Only the counts that are not 0
    /// are said, or "none downloaded" when both are, and the downloads left
    /// waiting follow. Each failed item's row says why.
    static func finished(downloaded: Int, failed: Int, waits: FeedDownloadWaits) -> String {
        var counts: [String] = []
        if downloaded > 0 {
            counts.append("\(downloaded) downloaded")
        }
        if failed > 0 {
            counts.append("\(failed) failed")
        }
        let finished = "Feed downloads finished: \(counts.isEmpty ? "none downloaded" : counts.joined(separator: ", "))."
        return ([finished] + waitSentences(waits)).joined(separator: " ")
    }

    /// Announced as a run of one download that ran long ends: "Finished
    /// downloading “Ep. 368”.", or, when it failed, "Could not download
    /// “Ep. 368”.", whose row says why; the downloads left waiting follow.
    static func finished(download title: String, failed: Bool, waits: FeedDownloadWaits) -> String {
        let ending = failed ? "Could not download “\(title)”." : "Finished downloading “\(title)”."
        return ([ending] + waitSentences(waits)).joined(separator: " ")
    }

    /// Announced at once as Cancel stops the downloads: the one stopped by
    /// its title, as Cancel Download says it ("Stopped downloading
    /// “Ep. 368”."), or how many ("Stopped 6 feed downloads."); then the
    /// download that finishes all the same, `finishing`, because its book
    /// was already being added to the library; then the downloads Cancel
    /// leaves waiting for a network or for room. With nothing stopped and
    /// nothing finishing, no download was under way.
    static func cancelled(stopped titles: [String], finishing: String?, waits: FeedDownloadWaits) -> String {
        var sentences: [String] = []
        switch titles.count {
        case 0:
            if finishing == nil {
                sentences.append(noDownloadUnderWay)
            }
        case 1:
            sentences.append(FeedWording.downloadCancelled(title: titles[0]))
        default:
            sentences.append("Stopped \(titles.count) feed downloads.")
        }
        if let finishing {
            sentences.append("“\(finishing)” is already being added to the library.")
        }
        return (sentences + waitSentences(waits, still: true)).joined(separator: " ")
    }

    // MARK: The Section's Controls

    /// The Cancel button's title, beside the section's title.
    static let cancelButtonTitle = "Cancel"
    /// What VoiceOver calls the Cancel button: the import overlay has a
    /// Cancel too, so the name says what it cancels.
    static let cancelButtonLabel = "Cancel Feed Downloads"
    /// What VoiceOver says the Cancel button does: it stops the download
    /// under way and those waiting to start, whether the listener or the
    /// newest-N rule asked for them, and the rule never starts them again
    /// by itself (`FeedItem.downloadOrigin`); the rule's downloads waiting
    /// for a network or for room are left waiting.
    static let cancelButtonHint = "Stops the downloads under way and waiting to start, "
        + "and TextMouth won't start them again by itself. Downloads waiting for a network or for room keep waiting."
    /// What VoiceOver calls the section's bar, which counts every download
    /// of the run, the one under way by its bytes.
    static let overallBarLabel = "All feed downloads"
}
