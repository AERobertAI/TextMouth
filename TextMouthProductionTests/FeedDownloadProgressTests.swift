import XCTest
@testable import TextMouth

/// The feed downloads' progress (FR10's feed half): the words the Library
/// window's feed downloads section shows and VoiceOver reads, and the time
/// the downloads have left, estimated by size where sizes are known.
@MainActor
final class FeedDownloadProgressTests: XCTestCase {

    // MARK: - The Section's Lines

    /// The count says the downloads done of the total, those that failed
    /// among them when any did.
    func testTheCountSaysTheDownloadsDoneAndThoseThatFailed() {
        XCTAssertEqual(FeedDownloadProgressWording.count(done: 3, of: 9, failed: 0), "3 of 9 done")
        XCTAssertEqual(FeedDownloadProgressWording.count(done: 3, of: 9, failed: 1), "3 of 9 done, 1 failed")
        XCTAssertEqual(FeedDownloadProgressWording.count(done: 0, of: 1, failed: 0), "0 of 1 done")
    }

    /// The download under way is named with its number among the run's
    /// downloads and its feed, then what it is doing, when there is
    /// something to say.
    func testTheItemLineNamesTheDownloadItsFeedAndWhatItIsDoing() {
        XCTAssertEqual(
            FeedDownloadProgressWording.item("Ep. 368", feed: "Finish It!", number: 3, of: 9, doing: "40% of 63 MB"),
            "Download 3 of 9: “Ep. 368” from Finish It!, 40% of 63 MB"
        )
        XCTAssertEqual(
            FeedDownloadProgressWording.item("How the Fed sets rates", feed: "Planet Money", number: 1, of: 1, doing: nil),
            "Download 1 of 1: “How the Fed sets rates” from Planet Money"
        )
        XCTAssertEqual(FeedDownloadProgressWording.addingToLibrary, "adding it to the library")
    }

    /// A file's progress is its percent of the size the server or the feed
    /// gives, never 100 before its book is in; the bytes alone when no size
    /// is known; and nothing before the first byte of a file of unknown
    /// size.
    func testAFilesProgressIsItsPercentOfItsSizeOrItsBytesSoFar() {
        XCTAssertEqual(FeedDownloadProgressWording.transfer(Self.transfer(25_200_000, of: 63_000_000)), "40% of 63 MB")
        XCTAssertEqual(FeedDownloadProgressWording.transfer(Self.transfer(0, of: 63_000_000)), "0% of 63 MB")
        XCTAssertEqual(
            FeedDownloadProgressWording.transfer(Self.transfer(63_000_000, of: 63_000_000)),
            "99% of 63 MB",
            "100 percent was said before the book was in the library"
        )
        XCTAssertEqual(FeedDownloadProgressWording.transfer(Self.transfer(12_000_000, of: 0)), "12 MB so far")
        XCTAssertNil(FeedDownloadProgressWording.transfer(Self.transfer(0, of: 0)))
    }

    /// The downloads waiting apart are counted by their reason, a line for
    /// each reason with any.
    func testWaitingDownloadsAreCountedApartByTheirReason() {
        XCTAssertEqual(
            FeedDownloadProgressWording.waits(FeedDownloadWaits(network: 2, room: 1)),
            ["2 waiting for a network without data limits", "1 waiting for room on this Mac"]
        )
        XCTAssertEqual(FeedDownloadProgressWording.waits(FeedDownloadWaits(network: 0, room: 3)), ["3 waiting for room on this Mac"])
        XCTAssertEqual(FeedDownloadProgressWording.waits(FeedDownloadWaits()), [])
        XCTAssertTrue(FeedDownloadWaits().isEmpty)
        XCTAssertFalse(FeedDownloadWaits(network: 1).isEmpty)
    }

    // MARK: - What VoiceOver Reads

    /// VoiceOver reads the section's title, then every line it shows as a
    /// sentence, as it reads the import overlay's; with no line, the title
    /// alone.
    func testVoiceOverReadsTheTitleThenEveryLine() {
        XCTAssertEqual(
            FeedDownloadProgressWording.spokenStatus([
                "2 of 9 done",
                "Download 3 of 9: “Ep. 368” from Finish It!, 40% of 63 MB",
                "About 4 minutes left",
                "2 waiting for a network without data limits",
            ]),
            "Feed Downloads: 2 of 9 done. Download 3 of 9: “Ep. 368” from Finish It!, 40% of 63 MB. About 4 minutes left. "
                + "2 waiting for a network without data limits."
        )
        XCTAssertEqual(FeedDownloadProgressWording.spokenStatus([]), "Feed Downloads")
        XCTAssertEqual(ImportProgressWording.spokenStatus(title: "Feed Downloads", lines: ["", "Cancelling..."]), "Feed Downloads: Cancelling...")
        XCTAssertEqual(ImportProgressWording.spokenStatus(["1 of 2 books processed"]), "Importing Books: 1 of 2 books processed.")
    }

    /// With no download under way, Speak Download Progress says so, and
    /// counts the downloads waiting apart.
    func testNoDownloadUnderWayIsSaidWithTheWaitingOnes() {
        XCTAssertEqual(FeedDownloadProgressWording.noneUnderWay(waits: FeedDownloadWaits()), "No feed download is under way.")
        XCTAssertEqual(
            FeedDownloadProgressWording.noneUnderWay(waits: FeedDownloadWaits(network: 2)),
            "No feed download is under way. 2 waiting for a network without data limits."
        )
    }

    // MARK: - What VoiceOver Hears Unasked

    /// Each quarter is said with the downloads done and, when there is one,
    /// the time left.
    func testAQuarterSaysTheDownloadsDoneAndTheTimeLeft() {
        XCTAssertEqual(
            FeedDownloadProgressWording.quarter(done: 3, of: 12, failed: 0, secondsLeft: 240),
            "Feed downloads: 3 of 12 done, about 4 minutes left."
        )
        XCTAssertEqual(
            FeedDownloadProgressWording.quarter(done: 6, of: 12, failed: 1, secondsLeft: 20),
            "Feed downloads: 6 of 12 done, 1 failed, less than a minute left."
        )
        XCTAssertEqual(FeedDownloadProgressWording.quarter(done: 3, of: 12, failed: 0, secondsLeft: nil), "Feed downloads: 3 of 12 done.")
    }

    /// A run's end says how many downloaded and failed, only the counts that
    /// are not 0, or the one download by its title, then the downloads left
    /// waiting.
    func testTheEndSaysWhatDownloadedAndWhatStillWaits() {
        XCTAssertEqual(
            FeedDownloadProgressWording.finished(downloaded: 8, failed: 1, waits: FeedDownloadWaits(network: 2)),
            "Feed downloads finished: 8 downloaded, 1 failed. 2 waiting for a network without data limits."
        )
        XCTAssertEqual(
            FeedDownloadProgressWording.finished(downloaded: 9, failed: 0, waits: FeedDownloadWaits()),
            "Feed downloads finished: 9 downloaded."
        )
        XCTAssertEqual(
            FeedDownloadProgressWording.finished(downloaded: 0, failed: 0, waits: FeedDownloadWaits(room: 1)),
            "Feed downloads finished: none downloaded. 1 waiting for room on this Mac."
        )
        XCTAssertEqual(
            FeedDownloadProgressWording.finished(download: "Ep. 368", failed: false, waits: FeedDownloadWaits()),
            "Finished downloading “Ep. 368”."
        )
        XCTAssertEqual(
            FeedDownloadProgressWording.finished(download: "Ep. 368", failed: true, waits: FeedDownloadWaits()),
            "Could not download “Ep. 368”."
        )
    }

    /// Cancel says what it stopped: one download by its title, as Cancel
    /// Download says it, or how many; one that finishes all the same; and
    /// the downloads it leaves waiting.
    func testCancelSaysWhatItStoppedAndWhatStillWaits() {
        XCTAssertEqual(
            FeedDownloadProgressWording.cancelled(stopped: ["Ep. 368"], finishing: nil, waits: FeedDownloadWaits()),
            FeedWording.downloadCancelled(title: "Ep. 368")
        )
        XCTAssertEqual(
            FeedDownloadProgressWording.cancelled(stopped: ["Ep. 368"], finishing: nil, waits: FeedDownloadWaits()),
            "Stopped downloading “Ep. 368”."
        )
        XCTAssertEqual(
            FeedDownloadProgressWording.cancelled(
                stopped: ["1", "2", "3", "4", "5", "6"],
                finishing: "Ep. 370",
                waits: FeedDownloadWaits(network: 2, room: 1)
            ),
            "Stopped 6 feed downloads. “Ep. 370” is already being added to the library. "
                + "2 still waiting for a network without data limits. 1 still waiting for room on this Mac."
        )
        XCTAssertEqual(
            FeedDownloadProgressWording.cancelled(stopped: [], finishing: "Ep. 370", waits: FeedDownloadWaits()),
            "“Ep. 370” is already being added to the library."
        )
        XCTAssertEqual(
            FeedDownloadProgressWording.cancelled(stopped: [], finishing: nil, waits: FeedDownloadWaits()),
            "No feed download is under way."
        )
    }

    /// The section's Cancel button is named for what it cancels and says
    /// what it does and leaves; its bar is named too.
    func testTheCancelButtonSaysWhatItStopsAndWhatItLeaves() {
        XCTAssertEqual(FeedDownloadProgressWording.title, "Feed Downloads")
        XCTAssertEqual(FeedDownloadProgressWording.cancelButtonTitle, "Cancel")
        XCTAssertEqual(FeedDownloadProgressWording.cancelButtonLabel, "Cancel Feed Downloads")
        XCTAssertNotEqual(FeedDownloadProgressWording.cancelButtonLabel, ProgressOverlay.cancelButtonLabel)
        XCTAssertEqual(
            FeedDownloadProgressWording.cancelButtonHint,
            "Stops the downloads under way and waiting to start, and TextMouth won't start them again by itself. "
                + "Downloads waiting for a network or for room keep waiting."
        )
        XCTAssertEqual(FeedDownloadProgressWording.overallBarLabel, "All feed downloads")
        XCTAssertEqual(FeedDownloadProgressWording.cancelling, "Cancelling...")
        XCTAssertEqual(FeedDownloadProgressWording.refreshInterval, 5)
    }

    // MARK: - The Time Left

    /// Nothing is estimated before a download has finished, nor with
    /// nothing left.
    func testNoEstimateBeforeADownloadFinishesOrWithNothingLeft() {
        var timing = FeedDownloadTiming()
        XCTAssertNil(FeedDownloadTimeEstimate.secondsLeft(after: timing, for: [.init(bytes: 1_000_000)]))
        timing.add(seconds: 30, bytes: 60_000_000)
        XCTAssertNil(FeedDownloadTimeEstimate.secondsLeft(after: timing, for: []))
    }

    /// A download of known size takes its bytes at the rate the finished
    /// downloads of known size came at, the one under way only its bytes
    /// still to come.
    func testSizedDownloadsTakeTheirBytesAtTheRateSoFar() throws {
        var timing = FeedDownloadTiming()
        // 60 MB in 30 seconds: 2 MB a second.
        timing.add(seconds: 30, bytes: 60_000_000)

        let seconds = try XCTUnwrap(FeedDownloadTimeEstimate.secondsLeft(after: timing, for: [
            .init(bytes: 30_000_000, elapsed: 15),
            .init(bytes: 120_000_000),
        ]))

        XCTAssertEqual(seconds, 75, accuracy: 0.001)
        XCTAssertEqual(ImportProgressWording.timeLeft(seconds), "About 1 minute left")
    }

    /// An article, or an episode whose size nobody gives, takes the average
    /// time of a finished download, less the time it has run; a download of
    /// known size before any sized one finished does too.
    func testDownloadsOfUnknownSizeTakeTheAverageTime() throws {
        var timing = FeedDownloadTiming()
        timing.add(seconds: 2, bytes: 0)
        // Only an article finished: no rate yet, so the episode of known
        // size takes the average too.
        XCTAssertEqual(
            try XCTUnwrap(FeedDownloadTimeEstimate.secondsLeft(after: timing, for: [.init(bytes: 50_000_000)])),
            2,
            accuracy: 0.001
        )

        timing.add(seconds: 30, bytes: 60_000_000)
        // Average 16 seconds a download; 2 MB a second for sized ones.
        let seconds = try XCTUnwrap(FeedDownloadTimeEstimate.secondsLeft(after: timing, for: [
            .init(bytes: nil, elapsed: 6),
            .init(bytes: nil),
            .init(bytes: 60_000_000),
        ]))
        XCTAssertEqual(seconds, 10 + 16 + 30, accuracy: 0.001)

        // A download that has run past the average counts as nothing more.
        XCTAssertEqual(
            try XCTUnwrap(FeedDownloadTimeEstimate.secondsLeft(after: timing, for: [.init(bytes: nil, elapsed: 600)])),
            0,
            accuracy: 0.001
        )
    }

    /// A clock that moved back, or a time that is no number, is timed as no
    /// time, and a failed download is never timed (the caller adds only
    /// finished ones).
    func testTimesThatMakeNoSenseCountAsNone() {
        var timing = FeedDownloadTiming()
        timing.add(seconds: -5, bytes: 1_000)
        timing.add(seconds: .nan, bytes: 0)
        XCTAssertEqual(timing.downloads, 2)
        XCTAssertEqual(timing.seconds, 0)
        XCTAssertEqual(timing.sizedBytes, 1_000)
        XCTAssertEqual(timing.sizedSeconds, 0)
        // No seconds for any sized bytes: no rate, so the average, 0.
        XCTAssertEqual(FeedDownloadTimeEstimate.secondsLeft(after: timing, for: [.init(bytes: 5_000)]), 0)
    }

    // MARK: - Fixtures

    /// A file's progress: `written` bytes of `total`, 0 when no size is
    /// known, as the download manager counts it.
    static func transfer(_ written: Int64, of total: Int64) -> BookDownloadProgress {
        BookDownloadProgress(completedFiles: 0, totalFiles: 1, completedBytes: written, totalBytes: total)
    }
}
