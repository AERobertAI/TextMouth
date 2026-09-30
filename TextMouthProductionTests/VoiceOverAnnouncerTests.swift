import AppKit
import XCTest
@testable import TextMouth

/// The shared VoiceOver announcer: its default priority, how it hands the
/// caller's window and priority to the poster, the poster swap that every
/// announcement test relies on, and the reader and sleep timer announcing
/// through it as before. Each test records its announcements, so none of
/// them is spoken by VoiceOver on the machine running the suite.
@MainActor
final class VoiceOverAnnouncerTests: XCTestCase {
    /// With no window or priority, an announcement is high priority and the
    /// poster is left to choose the key window, then the main window.
    func testAnnounceDefaultsToHighPriorityWithoutPreferredWindow() throws {
        let recorder = recordingAnnouncements {
            VoiceOverAnnouncer.announce("Chapter 2")
        }

        XCTAssertEqual(recorder.announcements, [
            VoiceOverAnnouncement(message: "Chapter 2", priority: .high)
        ])
        let recorded = try XCTUnwrap(recorder.recorded.first)
        XCTAssertNil(recorded.window)
    }

    /// A caller's window and priority reach the poster unchanged.
    func testAnnounceForwardsTheCallersWindowAndPriority() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        // Tests own this window; AppKit must not release it again on close.
        window.isReleasedWhenClosed = false
        defer { window.close() }

        let recorder = recordingAnnouncements {
            VoiceOverAnnouncer.announce("Sleep timer: 1 minute remaining", from: window, priority: .medium)
        }

        XCTAssertEqual(recorder.announcements, [
            VoiceOverAnnouncement(message: "Sleep timer: 1 minute remaining", priority: .medium)
        ])
        let recorded = try XCTUnwrap(recorder.recorded.first)
        XCTAssertTrue(recorded.window === window)
    }

    /// Recording ends with its scope: a nested recording hands announcements
    /// back to the outer one afterwards, so no test leaves its poster behind.
    func testRecordingPutsThePreviousPosterBack() {
        var inner: AnnouncementRecorder?
        let outer = recordingAnnouncements {
            inner = recordingAnnouncements {
                VoiceOverAnnouncer.announce("Inside")
            }
            VoiceOverAnnouncer.announce("Outside")
        }

        XCTAssertEqual(inner?.announcements.map(\.message), ["Inside"])
        XCTAssertEqual(outer.announcements.map(\.message), ["Outside"])
    }

    // MARK: - Earlier announcers now delegate unchanged

    /// The reader still remembers its last announcement for tests and posts
    /// it at high priority, leaving the window choice to the announcer.
    func testReaderAnnouncementKeepsLastAnnouncementAndHighPriority() throws {
        let reader = makeReader()
        defer { reader.close() }

        let recorder = recordingAnnouncements {
            reader.announceToVoiceOver("Reading position copied to clipboard")
        }

        XCTAssertEqual(reader.lastAnnouncement, "Reading position copied to clipboard")
        XCTAssertEqual(recorder.announcements, [
            VoiceOverAnnouncement(message: "Reading position copied to clipboard", priority: .high)
        ])
        let recorded = try XCTUnwrap(recorder.recorded.first)
        XCTAssertNil(recorded.window)
    }

    /// Sleep timer milestones keep their medium priority.
    func testSleepTimerMilestoneAnnouncesAtMediumPriority() throws {
        // A throwaway preferences suite keeps the user's last-used timer
        // duration out of reach.
        let suiteName = "com.textmouth.tests.announcer.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let timer = SleepTimerService(userDefaults: defaults)
        defer { timer._resetForTesting() }
        timer.start(duration: .minutes(1), ownerID: UUID(), onExpire: {})

        let recorder = recordingAnnouncements {
            // Thirty ticks take the one-minute countdown to its 30-second
            // milestone, the only milestone on the way.
            for _ in 0..<30 { timer._advanceCountdownForTesting() }
        }

        XCTAssertEqual(recorder.announcements, [
            VoiceOverAnnouncement(message: "Sleep timer: 30 seconds remaining", priority: .medium)
        ])
    }

    /// A reader for a book whose file does not exist, with an isolated
    /// library and settings: enough to announce, with nothing to play.
    private func makeReader() -> ReaderViewModel {
        let book = Book(
            title: "Announcements",
            format: .txt,
            filePath: "/tmp/\(UUID().uuidString)-announcements.txt",
            md5Hash: UUID().uuidString
        )
        let library = LibraryViewModel()
        library.library = Library(books: [book])
        return ReaderViewModel(
            book: book,
            libraryViewModel: library,
            settingsViewModel: SettingsViewModel(notificationCenter: NotificationCenter(), initializeServices: false)
        )
    }
}
