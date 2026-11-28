import Foundation

/// The words of the "Keep originals of converted audio" setting (Storage
/// settings, Import Behavior), kept in one place so a test pins each sentence
/// a VoiceOver or braille user meets.
enum ConvertedOriginalWording {
    /// The toggle's label.
    static var label: String {
        // Translators: Label of the Storage settings switch that keeps the original file of each audio file an import converts.
        InterfaceText.line("convertedOriginal.label", "Keep originals of converted audio")
    }

    /// The toggle's accessibility hint.
    static var hint: String {
        // Translators: VoiceOver hint of the switch that keeps the originals of converted audio.
        InterfaceText.line("convertedOriginal.hint", "Keeps each audio file an import converts, such as Ogg or AC-3, inside the book's package.")
    }

    /// The caption while the setting is on.
    static var keepingCaption: String {
        // Translators: Caption under the Keep Originals switch while it is on. "Original file" names the choice Export offers; keep it the same as that choice's translation.
        InterfaceText.line("convertedOriginal.keepingCaption", "TextMouth keeps the original file of audio it converts at import. An original takes about as much disk space as its converted file, or twice as much when uncompressed. Export offers it as the Original file. A feed episode's original is not kept: it can be downloaded again.")
    }

    /// The caption while the setting is off.
    static var notKeepingCaption: String {
        // Translators: Caption under the Keep Originals switch while it is off.
        InterfaceText.line("convertedOriginal.notKeepingCaption", "Audio that TextMouth converts at import keeps only the converted file.")
    }

    /// The caption that explains the setting's present state.
    static func caption(keeping: Bool) -> String {
        keeping ? keepingCaption : notKeepingCaption
    }
}
