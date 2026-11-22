import Foundation

/// The words of the import of formats only FFmpeg reads (FMT31, FMT32,
/// FMT50): the name each format is known by, and the sentences a listener
/// hears when such a file cannot be imported. VoiceOver speaks them and a
/// braille display shows them, so they hold no symbols and no abbreviation
/// people do not say aloud; each names the format or the file, so a listener
/// knows which of several files it is about.
///
/// Every sentence is a localized whole (FR34). A format's name is a
/// localized string of its own, so it fills a sentence as a noun does.
enum FFmpegImportWording {
    // MARK: - The Formats' Names

    /// The name "WMA".
    private static var wma: String {
        // Translators: The name of the Windows Media Audio format, as people say it. Inside sentences about importing a file of that format.
        InterfaceText.line("ffmpegImport.wma", "WMA")
    }

    /// The name "WMV video".
    private static var wmv: String {
        // Translators: The name of the Windows Media Video format, as people say it. Inside sentences about importing a file of that format.
        InterfaceText.line("ffmpegImport.wmv", "WMV video")
    }

    /// The name "Windows Media".
    private static var windowsMedia: String {
        // Translators: The name of the Windows Media container format, as people say it. Inside sentences about importing a file of that format.
        InterfaceText.line("ffmpegImport.windowsMedia", "Windows Media")
    }

    /// The name "Speex".
    private static var speex: String {
        // Translators: The name of the Speex speech format. Inside sentences about importing a file of that format.
        InterfaceText.line("ffmpegImport.speex", "Speex")
    }

    /// The name "Musepack".
    private static var musepack: String {
        // Translators: The name of the Musepack audio format. Inside sentences about importing a file of that format.
        InterfaceText.line("ffmpegImport.musepack", "Musepack")
    }

    /// The name "WebM".
    private static var webM: String {
        // Translators: The name of the WebM format. Inside sentences about importing a file of that format.
        InterfaceText.line("ffmpegImport.webM", "WebM")
    }

    /// The name "Matroska".
    private static var matroska: String {
        // Translators: The name of the Matroska container format, as people say it. Inside sentences about importing a file of that format.
        InterfaceText.line("ffmpegImport.matroska", "Matroska")
    }

    /// The name "AVI video".
    private static var avi: String {
        // Translators: The name of the AVI video format, as people say it. Inside sentences about importing a file of that format.
        InterfaceText.line("ffmpegImport.avi", "AVI video")
    }

    /// The name "Flash video".
    private static var flashVideo: String {
        // Translators: The name of the Flash video format, as people say it. Inside sentences about importing a file of that format.
        InterfaceText.line("ffmpegImport.flashVideo", "Flash video")
    }

    /// The name "RealMedia".
    private static var realMedia: String {
        // Translators: The name of the RealMedia format. Inside sentences about importing a file of that format.
        InterfaceText.line("ffmpegImport.realMedia", "RealMedia")
    }

    /// The name "Ogg".
    private static var ogg: String {
        // Translators: The name of the Ogg container format. Inside sentences about importing a file of that format.
        InterfaceText.line("ffmpegImport.ogg", "Ogg")
    }

    /// The name of the format of a file named with `fileExtension` (in any
    /// case, without its dot) among those FFmpeg reads, as people say it:
    /// "WMA", "WebM", "Matroska", "Flash video". Nil for any other.
    static func kindName(forExtension fileExtension: String) -> String? {
        switch fileExtension.lowercased() {
        case "wma": return wma // l10n: no (file extensions)
        case "wmv": return wmv // l10n: no (file extensions)
        case "asf": return windowsMedia // l10n: no (file extensions)
        case "spx": return speex // l10n: no (file extensions)
        case "mpc", "mp+": return musepack // l10n: no (file extensions)
        case "webm", "weba": return webM // l10n: no (file extensions)
        case "mka", "mkv": return matroska // l10n: no (file extensions)
        case "avi": return avi // l10n: no (file extensions)
        case "flv": return flashVideo // l10n: no (file extensions)
        case "ra", "rm", "rmvb": return realMedia // l10n: no (file extensions)
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
        if container == .oggSpeex { return speex }
        let fileExtension = url.pathExtension
        if let named = kindName(forExtension: fileExtension) { return named }
        if let container { return kindName(of: container) }
        return fileExtension.isEmpty
            // Translators: Stands for the name of a file's format inside a sentence about importing it, when the file's name and its bytes name none, as in "TextMouth can't read “Clip” as this format."
            ? InterfaceText.line("common.thisFormat", "this format")
            : fileExtension.uppercased()
    }

    /// The name of the format whose container is `container`, as people say it.
    static func kindName(of container: FFmpegContainer) -> String {
        switch container {
        case .asf: return windowsMedia
        case .matroska: return matroska
        case .flv: return flashVideo
        case .avi: return avi
        case .realMedia: return realMedia
        case .musepack7, .musepack8: return musepack
        case .oggSpeex: return speex
        case .ogg: return ogg
        }
    }

    // MARK: - When It Can't Be Imported

    /// What to do when TextMouth's own converter is missing from the app,
    /// which every such sentence ends with, naming what to import again:
    /// "Install TextMouth again, then import the file again." (`importingBook`
    /// false) or "... import the book again."
    static func reinstallAdvice(importingBook: Bool = false) -> String {
        importingBook
            // Translators: Advice ending the notice about a book's files that TextMouth's own converter could not read because the converter is missing from the app.
            ? InterfaceText.line("ffmpegImport.reinstallAdvice.book", "Install TextMouth again, then import the book again.")
            // Translators: Advice ending the sentences about a file that TextMouth's own converter could not read because the converter is missing from the app.
            : InterfaceText.line("ffmpegImport.reinstallAdvice.file", "Install TextMouth again, then import the file again.")
    }

    /// Why a file of the format `kind` was not imported when the converter
    /// TextMouth carries (the FFmpeg helper, FMT50) is missing from the app,
    /// which only a damaged copy of the app is: "TextMouth can't convert WMA
    /// files because its converter is missing from the app. Install TextMouth
    /// again, then import the file again."
    static func helperMissing(kind: String) -> String {
        // Translators: Why a file was not imported: the converter TextMouth carries is missing from the app, which only a damaged copy is. %@ is the name of the file's format, such as WMA or Matroska. Advice to install the app again follows.
        let why = InterfaceText.line("ffmpegImport.helperMissing", "TextMouth can't convert \(kind) files because its converter is missing from the app.")
        return SentenceWording.joined([why, reinstallAdvice()])
    }

    /// Why a copy-protected Windows Media file was not imported: the
    /// sentence every copy-protected file is refused with, kept once in the
    /// advice for refused formats (`RefusedFormatAdvice.copyProtected`, FMT02).
    static var copyProtected: String { RefusedFormatAdvice.copyProtected }

    /// Why a file was not imported whose bytes are not of the format its
    /// name says (`kind`), or are damaged: "TextMouth can't read
    /// “Lecture.wma” as WMA. It may be damaged, or named for another
    /// format." No article comes before the name, which may need "an"
    /// ("AVI video") or "a" ("WMA").
    static func notRecognized(fileName: String, kind: String) -> String {
        // Translators: Why a file was not imported: its bytes are not of the format its name says, or are damaged. %1$@ is the file's name and %2$@ the name of the format its name says, such as WMA or AVI video.
        InterfaceText.line("ffmpegImport.notRecognized", "TextMouth can't read “\(fileName)” as \(kind). It may be damaged, or named for another format.")
    }

    /// Why a file was not imported that holds no sound, such as a video
    /// without a sound track: "“Clip.mkv” holds no sound to import."
    static func noSound(fileName: String) -> String {
        // Translators: Why a file was not imported: it holds no sound, such as a video without a sound track. %@ is the file's name.
        InterfaceText.line("ffmpegImport.noSound", "“\(fileName)” holds no sound to import.")
    }

    /// Why a file was not imported whose sound is in a codec TextMouth's
    /// FFmpeg does not decode, which only a rare file of these formats holds:
    /// "TextMouth can't convert the sound of “Clip.avi”: it is in a kind of
    /// audio TextMouth does not read."
    static func soundNotDecoded(fileName: String) -> String {
        // Translators: Why a file was not imported: its sound is in a codec TextMouth does not decode. %@ is the file's name.
        InterfaceText.line("ffmpegImport.soundNotDecoded", "TextMouth can't convert the sound of “\(fileName)”: it is in a kind of audio it does not read.")
    }

    /// Why a file was not imported whose sound changes its rate or its
    /// channels partway through by more than TextMouth can follow: a rate
    /// more than 16 times the first one's or a sixteenth of it, a form that
    /// cannot be converted, or more than 1,000 changes. A sound that changes
    /// less is converted (FU-FFMPEG2): "TextMouth can't convert “Radio.mkv”:
    /// its sound changes its rate or its channels partway through, by more
    /// than TextMouth can follow."
    static func formChanged(fileName: String) -> String {
        // Translators: Why a file was not imported: its sound changes its sample rate or its number of channels partway through, by more than the converter can follow. %@ is the file's name.
        InterfaceText.line("ffmpegImport.formChanged", "TextMouth can't convert “\(fileName)”: its sound changes rate or channels partway through, by more than it can follow.")
    }

    /// Why the iPhone stopped a conversion because the app's memory grew
    /// past what it keeps free (the FMT54 review's finding 4), by more than
    /// `megabytes` MB since the conversion began, other conversions of the
    /// import counted with it: the end of "Converting tones.wma was stopped
    /// because the app's memory grew by more than 1700 MB while it ran."
    /// A reason in English, as `WatchedProcess.KillReason.words` words every
    /// reason: the debug log writes it too.
    static func memoryGrew(megabytes: Int64) -> String {
        "the app's memory grew by more than \(megabytes) MB while it ran" // l10n: no (a kill reason, in English like KillReason.words, which the debug log writes too)
    }

    /// Why the iPhone stopped a conversion it began with less than 1 GB of
    /// memory free, `freeMegabytes` MB, half of which it keeps free (the
    /// check of the FMT54 review's fixes, item 2): the end of "Converting
    /// tones.wma was stopped because the iPhone had only 400 MB of memory free
    /// when it began, and TextMouth keeps half of that free." English, like
    /// `memoryGrew(megabytes:)`.
    static func beganShortOfMemory(freeMegabytes: Int64) -> String {
        "the iPhone had only \(freeMegabytes) MB of memory free when it began, and TextMouth keeps half of that free" // l10n: no (a kill reason, in English like KillReason.words, which the debug log writes too)
    }

    /// Why a file was not imported one frame of whose sound holds more
    /// samples than TextMouth decodes at once (16,777,216 over its channels,
    /// almost three minutes of 48 kHz stereo in one piece), where a good file
    /// holds far fewer: "TextMouth can't convert “Radio.mkv”: part of its
    /// sound is stored in one piece too large for TextMouth to decode."
    static func frameTooLarge(fileName: String) -> String {
        // Translators: Why a file was not imported: one frame of its sound holds more samples than TextMouth decodes at once. %@ is the file's name.
        InterfaceText.line("ffmpegImport.frameTooLarge", "TextMouth can't convert “\(fileName)”: part of its sound is in one piece too large to decode.")
    }

    /// Why a file was not imported when the converter stopped unexpectedly
    /// reading it, as a damaged file can make it do (the TODO's FU-FFMPEG
    /// item: a crashed helper's own sentence): "TextMouth's converter stopped
    /// unexpectedly while reading “Lecture.wma”. The file may be damaged."
    static func crashed(fileName: String) -> String {
        // Translators: Why a file was not imported: TextMouth's converter stopped unexpectedly while reading it, as a damaged file can make it do. %@ is the file's name.
        InterfaceText.line("ffmpegImport.crashed", "TextMouth's converter stopped unexpectedly while reading “\(fileName)”. The file may be damaged.")
    }

    /// Why a file was not imported when the converter could not confine
    /// itself before reading it, which it always does, so a file it reads
    /// cannot harm the Mac (FMT50's confinement): "TextMouth's converter could
    /// not make itself safe before reading “Lecture.wma”, so it did not read
    /// the file. Install TextMouth again, then import the file again."
    static func notConfined(fileName: String) -> String {
        // Translators: Why a file was not imported: TextMouth's converter could not confine itself before reading it, so it did not read the file. %@ is the file's name. Advice to install the app again follows.
        let why = InterfaceText.line("ffmpegImport.notConfined", "TextMouth's converter could not make itself safe before reading “\(fileName)”, so it did not read the file.")
        return SentenceWording.joined([why, reinstallAdvice()])
    }

    /// Why a file was not imported when the converter ended, with no error,
    /// before the end of its sound: "TextMouth's converter stopped before the
    /// end of “Lecture.wma”, so it could not be imported."
    static func endedEarly(fileName: String) -> String {
        // Translators: Why a file was not imported: TextMouth's converter ended before the end of its sound, with no error. %@ is the file's name.
        InterfaceText.line("ffmpegImport.endedEarly", "TextMouth's converter stopped before the end of “\(fileName)”, so it could not be imported.")
    }

    /// Why a file was not imported when what the converter gave back for it
    /// was not what it gives, which only a damaged copy of the app could
    /// make: "TextMouth's converter gave back audio of “Lecture.wma” that
    /// TextMouth could not read. Install TextMouth again, then import the
    /// file again."
    static func unreadableStream(fileName: String) -> String {
        // Translators: Why a file was not imported: what TextMouth's converter gave back was not audio TextMouth reads, which only a damaged copy of the app could make. %@ is the file's name. Advice to install the app again follows.
        let why = InterfaceText.line("ffmpegImport.unreadableStream", "TextMouth's converter gave back audio of “\(fileName)” that TextMouth could not read.")
        return SentenceWording.joined([why, reinstallAdvice()])
    }

    /// Why the converter was stopped when FFmpeg asked for more memory than
    /// it may use at once, as the end of the sentence every stopped
    /// conversion says (`ImportAudioConverter.Failure.killed`): "Converting
    /// Lecture.wma was stopped because it needed more memory than it may use."
    /// English, like every kill reason (`WatchedProcess.KillReason.words`).
    static let neededTooMuchMemory = "it needed more memory than it may use" // l10n: no (a kill reason, in English like KillReason.words, which the debug log writes too)

    /// Why a converted file failed its check when its source said no length
    /// and the file lasts no time at all, as the end of the sentence every
    /// failed check says (`ImportAudioConverter.Failure.checkFailed`): "The
    /// audio converted from Talk.webm failed its check: it lasts no time."
    static var convertedFileIsSilent: String {
        // Translators: The reason inside "The audio converted from <file> failed its check: <reason>.": the converted file has no length at all. Starts with a lowercase letter and has no full stop, which the sentence adds.
        InterfaceText.line("ffmpegImport.convertedFileIsSilent", "it lasts no time")
    }

    /// What the iPhone's FFmpeg engine names its work by in its two sentences
    /// (FMT54, `InProcessEngineWording`), for a call abandoned past its time
    /// and for every one refused after it: "TextMouth stopped the audio
    /// conversion because it ran longer than 62 seconds, and won't try again
    /// until TextMouth is closed and opened again."
    static let inAppWork = "the audio conversion" // l10n: no (inside InProcessEngineWording's English sentences until that area converts)

    // MARK: - Sound the Decoder Refused

    /// What an import tells of `names`, the files whose sound the decoder
    /// refused in part (FU03), which the book keeps as silence so its length
    /// and chapters hold: "Part of “Lecture.wma” could not be decoded and is
    /// kept as silence." Nil for no names.
    static func partlyDecodedNotice(_ names: [String]) -> String? {
        guard !names.isEmpty else { return nil }
        // One file is named alone; several are counted and listed, set off by commas.
        if names.count == 1 {
            // Translators: Notice that part of one file's sound could not be decoded and the book keeps it as silence. %@ is the file's name in curly quotes.
            return InterfaceText.line("ffmpegImport.partlyDecodedNotice.silence", "Part of \(leftOutFiles(names)) could not be decoded and is kept as silence.")
        }
        // Translators: Notice that part of several files' sound could not be decoded and the book keeps it as silence. %1$lld is the number of files and %2$@ their names in curly quotes, listed as a sentence lists them.
        return InterfaceText.line("ffmpegImport.partlyDecodedNotice.files", "Part of \(number: names.count) files, \(leftOutList(names)), could not be decoded and is kept as silence.")
    }

    // MARK: - Tracks Left Out of a Book

    /// The most left-out files a notice names; "and 3 more" counts the rest.
    static let leftOutNamedLimit = 5

    /// `names` in curly quotes, at most `leftOutNamedLimit` of them, then
    /// the count of the rest, listed as a sentence lists them: "“a.avi” and
    /// “b.wmv”", "“1.wmv”, “2.wmv”, and 2 more".
    private static func leftOutList(_ names: [String]) -> String {
        let named = names.prefix(leftOutNamedLimit).map { "“\($0)”" }
        let more = names.count > named.count
            // Translators: Last item of a list of the files a book left out, counting the files not named. %lld is how many more there are.
            ? [InterfaceText.line("common.countMore", "\(number: names.count - named.count) more")]
            : []
        return CountWording.list(named + more)
    }

    /// `names`, files a book left out, as its notice names them: "“Trailer.avi”",
    /// or, for several, their count first, "2 files, “Trailer.avi” and
    /// “Intro.wmv”", with at most `leftOutNamedLimit` named.
    static func leftOutFiles(_ names: [String]) -> String {
        let listed = leftOutList(names)
        guard names.count != 1 else { return listed }
        // Translators: The files a book left out, counted and named, inside a sentence: the count, a comma, then their names. %1$lld is the number of files and %2$@ their names in curly quotes, listed as a sentence lists them.
        return InterfaceText.line("ffmpegImport.leftOutFiles", "\(number: names.count) files, \(listed)")
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
        switch located {
        case .found, .inProcess:
            return nil
        case .missing:
            let files = leftOutFiles(names)
            let why = names.count == 1
                // Translators: Notice that a book left out one file that only TextMouth's own converter reads, because the converter is missing from the app. %@ is the file's name in curly quotes. Advice to install the app again follows.
                ? InterfaceText.line("ffmpegImport.missing.needs", "TextMouth left out \(files), which needs TextMouth's converter, missing from the app.")
                // Translators: Notice that a book left out several files that only TextMouth's own converter reads, because the converter is missing from the app. %@ is the files' count and names, such as "2 files, “a.avi” and “b.wmv”". Advice to install the app again follows.
                : InterfaceText.line("ffmpegImport.missing.need", "TextMouth left out \(files), which need TextMouth's converter, missing from the app.")
            return SentenceWording.joined([why, reinstallAdvice(importingBook: true)])
        }
    }

    /// What a book of several tracks says of `names`, files named for a
    /// format only ffmpeg reads whose bytes are of none, which it left out:
    /// "TextMouth left out “Report.spx”, which holds no sound it can read."
    /// Nil for no names.
    static func leftOutHoldingNoSound(_ names: [String]) -> String? {
        guard !names.isEmpty else { return nil }
        let files = leftOutFiles(names)
        return names.count == 1
            // Translators: Notice that a book left out one file that holds no sound TextMouth can read. %@ is the file's name in curly quotes.
            ? InterfaceText.line("ffmpegImport.leftOutHoldingNoSound.holds", "TextMouth left out \(files), which holds no sound it can read.")
            // Translators: Notice that a book left out several files that hold no sound TextMouth can read. %@ is the files' count and names, such as "2 files, “a.spx” and “b.spx”".
            : InterfaceText.line("ffmpegImport.leftOutHoldingNoSound.hold", "TextMouth left out \(files), which hold no sound it can read.")
    }

    /// The notice of a book of several tracks that left out files only
    /// FFmpeg reads (`FFmpegAudioConverter.tracksToLeaveOut(of:located:)`):
    /// `needingConverter`, the sentence of those that can't be converted here
    /// (the Mac's `leftOutNeedingConverter(_:located:)`, or the iPhone's own),
    /// then the one of `holdingNoSound`'s files, as one message; nil when it
    /// left out none.
    static func tracksLeftOutNotice(needingConverter: String?, holdingNoSound: [String]) -> String? {
        let sentences = [needingConverter, leftOutHoldingNoSound(holdingNoSound)].compactMap { $0 }
        return sentences.isEmpty ? nil : SentenceWording.joined(sentences)
    }
}
