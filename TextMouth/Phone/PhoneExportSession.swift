import Combine
import Foundation

// MARK: - The System's Continued Task

/// What the system's continued processing task of an export is to the session: told how far the export has come, and
/// told when it has ended. The iPhone's is `PhoneExportBackgroundTask`; a test's records what it is told.
protocol PhoneExportTaskHandle: AnyObject, Sendable {
    /// Shows `update` as the task's title, subtitle, and progress.
    func update(_ update: PhoneExportTaskMirror.Update)
    /// Ends the task, as succeeded or not. Called once.
    func finish(success: Bool)
}

/// How an export starts the system's continued processing task: handed to the session, so that the Mac's test host
/// drives the session with a task of its own making and no system.
struct PhoneExportTasking: Sendable {
    /// Starts a task titled `title`, subtitled `subtitle`, whose `onExpire` is what the system's expiry, or the
    /// person's cancel in the Live Activity, does: the export's Stop. Nil when the system would not take the task
    /// (no room, or the system is under load, or there is no such task on this device); the export goes on as it
    /// is, held by a background task, as it does when the screen locks in any export.
    var begin: @MainActor @Sendable (_ title: String, _ subtitle: String, _ onExpire: @escaping @Sendable () -> Void) -> (any PhoneExportTaskHandle)?

    /// No task: an export that goes on only as long as the app does.
    static let none = PhoneExportTasking { _, _, _ in nil }

    /// The device's own: the system's continued task on the iPhone (`PhoneExportBackgroundTask`), none elsewhere.
    static var platform: PhoneExportTasking {
        #if os(iOS)
        .system
        #else
        .none
        #endif
    }
}

// MARK: - The Session

/// The export under way on the iPhone (FR31, phase 2), and what it needs beyond its sheet, held by the app for as long
/// as it runs: the Export sheet may close while the spoken audio file is made, and the export goes on, with a card at
/// the top of the Library showing it (`PhoneExportProgressCard`) and the system's continued task keeping the app running
/// with the screen locked.
///
/// The sheet gives the session its model when Export is pressed, which is the person's action the system requires
/// before it will take a continued task (`export(_:)`). From then on the session carries the task's progress, ends it
/// when the export ends, and, once the sheet has closed on an export still under way, keeps the model for the card
/// until the person closes the card.
///
/// One export runs at a time: spoken audio holds the store of its chapters (`SpeechExportStore.claim()`), and the card
/// and the task are one export's. A second Export is dimmed in its sheet, with a hint that says where the first is
/// (`isBusy(for:)`), and refused here as a guard.
@MainActor
final class PhoneExportSession: ObservableObject {
    /// What happened to the Library's card, which the Library moves VoiceOver's focus by.
    enum CardEvent: Equatable, Sendable {
        /// The card appeared: the sheet closed on an export that goes on.
        case appeared
        /// The export the card shows has ended: its words now say what it did.
        case ended
        /// The person closed the card.
        case closed
        /// A new export, begun in a sheet over the Library or the reader, took the place of the card of one that had
        /// ended: the person is in that sheet, so no Library screen behind it asks for VoiceOver's focus.
        case replaced
    }

    /// The app's one session, which the sheets and the Library's card share.
    static let shared = PhoneExportSession(tasking: .platform)

    /// How a task is started.
    private let tasking: PhoneExportTasking
    /// The export most recently begun, until it has ended and its card is closed.
    private var current: BookExportModel?
    /// The system's task for `current`, while there is one.
    private var handle: (any PhoneExportTaskHandle)?
    /// What carries the model's progress to the task.
    private var watching: AnyCancellable?
    /// What the task has been told, so that its bar never goes back: the whole export's fraction does for a moment when
    /// the speech ends, before the file it made is counted as written.
    private var told = PhoneExportTaskMirror.NeverBackwards()

    /// The export under way, from the press of Export until it has ended. Nil while none runs; published, so that a sheet
    /// that dims Export for another export's sake lights it again when that one ends.
    @Published private(set) var running: BookExportModel?

    /// The export the Library's card shows: one whose sheet closed while it was still under way, until the person closes
    /// the card, which they can do once it has ended. Nil when there is no card.
    @Published private(set) var cardModel: BookExportModel?

    /// Says what happens to the card, once for each event.
    let cardEvents = PassthroughSubject<CardEvent, Never>()

    /// A session starting its tasks as `tasking` does.
    init(tasking: PhoneExportTasking = .none) {
        self.tasking = tasking
    }

    // MARK: Exporting

    /// Whether another export than `model`'s is under way, which dims Export in `model`'s sheet.
    func isBusy(for model: BookExportModel) -> Bool {
        guard let running else { return false }
        return running !== model
    }

    /// Runs `model`'s export, as Export is pressed: asks for the system's continued task if it exports spoken audio (a
    /// text export takes seconds, and the background task every export holds is enough), shows the export's progress to
    /// the task while it runs, and ends the task when the export ends, however it ends. Called with the person's press
    /// of Export, on the main actor, which the system requires before it takes a continued task.
    /// - Returns: What the export did; nil when it could not start, as when another export is under way.
    @discardableResult
    func export(_ model: BookExportModel) async -> BookExportOutcome? {
        // One export at a time: a second would end the first's card and task, and fight it for the chapters' store.
        guard running == nil else { return nil }
        running = model
        begin(model)
        let outcome = await model.export()
        end(model, outcome: outcome)
        running = nil
        return outcome
    }

    /// Begins to carry `model`'s export: asks for the task, and watches the model's progress.
    private func begin(_ model: BookExportModel) {
        watching = nil
        handle = nil
        told = PhoneExportTaskMirror.NeverBackwards()
        // A card left from an earlier export, which has ended, goes with the new one, whose sheet the person is in.
        if cardModel != nil {
            cardModel = nil
            cardEvents.send(.replaced)
        }
        current = model
        // A task only for spoken audio, and only for an export that can begin: Export dimmed asks for nothing.
        guard model.isChecked(.spokenAudio), model.canExport else { return }
        let first = taskUpdate(for: model)
        handle = tasking.begin(first.title, first.subtitle) { [weak self, weak model] in
            // The system's expiry, or Cancel in the Live Activity.
            Task { @MainActor in
                guard let self, let model else { return }
                self.stopBySystem(model)
            }
        }
        guard handle != nil else { return }
        // The model changes its phase and its speech progress on the main actor; it is read after the change.
        watching = model.$phase.combineLatest(model.$speechProgress)
            .receive(on: RunLoop.main)
            .sink { [weak self, weak model] _, _ in
                guard let self, let model else { return }
                self.carry(model)
            }
    }

    /// iOS ended the task, by its expiry or by the person's Cancel in the Live Activity: the export stops as Stop stops
    /// it, its chapters spoken kept, and its end says that iOS stopped it, which the person's own Stop never does.
    func stopBySystem(_ model: BookExportModel) {
        guard model.isExporting else { return }
        model.wordsBeforeTheEnd = PhoneExportWording.stoppedBySystem
        model.stop()
    }

    /// Passes `model`'s progress on to the task while the export runs.
    func carry(_ model: BookExportModel) {
        guard model.isExporting else { return }
        handle?.update(told.next(taskUpdate(for: model)))
    }

    /// What the task shows of `model` now: the sheet's title, the progress words, and how far the whole export has come
    /// (`PhoneExportTaskMirror.fraction(done:total:speech:)`), not the part under way that the sheet's bar shows, which
    /// starts again at 0 for the encoding and would hold the task's bar still through it.
    private func taskUpdate(for model: BookExportModel) -> PhoneExportTaskMirror.Update {
        var done = 0
        var total = 0
        if case .exporting(let filesDone, let files) = model.phase {
            done = filesDone
            total = files
        }
        return PhoneExportTaskMirror.update(
            title: model.title,
            progressText: model.progressText,
            fraction: PhoneExportTaskMirror.fraction(done: done, total: total, speech: model.speechProgress)
        )
    }

    /// The export has ended, as `outcome` says (nil when it never began): the task ends with it, a success only when
    /// every file was written; a Stop, a failure, or a refusal is not one. A card shows what it did.
    private func end(_ model: BookExportModel, outcome: BookExportOutcome?) {
        // iOS's words are the end's, which takes them as it says what the export did. An export that never began, as one
        // stopped in its first moments, while it waits for a braille table's check, has no end to take them: they would
        // begin the next export's end, a Stop of the person's own.
        model.wordsBeforeTheEnd = nil
        guard current === model else { return }
        watching = nil
        handle?.finish(success: outcome.map { $0.failures.isEmpty && !$0.wasCancelled } ?? false)
        handle = nil
        if cardModel === model { cardEvents.send(.ended) }
    }

    // MARK: The Sheet Closing, and the Card

    /// The sheet of `model` has closed. An export still under way goes on, with its card in the Library; one that has
    /// ended, or never began, leaves nothing.
    func sheetClosed(_ model: BookExportModel) {
        guard current === model, model.isExporting, cardModel == nil else { return }
        cardModel = model
        // Its end is a background result now: announced, but never over what VoiceOver is saying.
        model.announcementPriority = .low
        // Nobody can answer a question now: the export asks no more (`PhoneExportQuestionPrompt.sheetClosed()`).
        #if !os(macOS)
        model.questionPrompt?.sheetClosed()
        #endif
        cardEvents.send(.appeared)
    }

    /// Whether the sheet may close without stopping `model`'s export: it is making the spoken audio file. A file of the
    /// same book may still follow it (a transcript, an original), and a question about a chapter nested too deeply may come
    /// with it; with the sheet closed, the prompt answers Cancel Export (`PhoneExportQuestionPrompt.sheetClosed()`).
    func letsGo(on model: BookExportModel) -> Bool {
        current === model && model.isMakingSpeech
    }

    /// Stops the export under way, from the card: its chapters spoken are kept.
    func stop() {
        cardModel?.stop()
    }

    /// Closes the card, once its export has ended.
    func closeCard() {
        guard let cardModel, !cardModel.isExporting else { return }
        self.cardModel = nil
        if current === cardModel { current = nil }
        cardEvents.send(.closed)
    }
}

// MARK: - Where the Card Sends Focus

/// What VoiceOver's focus does as the export's card comes and goes (`PhoneExportSession.cardEvents`): one request for each
/// change, from one place, so that two never compete and the later one wins by luck.
enum PhoneExportCardFocus {
    /// Where focus goes: the card's title, or the Library's first row.
    enum Target: Equatable, Sendable {
        case card
        case firstRow
    }

    /// What the Library focuses once a sheet has closed: the card, when it appeared as that sheet closed, else the row or
    /// button that opened the sheet. The sheet's dismissal asks, and only it: the card's appearing asks for nothing.
    enum AfterSheet: Equatable, Sendable {
        case card
        case opener
    }

    /// Where focus goes for `event`, nil for nowhere.
    /// - The card appearing: nowhere, since the dismissal of the sheet that closed on it decides (`afterSheetClosed`).
    /// - Its export ending: nowhere, so that the person is not moved off what they are doing; the end is announced. Only
    ///   when focus was on the card's Stop, which has gone, it goes to the card's title.
    /// - The card closed: the Library's first row.
    /// - The card replaced by a new export: nowhere, since the person is in that export's sheet, and a request from a
    ///   Library screen behind it would ask for a row the sheet covers.
    static func target(for event: PhoneExportSession.CardEvent, focusWasOnStop: Bool) -> Target? {
        switch event {
        case .appeared, .replaced: return nil
        case .ended: return focusWasOnStop ? .card : nil
        case .closed: return .firstRow
        }
    }

    /// What the Library focuses once a sheet has closed, `cardAppeared` saying whether the card appeared as it did.
    static func afterSheetClosed(cardAppeared: Bool) -> AfterSheet {
        cardAppeared ? .card : .opener
    }
}
