import Foundation

/// The words of the "Keep originals of converted audio" setting (Storage
/// settings, Import Behavior), kept in one place so a test pins each sentence
/// a VoiceOver or braille user meets.
enum ConvertedOriginalWording {
    /// The toggle's label.
    static let label = "Keep originals of converted audio"

    /// The toggle's accessibility hint.
    static let hint =
        "Also keeps each audio file that an import converts, such as Ogg or AC-3, inside the book's package."

    /// The caption while the setting is on.
    static let keepingCaption =
        "When TextMouth converts audio at import, it keeps the original file too. An original takes about "
        + "as much disk space as its converted file, or about twice as much when it is uncompressed. "
        + "Export offers it as the Original file. A feed episode's original is not kept: it can be "
        + "downloaded again."

    /// The caption while the setting is off.
    static let notKeepingCaption = "Audio that TextMouth converts at import keeps only the converted file."

    /// The caption that explains the setting's present state.
    static func caption(keeping: Bool) -> String {
        keeping ? keepingCaption : notKeepingCaption
    }
}
