import Foundation

// MARK: - Cue Sheets (FMT24)

/// How a cue sheet arrives, decided from how folders and playlists import
/// today:
///
/// - With its audio in a folder or a ZIP (`importAudioFolderWithReport`,
///   `importAudioZipWithReport`): when no manifest.json arranges the tracks,
///   the sheets beside them do (`arrangeByCueSheets(in:)`), through a
///   manifest of sections written into the staged package, which the import
///   then checks, converts, and reads like any other.
/// - Chosen on its own (`importCueSheetWithReport`), as a playlist is: the
///   files it names inside its folder become one book, and nothing else of
///   the folder.
///
/// An Audacity label file (FMT06) arrives with its audio in a folder only:
/// a .txt chosen on its own imports as a text book, as it always has, and a
/// ZIP holding one is imported as a batch of books.
extension FileImportService {
    /// Whether `source` is a cue sheet's file (`CueSheet.isCueSheet`): a
    /// folder that happens to be named like one is not.
    static func isCueSheetFile(_ source: URL) -> Bool {
        CueSheet.isCueSheet(source) && !isFolder(source)
    }

    /// Imports the audio files the cue sheet `sheet` names as one audiobook
    /// with a heading per track (FMT24), as a playlist imports the files it
    /// lists (`importPlaylistWithReport`): through the same staging,
    /// copying, manifest check, conversion of formats Apple's players must
    /// not read, and read-back before publishing. Only files inside the
    /// sheet's own folder are used, found as `CueSheetArrangement` says;
    /// each is copied to the same path in the book's package, and a
    /// manifest.json written there gives the sections, and the sheet's
    /// title and performer as the book's (its file's name and an unknown
    /// author otherwise). The book is known by a checksum of the files'
    /// paths and bytes and the sheet's own name and bytes, so the same sheet
    /// imported twice is a duplicate. The names skipped are told in the
    /// result's `notice`. Nothing is deleted or offered for deletion
    /// afterwards: the files belong to the listener's music folders.
    /// - Throws: an `ImportFailure` naming the sheet and the step that
    ///   failed, with what `CueSheetArrangement.arranging(sheetAt:measure:)`
    ///   throws when the sheet places no track, names no usable file, or
    ///   runs past its audio; whatever was staged is removed first, and the
    ///   sheet and its files are never changed.
    static func importCueSheetWithReport(
        from sheet: URL,
        toFolder folderPath: String = "",
        observer: ImportStepObserver? = nil
    ) throws -> ImportedBook {
        try ImportRun.perform(importing: sheet.lastPathComponent, observer: observer) { run in
            try run.begin(.readingSource)
            let folder = sheet.deletingLastPathComponent()
            let arrangement = try CueSheetArrangement.arranging(sheetAt: sheet, measure: measuredLengths(of:))
            let bookTitle = arrangement.title ?? sheet.deletingPathExtension().lastPathComponent
            let author = arrangement.author ?? Book.unknownAuthor
            let hash = try folderHash(of: arrangement.files.map(\.path) + [sheet.lastPathComponent], in: folder)
            let bookID = UUID()
            let dateAdded = Date()

            try run.begin(.preparingPackage)
            let staging = try ImportStaging.makeEmpty(publishingTo: try destinationPackageURL(
                title: bookTitle,
                author: author,
                dateAdded: dateAdded,
                bookID: bookID,
                folderPath: folderPath
            ))
            defer { staging.discard() }

            try run.begin(.copying, in: staging.directory)
            let audioDirectory = try makeAudioDirectory(in: staging)
            try copyTracks(arrangement.files.map { (path: $0.path, source: $0.url) }, into: audioDirectory)
            // The manifest lies at the top of the book's folder of tracks,
            // where the files' paths are taken from.
            let location = AudioManifestLocation(
                url: audioDirectory.appendingPathComponent(AudioManifest.fileName),
                prefix: ""
            )
            try BookManifestFile.encoded(arrangement.manifest(at: location)).write(to: location.url)

            var imported: ImportedBook
            do {
                imported = try publishTracks(
                    titled: bookTitle,
                    in: audioDirectory,
                    of: staging,
                    id: bookID,
                    md5Hash: hash,
                    folderPath: folderPath,
                    dateAdded: dateAdded,
                    source: sheet,
                    pairingIn: folder,
                    run: &run
                )
            } catch let error as AudioParseError where error.placesASectionOutsideItsFile {
                // The book's reading, after the conversion, found a track past
                // its file's end that the check before could not see: the
                // sheet is refused in its own words, as that check refuses it.
                throw CueSheetError.timesPastAudio
            }
            // The files and the sheet belong to the listener's folders, so
            // none is deleted or offered for deletion, whatever "After
            // Importing a Book" says.
            imported.isFromFolder = true
            imported.notice = joinedNotices(imported.notice, arrangement.notice)
            return imported
        }
    }

    /// What the cue sheets and label files of a book's folder of tracks did
    /// to it (`arrangeByCueSheets(in:)`).
    struct SheetsArranged {
        /// The manifest their sections were written to; nil when they wrote
        /// none (the folder had a manifest, or they arrange nothing).
        var manifest: URL?
        /// What the import tells of them (`CueSheetArrangement.notice`).
        var notice: String?
        /// What it tells instead should the book be read without their
        /// sections (`CueSheetArrangement.noticeWithoutItsSections`).
        var noticeWithoutTheirSections: String?
    }

    /// Lets the cue sheets and Audacity label files in `audioDirectory`, a
    /// book's folder of tracks staged by the import of a folder or a ZIP,
    /// arrange it when no manifest.json does (FMT24, FMT06): their sections
    /// are written as a manifest where a new one goes
    /// (`AudioManifestLocation.forNewManifest(in:)`), so the import reads the
    /// book by it. A folder with a manifest, or with neither, is left exactly
    /// as it was, and so is one whose sheets and label files arrange nothing,
    /// as the notice returned says. (A ZIP holding a .txt file is imported as
    /// a batch of books, so a label file arranges a folder's tracks alone.)
    /// - Returns: the manifest written, if any, and what the import tells.
    /// - Throws: the error writing the manifest.
    static func arrangeByCueSheets(in audioDirectory: URL) throws -> SheetsArranged {
        guard AudioManifestLocation.find(in: audioDirectory) == nil,
              let arrangement = CueSheetArrangement.arranging(folder: audioDirectory, measure: measuredLengths(of:))
        else { return SheetsArranged() }
        var arranged = SheetsArranged(notice: arrangement.notice, noticeWithoutTheirSections: arrangement.noticeWithoutItsSections)
        if arrangement.arrangesAnything {
            let location = AudioManifestLocation.forNewManifest(in: audioDirectory)
            try BookManifestFile.encoded(arrangement.manifest(at: location)).write(to: location.url)
            arranged.manifest = location.url
        }
        return arranged
    }

    /// The book `publish` makes of a folder of tracks the sheets arranged
    /// (`arranged`), as `publishTracks` makes every one: once with their
    /// sections, telling their notice; and, should the book's reading find
    /// one of those sections past its file's end after all, once more
    /// without them, their manifest removed, telling why. The reading
    /// measures each file as the reader will, after the import's
    /// conversion, which the sheets' check could not wait for: a converted
    /// file can be a little shorter than its source, and a file no check
    /// could measure is checked only there. Any other failure, or one from a
    /// manifest the sheets did not write, is thrown as it is. Generic over
    /// what `publish` returns, so a test can watch the two tries.
    static func publishingWithoutSheetsOnMisfit<Published>(
        _ arranged: SheetsArranged,
        publish: (_ sheetNotice: String?) throws -> Published
    ) throws -> Published {
        do {
            return try publish(arranged.notice)
        } catch let error as AudioParseError where error.placesASectionOutsideItsFile {
            guard let manifest = arranged.manifest else { throw error }
            try FileManager.default.removeItem(at: manifest)
            return try publish(arranged.noticeWithoutTheirSections)
        }
    }

    /// The length of each of `files`, by its path, measured without Apple's
    /// decoders unless the book plays the file as it is: a file whose bytes
    /// are of a format TextMouth plays as it is
    /// (`ImportAudioConverter.verdict(for:)` is `.leave`) as the book's
    /// parse measures it (`AudioMediaProber.avFoundation`); a file only
    /// FFmpeg reads (WMA, Matroska, and the rest) by TextMouth's FFmpeg helper
    /// (`FFmpegAudioConverter.length(of:using:)`, the TODO's FU-FFMPEG item:
    /// afinfo reads none of them, so a sheet over one was taken to fit
    /// unchecked); every other file (MPEG-4, which the bytes leave open, and
    /// every other format the import converts) as the conversion reads it
    /// first (`ImportAudioConverter.inspect`: an Ogg file from its own pages,
    /// any other by `afinfo` in its child). A file that cannot be measured is
    /// not listed, and the parse checks it, after the conversion. The FFmpeg
    /// tool is read on this thread, since the wait's task does not inherit it.
    static func measuredLengths(of files: [M3UPlaylist.Track]) -> [String: TimeInterval] {
        guard !files.isEmpty else { return [:] }
        // The verdict reads a file's first bytes, so it is asked once a file.
        let playedAsTheyAre = Set(files.filter { ImportAudioConverter.verdict(for: $0.url) == .leave }.map(\.path))
        let asTheyAre = files.filter { playedAsTheyAre.contains($0.path) }
        let others = files.filter { !playedAsTheyAre.contains($0.path) }
        let ffmpeg = FFmpegAudioConverter.tool
        let measured = try? AsyncBridge.waitForResult(timeLimit: AsyncBridge.audioAnalysisTimeLimit, of: {
            var lengths: [String: TimeInterval] = [:]
            let outcomes = await AudioMediaProber.avFoundation.probeEach(asTheyAre.map(\.url))
            for (file, outcome) in zip(asTheyAre, outcomes) {
                if case .success(let seconds) = outcome { lengths[file.path] = seconds }
            }
            for file in others {
                if FFmpegAudioConverter.converts(file.url) {
                    if let seconds = await FFmpegAudioConverter.length(of: file.url, using: ffmpeg), seconds > 0 {
                        lengths[file.path] = seconds
                    }
                } else if let info = try await ImportAudioConverter.inspect(file.url), info.duration.isFinite, info.duration > 0 {
                    lengths[file.path] = info.duration
                }
            }
            return lengths
        })
        return measured ?? [:]
    }

    /// `notices` that are not nil, joined into one message; nil when none is.
    static func joinedNotices(_ notices: String?...) -> String? {
        let sentences = notices.compactMap { $0 }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }
}

extension AudioParseError {
    /// Whether the parse refused a section for where it lies in its file:
    /// starting, or ending, past the file's end, or starting before an
    /// earlier section of the same file. A cue sheet's or label file's
    /// times made for other audio fail so (`publishingWithoutSheetsOnMisfit`).
    var placesASectionOutsideItsFile: Bool {
        switch self {
        case .sectionStartsPastEnd, .sectionEndsPastEnd, .sectionStartsBeforeEarlierSection:
            return true
        default:
            return false
        }
    }
}
