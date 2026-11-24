import Foundation

/// Why the iPhone can't import a file yet, thrown on iOS where the Mac would
/// start a helper program the phone doesn't have: Apple's audio converter,
/// and textutil for a Word 6 or Word 95 document; and why it can't read a
/// braille book that needs one of a Mac's own braille tables, which only
/// that Mac has. (Braille, refused here until November 16, 2026, is
/// translated in the app itself since DR34, with the tables TextMouth
/// bundles; the formats only FFmpeg reads, refused here until November 17,
/// are converted in the app itself since FMT54, with the FFmpeg TextMouth
/// links; and True Audio, WavPack, and Monkey's Audio, refused here until
/// November 18, are decoded in the app by TextMouth's own readers, as on
/// the Mac.)
///
/// The shared import wraps it in an `ImportFailure`, as every failure is,
/// and on iOS that failure's sentence is this refusal's, naming the file and
/// the next step (`sentence(naming:)`), in place of "Could not import …".
/// The Mac never throws one: every throw is behind `#if os(iOS)`.
enum PhoneImportRefusal: LocalizedError, Equatable, Sendable {
    /// Audio the import converts with Apple's converter on the Mac (Ogg,
    /// Opus, AC-3, AMR, MP2, CAF, and the rest of
    /// `ImportAudioConverter.convertedExtensions` but the formats only FFmpeg
    /// reads and those of TextMouth's own readers), named as `kind`.
    case convertedAudio(kind: String)
    /// A Word 6 or Word 95 document, which TextMouth's own Word reader
    /// leaves to textutil.
    case wordSixOrNinetyFive
    /// A braille book that needs one of a Mac's own braille tables (a
    /// stored "mac:" value), named by its file name `table`: a book a Mac
    /// read, sent in a TextMouth package or a shared library, or the import
    /// table of a config.json made on a Mac. The iPhone has none of them,
    /// so the Mac's sentences, which speak of "this Mac's" table, would be
    /// wrong here (the review of November 16, finding 5).
    case macBrailleTable(String)

    /// The sentence a person hears about the file called `name` (as
    /// `PhoneImportWording.displayName(of:)` gives it), or about "This
    /// file" when `name` is nil.
    func sentence(naming name: String?) -> String {
        switch self {
        case let .convertedAudio(kind):
            return PhoneImportWording.convertedAudioRefusal(name, kind: kind)
        case .wordSixOrNinetyFive:
            return PhoneImportWording.wordSixOrNinetyFiveRefusal(name)
        case let .macBrailleTable(table):
            return PhoneImportWording.macBrailleTableRefusal(name, table: table)
        }
    }

    /// The sentence without the file's name, for an alert that has no
    /// `ImportFailure` around the refusal to name the file.
    var errorDescription: String? {
        sentence(naming: nil)
    }

    // MARK: - Braille

    /// Throws `.macBrailleTable` when `table`, a stored value
    /// (`BrailleTableSource`), names one of a Mac's own tables that the phone's
    /// pack has no table of the same file name for; nothing for a table
    /// TextMouth bundles, and nothing for a Mac's table whose file name the pack
    /// has, which the phone reads with its own (FR40,
    /// `BrailleTableCatalog.bundledID(forStored:)`).
    static func refuseMacBrailleTable(_ table: String) throws {
        let (source, fileName) = BrailleTableSource.parse(table)
        guard source == .mac, BrailleTableCatalog.bundledID(forStored: table) == nil else { return }
        throw PhoneImportRefusal.macBrailleTable(fileName)
    }

    // MARK: - Audio

    /// Throws for the files among `sources`, those an import would convert,
    /// that the phone can't import, before any is converted; nothing for none:
    /// - **A copy-protected Windows Media file**, first, with the Mac's own
    ///   refusal (`FFmpegAudioConverter.Failure.copyProtected`, FU-FFMPEG): no
    ///   Mac could convert it either, so it is told as such before any other
    ///   file is refused and before the phone sends anyone to the Mac.
    /// - **`.convertedAudio`**, naming its kind, for the first file the phone
    ///   has no converter for: every format the import converts but those
    ///   only FFmpeg reads (`FFmpegAudioConverter.converts(_:)`) and those of
    ///   TextMouth's own readers (`isReadByOwnReader(_:)`), which the app
    ///   converts itself, as the Mac does.
    static func refuseConversion(of sources: [URL]) throws {
        if sources.contains(where: { FFmpegAudioConverter.isCopyProtected($0, container: FFmpegContainer.of(fileAt: $0)) }) {
            throw FFmpegAudioConverter.Failure.copyProtected
        }
        guard let first = sources.first(where: { !FFmpegAudioConverter.converts($0) && !isReadByOwnReader($0) }) else { return }
        throw PhoneImportRefusal.convertedAudio(kind: audioKindName(of: first))
    }

    /// Whether the file at `url` is one TextMouth's own readers decode
    /// (`OwnAudioFormat`: True Audio, WavPack, Monkey's Audio), which the
    /// app converts itself with no helper program, as on the Mac
    /// (`OwnAudioConverter`): its bytes are of such a format whatever its
    /// name; or its name is such a format's and its bytes are of no format
    /// the import converts, which the conversion then fails as the Mac does,
    /// saying it can't be read (and with an old WavPack file's own sentence),
    /// rather than sending anyone to a Mac that could not read it either. A
    /// file of another format the import converts (Ogg, AC-3, ...) named like
    /// one is not let by its name: it is refused as what it is, as it was.
    static func isReadByOwnReader(_ url: URL) -> Bool {
        if OwnAudioConverter.format(of: url) != nil { return true }
        guard ImportAudioConverter.ownReaderExtensions.contains(url.pathExtension.lowercased()) else { return false }
        return AudioContentSniffer.verdict(for: AudioContentSniffer.kind(of: url)) != .convert
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
        case .ogg: return ext == "opus" ? "Opus" : "Ogg" // l10n: no (a format's name)
        case .ac3: return "AC-3"
        case .caf: return "CAF"
        case .aifc: return "AIFF-C"
        case .au: return "AU"
        case .wave64: return "Wave64" // l10n: no (a format's name)
        case .amr: return "AMR"
        case .threeGPP: return "3GPP"
        case .mpegLayerI: return "MP1"
        case .mpegLayerII: return "MP2"
        // A file of TextMouth's own readers is never refused (`isReadByOwnReader(_:)`).
        case .aiff, .wave, .flac, .mpegLayerIII, .adts, .mpeg4, .ownReader, .unknown:
            return audioKindName(fileExtension: ext)
        }
    }

    /// The name of the audio format an extension, in lowercase, stands for
    /// among those the import converts, those only ffmpeg reads named as
    /// the Mac names them (`FFmpegImportWording.kindName(forExtension:)`);
    /// the extension in capitals for any other.
    private static func audioKindName(fileExtension ext: String) -> String {
        if let ffmpegKind = FFmpegImportWording.kindName(forExtension: ext) { return ffmpegKind }
        switch ext {
        case "ogg", "oga": return "Ogg" // l10n: no (a format's name)
        case "opus": return "Opus" // l10n: no (a format's name)
        case "ac3", "ec3", "eac3": return "AC-3"
        case "caf": return "CAF"
        case "aifc": return "AIFF-C"
        case "au", "snd": return "AU"
        case "w64": return "Wave64" // l10n: no (a format's name)
        case "amr", "awb": return "AMR"
        case "3gp", "3g2", "3ga": return "3GPP"
        case "mp1": return "MP1"
        case "mp2", "mpa": return "MP2"
        default:
            return ext.isEmpty
                // Translators: Stands for the name of a file's format inside a sentence about importing it, when the file's name and its bytes name none, as in "TextMouth can't read “Clip” as this format."
                ? InterfaceText.line("common.thisFormat", "this format")
                : ext.uppercased()
        }
    }
}
