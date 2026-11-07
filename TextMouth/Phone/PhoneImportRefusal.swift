import Foundation

/// Why the iPhone can't import a file yet, thrown on iOS where the Mac would
/// start a helper program the phone doesn't have: Apple's audio converter,
/// textutil for a Word 6 or Word 95 document, and the braille translator.
///
/// The shared import wraps it in an `ImportFailure`, as every failure is,
/// and on iOS that failure's sentence is this refusal's, naming the file and
/// the next step (`sentence(naming:)`), in place of "Could not import …".
/// The Mac never throws one: every throw is behind `#if os(iOS)`.
enum PhoneImportRefusal: LocalizedError, Equatable, Sendable {
    /// Audio the import converts (Ogg, Opus, AC-3, AMR, MP2, CAF, and the
    /// rest of `ImportAudioConverter.convertedExtensions`), named as `kind`.
    case convertedAudio(kind: String)
    /// A Word 6 or Word 95 document, which TextMouth's own Word reader
    /// leaves to textutil.
    case wordSixOrNinetyFive
    /// A braille book: BRF, BRL, or PEF.
    case braille

    /// The sentence a person hears about the file called `name` (as
    /// `PhoneImportWording.displayName(of:)` gives it), or about "This
    /// file" when `name` is nil.
    func sentence(naming name: String?) -> String {
        switch self {
        case let .convertedAudio(kind):
            return PhoneImportWording.convertedAudioRefusal(name, kind: kind)
        case .wordSixOrNinetyFive:
            return PhoneImportWording.wordSixOrNinetyFiveRefusal(name)
        case .braille:
            return PhoneImportWording.brailleRefusal(name)
        }
    }

    /// The sentence without the file's name, for an alert that has no
    /// `ImportFailure` around the refusal to name the file.
    var errorDescription: String? {
        sentence(naming: nil)
    }

    // MARK: - Braille

    /// Throws `.braille`: the phone has no braille translator yet, so every
    /// braille book is refused before it is read. A function rather than a
    /// bare `throw`, so the reader's code after the call draws no warning
    /// that it will never run.
    static func refuseBrailleBook() throws {
        throw PhoneImportRefusal.braille
    }

    // MARK: - Audio

    /// Throws `.convertedAudio`, naming the kind of the first of `sources`,
    /// when there are any: the files an import would convert, which the
    /// phone can't. Nothing is thrown for none.
    static func refuseConversion(of sources: [URL]) throws {
        guard let first = sources.first else { return }
        throw PhoneImportRefusal.convertedAudio(kind: audioKindName(of: first))
    }

    /// The name of the audio format the file at `url` holds, as the Mac's
    /// documentation of the import's conversions names them
    /// (`ImportAudioConverter`, `AudioContentSniffer`): its content first,
    /// since an Ogg file named .m4a is Ogg all the same, then its extension.
    static func audioKindName(of url: URL) -> String {
        audioKindName(content: AudioContentSniffer.kind(of: url), fileExtension: url.pathExtension)
    }

    /// The name of the audio format of content `kind` in a file whose
    /// extension is `fileExtension`. Ogg holding Opus is called Opus when
    /// the extension says so, as the sniffer can't tell the two apart; a
    /// kind the sniffer can't settle is named by the extension, and an
    /// unknown extension in capitals, as "WMA".
    static func audioKindName(content kind: AudioContentSniffer.Kind, fileExtension: String) -> String {
        let ext = fileExtension.lowercased()
        switch kind {
        case .ogg: return ext == "opus" ? "Opus" : "Ogg"
        case .ac3: return "AC-3"
        case .caf: return "CAF"
        case .aifc: return "AIFF-C"
        case .au: return "AU"
        case .wave64: return "Wave64"
        case .amr: return "AMR"
        case .threeGPP: return "3GPP"
        case .mpegLayerI: return "MP1"
        case .mpegLayerII: return "MP2"
        case .aiff, .wave, .flac, .mpegLayerIII, .adts, .mpeg4, .unknown:
            return audioKindName(fileExtension: ext)
        }
    }

    /// The name of the audio format an extension, in lowercase, stands for
    /// among those the import converts; the extension in capitals for any
    /// other.
    private static func audioKindName(fileExtension ext: String) -> String {
        switch ext {
        case "ogg", "oga": return "Ogg"
        case "opus": return "Opus"
        case "ac3", "ec3", "eac3": return "AC-3"
        case "caf": return "CAF"
        case "aifc": return "AIFF-C"
        case "au", "snd": return "AU"
        case "w64": return "Wave64"
        case "amr", "awb": return "AMR"
        case "3gp", "3g2", "3ga": return "3GPP"
        case "mp1": return "MP1"
        case "mp2", "mpa": return "MP2"
        default: return ext.isEmpty ? "this format" : ext.uppercased()
        }
    }
}
