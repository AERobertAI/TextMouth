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

    // MARK: - A Run of Downloads

    /// A run counts its downloads done of the total, names the one under
    /// way with its feed and how far its file has come, then that its book
    /// is being added, and, once one has finished, the time left, by bytes
    /// where sizes are known; it ends with its last download.
    func testARunCountsItsDownloadsAndNamesTheOneUnderWay() {
        let clock = CommandClock()
        let progress = FeedDownloadProgress(now: { clock.now })
        let none = FeedDownloadWaits()
        progress.update(queued: [63_000_000, 63_000_000, nil], waits: none)
        XCTAssertTrue(progress.state.isRunning)
        XCTAssertEqual(progress.state.lines(at: clock.now), ["0 of 3 done"])

        progress.begin(title: "Ep. 368", feedTitle: "Finish It!", transfer: Self.transfer(0, of: 63_000_000), queued: [63_000_000, nil], waits: none)
        XCTAssertEqual(progress.state.total, 3)
        XCTAssertEqual(
            progress.state.lines(at: clock.now),
            ["0 of 3 done", "Download 1 of 3: “Ep. 368” from Finish It!, 0% of 63 MB"],
            "no time left before a download has finished"
        )
        progress.receive(Self.transfer(25_200_000, of: 63_000_000))
        XCTAssertEqual(progress.state.lines(at: clock.now).last, "Download 1 of 3: “Ep. 368” from Finish It!, 40% of 63 MB")
        XCTAssertEqual(progress.state.fractionDone, 0.4 / 3, accuracy: 0.0001)
        progress.receive(Self.transfer(63_000_000, of: 63_000_000))
        progress.beginAddingToLibrary()
        progress.receive(Self.transfer(1_000, of: 63_000_000))
        XCTAssertEqual(
            progress.state.lines(at: clock.now).last,
            "Download 1 of 3: “Ep. 368” from Finish It!, adding it to the library",
            "a late report of the bytes undid the import"
        )

        // 63 MB in 30 seconds; the second episode at that rate and the
        // article at the average: about a minute.
        clock.advance(by: 30)
        progress.end(.downloaded, queued: [63_000_000, nil], waits: none)
        progress.begin(title: "Ep. 369", feedTitle: "Finish It!", transfer: Self.transfer(0, of: 63_000_000), queued: [nil], waits: none)
        XCTAssertEqual(progress.state.lines(at: clock.now), [
            "1 of 3 done",
            "Download 2 of 3: “Ep. 369” from Finish It!, 0% of 63 MB",
            "About 1 minute left",
        ])
        clock.advance(by: 15)
        progress.receive(Self.transfer(31_500_000, of: 63_000_000))
        XCTAssertEqual(progress.state.lines(at: clock.now).last, "Less than a minute left")

        progress.end(.failed, queued: [nil], waits: none)
        progress.begin(title: "How the Fed sets rates", feedTitle: "Planet Money", transfer: nil, queued: [], waits: none)
        XCTAssertEqual(progress.state.lines(at: clock.now), [
            "2 of 3 done, 1 failed",
            "Download 3 of 3: “How the Fed sets rates” from Planet Money",
            "Less than a minute left",
        ])
        XCTAssertEqual(
            progress.state.spokenStatus(at: clock.now),
            "Feed Downloads: 2 of 3 done, 1 failed. Download 3 of 3: “How the Fed sets rates” from Planet Money. Less than a minute left."
        )

        progress.end(.downloaded, queued: [], waits: none)
        XCTAssertFalse(progress.state.isRunning)
        XCTAssertEqual(progress.state, FeedDownloadProgressState(), "the run that ended was not forgotten")
        XCTAssertEqual(progress.state.lines(at: clock.now), [])
    }

    /// A download put off to wait, or stopped, leaves the run's count; the
    /// downloads waiting apart are counted by their reason, outlast the run,
    /// and are said when no download runs.
    func testWaitingAndStoppedDownloadsLeaveTheRunAndTheWaitsOutlastIt() {
        let clock = CommandClock()
        let progress = FeedDownloadProgress(now: { clock.now })
        let network = FeedDownloadWaits(network: 1)
        progress.update(queued: [nil, nil], waits: FeedDownloadWaits())
        progress.begin(title: "Ep. 1", feedTitle: "Finish It!", transfer: nil, queued: [nil], waits: FeedDownloadWaits())

        progress.end(.waiting, queued: [nil], waits: network)
        XCTAssertEqual(progress.state.total, 1)
        XCTAssertEqual(progress.state.lines(at: clock.now), ["0 of 1 done", "1 waiting for a network without data limits"])

        progress.begin(title: "Ep. 2", feedTitle: "Finish It!", transfer: nil, queued: [], waits: network)
        progress.end(.stopped, queued: [], waits: network)
        XCTAssertFalse(progress.state.isRunning)
        XCTAssertEqual(progress.state.waits, network)
        XCTAssertEqual(progress.spokenStatus(), "No feed download is under way. 1 waiting for a network without data limits.")
    }

    /// A download's bytes change the progress without publishing it, so its
    /// many reports redraw nothing; every other change publishes once, and
    /// a report that changes nothing publishes nothing.
    func testADownloadsBytesPublishNothing() {
        let progress = FeedDownloadProgress()
        var publishes = 0
        let watcher = progress.objectWillChange.sink { publishes += 1 }
        defer { watcher.cancel() }

        progress.begin(title: "Ep. 368", feedTitle: "Finish It!", transfer: Self.transfer(0, of: 63_000_000), queued: [], waits: FeedDownloadWaits())
        XCTAssertEqual(publishes, 1)
        for megabytes in 1...60 {
            progress.receive(Self.transfer(Int64(megabytes) * 1_000_000, of: 63_000_000))
        }
        XCTAssertEqual(publishes, 1, "a download's bytes published the progress")
        XCTAssertEqual(progress.state.download?.transfer?.completedBytes, 60_000_000)

        progress.update(queued: [], waits: FeedDownloadWaits())
        XCTAssertEqual(publishes, 1, "a change of nothing published")
        progress.beginAddingToLibrary()
        progress.end(.downloaded, queued: [], waits: FeedDownloadWaits())
        XCTAssertEqual(publishes, 3)
    }

    // MARK: - What VoiceOver Hears

    /// A run that ends within 10 seconds is heard nothing unasked, as a
    /// short import is not.
    func testAShortRunIsHeardNothingUnasked() {
        let clock = CommandClock()
        let progress = FeedDownloadProgress(now: { clock.now })

        let recorder = recordingAnnouncements {
            Self.run(progress, downloads: 4, seconds: 2, clock: clock)
        }

        XCTAssertEqual(recorder.announcements, [])
    }

    /// A run that lasts is heard at each quarter of its downloads, once, at
    /// medium priority, with the time left, and at its end, at once.
    func testALongRunIsHeardAtEachQuarterAndAtItsEnd() {
        let clock = CommandClock()
        let progress = FeedDownloadProgress(now: { clock.now })

        // 60 MB a minute: each of the eight episodes takes a minute.
        let recorder = recordingAnnouncements {
            Self.run(progress, downloads: 8, seconds: 60, bytes: 60_000_000, clock: clock)
        }

        XCTAssertEqual(recorder.announcements.map(\.message), [
            "Feed downloads: 2 of 8 done, about 6 minutes left.",
            "Feed downloads: 4 of 8 done, about 4 minutes left.",
            "Feed downloads: 6 of 8 done, about 2 minutes left.",
            "Feed downloads finished: 8 downloaded.",
        ])
        XCTAssertEqual(recorder.announcements.map(\.priority), [.medium, .medium, .medium, .high])
    }

    /// A quarter reached while the run was still short passes silently and
    /// is never said later; the next quarter is.
    func testAQuarterReachedEarlyPassesSilently() {
        let clock = CommandClock()
        let progress = FeedDownloadProgress(now: { clock.now })

        let recorder = recordingAnnouncements {
            progress.update(queued: Array(repeating: nil, count: 4), waits: FeedDownloadWaits())
            for (number, seconds) in [(1, 1.0), (2, 20.0), (3, 1.0), (4, 1.0)] {
                progress.begin(title: "Item \(number)", feedTitle: "Notes", transfer: nil, queued: Array(repeating: nil, count: 4 - number), waits: FeedDownloadWaits())
                clock.advance(by: seconds)
                progress.end(.downloaded, queued: Array(repeating: nil, count: 4 - number), waits: FeedDownloadWaits())
            }
        }

        XCTAssertEqual(recorder.announcements.map(\.message), [
            "Feed downloads: 2 of 4 done, less than a minute left.",
            "Feed downloads: 3 of 4 done, less than a minute left.",
            "Feed downloads finished: 4 downloaded.",
        ])
    }

    /// The end of a run of one download that lasted names it, downloaded or
    /// failed, with the downloads left waiting; a run whose one download was
    /// stopped says nothing.
    func testTheEndOfALongRunOfOneDownloadNamesIt() {
        let clock = CommandClock()
        let progress = FeedDownloadProgress(now: { clock.now })

        let recorder = recordingAnnouncements {
            for (title, ending) in [("Ep. 368", FeedDownloadEnding.downloaded), ("Ep. 369", .failed), ("Ep. 370", .stopped)] {
                progress.begin(title: title, feedTitle: "Finish It!", transfer: nil, queued: [], waits: FeedDownloadWaits(room: 1))
                clock.advance(by: 12)
                progress.end(ending, queued: [], waits: ending == .stopped ? FeedDownloadWaits() : FeedDownloadWaits(room: 1))
            }
        }

        XCTAssertEqual(recorder.announcements.map(\.message), [
            "Finished downloading “Ep. 368”. 1 waiting for room on this Mac.",
            "Could not download “Ep. 369”. 1 waiting for room on this Mac.",
        ])
    }

    /// Cancel is heard at once with what it stopped, and the section says
    /// the downloads are cancelling in place of the time left; the run then
    /// ends without announcing its end. Cancel with no run says none is
    /// under way, and changes nothing.
    func testCancelIsHeardAtOnceAndTheRunEndsQuietly() {
        let clock = CommandClock()
        let progress = FeedDownloadProgress(now: { clock.now })

        let recorder = recordingAnnouncements {
            progress.cancel(stopped: [], finishing: nil)
            XCTAssertEqual(progress.state, FeedDownloadProgressState())

            Self.run(progress, downloads: 1, seconds: 20, clock: clock)
            progress.begin(title: "Ep. 370", feedTitle: "Finish It!", transfer: nil, queued: [nil, nil], waits: FeedDownloadWaits(network: 2))
            clock.advance(by: 20)
            progress.cancel(stopped: ["Ep. 370", "Ep. 371", "Ep. 372"], finishing: nil)
            XCTAssertEqual(progress.state.lines(at: clock.now), [
                "0 of 3 done",
                "Download 1 of 3: “Ep. 370” from Finish It!",
                "Cancelling...",
                "2 waiting for a network without data limits",
            ])
            progress.update(queued: [], waits: FeedDownloadWaits(network: 2))
            progress.end(.stopped, queued: [], waits: FeedDownloadWaits(network: 2))
        }

        XCTAssertEqual(recorder.announcements.map(\.message), [
            "No feed download is under way.",
            "Finished downloading “Item 1”.",
            "Stopped 3 feed downloads. 2 still waiting for a network without data limits.",
        ])
        XCTAssertEqual(recorder.announcements.map(\.priority), [.high, .high, .high])
        XCTAssertFalse(progress.state.isRunning)
        XCTAssertFalse(progress.state.isCancelling, "Cancel outlasted its run")
    }

    /// A download asked for after Cancel, while the one Cancel let finish was
    /// still being added, ends the cancelling as it begins: the section no
    /// longer says "Cancelling...", and its Cancel is offered again (feed
    /// review item 13).
    func testADownloadBegunAfterCancelEndsTheCancelling() {
        let clock = CommandClock()
        let progress = FeedDownloadProgress(now: { clock.now })
        let none = FeedDownloadWaits()

        _ = recordingAnnouncements {
            progress.begin(title: "Ep. 370", feedTitle: "Finish It!", transfer: nil, queued: [], waits: none)
            progress.beginAddingToLibrary()
            progress.cancel(stopped: [], finishing: "Ep. 370")
            XCTAssertTrue(progress.state.isCancelling)
            // The listener asks for another while the first is being added.
            progress.update(queued: [nil], waits: none)
            progress.end(.downloaded, queued: [nil], waits: none)
            XCTAssertTrue(progress.state.isCancelling, "the cancelling ended before a download began")
            progress.begin(title: "Ep. 371", feedTitle: "Finish It!", transfer: nil, queued: [], waits: none)
        }

        XCTAssertTrue(progress.state.isRunning)
        XCTAssertFalse(progress.state.isCancelling, "Cancelling outlasted the downloads it stopped")
        XCTAssertFalse(progress.state.lines(at: clock.now).contains(FeedDownloadProgressWording.cancelling))
    }

    /// As TextMouth quits, the progress shows nothing and says nothing, and
    /// a download that stops afterwards changes nothing.
    func testQuittingClearsTheProgressWithoutAWord() {
        let clock = CommandClock()
        let progress = FeedDownloadProgress(now: { clock.now })

        let recorder = recordingAnnouncements {
            progress.begin(title: "Ep. 368", feedTitle: "Finish It!", transfer: nil, queued: [nil], waits: FeedDownloadWaits())
            clock.advance(by: 60)
            progress.clear()
            progress.end(.stopped, queued: [], waits: FeedDownloadWaits())
        }

        XCTAssertEqual(recorder.announcements, [])
        XCTAssertEqual(progress.state, FeedDownloadProgressState())
    }

    /// Speak Download Progress says every line the section shows while
    /// downloads run, the bytes of the one under way as they are now.
    func testSpeakingTheProgressSaysEveryLineWithTheBytesAsTheyAreNow() {
        let clock = CommandClock()
        let progress = FeedDownloadProgress(now: { clock.now })
        progress.begin(
            title: "Ep. 368",
            feedTitle: "Finish It!",
            transfer: Self.transfer(0, of: 63_000_000),
            queued: [nil],
            waits: FeedDownloadWaits(room: 1)
        )
        progress.receive(Self.transfer(25_200_000, of: 63_000_000))

        XCTAssertEqual(
            progress.spokenStatus(),
            "Feed Downloads: 0 of 2 done. Download 1 of 2: “Ep. 368” from Finish It!, 40% of 63 MB. 1 waiting for room on this Mac."
        )
    }

    // MARK: - Fixtures

    /// A file's progress: `written` bytes of `total`, 0 when no size is
    /// known, as the download manager counts it.
    static func transfer(_ written: Int64, of total: Int64) -> BookDownloadProgress {
        BookDownloadProgress(completedFiles: 0, totalFiles: 1, completedBytes: written, totalBytes: total)
    }

    /// Runs `downloads` downloads through `progress`, one after another, each
    /// taking `seconds` on `clock` and bringing `bytes` (none, as an
    /// article's page, by default), each named "Item" and its number.
    static func run(_ progress: FeedDownloadProgress, downloads: Int, seconds: TimeInterval, bytes: Int64 = 0, clock: CommandClock) {
        let none = FeedDownloadWaits()
        let size: Int64? = bytes > 0 ? bytes : nil
        progress.update(queued: Array(repeating: size, count: downloads), waits: none)
        for number in 1...downloads {
            let left = Array(repeating: size, count: downloads - number)
            progress.begin(title: "Item \(number)", feedTitle: "Notes", transfer: size.map { transfer(0, of: $0) }, queued: left, waits: none)
            clock.advance(by: seconds)
            if let size {
                progress.receive(transfer(size, of: size))
            }
            progress.end(.downloaded, queued: left, waits: none)
        }
    }
}
