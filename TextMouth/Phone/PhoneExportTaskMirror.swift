import Foundation

/// What the system's continued processing task for a spoken audio export shows and measures (FR31, phase 2), made from
/// the export's own progress so that the Mac's test host reads it: the title, which is the Export sheet's ("Export
/// Moby-Dick"); the subtitle, which is the progress words ("Speaking chapter 3 of 12…"); and the progress, as whole units
/// out of `totalUnits`.
///
/// iOS expires a continued task that reports no progress, and shows a bar for the progress it does report in the Live
/// Activity and on the Lock Screen, so the export's fraction is reported at every change, at least each chapter and each
/// quarter second of one (`SpeechExportJob.progressInterval`).
enum PhoneExportTaskMirror {
    /// The units a task's progress is measured in: its total. A thousand is fine enough to move for each percent a
    /// long book's progress makes, and coarse enough to read.
    static let totalUnits: Int64 = 1_000

    /// What the task shows and measures at one moment.
    struct Update: Equatable, Sendable {
        /// The task's title.
        let title: String
        /// The task's subtitle: how far the export has come, in words.
        let subtitle: String
        /// How many of `PhoneExportTaskMirror.totalUnits` are done.
        let completedUnits: Int64
    }

    /// The task's update for the export titled `title`, which says `progressText` (the model's words; none until it
    /// has begun) at `fraction` of the way (from 0 to 1; none while it isn't known, which counts as none done). A
    /// fraction outside 0 to 1 is held to it.
    static func update(title: String, progressText: String?, fraction: Double?) -> Update {
        let held = min(max(fraction ?? 0, 0), 1)
        return Update(title: title, subtitle: progressText ?? "", completedUnits: Int64((held * Double(totalUnits)).rounded()))
    }

    /// What the task has been told, so that its bar never goes back: the model's own fraction does when the speech ends
    /// and the bar returns to the items done, and the system's bar would show a book that is further from done than it
    /// was. Each update goes out with the most units reported so far.
    struct NeverBackwards: Sendable {
        /// The most units any update has reported.
        private var most: Int64 = 0

        /// `update`, with its units raised to the most reported so far.
        mutating func next(_ update: Update) -> Update {
            most = max(most, update.completedUnits)
            return Update(title: update.title, subtitle: update.subtitle, completedUnits: most)
        }
    }
}
