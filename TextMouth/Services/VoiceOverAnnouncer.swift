import AppKit

/// One request for VoiceOver to speak a message.
struct VoiceOverAnnouncement: Equatable {
    /// The words VoiceOver speaks.
    let message: String
    /// How urgent the message is. VoiceOver may speak a high-priority
    /// announcement at once and a lower one after its current speech.
    let priority: NSAccessibilityPriorityLevel
}

/// Posts every VoiceOver announcement the app makes.
///
/// The reader, the library, the sleep timer, and the settings window all
/// announce through `announce`, so the notification format and the choice of
/// window live in one place. Tests replace `poster` to capture announcements
/// without a window, a running screen reader, or AppKit posting.
///
/// In a process hosting tests the default poster records instead of posting
/// (see `Delivery`), so a test that does not capture its announcements never
/// makes VoiceOver speak on the machine running the suite.
@MainActor
enum VoiceOverAnnouncer {
    /// Delivers one announcement. `window` is the caller's preferred window,
    /// or nil when the caller has none.
    typealias Poster = @MainActor (_ announcement: VoiceOverAnnouncement, _ window: NSWindow?) -> Void

    /// How the default poster delivers an announcement.
    enum Delivery: Equatable {
        /// Ask VoiceOver to speak it, as the app does.
        case post
        /// Keep it in `recordedAnnouncements` without posting, as a process
        /// hosting tests does.
        case record
    }

    /// The delivery a process with `runtime` starts with: posting in the
    /// app, recording under hosted tests.
    nonisolated static func defaultDelivery(for runtime: TextMouthRuntime) -> Delivery {
        runtime.isHostedTest ? .record : .post
    }

    /// The poster in use: at first the one this process's runtime calls for
    /// (see `defaultDelivery(for:)`). A test may install its own, and must
    /// put the previous poster back when it ends.
    static var poster: Poster = makePoster(delivering: defaultDelivery(for: .current))

    /// The announcements the recording poster kept instead of posting, oldest
    /// first. The app never records any.
    private(set) static var recordedAnnouncements: [VoiceOverAnnouncement] = []

    /// The poster that delivers announcements as `delivery` says.
    static func makePoster(delivering delivery: Delivery) -> Poster {
        switch delivery {
        case .post:
            return postThroughAccessibility
        case .record:
            return { announcement, _ in recordedAnnouncements.append(announcement) }
        }
    }

    /// Asks VoiceOver to speak `message`.
    ///
    /// - Parameters:
    ///   - message: The words to speak.
    ///   - window: The window to post from. When nil, the key window is used,
    ///     then the main window.
    ///   - priority: How urgent the message is; high unless stated.
    static func announce(
        _ message: String,
        from window: NSWindow? = nil,
        priority: NSAccessibilityPriorityLevel = .high
    ) {
        poster(VoiceOverAnnouncement(message: message, priority: priority), window)
    }

    /// The app's poster. It requests the announcement from `window`, falling
    /// back to the key window and then the main window, and does nothing when
    /// the app has no window to post from.
    static func postThroughAccessibility(_ announcement: VoiceOverAnnouncement, from window: NSWindow?) {
        guard let target = window ?? NSApp?.keyWindow ?? NSApp?.mainWindow else { return }
        NSAccessibility.post(
            element: target,
            notification: .announcementRequested,
            userInfo: [
                .announcement: announcement.message,
                .priority: announcement.priority.rawValue
            ]
        )
    }
}
