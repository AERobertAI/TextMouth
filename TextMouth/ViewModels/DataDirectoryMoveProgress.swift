import Foundation
import os

// MARK: - A Move Under Way (FR02)

/// A data-directory move under way (FR02), as every Library window's sheet
/// and Storage settings show it: what the move is doing, how far its copy
/// has got, and its Cancel.
///
/// The library model makes one for each move that copies the library
/// (Change Location's Move Library Here, Reset to Default, or a location
/// config.json names) and drops it when the move ends, however it ends. It
/// tells VoiceOver, through `VoiceOverAnnouncer`, what the move waits for,
/// when the copy starts, each quarter of the copy, and that Cancel was
/// pressed. How the move ended, done, failed, or cancelled, is announced by
/// whoever started it: Storage settings in its status line, or the library
/// model for a move config.json asked for.
@MainActor
final class DataDirectoryMoveProgress: ObservableObject, Identifiable {
    /// What the move is doing.
    enum Phase: Equatable {
        /// Getting ready: waiting to hold the storage work, or checking which
        /// books are only in the cloud.
        case preparing
        /// Waiting for storage work under way to finish (TODO S04).
        case waiting(StorageWork)
        /// Copying the library, `percent` of it so far.
        case copying
        /// The copy is complete: checking it and putting it in place, which
        /// is too late to cancel.
        case finishing
    }

    /// The new location, as chosen.
    let destination: URL
    /// Whether the move is Reset to Default, back to the default location.
    let isResetToDefault: Bool

    /// What the move is doing now.
    @Published private(set) var phase: Phase = .preparing
    /// How much of the library is copied, in whole percent.
    @Published private(set) var percent = 0
    /// Whether Cancel was pressed.
    @Published private(set) var isCancelRequested = false
    /// A sentence about the last action refused while the library moves,
    /// such as opening a book, for the sheet; nil when there is none.
    var notice: String? { noticeWording?() }
    /// How the notice is worded, kept so that it is made in the interface language in use when the sheet shows it (FR39).
    @Published private var noticeWording: (() -> String)?

    /// Shows the sentence `wording` makes as the notice, made again whenever the sheet shows it.
    func refuse(_ wording: @escaping () -> String) {
        noticeWording = wording
    }

    /// Whether Cancel was pressed, read by the copy on its own thread.
    private let cancellation = OSAllocatedUnfairLock(initialState: false)
    /// The highest quarter of the copy announced so far: 1 for 25 percent.
    private var announcedQuarter = 0
    /// Whether the move has ended.
    private(set) var hasEnded = false
    /// What to do once the move has ended, such as quitting.
    private var endHandlers: [@MainActor @Sendable () -> Void] = []

    /// The move under way in this process, if any: one at a time, since
    /// each holds the storage work (`StorageBoundary.holdWork(for:)`).
    /// Quitting asks it to stop first (`stopForQuit(then:)`).
    private(set) static weak var running: DataDirectoryMoveProgress?

    /// A move to `destination`; `isResetToDefault` for Reset to Default.
    init(destination: URL, isResetToDefault: Bool = false) {
        self.destination = destination
        self.isResetToDefault = isResetToDefault
    }

    // MARK: The Move's Steps

    /// Marks the move as the one under way in this process.
    func begin() {
        Self.running = self
    }

    /// The move waits for `work` under way to finish before it copies
    /// anything: shown, and announced once for each kind of work.
    func wait(for work: StorageWork) {
        guard phase != .waiting(work) else { return }
        phase = .waiting(work)
        VoiceOverAnnouncer.announce(work.waitingMessage)
    }

    /// The move checks the library before copying it.
    func beginPreparing() {
        phase = .preparing
    }

    /// The copy starts: shown, and announced with where the library goes.
    func beginCopying() {
        phase = .copying
        percent = 0
        VoiceOverAnnouncer.announce(DataDirectoryMoveWording.startAnnouncement(to: destination, isResetToDefault: isResetToDefault))
    }

    /// Takes the copy's `progress`: the percentage shown, each quarter newly
    /// reached announced, and, once every item is copied, the finishing.
    func receive(_ progress: DataDirectoryCopyProgress) {
        guard !hasEnded else { return }
        percent = progress.percent
        if progress.isComplete {
            phase = .finishing
            return
        }
        // A quarter is announced once, even when one large book carries the
        // copy past several: only the highest reached is said.
        let quarter = progress.percent / 25
        if quarter > announcedQuarter, quarter < 4 {
            announcedQuarter = quarter
            VoiceOverAnnouncer.announce(DataDirectoryMoveWording.quarterAnnouncement(percent: quarter * 25))
        }
    }

    /// Cancel: the copy stops before its next item, and the move then
    /// deletes what it copied. Announced at once, so the press is heard to
    /// count. Does nothing once the copy is complete, or after a first Cancel.
    func cancel() {
        guard canCancel, !isCancelRequested else { return }
        cancellation.withLock { $0 = true }
        isCancelRequested = true
        VoiceOverAnnouncer.announce(DataDirectoryMoveWording.cancellingAnnouncement)
    }

    /// Whether Cancel can still stop the move: until the copy is complete.
    var canCancel: Bool {
        !hasEnded && phase != .finishing
    }

    /// Throws `DataDirectoryMigrationError.cancelled` when Cancel was
    /// pressed: the move checks before each step it can still skip.
    func checkCancellation() throws {
        if isCancelled {
            throw DataDirectoryMigrationError.cancelled
        }
    }

    /// Marks the move as ended, however it ended, and runs, on the main
    /// queue's next turn, what waited for it.
    func end() {
        guard !hasEnded else { return }
        hasEnded = true
        if Self.running === self {
            Self.running = nil
        }
        let handlers = endHandlers
        endHandlers.removeAll()
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                for handler in handlers {
                    handler()
                }
            }
        }
    }

    /// Runs `handler` once the move has ended: at once, on the main queue's
    /// next turn, when it already has.
    func whenEnded(_ handler: @escaping @MainActor @Sendable () -> Void) {
        guard !hasEnded else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { handler() }
            }
            return
        }
        endHandlers.append(handler)
    }

    // MARK: The Copy's Thread

    /// Whether Cancel was pressed: read from any thread.
    nonisolated var isCancelled: Bool {
        cancellation.withLock { $0 }
    }

    /// The observer the copy reports to and asks, on its own thread. Each
    /// report that changes the whole percentage, and the last, reaches this
    /// move on the main actor; `outer`, an observer bound around the move,
    /// as a test binds one, hears every report too, after this move, and
    /// can cancel it as well.
    nonisolated func copyObserver(followedBy outer: DataDirectoryCopyObserver?) -> DataDirectoryCopyObserver {
        let lastPercent = OSAllocatedUnfairLock(initialState: -1)
        return DataDirectoryCopyObserver(
            report: { [weak self] progress in
                let changed = lastPercent.withLock { last -> Bool in
                    guard last != progress.percent else { return false }
                    last = progress.percent
                    return true
                }
                if changed || progress.isComplete, let move = self {
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { move.receive(progress) }
                    }
                }
                outer?.report(progress)
            },
            isCancelled: { [weak self] in
                (self?.isCancelled ?? false) || (outer?.isCancelled() ?? false)
            }
        )
    }

    // MARK: Words

    /// What the move is doing, as the sheet and Storage settings show it:
    /// "Moving the library… 40 percent".
    var statusText: String {
        DataDirectoryMoveWording.status(phase: phase, percent: percent, isCancelling: isCancelRequested && canCancel)
    }

    /// The progress bar's value as VoiceOver speaks it: "40 percent".
    var spokenValue: String {
        DataDirectoryMoveWording.spokenValue(phase: phase, percent: percent, isCancelling: isCancelRequested && canCancel)
    }

    /// How full the progress bar is, from 0 to 1, or nil while it shows no
    /// amount: before the copy starts.
    var fraction: Double? {
        switch phase {
        case .copying, .finishing: return Double(percent) / 100
        case .preparing, .waiting: return nil
        }
    }

    /// Where the library is going, as the sheet says it.
    var destinationText: String {
        DataDirectoryMoveWording.destination(destination, isResetToDefault: isResetToDefault)
    }

    // MARK: Quitting

    /// Stops the move under way, if it is copying, before TextMouth quits,
    /// so no partial copy is left behind: Cancel is pressed, or, when the
    /// copy is already complete, the move is let finish, and `quit` runs
    /// once it has ended. A move that has not started copying, still
    /// waiting for other work or getting ready, has written nothing, and
    /// does not hold up quitting. Returns whether a move was stopped, in
    /// which case the request to quit is to be cancelled for now.
    @discardableResult
    static func stopForQuit(then quit: @escaping @MainActor @Sendable () -> Void) -> Bool {
        guard let move = running, !move.hasEnded, move.hasStartedCopying else { return false }
        VoiceOverAnnouncer.announce(DataDirectoryMoveWording.quitAnnouncement)
        move.cancel()
        move.whenEnded(quit)
        return true
    }

    /// Whether the copy has started, so the move may have written a
    /// partial copy that only its own ending deletes.
    var hasStartedCopying: Bool {
        phase == .copying || phase == .finishing
    }
}

// MARK: - Requests

/// A data-directory move asked for (FR02): where to, whether it is Reset to
/// Default, and how it tells which books are only in the cloud.
struct DataDirectoryMoveRequest {
    /// The new location, as chosen.
    let destination: URL
    /// Whether the move is Reset to Default, back to the default location.
    var isResetToDefault = false
    /// How the move tells which books are only in the cloud: `live` in the
    /// app; tests pass one that pretends files are there.
    let access: MaintenanceFileAccess
}

// MARK: - Refusals

/// Why a data-directory move was refused before anything was copied (FR02).
/// Each description is what the Storage settings status line and the
/// library's error alert show, after "Failed to move directory: ".
enum DataDirectoryMoveRefusal: LocalizedError, Equatable {
    /// Books are open in readers: their titles.
    case booksOpen([String])
    /// This many books have files only in the cloud, which copying would
    /// have to download first.
    case booksNotDownloaded(Int)

    var errorDescription: String? {
        switch self {
        case .booksOpen(let titles):
            let quoted = titles.map { "“\($0)”" }
            guard quoted.count > 1 else {
                guard let title = quoted.first else {
                    // Translators: Why a move of the library was refused: a book is open in a reader. "It" is that book.
                    return InterfaceText.line("dataDirectoryMoveRefusal.booksOpen.library", "The library can't move while a book is open. Close it first.")
                }
                // Translators: Why a move of the library was refused: a book is open in a reader. %@ is the book's title, in quotation marks.
                return InterfaceText.line("dataDirectoryMoveRefusal.booksOpen.libraryCant", "The library can't move while a book is open. Close \(title) first.")
            }
            return SentenceWording.joined([
                // Translators: First sentence of why a move of the library was refused: several books are open in readers.
                InterfaceText.line("dataDirectoryMoveRefusal.booksOpen.libraryWhile", "The library can't move while books are open."),
                // Translators: Last sentence of why a move of the library was refused: which books to close. %@ is their titles in quotation marks, as a short list.
                InterfaceText.line("dataDirectoryMoveRefusal.booksOpen.these", "Close these first: \(DataDirectoryDestinationChange.listing(quoted))."),
            ])
        case .booksNotDownloaded(let count):
            return SentenceWording.joined([
                // Translators: First sentence of why a move of the library was refused: some books' files are only in the cloud. %lld is how many books.
                InterfaceText.line("dataDirectoryMoveRefusal.booksNotDownloaded", "\(number: count) books aren't downloaded."),
                LibraryCloudWording.downloadFirst(count: count),
            ])
        }
    }
}

// MARK: - Words

/// The words of a data-directory move under way (FR02), kept in one place so
/// the sheet, Storage settings, VoiceOver, and the tests say the same thing.
enum DataDirectoryMoveWording {
    /// The sheet's heading.
    static var title: String {
        // Translators: Heading of the sheet that shows the library being moved to another folder.
        InterfaceText.line("dataDirectoryMove.title", "Moving the Library")
    }
    /// What VoiceOver calls the progress bar.
    static var progressLabel: String {
        // Translators: VoiceOver label of the progress bar of the library being moved.
        InterfaceText.line("dataDirectoryMove.progressLabel", "Moving the library")
    }
    /// What VoiceOver calls the Cancel button.
    static var cancelLabel: String {
        // Translators: VoiceOver label of the button that cancels the move of the library.
        InterfaceText.line("dataDirectoryMove.cancelLabel", "Cancel Move")
    }
    /// What the Cancel button does.
    static var cancelHint: String {
        // Translators: VoiceOver hint of the button that cancels the move of the library.
        InterfaceText.line("dataDirectoryMove.cancelHint", "Stops moving the library. The library stays where it is, and nothing is changed.")
    }
    /// Announced when Cancel is pressed.
    static var cancellingAnnouncement: String {
        // Translators: Announcement when the listener cancels the move of the library.
        InterfaceText.line("dataDirectoryMove.cancellingAnnouncement", "Cancelling the move.")
    }
    /// Announced when TextMouth is asked to quit during a move.
    static var quitAnnouncement: String {
        // Translators: Announcement when TextMouth is asked to quit during a move of the library.
        InterfaceText.line("dataDirectoryMove.quitAnnouncement", "Stopping the library move before quitting.")
    }
    /// Added to the done message when Cancel came too late.
    static var finishedDespiteCancelSentence: String {
        // Translators: Sentence added to the done message of a move of the library when Cancel was pressed after the copy was complete.
        InterfaceText.line("dataDirectoryMove.finishedDespiteCancelSentence", "The copy was already complete when Cancel was pressed, so the move went ahead.")
    }

    /// The move sheet's Cancel button: it cancels the move, as `cancelLabel` says to VoiceOver.
    static var cancelTitle: String {
        // Translators: Button of the sheet that shows the library being moved: cancels the move.
        InterfaceText.line("common.cancel", "Cancel")
    }

    /// The last sentence of several reasons a move of the data directory was
    /// refused: what to do about the new location.
    static var chooseAnotherLocation: String {
        // Translators: Last sentence of why a move of the data directory was refused: what to do about the new location.
        InterfaceText.line("dataDirectoryMove.chooseAnotherLocation", "Choose another location.")
    }

    /// Announced when the copy starts: where the library goes.
    static func startAnnouncement(to destination: URL, isResetToDefault: Bool) -> String {
        isResetToDefault
            // Translators: Announcement when the library's move back to the default location starts. %@ is the default location's path.
            ? InterfaceText.line("dataDirectoryMove.startAnnouncement.location", "Moving the library to the default location, \(destination.path).")
            // Translators: Announcement when the library's move starts. %@ is the new location's path.
            : InterfaceText.line("dataDirectoryMove.startAnnouncement.library", "Moving the library to \(destination.path).")
    }

    /// Announced as the copy reaches each quarter.
    static func quarterAnnouncement(percent: Int) -> String {
        // Translators: Announcement as the move of the library reaches each quarter. %lld is the percent done, from 0 to 100.
        InterfaceText.line("dataDirectoryMove.quarterAnnouncement", "Moving the library, \(number: percent) percent.")
    }

    /// Where the library is going, as the sheet says it.
    static func destination(_ destination: URL, isResetToDefault: Bool) -> String {
        isResetToDefault
            // Translators: Line of the move sheet that says where the library is going: the default location. %@ is its path.
            ? InterfaceText.line("dataDirectoryMove.destination.location", "To the default location, \(destination.path)")
            // Translators: Line of the move sheet that says where the library is going. %@ is the new location's path.
            : InterfaceText.line("dataDirectoryMove.destination.value", "To \(destination.path)")
    }

    /// What the move is doing, as shown.
    static func status(phase: DataDirectoryMoveProgress.Phase, percent: Int, isCancelling: Bool) -> String {
        if isCancelling {
            // Translators: Status line of the move sheet while the move is being cancelled.
            return InterfaceText.line("dataDirectoryMove.status", "Cancelling the move…")
        }
        switch phase {
        case .preparing:
            // Translators: Status line of the move sheet before the copy starts.
            return InterfaceText.line("dataDirectoryMove.status.preparing", "Getting ready to move the library…")
        case .waiting(let work): return work.waitingMessage
        case .copying:
            // Translators: Status line of the move sheet while the library is copied. %lld is the percent done, from 0 to 100.
            return InterfaceText.line("dataDirectoryMove.status.copying", "Moving the library… \(number: percent) percent")
        case .finishing:
            // Translators: Status line of the move sheet while the move is being finished.
            return InterfaceText.line("dataDirectoryMove.status.finishing", "Finishing the move…")
        }
    }

    /// The progress bar's value as VoiceOver speaks it.
    static func spokenValue(phase: DataDirectoryMoveProgress.Phase, percent: Int, isCancelling: Bool) -> String {
        if isCancelling {
            // Translators: VoiceOver value of the move's progress bar while the move is being cancelled.
            return InterfaceText.line("dataDirectoryMove.spokenValue", "Cancelling")
        }
        switch phase {
        case .preparing:
            // Translators: VoiceOver value of the move's progress bar before the copy starts.
            return InterfaceText.line("dataDirectoryMove.spokenValue.preparing", "Getting ready")
        case .waiting(let work): return work.waitingMessage
        case .copying:
            // Translators: VoiceOver value of the move's progress bar while the library is copied. %lld is the percent done, from 0 to 100.
            return InterfaceText.line("common.countPercent", "\(number: percent) percent")
        case .finishing:
            // Translators: VoiceOver value of the move's progress bar while the move is being finished.
            return InterfaceText.line("dataDirectoryMove.spokenValue.finishing", "Finishing")
        }
    }

    /// The outcome of a cancelled move.
    static func cancelled(stillAt root: DataDirectoryLocation) -> String {
        SentenceWording.joined([
            // Translators: First sentence of the message after the move of the library was cancelled.
            InterfaceText.line("dataDirectoryMove.cancelled.moveStopped", "Move cancelled."),
            // Translators: Last sentence of the message after the move of the library was cancelled. %@ is the library's path, with where it leads when it is a link.
            InterfaceText.line("dataDirectoryMove.cancelled.library", "The library is still at \(root.namedDescription)."),
        ])
    }

    /// What a Library window says when an app-wide action reaches it while
    /// the library moves, or nil for an action that needs no library, such
    /// as bringing the Library window forward.
    static func refusal(of action: GlobalAction) -> String? {
        switch action {
        case .openBookFile, .newFromText, .importDAISYFolder:
            // Translators: What a Library window says when a command that adds a book is chosen while the library is being moved.
            return InterfaceText.line("dataDirectoryMove.refusal.openBookFile", "Books can't be added while the library is moving.")
        case .openBookWindow, .continueToNextBook:
            // Translators: What a Library window says when a command that opens a book is chosen while the library is being moved.
            return InterfaceText.line("dataDirectoryMove.refusal.openBookWindow", "Books can't be opened while the library is moving.")
        case .openFiles, .goToLibrary:
            // Files opened from Finder are imported once the move is done
            // (the import waits for it, TODO S04), and open then.
            return nil
        }
    }

    /// What an import question's sheet says, and VoiceOver speaks, when it
    /// is answered while the library moves. An answer can add, replace, or
    /// discard a book, move books into a new folder, or open a book, and the
    /// library and its files must not change while they are copied, so no
    /// answer is taken until the move ends, however it ends. The question
    /// stays, to be answered then.
    static var importAnswerRefusal: String {
        SentenceWording.joined([
            // Translators: First sentence of what an import question says when it is answered while the library is being moved.
            InterfaceText.line("dataDirectoryMove.importAnswerRefusal.questions", "Import questions can't be answered while the library is moving."),
            // Translators: Last sentence of what an import question says when it is answered while the library is being moved.
            InterfaceText.line("dataDirectoryMove.importAnswerRefusal.when", "Answer this one when the move ends."),
        ])
    }
}
