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
/// before it will take a continued task (`begin(_:)`). From then on the session carries the task's progress, ends it
/// when the export ends, and, once the sheet has closed on an export still under way, keeps the model for the card
/// until the person closes the card.
@MainActor
final class PhoneExportSession: ObservableObject {
    /// The app's one session, which the sheets and the Library's card share.
    static let shared = PhoneExportSession(tasking: .platform)

    /// How a task is started.
    private let tasking: PhoneExportTasking
    /// The export most recently begun, until it has ended and its sheet is gone.
    private var current: BookExportModel?
    /// The system's task for `current`, while there is one.
    private var handle: (any PhoneExportTaskHandle)?
    /// What carries the model's progress to the task.
    private var watching: AnyCancellable?

    /// The export the Library's card shows: one whose sheet closed while it was still under way, until the person closes
    /// the card, which they can do once it has ended. Nil when there is no card.
    @Published private(set) var cardModel: BookExportModel?

    /// A session starting its tasks as `tasking` does.
    init(tasking: PhoneExportTasking = .none) {
        self.tasking = tasking
    }

    // MARK: Exporting

    /// Runs `model`'s export, as Export is pressed: asks for the system's continued task if it exports spoken audio (a
    /// text export takes seconds, and the background task every export holds is enough), shows the export's progress to
    /// the task while it runs, and ends the task when the export ends, however it ends. Called with the person's press
    /// of Export, on the main actor, which the system requires before it takes a continued task.
    /// - Returns: What the export did; nil when it could not start.
    @discardableResult
    func export(_ model: BookExportModel) async -> BookExportOutcome? {
        begin(model)
        let outcome = await model.export()
        end(model, outcome: outcome)
        return outcome
    }

    /// Begins to carry `model`'s export: asks for the task, and watches the model's progress.
    private func begin(_ model: BookExportModel) {
        watching = nil
        // A task of an earlier export that nobody ended is let go.
        handle?.finish(success: false)
        handle = nil
        cardModel = nil
        current = model
        // A task only for spoken audio, and only for an export that can begin: Export dimmed asks for nothing.
        guard model.isChecked(.spokenAudio), model.canExport else { return }
        let first = PhoneExportTaskMirror.update(title: model.title, progressText: model.progressText, fraction: model.progressFraction)
        handle = tasking.begin(first.title, first.subtitle) { [weak model] in
            // The system's expiry, or Cancel in the Live Activity: Stop, which keeps the chapters spoken.
            Task { @MainActor in model?.stop() }
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

    /// Passes `model`'s progress on to the task while the export runs.
    private func carry(_ model: BookExportModel) {
        guard model.isExporting else { return }
        handle?.update(PhoneExportTaskMirror.update(
            title: model.title, progressText: model.progressText, fraction: model.progressFraction
        ))
    }

    /// The export has ended, as `outcome` says (nil when it never began): the task ends with it, a success only when
    /// every file was written; a Stop, a failure, or a refusal is not one.
    private func end(_ model: BookExportModel, outcome: BookExportOutcome?) {
        guard current === model else { return }
        watching = nil
        handle?.finish(success: outcome.map { $0.failures.isEmpty && !$0.wasCancelled } ?? false)
        handle = nil
    }

    // MARK: The Sheet Closing, and the Card

    /// The sheet of `model` has closed. An export still under way goes on, with its card in the Library; one that has
    /// ended, or never began, leaves nothing.
    func sheetClosed(_ model: BookExportModel) {
        if current === model, model.isExporting {
            cardModel = model
            // Its end is a background result now: announced, but never over what VoiceOver is saying.
            model.announcementPriority = .low
        }
    }

    /// Whether the sheet may close without stopping `model`'s export: it is making the spoken audio file, whose sheet
    /// has nothing more to ask.
    func letsGo(on model: BookExportModel) -> Bool {
        current === model && model.isMakingSpeech
    }

    /// Stops the export under way, from the card or the Live Activity's Cancel: its chapters spoken are kept.
    func stop() {
        cardModel?.stop()
    }

    /// Closes the card, once its export has ended.
    func closeCard() {
        guard let cardModel, !cardModel.isExporting else { return }
        self.cardModel = nil
        if current === cardModel { current = nil }
    }
}
