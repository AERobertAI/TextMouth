import Foundation

/// What the system's continued processing task for a spoken audio export shows and measures (FR31, phase 2), made from
/// the export's own progress so that the Mac's test host reads it: the title, which is the Export sheet's ("Export
/// Moby-Dick"); the subtitle, which is the progress words ("Speaking chapter 3 of 12…"); and the progress, as whole units
/// out of `totalUnits`.
///
/// iOS expires a continued task that reports no progress, and shows a bar for the progress it does report in the Live
/// Activity and on the Lock Screen, so the export's fraction is reported at every change, at least each chapter and each
/// quarter second of one (`SpeechExportJob.progressInterval`).
///
/// The bar measures the whole export (`fraction(done:total:speech:)`), never the part under way that the sheet's own bar
/// shows: the sheet's starts again at 0 when the encoding begins, and when the files before the spoken audio are done, so
/// a bar that never goes back would stand still through the whole encoding of a long book, which the system takes for a
/// stalled task.
enum PhoneExportTaskMirror {
    /// The units a task's progress is measured in: its total. A thousand is fine enough to move for each percent a
    /// long book's progress makes, and coarse enough to read.
    static let totalUnits: Int64 = 1_000

    /// How much of a spoken audio file's part of the bar its speaking fills; the encoding fills the rest. Speaking takes
    /// most of a spoken audio file's time (the voices render 18 to 195 times faster than real time, and the encoders
    /// many times faster than that), but an MP3 of a long book takes minutes to encode on a phone, and the bar moves
    /// through those minutes too.
    static let speakingShare = 0.8

    /// How far the whole export has come, from 0 to 1, as the task's bar measures it: `done` of its `total` files written,
    /// and of the file under way, the part its speech has come (`speech`, nil for a file that isn't spoken audio, which
    /// counts only once it is written). Speaking fills `speakingShare` of a spoken audio file's part and its encoding the
    /// rest, so the bar moves all through both. Until the first file is written the count is not known (`total` is 0),
    /// and the file under way stands for the whole.
    static func fraction(done: Int, total: Int, speech: SpeechExportProgress?) -> Double {
        let part: Double
        switch speech {
        case .speaking(_, _, let fraction)?:
            part = speakingShare * held(fraction)
        case .encoding(_, let fraction)?:
            part = speakingShare + (1 - speakingShare) * held(fraction)
        case .ended?, nil:
            part = 0
        }
        guard total > 0 else { return part }
        return held((Double(min(max(done, 0), total)) + part) / Double(total))
    }

    /// `value` held to 0 through 1.
    private static func held(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

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
        Update(title: title, subtitle: progressText ?? "", completedUnits: Int64((held(fraction ?? 0) * Double(totalUnits)).rounded()))
    }

    /// What the task has been told, so that its bar never goes back: the whole export's fraction does for a moment when
    /// the speech ends, before the file it made is counted as written, and the system's bar would show a book that is
    /// further from done than it was. Each update goes out with the most units reported so far.
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
