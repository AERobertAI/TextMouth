#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Foundation
import UniformTypeIdentifiers

// MARK: - What the Sheet Reaches

/// What the Clean Up sheet asks of the app beyond the book's own files: the
/// rules, the user's text editor, the transcriptions under way, Edit Text's
/// sessions, and VoiceOver. The app's own, unless a test passes its own
/// (`live`).
struct TranscriptCleanupServices {
    /// The rules to clean up with, read off the main thread
    /// (`TranscriptCleanupRuleFile.load`).
    var loadRules: @Sendable () async -> TranscriptCleanupRuleFile.Lookup
    /// Asks the sync service for the user's copy of the rules, found only in
    /// the cloud.
    var requestRulesDownload: @MainActor () -> Void
    /// Opens the user's copy of the rules in their text editor, from a
    /// window, making it from TextMouth's own rules first when there is
    /// none: nil once it opened, or why it could not.
    var editRules: @MainActor (NSWindow?) async -> String?
    /// Whether the book is being transcribed now.
    var isTranscribing: @MainActor (UUID) -> Bool
    /// Settles and ends the Edit Text session of a book whose transcript is
    /// about to be rewritten (an edit saved but not yet checked is taken
    /// first); whether the book was being edited.
    var pauseTextEdit: @MainActor (Book) async -> Bool
    /// Begins the book's Edit Text session again when the rewrite failed.
    var resumeTextEdit: @MainActor (Book) async -> Void
    /// Asks VoiceOver to speak a message from a window.
    var announce: @MainActor (String, NSWindow?) -> Void

    /// The app's own: the rule file in the bundle and the data directory,
    /// the user's default text editor, the app's transcription center and
    /// Edit Text, and VoiceOver.
    @MainActor
    static var live: TranscriptCleanupServices {
        TranscriptCleanupServices(
            loadRules: { await OffMainWork.run { TranscriptCleanupRuleFile.load() } },
            requestRulesDownload: { SavedFile.requestDownload(of: TextMouthPaths.transcriptCleanupRulesFile) },
            editRules: { _ in await openRulesInTextEditor() },
            isTranscribing: { TranscriptionJobCenter.shared.current?.bookID == $0 },
            pauseTextEdit: { await BookTextEditor.shared.pauseEditing(of: $0) },
            resumeTextEdit: { await BookTextEditor.shared.resumeEditing(of: $0) },
            announce: { message, window in VoiceOverAnnouncer.announce(message, from: window) }
        )
    }

    /// Opens the user's copy of the rules in their default text editor,
    /// making it from TextMouth's own rules first, as storage work, when
    /// there is none: nil once it opened, or why it could not.
    @MainActor
    private static func openRulesInTextEditor() async -> String? {
        do {
            // Whether a copy was made matters not: either way it opens.
            _ = try await OffMainWork.runThrowing {
                try StorageBoundary.shared.perform(.textExtraction) { _ in
                    try TranscriptCleanupRuleFile.prepareUserCopy()
                }
            }
            let editor = NSWorkspace.shared.urlForApplication(toOpen: .plainText)
            try await PackageFileEditing.openWithWorkspace(TextMouthPaths.transcriptCleanupRulesFile, app: editor)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

// MARK: - The Sheet's Model

/// The Clean Up sheet of one transcribed audiobook (FR05, experimental):
/// the rules in use, what they would change, rule by rule with examples,
/// Apply, which makes the changes, and Undo Cleanup, which puts back the
/// transcript from before the last cleanup.
///
/// Nothing changes unless Apply or Undo Cleanup is pressed. The rules are
/// read again, and what they would change worked out again, as the user
/// comes back to TextMouth, as after editing their copy of the rules. While
/// the book is being transcribed, or has no transcript that can be read,
/// the sheet only says so.
@MainActor
final class TranscriptCleanupSheetModel: ObservableObject, Identifiable {
    /// Where the sheet is.
    enum Phase: Equatable {
        /// Reading the transcript and the rules.
        case checking
        /// Saying why nothing can be cleaned up, with only OK.
        case unavailable(String)
        /// Showing what the rules would change.
        case ready
        /// Applying the cleanup, or undoing it.
        case working(String)
        /// Saying why the cleanup or its undo failed, with only Close.
        case failed(String)
    }

    /// The sheet's controls that VoiceOver and keyboard focus can be moved
    /// to, each the first control of the sheet in some phase.
    enum FocusTarget: Hashable {
        /// Apply, making the changes.
        case apply
        /// Cancel, closing the sheet.
        case cancel
        /// OK, closing a sheet that says why nothing can be cleaned up.
        case ok
        /// Close, closing a sheet that says why the work failed.
        case close
    }

    /// One rule's changes as the sheet lists them: its line, then its
    /// examples, read by VoiceOver as one.
    struct ChangeRow: Identifiable, Equatable {
        /// The rule's place among the rules that changed something.
        let id: Int
        /// The rule's line: what it changes, and how often.
        let title: String
        /// Its examples, each before and after.
        let examples: [String]

        /// What VoiceOver reads for the row.
        var accessibilityLabel: String {
            ([title] + examples).joined(separator: " ")
        }
    }

    /// Tells sheets apart.
    let id = UUID()
    /// The book whose transcript the sheet cleans up.
    let book: Book

    /// Where the sheet is.
    @Published private(set) var phase: Phase = .checking
    /// The rules in use, and where they came from, once read.
    @Published private(set) var rules: TranscriptCleanupRuleFile.Lookup?
    /// What the rules would change, once worked out.
    @Published private(set) var preview: TranscriptCleanup.Preview?
    /// Whether Undo Cleanup is offered: the transcript is cleaned up, and
    /// the transcript from before is kept beside it.
    @Published private(set) var canUndo = false
    /// Why Edit Rules… could not open the rules, after it tried.
    @Published private(set) var editRulesNotice: String?

    /// The window the sheet sits on, where announcements come from.
    weak var window: NSWindow?
    /// Closes the sheet; the presenter sets it.
    var onClose: () -> Void = {}

    /// The library, which gives the book as it holds it when the cleanup is
    /// saved, and tells its open readers.
    private weak var library: LibraryViewModel?
    /// What the sheet asks of the app.
    private let services: TranscriptCleanupServices
    /// The phase whose lines VoiceOver last heard (`announceSheet()`).
    private var announcedPhase: Phase?

    /// A sheet cleaning up `book`'s transcript in `library`.
    init(book: Book, library: LibraryViewModel?, services: TranscriptCleanupServices = .live) {
        self.book = book
        self.library = library
        self.services = services
    }

    // MARK: Loading

    /// Finds out what the sheet shows: the transcript, the rules, what they
    /// would change, and whether a cleanup can be undone; or why nothing
    /// can be cleaned up.
    func load() async {
        guard phase == .checking else { return }
        if services.isTranscribing(book.id) {
            phase = .unavailable(TranscriptCleanupWording.busyTranscribing(bookTitle: book.title))
            return
        }
        switch await examine() {
        case .found(let found):
            take(found)
            phase = .ready
        case .unavailable(let reason):
            phase = .unavailable(reason)
        }
    }

    /// Reads the rules and the transcript again, as the user comes back to
    /// TextMouth, and shows what the rules would change now. When anything
    /// changed, VoiceOver hears the sheet's lines again. A sheet no longer
    /// ready, as one applying its cleanup meanwhile, is left as it is.
    func refresh() async {
        guard phase == .ready else { return }
        let examined = await examine()
        guard phase == .ready else { return }
        switch examined {
        case .unavailable(let reason):
            phase = .unavailable(reason)
        case .found(let found):
            guard found.rules != rules || found.preview != preview || found.canUndo != canUndo else { return }
            take(found)
            announcedPhase = nil
            announceSheet()
        }
    }

    /// What a look at the book and the rules found.
    private struct Examination {
        let rules: TranscriptCleanupRuleFile.Lookup
        let preview: TranscriptCleanup.Preview
        let canUndo: Bool
    }

    /// What a look at the book found: what the sheet shows, or why it can
    /// show nothing.
    private enum Examined {
        case found(Examination)
        case unavailable(String)
    }

    /// Reads the rules and the book's transcript, off the main thread, and
    /// works out what the rules would change; or why the transcript can't
    /// be read.
    private func examine() async -> Examined {
        let rules = await services.loadRules()
        if rules.userCopy == .inCloud {
            services.requestRulesDownload()
        }
        // The book as the library holds it now, as apply() and undo() read it:
        // a sheet left open while the book moved (Move to Library..., a move
        // between folders) would otherwise look for the transcript where the
        // book used to be and wrongly find none.
        let book = library?.bookByID(self.book.id) ?? self.book
        let found = await OffMainWork.run {
            (lookup: TranscriptStore.read(from: book.tmbDirectory), hasCopy: TranscriptStore.hasTranscriptBeforeCleanup(of: book))
        }
        let transcript: Transcript
        switch found.lookup {
        case .found(let read):
            transcript = read
        case .missing:
            return .unavailable(TranscriptCleanupWording.noTranscript(bookTitle: book.title))
        case .inCloud, .unsupportedVersion, .unusable:
            return .unavailable(TranscriptCleanupWording.unreadableTranscript(bookTitle: book.title))
        }
        let cleanup = TranscriptCleanup(rules: rules.rules.rules)
        let preview = await OffMainWork.run { cleanup.preview(of: transcript) }
        return .found(Examination(rules: rules, preview: preview, canUndo: found.hasCopy && transcript.cleanedUp != nil))
    }

    /// Shows what `found` holds.
    private func take(_ found: Examination) {
        rules = found.rules
        preview = found.preview
        canUndo = found.canUndo
    }

    // MARK: What the Sheet Shows

    /// The sheet's heading.
    var heading: String {
        TranscriptCleanupWording.sheetTitle(bookTitle: book.title)
    }

    /// The note that a feed episode's cleaned-up transcript stays with the
    /// episode in its feed, as the listener hears it before applying; nil for
    /// a book that is not a feed item.
    var feedNoteLine: String? {
        book.isFeedItem ? TranscriptionWording.feedEpisodeTranscriptNote : nil
    }

    /// The line naming the rules in use.
    var rulesLine: String? {
        rules.map { TranscriptCleanupWording.rulesLine($0.rules, source: $0.source) }
    }

    /// The lines about the user's copy of the rules: waiting in the cloud,
    /// unusable, or older than TextMouth's own; and why Edit Rules… failed.
    var rulesNoticeLines: [String] {
        guard let rules else { return [] }
        // A list without a rule says why, and how to add some.
        var lines = rules.rules.rules.isEmpty ? [TranscriptCleanupWording.noRules(source: rules.source)] : []
        switch rules.userCopy {
        case .none:
            break
        case .used:
            if rules.builtInVersion > rules.rules.version {
                lines.append(TranscriptCleanupWording.newerBuiltInRules(version: rules.builtInVersion))
            }
        case .inCloud:
            lines.append(TranscriptCleanupWording.userCopyInCloud)
        case .unusable(let reason):
            lines.append(TranscriptCleanupWording.userCopyUnusable(reason: reason))
        }
        return lines + [editRulesNotice].compactMap { $0 }
    }

    /// What the rules would change, in all.
    var summaryLine: String? {
        guard let preview else { return nil }
        guard preview.corrections > 0 else { return TranscriptCleanupWording.nothingToChange }
        return TranscriptCleanupWording.summary(corrections: preview.corrections, sentences: preview.changedSentences)
    }

    /// The lines about the transcript's last cleanup, and edits since it.
    var historyLines: [String] {
        guard let note = preview?.original.cleanedUp else { return [] }
        var lines = [TranscriptCleanupWording.alreadyCleanedUp(note, canUndo: canUndo)]
        if canUndo, let edited = preview?.original.editedAt, edited > note.cleanedAt {
            lines.append(TranscriptCleanupWording.editedSinceCleanup(on: edited))
        }
        return lines
    }

    /// Each rule's changes, as the sheet lists them.
    var changeRows: [ChangeRow] {
        (preview?.changes ?? []).enumerated().map { number, change in
            ChangeRow(
                id: number,
                title: TranscriptCleanupWording.ruleLine(change.rule, corrections: change.corrections),
                examples: change.examples.map(TranscriptCleanupWording.exampleLine)
            )
        }
    }

    /// Every line the ready sheet shows above its list, in order, as
    /// VoiceOver hears them together once its focus lands.
    var readyLines: [String] {
        [heading, TranscriptCleanupWording.experimentalLine, feedNoteLine, rulesLine].compactMap { $0 }
            + rulesNoticeLines + [summaryLine].compactMap { $0 } + historyLines
    }

    /// Whether Apply can be pressed: the rules change something.
    var canApply: Bool {
        phase == .ready && (preview?.corrections ?? 0) > 0
    }

    /// Whether Undo Cleanup can be pressed.
    var canPressUndo: Bool {
        phase == .ready && canUndo
    }

    /// Whether the buttons that change nothing yet, Edit Rules… and Cancel,
    /// can be pressed: not while the cleanup is saved.
    var isIdle: Bool {
        if case .working = phase { return false }
        return true
    }

    /// The control VoiceOver and keyboard focus move to: Apply when the
    /// rules change something, Cancel otherwise, and the one button of a
    /// sheet that says why. Nil while the sheet checks; while it works, the
    /// focus stays where it was.
    var focusTarget: FocusTarget? {
        switch phase {
        case .checking:
            return nil
        case .unavailable:
            return .ok
        case .failed:
            return .close
        case .ready, .working:
            return canApplyIgnoringWork ? .apply : .cancel
        }
    }

    /// Whether the rules change something, whatever the sheet is doing.
    private var canApplyIgnoringWork: Bool {
        (preview?.corrections ?? 0) > 0
    }

    /// What VoiceOver hears once its focus has landed on the sheet's first
    /// control; nil while the sheet checks or works.
    var announcement: String? {
        switch phase {
        case .checking, .working:
            return nil
        case .unavailable(let reason), .failed(let reason):
            return reason
        case .ready:
            return TranscriptCleanupWording.sheetAnnouncement(lines: readyLines)
        }
    }

    /// Announces the sheet's lines (`announcement`), once for each phase.
    func announceSheet() {
        guard let announcement, announcedPhase != phase else { return }
        announcedPhase = phase
        services.announce(announcement, window)
    }

    // MARK: Applying and Undoing

    /// Makes the changes shown, off the main thread, in the book as the
    /// library holds it now: the book's open readers show the cleaned text,
    /// VoiceOver hears how many corrections were made, and the sheet
    /// closes. A failure is shown, with Close, and spoken.
    func apply() async {
        guard canApply, let preview, let rules, let library else { return }
        guard !isRefusedWhileTranscribing(TranscriptCleanupWording.applyFailed) else { return }
        phase = .working(TranscriptCleanupWording.applyingLine)
        let book = library.bookByID(self.book.id) ?? self.book
        // The transcript's text is rewritten: an Edit Text session of it
        // would take the new text for the user's edit. An edit saved but not
        // yet checked is taken first, and the session ends; if the cleanup
        // fails, the session begins again, so the user's later saves are
        // still taken.
        let wasEditing = await services.pauseTextEdit(book)
        let expected = preview.original
        let ruleSet = rules.rules
        let source = rules.source
        do {
            let result = try await OffMainWork.runThrowing {
                try TranscriptStore.cleanUp(book, expecting: expected, with: ruleSet, from: source)
            }
            library.bookUpdates.transcriptReplaced(bookID: book.id, with: result.installation.text)
            services.announce(TranscriptCleanupWording.applied(bookTitle: book.title, corrections: result.corrections), window)
            close()
        } catch {
            if wasEditing { await services.resumeTextEdit(book) }
            phase = .failed(TranscriptCleanupWording.applyFailed(bookTitle: book.title, reason: error.localizedDescription))
        }
    }

    /// Puts back the transcript from before the last cleanup, off the main
    /// thread, as `apply()` makes a cleanup.
    func undo() async {
        guard canPressUndo, let library else { return }
        guard !isRefusedWhileTranscribing(TranscriptCleanupWording.undoFailed) else { return }
        phase = .working(TranscriptCleanupWording.undoingLine)
        let book = library.bookByID(self.book.id) ?? self.book
        // The session is paused, and begins again on failure, as in `apply()`.
        let wasEditing = await services.pauseTextEdit(book)
        do {
            let installation = try await OffMainWork.runThrowing { try TranscriptStore.undoCleanup(of: book) }
            library.bookUpdates.transcriptReplaced(bookID: book.id, with: installation.text)
            services.announce(TranscriptCleanupWording.undone(bookTitle: book.title), window)
            close()
        } catch {
            if wasEditing { await services.resumeTextEdit(book) }
            phase = .failed(TranscriptCleanupWording.undoFailed(bookTitle: book.title, reason: error.localizedDescription))
        }
    }

    /// Whether the book is being transcribed again now, as another window
    /// may have begun since the sheet opened: if so, the sheet says so in
    /// the words `failure` gives a reason, and nothing is done.
    private func isRefusedWhileTranscribing(_ failure: (String, String) -> String) -> Bool {
        guard services.isTranscribing(book.id) else { return false }
        let reason = TranscriptCleanupError.busyTranscribing.errorDescription ?? ""
        phase = .failed(failure(book.title, reason))
        return true
    }

    /// Opens the user's copy of the rules in their text editor. Their
    /// changes are read as they come back to TextMouth (`refresh()`); a
    /// failure is shown and spoken.
    func editRules() async {
        guard phase == .ready else { return }
        editRulesNotice = await services.editRules(window).map(TranscriptCleanupWording.editRulesFailed(reason:))
        if let notice = editRulesNotice {
            services.announce(notice, window)
        }
    }

    // MARK: Closing

    /// Closes the sheet. Work under way goes on, and its end is announced.
    func close() {
        onClose()
    }

    /// Escape in a sheet without a Cancel button, one that only says why,
    /// closes it; elsewhere Cancel takes Escape itself.
    func escape() {
        switch phase {
        case .unavailable, .failed:
            close()
        case .checking, .ready, .working:
            break
        }
    }
}
