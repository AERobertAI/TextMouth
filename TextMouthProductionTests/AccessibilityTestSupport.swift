import AppKit
import XCTest
@testable import TextMouth

/// One VoiceOver announcement captured during a test, with the window its
/// caller asked to post from (nil when the caller named none).
struct RecordedAnnouncement {
    let announcement: VoiceOverAnnouncement
    let window: NSWindow?
}

/// Collects what `VoiceOverAnnouncer` is asked to announce while a test
/// records, so nothing reaches VoiceOver on the machine running the tests.
@MainActor
final class AnnouncementRecorder {
    /// Every announcement so far, oldest first.
    private(set) var recorded: [RecordedAnnouncement] = []

    /// The announcements alone, for comparing messages and priorities.
    var announcements: [VoiceOverAnnouncement] {
        recorded.map(\.announcement)
    }

    fileprivate func record(_ announcement: VoiceOverAnnouncement, window: NSWindow?) {
        recorded.append(RecordedAnnouncement(announcement: announcement, window: window))
    }
}

extension XCTestCase {
    /// Run `body` with VoiceOver announcements recorded instead of posted,
    /// then put the previous poster back, even when `body` throws.
    /// - Returns: The recorder holding everything `body` announced.
    @MainActor
    @discardableResult
    func recordingAnnouncements(_ body: () throws -> Void) rethrows -> AnnouncementRecorder {
        let recorder = AnnouncementRecorder()
        let previousPoster = VoiceOverAnnouncer.poster
        VoiceOverAnnouncer.poster = { announcement, window in
            recorder.record(announcement, window: window)
        }
        defer { VoiceOverAnnouncer.poster = previousPoster }
        try body()
        return recorder
    }
}
