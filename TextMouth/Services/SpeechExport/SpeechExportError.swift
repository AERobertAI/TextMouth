import Foundation

/// Why a speech export (FMT43) could not speak a book into a file, in the
/// words the Export dialog shows and VoiceOver speaks. Each is found before
/// anything is spoken, and each says what the listener can do about it.
enum SpeechExportError: LocalizedError, Equatable {
    /// The voice the book is read with is a Personal Voice, named `name`,
    /// which macOS speaks aloud but never into a file.
    case personalVoice(name: String)
    /// No voice is installed to speak the book: neither the book's own nor
    /// the global one, nor the system's voice for US English.
    case noVoice
    /// A disk lacks room for the export: the spoken chapters kept on this
    /// Mac, the exported file, or both, which need about `needed` bytes on
    /// it beyond the room TextMouth always leaves free.
    case notEnoughSpace(needed: Int64)
    /// Another book is being exported as spoken audio; one export runs at a
    /// time (`SpeechExportStore.claim()`).
    case busy
    /// The part of the book chosen to export, the whole book or a range of
    /// its headings, has no words to speak.
    case nothingToSpeak
    /// A heading the Export dialog's range names is no longer in the book:
    /// the book's headings changed after the dialog opened.
    case headingsChanged

    /// The name of the Voice button in a book's reader, which the sentences
    /// that send the listener there name, so the two agree in every language.
    private static var voiceButtonName: String {
        // Translators: The name of the Voice button in a book's reader, which opens the book's voice choices.
        InterfaceText.line("common.voice", "Voice")
    }

    var errorDescription: String? {
        description(onPhone: SpeechRefusalWording.runsOnPhone)
    }

    /// The refusal in the words of the device: the Mac's, or, with `onPhone`, the iPhone's, which names no macOS
    /// setting. A parameter so that a test on the Mac reaches both, as the refusal report's lines do.
    func description(onPhone: Bool) -> String {
        switch self {
        case .personalVoice(let name):
            if onPhone {
                // Translators: Why a spoken audio export was refused on the iPhone: the book's voice is a Personal Voice. %1$@ is the voice's name and %2$@ the name of the Voice button in the book's reader.
                return InterfaceText.line("speechExportError.personalVoice.iphone", "“\(name)” is a Personal Voice, which the iPhone can't record to a file. Choose another voice with the \(Self.voiceButtonName) button in the reader, then export again.")
            }
            // Translators: Why a spoken audio export was refused: the book's voice is a Personal Voice. %1$@ is the voice's name and %2$@ the name of the Voice button in the book's reader.
            return InterfaceText.line("speechExportError.personalVoice", "“\(name)” is a Personal Voice, which macOS can't record to a file. Choose another voice with the \(Self.voiceButtonName) button in the reader, then export again.")
        case .noVoice:
            if onPhone {
                // Translators: Why a spoken audio export was refused on the iPhone: no voice is installed. Settings, Accessibility, and Spoken Content are the names of iOS settings.
                return InterfaceText.line("speechExportError.noVoice.iphone", "No voice is installed. Add one in Settings, Accessibility, Spoken Content, then export again.")
            }
            // Translators: Why a spoken audio export was refused: no voice is installed. System Settings, Accessibility, and Spoken Content are the names of macOS settings.
            return InterfaceText.line("speechExportError.noVoice", "No voice is installed. Add one in System Settings, Accessibility, Spoken Content, then export again.")
        case .notEnoughSpace(let needed):
            // Translators: Why a spoken audio export was refused: the disk is too full. %1$@ is the space the export needs and %2$@ the space TextMouth always keeps free, each a size such as 1 GB.
            return InterfaceText.line("speechExportError.notEnoughSpace", "The disk lacks room: this needs about \(Self.size(needed)), and TextMouth keeps \(Self.size(ArchiveLimits.standard.freeSpaceReserve)) free. Free some space, then export again.")
        case .busy:
            // Translators: Why a spoken audio export was refused: another one is running.
            return InterfaceText.line("speechExportError.busy", "TextMouth exports one spoken audio file at a time. Export this once the current one has finished.")
        case .nothingToSpeak:
            // Translators: Why a spoken audio export was refused: the chosen part of the book has no words.
            return InterfaceText.line("speechExportError.nothingToSpeak", "The part of the book chosen has no words to speak.")
        case .headingsChanged:
            // Translators: Why a spoken audio export was refused: the book's headings changed after the Export dialog opened.
            return InterfaceText.line("speechExportError.headingsChanged", "The book's headings changed after the dialog opened. Reopen it and choose the range again.")
        }
    }

    /// `bytes` as the Finder shows a file's size ("1 GB"), in the
    /// listener's own language.
    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
