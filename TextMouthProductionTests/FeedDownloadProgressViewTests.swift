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

    // MARK: - The Library's Cancel

    /// The library's Cancel, which the section's button calls, stops the
    /// feed engine's downloads, saying what it stopped.
    func testTheLibrarysCancelStopsTheFeedDownloads() async throws {
        let world = try FeedTestWorld(self, label: "FeedProgressLibraryCancel")
        let words = (1...300).map { "word\($0)" }.joined(separator: " ")
        let items = (1...2).map { number in
            FeedXML.Item(guid: "post-\(number)", title: "Note \(number)", published: world.day(-Double(number)), description: "<p>\(words)</p>")
        }
        world.server.serve("/feed.xml", .feed(FeedXML.rss(title: "Corkboard News", items: items)))
        let feed = try await world.subscribe("/feed.xml")

        world.center.download("guid:post-1", of: feed.id)
        world.center.download("guid:post-2", of: feed.id)
        let recorder = recordingAnnouncements {
            world.library.cancelFeedDownloads()
        }
        await waitFor("the download under way stops") { !world.center.downloads.isDownloading("guid:post-1", of: feed.id) }

        XCTAssertEqual(recorder.announcements.map(\.message), ["Stopped 2 feed downloads."])
        XCTAssertEqual(world.center.store.record(of: feed.id)?.items.map(\.state), [.notDownloaded, .notDownloaded])
        XCTAssertFalse(world.library.feedDownloadProgress.state.isRunning)
    }
}

/// The messages VoiceOver was asked to speak while a test listened.
@MainActor
private final class HeardAnnouncements {
    /// Every message, oldest first.
    var messages: [String] = []
}
