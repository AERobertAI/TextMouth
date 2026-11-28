import Foundation

// MARK: - A Book's Chapters, for a Chapter List

/// One chapter of an audiobook as a chapter list names it (FMT24): its
/// title, the audio file it begins in, as Export names that file, and where
/// it begins there.
struct ChapterListEntry: Equatable, Sendable {
    /// The chapter's title, which its heading shows.
    let title: String
    /// The audio file it begins in, as Export writes the book's audio:
    /// "Moby-Dick.m4b", or "Moby-Dick/01 - Loomings.mp3" for a book of
    /// tracks, whose files go in a folder named after the book.
    let file: String
    /// Where it begins in that file, in seconds.
    let start: TimeInterval
}

/// Why Export could not write an audiobook's headings or bookmarks as a
/// chapter list (FMT24, FMT06), in words the export's summary names with
/// the file.
enum ChapterListExportError: LocalizedError, Equatable {
    /// The book's package keeps no content index to take its headings from.
    case noHeadings
    /// Audacity labels mark one audio file, and the book's audio is in
    /// `fileCount` files.
    case severalFiles(fileCount: Int)

    var errorDescription: String? {
        switch self {
        case .noHeadings:
            return BookExportWording.noHeadingsReason
        case let .severalFiles(fileCount):
            return BookExportWording.labelsNeedOneFileReason(fileCount: fileCount)
        }
    }
}

/// What a chapter list is made of: an audiobook's headings (FMT24, FMT06),
/// or its bookmarks (FMT06).
enum ChapterListSource: Equatable, Sendable {
    case headings
    case bookmarks
}

// MARK: - The Formats

/// The formats an audiobook's headings export in, as the Convert headings to
/// picker lists them (FMT24, FMT06), and the one its bookmarks export in.
enum ChapterListFormat: String, CaseIterable, Sendable {
    /// A CUE sheet, which CD players' software, audio editors, and
    /// TextMouth itself read (`CueSheet`).
    case cueSheet
    /// Audacity labels (FMT06), which Audacity imports as a label track
    /// beside the book's audio, and TextMouth reads beside a folder's audio
    /// (`AudacityLabels`). They mark one audio file.
    case audacityLabels

    /// The headings picker's first choice, its default, which the offer
    /// names the file by until another is chosen.
    static let standard = ChapterListFormat.cueSheet

    /// The formats a list of `source` is written in, in the picker's order:
    /// every format for headings; Audacity labels alone for bookmarks, which
    /// mark places, not chapters a CUE sheet's tracks are.
    static func formats(for source: ChapterListSource) -> [ChapterListFormat] {
        source == .headings ? allCases : [.audacityLabels]
    }

    /// The format whose picker tag is `choiceID`; nil for a tag the picker
    /// does not list.
    init?(choiceID: String) {
        guard let format = Self.allCases.first(where: { $0.choiceID == choiceID }) else { return nil }
        self = format
    }

    /// The format's tag in the picker.
    var choiceID: String {
        switch self {
        case .cueSheet: return "chapter-list-cue"
        case .audacityLabels: return "chapter-list-labels"
        }
    }

    /// The format's name, as the picker lists it and VoiceOver speaks it.
    var name: String {
        switch self {
        case .cueSheet: return "CUE sheet" // l10n: no (a file format's name, like WebVTT)
        case .audacityLabels: return "Audacity labels" // l10n: no (a file format's name, like WebVTT)
        }
    }

    /// The extension, without its dot, of the file it writes.
    var fileExtension: String {
        switch self {
        case .cueSheet: return CueSheet.fileExtension
        case .audacityLabels: return AudacityLabels.fileExtension
        }
    }

    /// The file's bytes for `entries`, the chapters or places of the book
    /// `book`. Audacity labels are points at each entry's start, in UTF-8.
    /// - Throws: `ChapterListExportError.severalFiles` for labels of entries
    ///   in more than one audio file.
    func fileBytes(of entries: [ChapterListEntry], book: ExportBookDetails) throws -> Data {
        switch self {
        case .cueSheet:
            return CueSheetWriter.fileBytes(of: entries, title: book.title, performer: book.author)
        case .audacityLabels:
            let files = Set(entries.map(\.file))
            guard files.count <= 1 else { throw ChapterListExportError.severalFiles(fileCount: files.count) }
            let labels = entries.map { AudacityLabels.Label(start: $0.start, end: $0.start, text: $0.title) }
            return Data(AudacityLabels.text(of: labels).utf8)
        }
    }
}

// MARK: - CUE Sheets

/// Writes a book's chapters as a CUE sheet (FMT24): the book's title and
/// author, then a FILE line for each audio file in the order the chapters
/// begin in them, and under it a track for each chapter that begins there,
/// titled by the chapter, at its start in minutes, seconds, and frames of
/// 1/75 second. TextMouth's own reader reads it back as the same headings
/// (`CueSheet`, `CueSheetArrangement`).
///
/// The sheet is UTF-8 with a byte-order mark and CRLF line ends, as Windows
/// tools, the format's first readers, expect; TextMouth's reader takes it
/// either way. A CUE sheet has no way to write a quotation mark inside a
/// value, so one becomes an apostrophe, and a line break a space. A file of
/// MP3 or AIFF is typed as such, any other as WAVE, as rippers type FLAC.
/// Tracks are numbered from 01; past 99, which a CD holds at most, they are
/// numbered on in three digits, which TextMouth reads and some programs may
/// not.
enum CueSheetWriter {
    /// The sheet's text for `entries`, under the book's `title` and its
    /// `performer` (nil writes none).
    static func text(of entries: [ChapterListEntry], title: String, performer: String?) -> String {
        var lines = ["TITLE \(quoted(title))"]
        if let performer = performer?.nonBlank {
            lines.append("PERFORMER \(quoted(performer))")
        }
        var currentFile: String?
        for (number, entry) in entries.enumerated() {
            if entry.file != currentFile {
                lines.append("FILE \(quoted(entry.file)) \(fileType(of: entry.file))")
                currentFile = entry.file
            }
            lines.append("  TRACK \(twoDigits(number + 1)) AUDIO") // l10n: no (CUE sheet file syntax)
            lines.append("    TITLE \(quoted(entry.title))")
            lines.append("    INDEX 01 \(time(entry.start))") // l10n: no (CUE sheet file syntax)
        }
        return lines.map { $0 + "\r\n" }.joined()
    }

    /// The sheet's bytes: its text in UTF-8 after a byte-order mark.
    static func fileBytes(of entries: [ChapterListEntry], title: String, performer: String?) -> Data {
        Data([0xEF, 0xBB, 0xBF]) + Data(text(of: entries, title: title, performer: performer).utf8)
    }

    /// `seconds` as a sheet's time, MM:SS:FF, to the nearest frame: minutes
    /// in at least two digits (more for a book past 99 minutes), seconds and
    /// frames in two. A time that is no finite number of seconds above zero
    /// is the start.
    static func time(_ seconds: TimeInterval) -> String {
        let total = seconds.isFinite && seconds > 0
            ? Int(min(seconds * Double(CueSheet.framesPerSecond), Double(Int32.max)).rounded())
            : 0
        let frames = total % CueSheet.framesPerSecond
        let wholeSeconds = total / CueSheet.framesPerSecond
        return "\(twoDigits(wholeSeconds / 60)):\(twoDigits(wholeSeconds % 60)):\(twoDigits(frames))"
    }

    /// `value` in at least two digits.
    private static func twoDigits(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }

    /// `text` as a sheet's quoted value: on one line, with its quotation
    /// marks as apostrophes, which the format cannot escape.
    private static func quoted(_ text: String) -> String {
        let oneLine = text.components(separatedBy: .newlines).joined(separator: " ")
            .replacingOccurrences(of: "\"", with: "'")
            .trimmingCharacters(in: .whitespaces)
        return "\"\(oneLine)\""
    }

    /// The type a FILE line gives `file`, by its extension.
    private static func fileType(of file: String) -> String {
        switch (file as NSString).pathExtension.lowercased() {
        case "mp3": return "MP3"
        case "aif", "aiff": return "AIFF"
        default: return "WAVE"
        }
    }
}
