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

            var imported = try publishTracks(
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
            // The files and the sheet belong to the listener's folders, so
            // none is deleted or offered for deletion, whatever "After
            // Importing a Book" says.
            imported.isFromFolder = true
            imported.notice = joinedNotices(imported.notice, arrangement.notice)
            return imported
        }
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
    /// - Returns: what the import tells of the sheets
    ///   (`CueSheetArrangement.notice`): the names they skipped and the
    ///   sheets not used; nil when there is nothing to tell.
    /// - Throws: the error writing the manifest.
    static func arrangeByCueSheets(in audioDirectory: URL) throws -> String? {
        guard AudioManifestLocation.find(in: audioDirectory) == nil,
              let arrangement = CueSheetArrangement.arranging(folder: audioDirectory, measure: measuredLengths(of:))
        else { return nil }
        if arrangement.arrangesAnything {
            let location = AudioManifestLocation.forNewManifest(in: audioDirectory)
            try BookManifestFile.encoded(arrangement.manifest(at: location)).write(to: location.url)
        }
        return arrangement.notice
    }

    /// The length of each of `files` that a reader may open at import,
    /// measured as the book's parse measures it (`AudioMediaProber.avFoundation`),
    /// by its path. Only a file whose bytes are of a format TextMouth plays as
    /// it is (`ImportAudioConverter.verdict(for:)` is `.leave`) is opened: a
    /// format the import converts is never handed to Apple's decoders before
    /// it is converted, and a file the bytes leave open (MPEG-4) waits for
    /// `afinfo`. A file not opened, or that cannot be measured, is not
    /// listed, and the parse checks it after the conversion.
    static func measuredLengths(of files: [M3UPlaylist.Track]) -> [String: TimeInterval] {
        let measurable = files.filter { ImportAudioConverter.verdict(for: $0.url) == .leave }
        guard !measurable.isEmpty,
              let outcomes = try? AsyncBridge.waitForResult(timeLimit: AsyncBridge.audioAnalysisTimeLimit, of: {
                  await AudioMediaProber.avFoundation.probeEach(measurable.map(\.url))
              }) else { return [:] }
        var lengths: [String: TimeInterval] = [:]
        for (file, outcome) in zip(measurable, outcomes) {
            if case .success(let seconds) = outcome { lengths[file.path] = seconds }
        }
        return lengths
    }

    /// `notices` that are not nil, joined into one message; nil when none is.
    static func joinedNotices(_ notices: String?...) -> String? {
        let sentences = notices.compactMap { $0 }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }
}
