import Foundation

/// The words of the import of formats only ffmpeg reads (FMT31, FMT32): the
/// name each format is known by, and the sentences a listener hears when
/// such a file cannot be imported. VoiceOver speaks them and a braille
/// display shows them, so they hold no symbols and no abbreviation people
/// do not say aloud; each names the format, so a listener knows which of
/// several files it is about.
enum FFmpegImportWording {
    // MARK: - The Formats' Names

    /// The name of the format of a file named with `fileExtension` (in any
    /// case, without its dot) among those ffmpeg reads, as people say it:
    /// "WMA", "WebM", "Matroska", "Flash video". Nil for any other.
    static func kindName(forExtension fileExtension: String) -> String? {
        switch fileExtension.lowercased() {
        case "wma": return "WMA"
        case "wmv": return "WMV video"
        case "asf": return "Windows Media"
        case "spx": return "Speex"
        case "mpc", "mp+", "mpp": return "Musepack"
        case "webm", "weba": return "WebM"
        case "mka", "mkv": return "Matroska"
        case "avi": return "AVI video"
        case "flv": return "Flash video"
        case "ra", "rm", "rmvb": return "RealMedia"
        default: return nil
        }
    }

    /// The name of the format of the file at `url`, which ffmpeg converts,
    /// whose bytes are of `container`: "Speex" for Speex in Ogg whatever the
    /// file's name; otherwise its extension's name (`kindName(forExtension:)`);
    /// for a name that says nothing of the format, its container's
    /// (`kindName(of:)`), so no sentence reads "To import XYZ files"; and the
    /// extension in capitals, or "this format", when nothing names it.
    static func kindName(of url: URL, container: FFmpegContainer?) -> String {
        if container == .oggSpeex { return "Speex" }
        let fileExtension = url.pathExtension
        if let named = kindName(forExtension: fileExtension) { return named }
        if let container { return kindName(of: container) }
        return fileExtension.isEmpty ? "this format" : fileExtension.uppercased()
    }

    /// The name of the format whose container is `container`, as people say it.
    static func kindName(of container: FFmpegContainer) -> String {
        switch container {
        case .asf: return "Windows Media"
        case .matroska: return "Matroska"
        case .flv: return "Flash video"
        case .avi: return "AVI video"
        case .realMedia: return "RealMedia"
        case .musepack7, .musepack8: return "Musepack"
        case .oggSpeex: return "Speex"
        case .ogg: return "Ogg"
        }
    }

    // MARK: - When It Can't Be Imported

    /// How to install ffmpeg, which every sentence below ends with, naming
    /// what is installed as `program`: "Install it with Homebrew by typing
    /// brew install ffmpeg in Terminal, then import the file again."
    static func installAdvice(naming program: String) -> String {
        "Install \(program) with Homebrew by typing brew install ffmpeg in Terminal, then import the file again."
    }

    /// Why a file of the format `kind` was not imported on a Mac without
    /// ffmpeg: "To import WMA files, TextMouth needs ffmpeg, a free program
    /// that isn't installed on this Mac. Install it with Homebrew by typing
    /// brew install ffmpeg in Terminal, then import the file again."
    static func ffmpegMissing(kind: String) -> String {
        "To import \(kind) files, TextMouth needs ffmpeg, a free program that isn't installed on this Mac. "
            + installAdvice(naming: "it")
    }

    /// Why a file of the format `kind` was not imported on a Mac whose
    /// ffmpeg has no ffprobe beside it, which tells TextMouth what a file
    /// holds: "To import WMA files, TextMouth needs ffprobe, which comes
    /// with ffmpeg but isn't installed on this Mac. Install ffmpeg with
    /// Homebrew by typing brew install ffmpeg in Terminal, then import the
    /// file again."
    static func ffprobeMissing(kind: String) -> String {
        "To import \(kind) files, TextMouth needs ffprobe, which comes with ffmpeg but isn't installed on this Mac. "
            + installAdvice(naming: "ffmpeg")
    }

    /// Why a copy-protected Windows Media file was not imported: the
    /// sentence every copy-protected file is refused with (FMT02).
    static let copyProtected = "TextMouth cannot open copy-protected files."

    /// Why a file was not imported whose bytes are not of the format its
    /// name says (`kind`), or are damaged: "TextMouth can't read
    /// “Lecture.wma” as WMA. It may be damaged, or named for another
    /// format." No article comes before the name, which may need "an"
    /// ("AVI video") or "a" ("WMA").
    static func notRecognized(fileName: String, kind: String) -> String {
        "TextMouth can't read “\(fileName)” as \(kind). It may be damaged, or named for another format."
    }

    /// Why a file was not imported that holds no sound, such as a video
    /// without a sound track: "“Clip.mkv” holds no sound to import."
    static func noSound(fileName: String) -> String {
        "“\(fileName)” holds no sound to import."
    }

    /// Why a converted file failed its check when its source said no length
    /// and the file lasts no time at all, as the end of the sentence every
    /// failed check says (`ImportAudioConverter.Failure.checkFailed`): "The
    /// audio converted from Talk.webm failed its check: it lasts no time."
    static let convertedFileIsSilent = "it lasts no time"
}
