import SwiftUI
import UIKit

/// What each reader sheet shows: the reader's panels, each rebuilt for the
/// phone over the reader's own functions and the Mac's words (the iPhone
/// interface spec, from "The Bookmarks sheet" to "The Book Info sheet").
///
/// It takes the reader as a plain value, never observed, so no sheet redraws
/// as the book plays. The reader's screen presents it through
/// `PhoneReaderSheet`, and returns focus to the control that opened it in
/// its `onDismiss`; what a sheet leaves to say once it has closed is said
/// from here, a moment after that, by `PhoneSheetFarewell`.
struct PhoneReaderSheetContent: View {
    /// The sheet to show.
    let sheet: PhoneReaderSheet
    /// The reader the sheet is over.
    let reader: ReaderViewModel
    /// Tells the session a jump from a sheet moved the book, so it counts as
    /// opened.
    let noteJumped: @MainActor () -> Void
    /// The library Book Info saves to.
    let library: LibraryViewModel
    /// Pauses the book that plays for the Voice sheet's Preview Voice
    /// (`PhoneSession.pauseBookForPreview`).
    let pauseBookForPreview: PhoneSettingsVoicePreview.PauseBook?

    /// What the sheet leaves to say, and to start, once it has closed.
    @State private var farewell = PhoneSheetFarewell()

    var body: some View {
        panel
            // A sheet's content disappears as the sheet finishes closing,
            // when the reader's screen has been asked to put focus back.
            .onDisappear {
                farewell.sheetDidClose()
            }
    }

    /// The panel `sheet` names.
    @ViewBuilder
    private var panel: some View {
        switch sheet {
        case .headings:
            PhoneHeadingsSheet(reader: reader, farewell: farewell, noteJumped: noteJumped)
        case .search:
            PhoneSearchSheet(reader: reader, farewell: farewell, noteJumped: noteJumped)
        case .goTo:
            PhoneGoToSheet(reader: reader, farewell: farewell, noteJumped: noteJumped)
        case .bookmarks:
            PhoneBookmarksSheet(reader: reader, farewell: farewell, noteJumped: noteJumped)
        case .sleepTimer:
            PhoneSleepTimerSheet(reader: reader, farewell: farewell)
        case .voice:
            PhoneVoiceSheet(reader: reader, farewell: farewell, pauseBookForPreview: pauseBookForPreview)
        case .bookInfo:
            // The Library's Book Info sheet, for the reader's book.
            PhoneReaderBookInfo(reader: reader, library: library)
        case .navigationUnit:
            // The Navigation unit's list is the reader's slice's, through
            // `PhoneChoiceSheet`; this shows its name, the Mac's, until then.
            PhoneUnbuiltSheet(title: "Navigation unit")
        }
    }
}

// MARK: - What a sheet leaves to do

/// What a reader sheet leaves to say once it has closed, and, for the sleep
/// timer, the book to start after the words (the spec, "Focus on arrival and
/// return" and "The Sleep Timer sheet").
///
/// VoiceOver hears a sheet close and lands on the control it returns to, and
/// either would cut off words posted with the closing. So the words wait for
/// the Mac's moment after a sheet closes (`VoiceOverAnnouncer.afterSheetDelay`,
/// longer than the reader's 0.35 seconds before returning focus), and are
/// said at iOS's low priority, which Apple's header says is "queued and spoken
/// when other speech utterances have completed" (`PhoneAnnouncer.say`), as one
/// announcement so that none cuts off the next.
/// A book to start waits for the last of them to be said, or for
/// `PhoneSleepTimerModel.longestWaitBeforePlaying`, whichever comes first.
///
/// **Unverified,** with nothing run on iOS: that the words follow VoiceOver's
/// reading of the returned control rather than cut it off, and that
/// VoiceOver's announcement-finished notice comes for an announcement SwiftUI
/// posted.
@MainActor
final class PhoneSheetFarewell {
    /// The words to say once the sheet has closed, in order.
    private var sentences: [String] = []
    /// What starts the book once they're said, if anything.
    private var bookStart: (@MainActor () -> Void)?

    /// Keeps `words` to say once the sheet has closed, after any kept before.
    func keep(_ words: [String]) {
        sentences += words.filter { !$0.isEmpty }
    }

    /// Keeps `start` to run once the words kept have been said.
    func keepStartingTheBook(_ start: @escaping @MainActor () -> Void) {
        bookStart = start
    }

    /// The sheet has closed: says the words kept, a moment later, and then
    /// starts the book if asked. Runs once; nothing kept, nothing done.
    func sheetDidClose() {
        let words = sentences
        let start = bookStart
        sentences = []
        bookStart = nil
        guard !words.isEmpty || start != nil else { return }
        VoiceOverAnnouncer.afterSheetCloses {
            Self.say(words, thenRun: start)
        }
    }

    /// Says `words` now, in order, then runs `start` once the last has been
    /// said: at once while VoiceOver isn't running, since nothing is said.
    /// For a sheet that stays open, as the sleep timer does when Settings
    /// say so, as well as for one that has closed.
    static func say(_ words: [String], thenRun start: (@MainActor () -> Void)?) {
        // One announcement, so that no word cuts off the one before it.
        PhoneAnnouncer.say(inOrder: words)
        guard let start else { return }
        guard let last = words.last, UIAccessibility.isVoiceOverRunning else {
            start()
            return
        }
        PhoneAnnouncementWait.run(start, after: last, atMost: PhoneSleepTimerModel.longestWaitBeforePlaying)
    }
}

/// Runs one piece of work once VoiceOver has finished saying an announcement,
/// or once a limit has passed, whichever comes first, and only once.
///
/// Apple's `UIAccessibility.announcementDidFinishNotification` says when
/// VoiceOver has finished an announcement, with its words in the
/// notification's `announcementStringValueUserInfoKey`. The observer is on
/// the main queue, as every observer of the iPhone app is.
@MainActor
private final class PhoneAnnouncementWait {
    /// The words waited for.
    private let words: String
    /// The work to run.
    private var work: (@MainActor () -> Void)?
    /// The notification observer, removed as the work runs.
    private var observer: NSObjectProtocol?
    /// The waits under way, kept until each runs its work.
    private static var running: [ObjectIdentifier: PhoneAnnouncementWait] = [:]

    /// A wait for `words`, to run `work`.
    private init(words: String, work: @escaping @MainActor () -> Void) {
        self.words = words
        self.work = work
    }

    /// Runs `work` once VoiceOver has said `words`, or after `limit` seconds.
    static func run(_ work: @escaping @MainActor () -> Void, after words: String, atMost limit: TimeInterval) {
        let wait = PhoneAnnouncementWait(words: words, work: work)
        running[ObjectIdentifier(wait)] = wait
        wait.observer = NotificationCenter.default.addObserver(
            forName: UIAccessibility.announcementDidFinishNotification,
            object: nil,
            queue: .main
        ) { [weak wait] notification in
            let said = notification.userInfo?[UIAccessibility.announcementStringValueUserInfoKey] as? String
            MainActor.assumeIsolated {
                wait?.heard(said)
            }
        }
        Task { @MainActor [weak wait] in
            try? await Task.sleep(for: .seconds(limit))
            wait?.finish()
        }
    }

    /// VoiceOver finished saying `said`: the work runs if it's the words
    /// waited for.
    private func heard(_ said: String?) {
        guard said == words else { return }
        finish()
    }

    /// Runs the work, once, and lets the wait go.
    private func finish() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
        let run = work
        work = nil
        Self.running[ObjectIdentifier(self)] = nil
        run?()
    }
}

// MARK: - Not yet built

/// A sheet the panels haven't built yet: its title, and Close.
private struct PhoneUnbuiltSheet: View {
    /// The sheet's title.
    let title: String
    /// Closes the sheet.
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Text(title)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    PhoneSheetButton(title: PhoneAppWording.close) { dismiss() }
                }
        }
    }
}
