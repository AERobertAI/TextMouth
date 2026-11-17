import Foundation

/// The sentences of `InProcessEngine`, the iPhone's way of running a C
/// library inside the app (DR34): a call that ran past its time limit and was
/// abandoned, and every call refused after it until TextMouth is opened
/// again. Each names its work with the phrase its engine was made with, such
/// as "the braille translation", so that another library's engine says its
/// own. A sentence is read after an import's own words ("Could not import
/// “book.brf”. Reading its text failed: "), so none names the file.
enum InProcessEngineWording {
    /// A call abandoned past its limit: "TextMouth stopped the braille
    /// translation because it ran longer than 11 seconds, and won't try
    /// again until TextMouth is opened again." The seconds are whole, rounded
    /// up, as the Mac's watchdog says them.
    static func abandoned(_ work: String, seconds: TimeInterval) -> String {
        "TextMouth stopped \(work) because it ran longer than \(CountWording.seconds(Int(seconds.rounded(.up)))), "
            + "and won't try again until TextMouth is opened again."
    }

    /// A call refused because an earlier one was abandoned: "TextMouth
    /// stopped the braille translation earlier because it took too long,
    /// and won't try again until TextMouth is opened again."
    static func refused(_ work: String) -> String {
        "TextMouth stopped \(work) earlier because it took too long, and won't try again until TextMouth is opened again."
    }
}
