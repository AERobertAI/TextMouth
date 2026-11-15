import Foundation

/// What can go wrong reading a cue sheet's file, or importing a sheet chosen
/// on its own, in words a listener hears. An import's alert reads it after
/// the file's name and the step that failed ("Could not import “album.cue”.
/// Reading the file failed: …"), so each sentence stands whole.
enum CueSheetError: LocalizedError, Equatable {
    /// The sheet's file is larger than `CueSheet.maximumByteCount`.
    case tooLarge(fileName: String)
    /// The sheet places no audio track: none has an `INDEX 01` in a file.
    case noTracks
    /// No file the sheet names is audio inside its own folder that
    /// TextMouth can import. The names skipped are told, so the listener
    /// hears why each was left out, as a playlist's refusal tells them.
    case noAudio(skipped: [M3UPlaylist.Skipped])
    /// The sheet's tracks run past the end of the audio it names.
    case timesPastAudio

    /// The sentence for the refusal, from `CueSheetWording`, or, for the
    /// names skipped, the playlist's words naming the cue sheet's folder
    /// (`PlaylistImportWording.noTrack(skipped:listedIn:)`).
    var errorDescription: String? {
        switch self {
        case let .tooLarge(fileName):
            return CueSheetWording.tooLarge(fileName: fileName)
        case .noTracks:
            return CueSheetWording.noTracks
        case let .noAudio(skipped):
            return PlaylistImportWording.noTrack(skipped: skipped, listedIn: CueSheetWording.ListKind.cueSheet.name)
        case .timesPastAudio:
            return CueSheetWording.timesPastAudio
        }
    }
}

/// A CUE sheet (FMT24): a text file that says where each track of a CD rip,
/// or of a one-file audiobook, begins inside the audio files it names. The
/// lines TextMouth reads:
///
/// - `FILE "album.wav" WAVE` names a file; the lines after it lie in it.
/// - `TRACK 01 AUDIO` starts a track; a track of another kind (`MODE1/2352`,
///   a CD's data) is passed over.
/// - `TITLE` and `PERFORMER` name the track they follow, or, before the first
///   `TRACK`, the whole sheet.
/// - `INDEX 01 MM:SS:FF` is where the track begins in the file named last, in
///   minutes, seconds, and frames of 1/75 second. `INDEX 00` marks a pregap,
///   the gap a CD player counts down before the track, and is ignored: the
///   gap's audio belongs to the track before, as a player plays it. Other
///   index numbers mark places inside a track and are ignored too.
/// - `REM` is a comment; every other command (`CATALOG`, `FLAGS`, `ISRC`,
///   `PREGAP`, `POSTGAP`, `SONGWRITER`) is ignored.
///
/// The GNU and Hydrogenaudio pages that describe the format could not be
/// read when it was researched (`FORMATS-RESEARCH-2026-10-17.md`, 5.3), so
/// this reader is lenient where sheets in the wild differ: commands in any
/// letter case, values with or without quotation marks, a track without a
/// type taken for audio, and a FILE line inside a track (the layout that
/// appends each gap to the track before) moving the track's start into the
/// file it names. This type is the pure part: `parse` reads the text, and
/// `read(at:)` reads a file into it. Which files the names are, and the
/// headings the tracks become, are decided elsewhere (`CueSheetArrangement`).
struct CueSheet: Equatable, Sendable {
    /// An audio track the sheet places: one with an `INDEX 01` line.
    struct Track: Equatable, Sendable {
        /// The track's number, as the sheet gives it.
        let number: Int
        /// The track's title, or nil when it gives none (or only blank text).
        var title: String?
        /// The track's own performer, or nil when it gives none.
        var performer: String?
        /// The file the track begins in, by its place in `files`: the file
        /// named last before the track's `INDEX 01` line.
        let fileIndex: Int
        /// Where the track begins in that file, in frames of 1/75 second.
        let startFrame: Int

        /// Where the track begins in its file, in seconds.
        var startTime: TimeInterval {
            CueSheet.seconds(ofFrames: startFrame)
        }
    }

    /// The sheet's title, from a `TITLE` line before its first track.
    var title: String?
    /// The sheet's performer, from a `PERFORMER` line before its first track.
    var performer: String?
    /// The names its `FILE` lines give, in order, as it spells them, without
    /// their quotation marks. A name may appear twice.
    var files: [String]
    /// Its audio tracks with a start, in the sheet's order.
    var tracks: [Track]

    // MARK: - Limits and Units

    /// The extension (lowercase) of a cue sheet's file.
    static let fileExtension = "cue"

    /// The largest sheet `read(at:)` accepts: 1 MiB. A sheet of a few
    /// hundred tracks is a few kilobytes.
    static let maximumByteCount = 1_048_576

    /// The most tracks and files a sheet is read for; later ones are passed
    /// over, so no sheet makes a book of more headings than a long DAISY
    /// book has. A CD holds 99 tracks.
    static let maximumTracks = 10_000
    static let maximumFiles = 10_000

    /// The frames a second has in a sheet's times: a CD's 75 sectors.
    static let framesPerSecond = 75

    /// `frames` CD frames as seconds.
    static func seconds(ofFrames frames: Int) -> TimeInterval {
        Double(frames) / Double(framesPerSecond)
    }

    /// `seconds` as CD frames, to the nearest frame: 0 for a time that is no
    /// finite number above zero, and at most a sheet's longest time (999,999
    /// minutes), so no time can overflow.
    static func frames(ofSeconds seconds: TimeInterval) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        let longest = Double(999_999 * 60 * framesPerSecond + 59 * framesPerSecond + framesPerSecond - 1)
        return Int(min(seconds * Double(framesPerSecond), longest).rounded())
    }

    /// Whether `url` names a cue sheet, by its extension in any case.
    static func isCueSheet(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == fileExtension
    }

    // MARK: - Parsing

    /// A track whose lines are still being read.
    private struct PendingTrack {
        let number: Int
        /// Whether the `TRACK` line names audio (or no type at all).
        let isAudio: Bool
        var title: String?
        var performer: String?
        /// The file and frame its first `INDEX 01` gave.
        var start: (fileIndex: Int, frame: Int)?

        /// The track as the sheet keeps it: an audio track with a start, or
        /// nil for one TextMouth cannot place.
        var finished: Track? {
            guard isAudio, let start else { return nil }
            return Track(
                number: number, title: title, performer: performer,
                fileIndex: start.fileIndex, startFrame: start.frame
            )
        }
    }

    /// The sheet whose text is `contents`.
    ///
    /// Lines end at CR, LF, or CRLF; a leading byte-order mark is dropped,
    /// each line is trimmed, and blank lines are skipped. A line's first word
    /// is its command, in any letter case; the rest are its values. An
    /// `INDEX 01` before any `FILE` line, or with a time that is not one
    /// (seconds of 60 or more, frames of 75 or more), is passed over, and so
    /// is every `INDEX 01` after a track's first.
    static func parse(_ contents: String) -> CueSheet {
        var sheet = CueSheet(title: nil, performer: nil, files: [], tracks: [])
        var pending: PendingTrack?

        /// Keeps the track being read, if it is one the sheet places.
        func finishTrack() {
            if let track = pending?.finished, sheet.tracks.count < maximumTracks {
                sheet.tracks.append(track)
            }
            pending = nil
        }

        let withoutMark = contents.hasPrefix("\u{FEFF}") ? String(contents.dropFirst()) : contents
        // Swift reads CRLF as one Character, so one test per kind of break
        // is enough.
        let lines = withoutMark.split { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let (command, values) = command(of: line) else { continue }
            switch command {
            case "FILE":
                if sheet.files.count < maximumFiles, let name = fileName(in: values) {
                    sheet.files.append(name)
                }
            case "TRACK":
                finishTrack()
                let words = values.split(whereSeparator: \.isWhitespace)
                guard let number = words.first.flatMap({ number(in: $0, maximumDigits: 4) }) else { continue }
                // A track without a type is taken for audio.
                let isAudio = words.count < 2 || words[1].uppercased() == "AUDIO"
                pending = PendingTrack(number: number, isAudio: isAudio)
            case "TITLE":
                let title = text(in: values)
                if pending != nil { pending?.title = title } else { sheet.title = title }
            case "PERFORMER":
                let performer = text(in: values)
                if pending != nil { pending?.performer = performer } else { sheet.performer = performer }
            case "INDEX":
                guard pending != nil, pending?.start == nil, !sheet.files.isEmpty else { continue }
                let words = values.split(whereSeparator: \.isWhitespace)
                guard words.count >= 2, number(in: words[0], maximumDigits: 2) == 1,
                      let frame = frames(in: words[1]) else { continue }
                pending?.start = (fileIndex: sheet.files.count - 1, frame: frame)
            default:
                // REM and every command TextMouth has no use for.
                continue
            }
        }
        finishTrack()
        return sheet
    }

    /// The command of `line`, its first word in capitals, and the rest of
    /// the line after the space that follows it; nil for a blank line.
    private static func command(of line: String) -> (command: String, values: Substring)? {
        guard let first = line.firstIndex(where: { !$0.isWhitespace }) else { return nil }
        let end = line[first...].firstIndex(where: \.isWhitespace) ?? line.endIndex
        let values = line[end...].drop(while: \.isWhitespace)
        return (String(line[first..<end]).uppercased(), values)
    }

    /// The text a `TITLE` or `PERFORMER` line gives: between its first
    /// quotation mark and its last, or, without one, the whole value. Nil
    /// when that is blank. A quotation mark that is never closed runs to the
    /// end of the line.
    private static func text(in values: Substring) -> String? {
        let value: Substring
        if values.first == "\"" {
            let inner = values.dropFirst()
            value = inner.lastIndex(of: "\"").map { inner[..<$0] } ?? inner
        } else {
            value = values
        }
        return String(value).trimmingCharacters(in: .whitespaces).nonBlank
    }

    /// The file a `FILE` line names: between its first quotation mark and its
    /// last, before the file's type (`WAVE`, `MP3`, `BINARY`); without
    /// quotation marks, everything before the last word, which is the type,
    /// or the one word there is. Nil when no name is left.
    private static func fileName(in values: Substring) -> String? {
        if values.first == "\"" {
            return text(in: values)
        }
        guard let typeStart = values.lastIndex(where: \.isWhitespace) else {
            return String(values).nonBlank
        }
        return String(values[..<typeStart]).trimmingCharacters(in: .whitespaces).nonBlank
    }

    /// The whole number `word` spells in at most `maximumDigits` ASCII
    /// digits, or nil.
    private static func number(in word: Substring, maximumDigits: Int) -> Int? {
        // ASCII digits only: `Int(_:)` alone would take a sign, and
        // `isNumber` other scripts' digits and fractions.
        guard !word.isEmpty, word.utf8.count <= maximumDigits,
              word.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }) else { return nil }
        return Int(word)
    }

    /// The frames a sheet's time `MM:SS:FF` spells: minutes in up to six
    /// digits (a long audiobook passes 99), seconds below 60, and frames
    /// below 75; nil for anything else.
    static func frames(in time: Substring) -> Int? {
        let parts = time.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let minutes = number(in: parts[0], maximumDigits: 6),
              let seconds = number(in: parts[1], maximumDigits: 2), seconds < 60,
              let frames = number(in: parts[2], maximumDigits: 2), frames < framesPerSecond else { return nil }
        return (minutes * 60 + seconds) * framesPerSecond + frames
    }

    // MARK: - Reading

    /// The sheet in the file at `url`: at most `maximumByteCount` bytes,
    /// decoded as a text file is (`SmallTextFile`), so a sheet in UTF-8 with
    /// or without a byte-order mark, in UTF-16, or in Windows-1252 or Latin 1
    /// (as Windows rippers write them) reads with its accents.
    /// - Throws: `CueSheetError.tooLarge` for a larger file, or the error
    ///   reading the file.
    static func read(at url: URL) throws -> CueSheet {
        guard let text = try SmallTextFile.text(at: url, byteLimit: maximumByteCount) else {
            throw CueSheetError.tooLarge(fileName: url.lastPathComponent)
        }
        return parse(text)
    }
}
