#if os(macOS)
import AppKit
#else
import Accessibility
import SwiftUI
import UIKit
#endif

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
    typealias Poster = @MainActor (_ announcement: VoiceOverAnnouncement, _ window: PlatformWindow?) -> Void

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
        from window: PlatformWindow? = nil,
        priority: NSAccessibilityPriorityLevel = .high
    ) {
        poster(VoiceOverAnnouncement(message: message, priority: priority), window)
    }

    /// How long an announcement waits once a sheet or dialog has closed,
    /// in seconds: a moment for VoiceOver to settle back on the window
    /// beneath, so the closing never cuts the words off (REV11 F6).
    static let afterSheetDelay: TimeInterval = 0.6

    /// Runs `announce` once a sheet or dialog has closed, a moment later
    /// (`afterSheetDelay`): for a caller announcing its own way, as a test
    /// listening in does.
    static func afterSheetCloses(_ announce: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + afterSheetDelay) {
            announce()
        }
    }

    /// Asks VoiceOver to speak `message` from `window` once a sheet or
    /// dialog over it has closed (`afterSheetCloses(_:)`), as a Library
    /// window says what a subscription, Move to Folder…, Move to Library…,
    /// or Remove's Delete Download did (REV11 F6).
    static func announceAfterSheetCloses(_ message: String, from window: PlatformWindow?) {
        afterSheetCloses { announce(message, from: window) }
    }

    /// The app's poster. It requests the announcement from `window`, falling
    /// back to the key window and then the main window, and does nothing when
    /// the app has no window to post from.
    static func postThroughAccessibility(_ announcement: VoiceOverAnnouncement, from window: PlatformWindow?) {
        #if os(macOS)
        guard let target = window ?? NSApp?.keyWindow ?? NSApp?.mainWindow else { return }
        NSAccessibility.post(
            element: target,
            notification: .announcementRequested,
            userInfo: [
                .announcement: announcement.message,
                .priority: announcement.priority.rawValue
            ]
        )
        #else
        // iOS posts through SwiftUI's announcement notification. The window
        // is not needed: iOS speaks the announcement for the whole screen.
        // Apple's header (UIAccessibilityConstants.h): default priority
        // "will interrupt existing speech, but [is] interruptible", and low is
        // "queued and spoken when other speech utterances have completed". So
        // the shared code's high and medium words interrupt at default, and
        // its low words wait their turn. Uninterruptible high priority is
        // kept for the few words the iPhone chooses (`PhoneAnnouncer.important`).
        switch announcement.priority {
        case .high, .medium: postToVoiceOver(announcement.message, priority: .default)
        case .low: postToVoiceOver(announcement.message, priority: .low)
        }
        #endif
    }

    #if os(iOS)
    /// Posts `message` through SwiftUI's announcement notification at iOS's
    /// speech `priority`.
    static func postToVoiceOver(
        _ message: String,
        priority: AttributeScopes.AccessibilityAttributes.AnnouncementPriorityAttribute.AnnouncementPriority
    ) {
        var spoken = AttributedString(message)
        spoken.accessibilitySpeechAnnouncementPriority = priority
        AccessibilityNotification.Announcement(spoken).post()
    }
    #endif
}

// MARK: - Said Once a Sheet Has Closed

/// What a sheet's work left to say, kept while the sheet closes and said
/// once it has (REV11 F6): VoiceOver hears the closing first, which would
/// cut off words posted with it. The sheet's owner keeps the sentence as
/// the sheet's work ends (`keep(_:)`), and says it from the sheet's
/// `onDismiss` (`sheetDidClose(say:)`), a moment later
/// (`VoiceOverAnnouncer.afterSheetCloses(_:)`).
@MainActor
final class AnnouncementAfterSheet {
    /// The sentence kept to say once the sheet has closed, if any.
    private(set) var pending: String?

    /// Keeps `sentence` to say once the sheet has closed; nil keeps
    /// nothing, as after Cancel.
    func keep(_ sentence: String?) {
        pending = sentence
    }

    /// Says the sentence kept, once, through `say`, a moment after the
    /// sheet has closed; nothing when none was kept.
    func sheetDidClose(say: @escaping @MainActor (String) -> Void) {
        guard let sentence = pending else { return }
        pending = nil
        VoiceOverAnnouncer.afterSheetCloses { say(sentence) }
    }
}
