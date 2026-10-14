import Foundation

// MARK: - Ogg Audio Converted at Import (B06)

extension FileImportService {
    /// Converts the Ogg audio of `book`, staged in `staging`, to AAC in .m4a
    /// files, before anything reads it as a book or plays it: every import
    /// of audio ends in `publishReadableBook`, which calls this first, so a
    /// ZIP of tracks, a folder of tracks, a single file, a feed's episode,
    /// and a DAISY book's audio are all converted here. It comes after an
    /// archive's extraction and its manifest's check, which names the
    /// archive's Ogg files as they are, and before Reading its audio.
    ///
    /// A folder of tracks has each Ogg track converted beside it and renamed
    /// in the folder's manifest, then the Ogg tracks are removed. A single
    /// Ogg file is converted, removed, and the book's file becomes the
    /// .m4a. Only the staged copy is ever changed: the archive, folder, or
    /// file imported from is never touched. A book without Ogg audio, and
    /// every other format, is left as it is.
    /// - Throws: the conversion's errors (`OggAudioConverter.Failure`), or
    ///   the manifest's or the file system's; the import then fails at
    ///   Converting its audio, with whatever was staged removed.
    static func convertOggAudio(of book: inout Book, in staging: ImportStaging, run: inout ImportRun) throws {
        guard book.format.isAudio else { return }
        let bookURL = URL(fileURLWithPath: book.filePath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: bookURL.path, isDirectory: &isDirectory) else { return }
        if isDirectory.boolValue {
            let sources = OggAudioConverter.oggFiles(in: bookURL)
            guard !sources.isEmpty else { return }
            let conversions = try convertOgg(sources, of: staging, run: &run)
            try OggAudioConverter.renameTracks(of: conversions, inManifestOf: bookURL, bookID: nil)
            try OggAudioConverter.removeSources(of: conversions)
        } else if OggAudioConverter.isOgg(bookURL) {
            let conversions = try convertOgg([bookURL], of: staging, run: &run)
            guard let converted = conversions.first?.converted else { return }
            try OggAudioConverter.removeSources(of: conversions)
            book.filePath = converted.path
        }
    }

    /// Converts `sources`, Ogg files inside `staging`, from the import's
    /// own thread, which waits for each group of up to
    /// `OggAudioConverter.maximumConcurrentConversions` converted at once,
    /// telling the run, and so the overlay, how many are done after each:
    /// "converting its audio: 12 of 176 tracks".
    /// - Throws: the first conversion's error, every file already converted
    ///   being removed first.
    private static func convertOgg(
        _ sources: [URL],
        of staging: ImportStaging,
        run: inout ImportRun
    ) throws -> [OggAudioConverter.Conversion] {
        try run.begin(.convertingOggAudio(done: 0, of: sources.count), in: staging.directory)
        var conversions: [OggAudioConverter.Conversion] = []
        do {
            let size = OggAudioConverter.maximumConcurrentConversions
            for start in stride(from: 0, to: sources.count, by: size) {
                let group = Array(sources[start..<min(start + size, sources.count)])
                conversions += try AsyncBridge.waitForResult {
                    try await OggAudioConverter.convertEach(group)
                }
                try run.begin(.convertingOggAudio(done: conversions.count, of: sources.count), in: staging.directory)
            }
        } catch {
            OggAudioConverter.discard(conversions)
            throw error
        }
        return conversions
    }
}
