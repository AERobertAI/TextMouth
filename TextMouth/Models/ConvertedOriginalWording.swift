import Foundation

/// The words of the "Keep originals of converted audio" setting (Storage
/// settings, Import Behavior), kept in one place so a test pins each sentence
/// a VoiceOver or braille user meets.
enum ConvertedOriginalWording {
    /// The toggle's label.
    static var label: String {
        String(localized: "Keep originals of converted audio",
               comment: "Label of the Storage settings switch that keeps the original file of each audio file an import converts.")
    }

    /// The toggle's accessibility hint.
    static var hint: String {
        String(localized: "Keeps each audio file an import converts, such as Ogg or AC-3, inside the book's package.",
               comment: "VoiceOver hint of the switch that keeps the originals of converted audio.")
    }

    /// The caption while the setting is on.
    static var keepingCaption: String {
        String(localized: "TextMouth keeps the original file of audio it converts at import. An original takes about as much disk space as its converted file, or twice as much when uncompressed. Export offers it as the Original file. A feed episode's original is not kept: it can be downloaded again.",
               comment: "Caption under the Keep Originals switch while it is on. \"Original file\" names the choice Export offers; keep it the same as that choice's translation.")
    }

    /// The caption while the setting is off.
    static var notKeepingCaption: String {
        String(localized: "Audio that TextMouth converts at import keeps only the converted file.",
               comment: "Caption under the Keep Originals switch while it is off.")
    }

    /// The caption that explains the setting's present state.
    static func caption(keeping: Bool) -> String {
        keeping ? keepingCaption : notKeepingCaption
    }
}
