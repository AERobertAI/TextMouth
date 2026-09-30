import AppKit
import XCTest
@testable import TextMouth

/// The shared VoiceOver announcer: its default priority, how it hands the
/// caller's window and priority to the poster, and the poster swap that
/// every announcement test relies on. Each test records its announcements,
/// so none of them is spoken by VoiceOver on the machine running the suite.
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
}
