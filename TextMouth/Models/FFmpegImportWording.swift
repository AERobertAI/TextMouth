import Foundation

/// The words of the import of formats only FFmpeg reads (FMT31, FMT32,
/// FMT50): the name each format is known by, and the sentences a listener
/// hears when such a file cannot be imported. VoiceOver speaks them and a
/// braille display shows them, so they hold no symbols and no abbreviation
/// people do not say aloud; each names the format or the file, so a listener
/// knows which of several files it is about.
enum FFmpegImportWording {
    // MARK: - The Formats' Names

    /// The name of the format of a file named with `fileExtension` (in any
    /// case, without its dot) among those FFmpeg reads, as people say it:
    /// "WMA", "WebM", "Matroska", "Flash video". Nil for any other.
    static func kindName(forExtension fileExtension: String) -> String? {
        switch fileExtension.lowercased() {
        case "wma": return "WMA"
        case "wmv": return "WMV video"
        case "asf": return "Windows Media"
        case "spx": return "Speex"
        case "mpc", "mp+": return "Musepack"
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

    /// What to do when TextMouth's own converter is missing from the app,
    /// which every such sentence ends with, naming what to import again as
    /// `what`: "Install TextMouth again, then import the file again."
    static func reinstallAdvice(importingAgain what: String = "the file") -> String {
        "Install TextMouth again, then import \(what) again."
    }

    /// Why a file of the format `kind` was not imported when the converter
    /// TextMouth carries (the FFmpeg helper, FMT50) is missing from the app,
    /// which only a damaged copy of the app is: "TextMouth can't convert WMA
    /// files because its converter is missing from the app. Install TextMouth
    /// again, then import the file again."
    static func helperMissing(kind: String) -> String {
        "TextMouth can't convert \(kind) files because its converter is missing from the app. " + reinstallAdvice()
    }

    /// Why a copy-protected Windows Media file was not imported: the
    /// sentence every copy-protected file is refused with, kept once in the
    /// advice for refused formats (`RefusedFormatAdvice.copyProtected`, FMT02).
    static let copyProtected = RefusedFormatAdvice.copyProtected

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

    /// Why a file was not imported whose sound is in a codec TextMouth's
    /// FFmpeg does not decode, which only a rare file of these formats holds:
    /// "TextMouth can't convert the sound of “Clip.avi”: it is in a kind of
    /// audio TextMouth does not read."
    static func soundNotDecoded(fileName: String) -> String {
        "TextMouth can't convert the sound of “\(fileName)”: it is in a kind of audio TextMouth does not read."
    }

    /// Why a file was not imported whose sound changes its rate or its
    /// channels partway through by more than TextMouth can follow: a rate
    /// more than 16 times the first one's or a sixteenth of it, a form that
    /// cannot be converted, or more than 1,000 changes. A sound that changes
    /// less is converted (FU-FFMPEG2): "TextMouth can't convert “Radio.mkv”:
    /// its sound changes its rate or its channels partway through, by more
    /// than TextMouth can follow."
    static func formChanged(fileName: String) -> String {
        "TextMouth can't convert “\(fileName)”: its sound changes its rate or its channels partway through, by more than TextMouth can follow."
    }

    /// Why a file was not imported when the converter stopped unexpectedly
    /// reading it, as a damaged file can make it do (the TODO's FU-FFMPEG
    /// item: a crashed helper's own sentence): "TextMouth's converter stopped
    /// unexpectedly while reading “Lecture.wma”. The file may be damaged."
    static func crashed(fileName: String) -> String {
        "TextMouth's converter stopped unexpectedly while reading “\(fileName)”. The file may be damaged."
    }

    /// Why a file was not imported when the converter could not confine
    /// itself before reading it, which it always does, so a file it reads
    /// cannot harm the Mac (FMT50's confinement): "TextMouth's converter could
    /// not make itself safe before reading “Lecture.wma”, so it did not read
    /// the file. Install TextMouth again, then import the file again."
    static func notConfined(fileName: String) -> String {
        "TextMouth's converter could not make itself safe before reading “\(fileName)”, so it did not read the file. "
            + reinstallAdvice()
    }

    /// Why a file was not imported when the converter ended, with no error,
    /// before the end of its sound: "TextMouth's converter stopped before the
    /// end of “Lecture.wma”, so it could not be imported."
    static func endedEarly(fileName: String) -> String {
        "TextMouth's converter stopped before the end of “\(fileName)”, so it could not be imported."
    }

    /// Why a file was not imported when what the converter gave back for it
    /// was not what it gives, which only a damaged copy of the app could
    /// make: "TextMouth's converter gave back audio of “Lecture.wma” that
    /// TextMouth could not read. Install TextMouth again, then import the
    /// file again."
    static func unreadableStream(fileName: String) -> String {
        "TextMouth's converter gave back audio of “\(fileName)” that TextMouth could not read. " + reinstallAdvice()
    }

    /// Why the converter was stopped when FFmpeg asked for more memory than
    /// it may use at once, as the end of the sentence every stopped
    /// conversion says (`ImportAudioConverter.Failure.killed`): "Converting
    /// Lecture.wma was stopped because it needed more memory than it may use."
    static let neededTooMuchMemory = "it needed more memory than it may use"

    /// Why a converted file failed its check when its source said no length
    /// and the file lasts no time at all, as the end of the sentence every
    /// failed check says (`ImportAudioConverter.Failure.checkFailed`): "The
    /// audio converted from Talk.webm failed its check: it lasts no time."
    static let convertedFileIsSilent = "it lasts no time"

    // MARK: - Tracks Left Out of a Book

    /// The most left-out files a notice names; "and 3 more" counts the rest.
    static let leftOutNamedLimit = 5

    /// `names`, files a book left out, as its notice names them: "“Trailer.avi”",
    /// or, for several, their count first, "2 files, “Trailer.avi” and
    /// “Intro.wmv”", with at most `leftOutNamedLimit` named.
    static func leftOutFiles(_ names: [String]) -> String {
        let named = names.prefix(leftOutNamedLimit).map { "“\($0)”" }
        let more = names.count > named.count ? ["\(names.count - named.count) more"] : []
        let listed = CountWording.list(named + more)
        return names.count == 1 ? listed : "\(CountWording.phrase(names.count, singular: "file", plural: "files")), \(listed)"
    }

    /// What a book of several tracks says of `names`, files only FFmpeg
    /// reads that it left out because the converter TextMouth carries is
    /// missing from the app (`located` is `.missing`): "TextMouth left out
    /// “Trailer.avi”, which needs TextMouth's converter, missing from the
    /// app. Install TextMouth again, then import the book again." Nil for no
    /// names, or when the converter is there: the Mac's helper, or the
    /// iPhone's session in the app (FMT54), which is never missing.
    static func leftOutNeedingConverter(_ names: [String], located: FFmpegAudioConverter.Located) -> String? {
        guard !names.isEmpty else { return nil }
        let needs = names.count == 1 ? "needs" : "need"
        switch located {
        case .found, .inProcess:
            return nil
        case .missing:
            return "TextMouth left out \(leftOutFiles(names)), which \(needs) TextMouth's converter, missing from the app. "
                + reinstallAdvice(importingAgain: "the book")
        }
    }

    /// What a book of several tracks says of `names`, files named for a
    /// format only ffmpeg reads whose bytes are of none, which it left out:
    /// "TextMouth left out “Report.spx”, which holds no sound it can read."
    /// Nil for no names.
    static func leftOutHoldingNoSound(_ names: [String]) -> String? {
        guard !names.isEmpty else { return nil }
        return "TextMouth left out \(leftOutFiles(names)), which \(names.count == 1 ? "holds" : "hold") no sound it can read."
    }

    /// The notice of a book of several tracks that left out files only
    /// FFmpeg reads (`FFmpegAudioConverter.tracksToLeaveOut(of:located:)`):
    /// `needingConverter`, the sentence of those that can't be converted here
    /// (the Mac's `leftOutNeedingConverter(_:located:)`, or the iPhone's own),
    /// then the one of `holdingNoSound`'s files, as one message; nil when it
    /// left out none.
    static func tracksLeftOutNotice(needingConverter: String?, holdingNoSound: [String]) -> String? {
        let sentences = [needingConverter, leftOutHoldingNoSound(holdingNoSound)].compactMap { $0 }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }
}
