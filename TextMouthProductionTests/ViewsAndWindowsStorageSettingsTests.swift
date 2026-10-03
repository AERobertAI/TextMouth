import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

/// The Storage settings pane observes the library, so it draws again for
/// every change to it, once a second while a book played. Its Status line
/// asked the disk whether the data directory exists twice at each of those
/// draws, on the main thread, which a network or unplugged volume can hold
/// up. The pane now checks off the main thread when it appears and when the
/// answer can have changed, and draws the answer it got (PERF32).
@MainActor
final class ViewsAndWindowsStorageSettingsTests: XCTestCase {

    /// The pane checks the data directory once as it appears, off the main
    /// thread, and not again for changes to the library, which it still
    /// draws.
    func testDataDirectoryIsCheckedOffTheMainThreadOnlyWhenItCanHaveChanged() throws {
        let checks = DirectoryCheckRecorder()
        let savedCheck = StorageSettingsView.directoryCheck
        StorageSettingsView.directoryCheck = { path in
            checks.record(path, onMainThread: Thread.isMainThread)
            return true
        }
        defer { StorageSettingsView.directoryCheck = savedCheck }
        let model = LibraryViewModel(initializeServices: false)
        model.library = ViewsAndWindowsFixtures.shapedLibrary(bookCount: 30, manualCount: 10)
        let changing = try XCTUnwrap(model.library.books.first?.id)
        let settings = SettingsViewModel(notificationCenter: NotificationCenter(), initializeServices: false)
        let hosted = hostOffscreen(
            StorageSettingsView().environmentObject(model).environmentObject(settings),
            size: NSSize(width: 600, height: 1_400)
        )
        defer { takeDown(hosted.window) }

        XCTAssertTrue(waitUntil { checks.count == 1 }, "The pane never checked the data directory")
        var offset = 1_000
        let runs = bodyRuns(of: ["StorageSettingsView"], in: hosted.hostingView) { _ in
            offset += 1
            ViewsAndWindowsFixtures.move(changing, to: offset, in: model)
        }
        settle(hosted.hostingView, seconds: 0.2)

        XCTAssertGreaterThan(runs["StorageSettingsView", default: 0], 0, "The pane never drew a change to the library")
        XCTAssertEqual(checks.count, 1, "The pane checked the data directory again for changes to the library")
        XCTAssertEqual(checks.paths, [TextMouthPaths.rootPath])
        XCTAssertFalse(checks.ranOnTheMainThread, "The data directory was checked on the main thread")
    }

    /// The check reports what it finds, from off the main thread.
    func testDirectoryCheckRunsOffTheMainThread() async {
        let checks = DirectoryCheckRecorder()
        let savedCheck = StorageSettingsView.directoryCheck
        StorageSettingsView.directoryCheck = { path in
            checks.record(path, onMainThread: Thread.isMainThread)
            return path == "/present"
        }
        defer { StorageSettingsView.directoryCheck = savedCheck }

        let present = await StorageSettingsView.directoryExists(at: "/present")
        let missing = await StorageSettingsView.directoryExists(at: "/missing")

        XCTAssertTrue(present)
        XCTAssertFalse(missing)
        XCTAssertEqual(checks.paths, ["/present", "/missing"])
        XCTAssertFalse(checks.ranOnTheMainThread)
    }
}

/// Records each data directory check and whether it ran on the main thread.
///
/// `@unchecked Sendable`: its one stored array is read and written only
/// under its lock, from whichever thread a check runs on.
private final class DirectoryCheckRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var checks: [(path: String, onMainThread: Bool)] = []

    /// Notes a check of `path`, and whether it ran on the main thread.
    func record(_ path: String, onMainThread: Bool) {
        lock.withLock { checks.append((path, onMainThread)) }
    }

    /// How many checks ran.
    var count: Int {
        lock.withLock { checks.count }
    }

    /// The paths checked, in order.
    var paths: [String] {
        lock.withLock { checks.map(\.path) }
    }

    /// Whether any check ran on the main thread.
    var ranOnTheMainThread: Bool {
        lock.withLock { checks.contains { $0.onMainThread } }
    }
}
