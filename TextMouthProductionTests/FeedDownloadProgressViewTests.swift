import AppKit
import XCTest
@testable import TextMouth

/// The feed downloads' progress as the listener meets it (FR10's feed
/// half): Speak Download Progress, an action with no key of its own and a
/// Library menu command beside Speak Import Progress, which speaks every
/// line of the feed downloads section from any window; and the library's
/// Cancel, which the section's button calls.
@MainActor
final class FeedDownloadProgressViewTests: XCTestCase {

    // MARK: - Speak Download Progress

    /// The action is "Speak Download Progress" (config.json's key for it),
    /// in the app's scope, so the key the user gives it works from any
    /// window but the audio editor's, listed in Settings under Information
    /// right after Speak Import Progress, with no key until the user gives
    /// it one, and it posts its own notification.
    func testSpeakDownloadProgressIsAnActionWithNoKeyAfterSpeakImportProgress() {
        let action = ShortcutAction.speakDownloadProgress
        XCTAssertEqual(action.rawValue, "Speak Download Progress")
        XCTAssertEqual(action.title, "Speak Download Progress")
        XCTAssertEqual(ShortcutAction(rawValue: "Speak Download Progress"), .speakDownloadProgress)
        XCTAssertEqual(ShortcutAction.defaultBindings[action], [])
        XCTAssertEqual(action.defaultScope, .app)
        XCTAssertEqual(action.availableScopes, [.app, .library, .reader])
        XCTAssertFalse(action.isKeyEquivalent)
        XCTAssertEqual(action.category, "Information")
        XCTAssertEqual(action.notificationName, .speakDownloadProgress)
        XCTAssertEqual(Notification.Name.speakDownloadProgress.rawValue, "speakDownloadProgress")
        let all = ShortcutAction.allCases
        XCTAssertEqual(all.firstIndex(of: action), all.firstIndex(of: .speakImportProgress).map { $0 + 1 })
    }

    /// The Library menu, the one shown while a Library window is key,
    /// offers Speak Download Progress right after Speak Import Progress,
    /// named as the action is.
    func testTheLibraryMenuOffersSpeakDownloadProgressAfterSpeakImportProgress() throws {
        let mainMenu = try XCTUnwrap(NSApp.mainMenu)
        let library = try XCTUnwrap(mainMenu.items.first { $0.title == "Library" }?.submenu, "no Library menu")
        let titles = library.items.map(\.title)
        let imports = try XCTUnwrap(titles.firstIndex(of: ShortcutAction.speakImportProgress.title), titles.joined(separator: ", "))
        // A slice, which never traps, of the one item after it.
        XCTAssertEqual(Array(titles.dropFirst(imports + 1).prefix(1)), [ShortcutAction.speakDownloadProgress.title], titles.joined(separator: ", "))
    }

    /// Speak Download Progress has VoiceOver speak every line the feed
    /// downloads section shows, at once, the bytes of the download under
    /// way as they are now; with no download under way, it says so.
    func testSpeakDownloadProgressSpeaksTheSectionsLines() throws {
        let world = try FeedTestWorld(self, label: "FeedProgressSpeak")
        let progress = world.library.feedDownloadProgress
        XCTAssertTrue(progress === world.center.downloads.progress, "the library spoke another engine's downloads")

        let recorder = recordingAnnouncements {
            world.library.speakDownloadProgress()
            progress.begin(
                title: "Ep. 368",
                feedTitle: "Finish It!",
                transfer: FeedDownloadProgressTests.transfer(0, of: 63_000_000),
                queued: [],
                waits: FeedDownloadWaits()
            )
            progress.receive(FeedDownloadProgressTests.transfer(25_200_000, of: 63_000_000))
            world.library.speakDownloadProgress()
            progress.clear()
        }

        XCTAssertEqual(recorder.announcements.map(\.message), [
            "No feed download is under way.",
            "Feed Downloads: 0 of 1 done. Download 1 of 1: “Ep. 368” from Finish It!, 40% of 63 MB.",
        ])
        XCTAssertEqual(recorder.announcements.map(\.priority), [.high, .high])
    }

    /// The menu item and the key reach Speak Download Progress through its
    /// notification, which the library answers once it observes it.
    func testTheCommandsNotificationReachesTheLibrary() throws {
        let world = try FeedTestWorld(self, label: "FeedProgressNotification")
        world.library.observeDownloadProgressRequests()
        let progress = world.center.downloads.progress
        progress.begin(title: "Heard on Request", feedTitle: "Corkboard News", transfer: nil, queued: [], waits: FeedDownloadWaits())
        let heard = HeardAnnouncements()
        let previousPoster = VoiceOverAnnouncer.poster
        VoiceOverAnnouncer.poster = { announcement, _ in heard.messages.append(announcement.message) }
        defer {
            VoiceOverAnnouncer.poster = previousPoster
            progress.clear()
        }

        NotificationCenter.default.post(name: .speakDownloadProgress, object: nil)

        XCTAssertTrue(
            waitUntil { heard.messages.contains("Feed Downloads: 0 of 1 done. Download 1 of 1: “Heard on Request” from Corkboard News.") },
            heard.messages.joined(separator: " | ")
        )
    }

    // MARK: - The Section

    /// The section a Library window shows is the library's feed downloads'
    /// progress as it is at the moment shown, and its Cancel, the library's,
    /// stops the feed engine's downloads, saying what it stopped, and moves
    /// VoiceOver's focus from the section, which goes as the run ends, to
    /// the window's list (feed review item 19).
    func testTheWindowsSectionShowsTheLibrarysDownloadsAndItsCancelStopsThem() async throws {
        var focusMoves = 0
        let focusListBefore = LibraryWindowView.focusListAfterCancel
        LibraryWindowView.focusListAfterCancel = { _ in focusMoves += 1 }
        defer { LibraryWindowView.focusListAfterCancel = focusListBefore }
        let world = try FeedTestWorld(self, label: "FeedProgressSectionCancel")
        let words = (1...300).map { "word\($0)" }.joined(separator: " ")
        let items = (1...2).map { number in
            FeedXML.Item(guid: "post-\(number)", title: "Note \(number)", published: world.day(-Double(number)), description: "<p>\(words)</p>")
        }
        world.server.serve("/feed.xml", .feed(FeedXML.rss(title: "Corkboard News", items: items)))
        let feed = try await world.subscribe("/feed.xml")
        world.center.download("guid:post-1", of: feed.id)
        world.center.download("guid:post-2", of: feed.id)

        let section = LibraryWindowView.feedDownloadSection(for: world.library)
        XCTAssertEqual(section.state, world.library.feedDownloadProgress.state)
        XCTAssertEqual(section.state.lines(at: section.now), ["0 of 2 done", "Download 1 of 2: “Note 1” from Corkboard News"])
        let recorder = recordingAnnouncements {
            section.onCancel()
        }
        await waitFor("the download under way stops") { !world.center.downloads.isDownloading("guid:post-1", of: feed.id) }

        XCTAssertEqual(recorder.announcements.map(\.message), ["Stopped 2 feed downloads."])
        XCTAssertEqual(world.center.store.record(of: feed.id)?.items.map(\.state), [.notDownloaded, .notDownloaded])
        XCTAssertFalse(world.library.feedDownloadProgress.state.isRunning)
        XCTAssertEqual(focusMoves, 1, "Cancel left VoiceOver's focus on the section that went")
    }

    /// VoiceOver finds the section as one container labelled with every
    /// line it shows, holding the Cancel Feed Downloads button, hint
    /// included, as a control of its own; pressing it through accessibility
    /// cancels once. SwiftUI builds these elements only for a connected
    /// assistive app, so the test skips, rather than fails, without them;
    /// the wording tests cover every label either way.
    func testTheSectionIsAContainerReadingEveryLineThatHoldsItsCancel() throws {
        let clock = CommandClock()
        let progress = FeedDownloadProgress(now: { clock.now })
        progress.begin(
            title: "Ep. 368",
            feedTitle: "Finish It!",
            transfer: FeedDownloadProgressTests.transfer(25_200_000, of: 63_000_000),
            queued: [nil],
            waits: FeedDownloadWaits(network: 2)
        )
        let presses = CancelPresses()
        let section = FeedDownloadProgressSection(state: progress.state, now: clock.now, onCancel: presses.press)
        let status = progress.state.spokenStatus(at: clock.now)
        XCTAssertEqual(
            status,
            "Feed Downloads: 0 of 2 done. Download 1 of 2: “Ep. 368” from Finish It!, 40% of 63 MB. 2 waiting for a network without data limits."
        )

        try withHostedView(section, until: { !self.accessibilityElements(labelled: status, in: $0).isEmpty }) { hostingView in
            let containers = accessibilityElements(labelled: status, in: hostingView)
            guard !containers.isEmpty else {
                throw XCTSkip("SwiftUI exposed no accessibility elements without an assistive app")
            }
            XCTAssertEqual(containers.count, 1, "One element carries the status")
            let buttons = accessibleControls(in: hostingView).filter { $0.role == .button }
            guard !buttons.isEmpty else {
                throw XCTSkip("SwiftUI exposed no button to accessibility without an assistive app")
            }
            XCTAssertEqual(buttons.map(\.label), [FeedDownloadProgressWording.cancelButtonLabel])
            XCTAssertEqual(buttons.first?.hint, FeedDownloadProgressWording.cancelButtonHint)
            XCTAssertTrue(buttons[0].element.accessibilityPerformPress())
            XCTAssertTrue(waitUntil { presses.count == 1 }, "The button was pressed \(presses.count) times")
        }
    }

    /// The observer shows the section only while downloads run, taking no
    /// room otherwise, and a download's bytes do not redraw it: it reads
    /// them as it shows itself anew every few seconds.
    func testTheSectionShowsOnlyWhileDownloadsRunAndTheBytesRedrawNothing() throws {
        let world = try FeedTestWorld(self, label: "FeedProgressObserver")
        let progress = world.library.feedDownloadProgress
        let hosted = hostOffscreen(
            FeedDownloadProgressObserver(library: world.library, progress: progress),
            size: NSSize(width: 600, height: 200)
        )
        defer {
            progress.clear()
            takeDown(hosted.window)
        }
        flush(hosted.hostingView)
        XCTAssertEqual(hosted.hostingView.fittingSize.height, 0, "the section took room while no download ran")
        let drawsBefore = ViewBodyCounter.count(of: "FeedDownloadProgressSection")

        progress.begin(
            title: "Ep. 368",
            feedTitle: "Finish It!",
            transfer: FeedDownloadProgressTests.transfer(0, of: 63_000_000),
            queued: [],
            waits: FeedDownloadWaits()
        )
        flush(hosted.hostingView)
        XCTAssertGreaterThan(ViewBodyCounter.count(of: "FeedDownloadProgressSection"), drawsBefore, "the section was not drawn")
        XCTAssertGreaterThan(hosted.hostingView.fittingSize.height, 0)

        let runs = bodyRuns(of: ["FeedDownloadProgressSection"], in: hosted.hostingView, publishing: 10) { index in
            progress.receive(FeedDownloadProgressTests.transfer(Int64(10 + max(index, 0)) * 1_000_000, of: 63_000_000))
        }
        // At most one redraw: the section's own tick may fall in the
        // middle; each report of the bytes would make ten.
        XCTAssertLessThanOrEqual(runs["FeedDownloadProgressSection", default: 0], 1, "a download's bytes redrew the section")

        progress.end(.downloaded, queued: [], waits: FeedDownloadWaits())
        flush(hosted.hostingView)
        XCTAssertEqual(hosted.hostingView.fittingSize.height, 0, "the section stayed after the downloads ended")
    }
}

/// The messages VoiceOver was asked to speak while a test listened.
@MainActor
private final class HeardAnnouncements {
    /// Every message, oldest first.
    var messages: [String] = []
}

/// Counts the times a section's Cancel button runs its action.
@MainActor
private final class CancelPresses {
    /// How many times `press()` has run.
    private(set) var count = 0

    /// The Cancel action: counts one more press.
    func press() {
        count += 1
    }
}
