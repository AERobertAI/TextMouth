import Foundation

/// The sentences of `InProcessEngine`, the iPhone's way of running a C
/// library inside the app (DR34): a call that ran past its time limit and was
/// abandoned, and every call refused after it until TextMouth is closed and
/// opened again. Each names its work with the phrase its engine was made
/// with, such as "the braille translation", so that another library's engine
/// says its own. A sentence is read after an import's own words ("Could not
/// import “book.brf”. Reading its text failed: "), so none names the file.
///
/// The remedy is closing TextMouth and opening it again, never just opening
/// it: an iPhone app left in the background keeps its process, abandoned
/// thread and all, so a listener who only switched back to TextMouth would
/// hear the same refusal (the review of November 16, finding 1).
enum InProcessEngineWording {
    /// A call abandoned past its limit: "TextMouth stopped the braille
    /// translation because it ran longer than 11 seconds, and won't try
    /// again until TextMouth is closed and opened again." The reason is the
    /// watchdog's own words (`WatchedProcess.KillReason.tookTooLong`), as the
    /// Mac says them when it stops its helper; the seconds are at least one,
    /// since a call whose time was already spent when it began still ran for
    /// some.
    static func abandoned(_ work: String, seconds: TimeInterval) -> String {
        // `work` and `reason` are English fragments of other areas (the engine's
        // owner names its work; the watchdog words its reason) until those convert.
        let reason = WatchedProcess.KillReason.tookTooLong(seconds: max(1, seconds)).words // l10n: no (inside this sentence until the watchdog's area converts)
        // Translators: Said when a library call inside the iPhone app ran too long and was abandoned. %1$@ is the work's name, such as "the braille translation" (English until its area converts); %2$@ is why it was stopped, such as "it ran longer than 11 seconds" (English until the watchdog's area converts). Read after an import's own words.
        return InterfaceText.line("inProcessEngine.abandoned", "TextMouth stopped \(work) because \(reason), and won't try again until TextMouth is closed and opened again.")
    }

    /// A call refused because an earlier one was abandoned: "TextMouth
    /// stopped the braille translation earlier because it took too long,
    /// and won't try again until TextMouth is closed and opened again."
    static func refused(_ work: String) -> String {
        // Translators: Said when a library call inside the iPhone app is refused because an earlier one was abandoned for taking too long. %@ is the work's name, such as "the braille translation" (English until its area converts). Read after an import's own words.
        InterfaceText.line("inProcessEngine.refused", "TextMouth stopped \(work) earlier because it took too long, and won't try again until TextMouth is closed and opened again.")
    }
}
