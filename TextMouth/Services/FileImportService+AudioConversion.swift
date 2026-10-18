import Foundation

// MARK: - Audio Converted at Import (B06, FMT09)

extension FileImportService {
    /// Converts the audio of `book`, staged in `staging`, that the import
    /// converts (`ImportAudioConverter.convertedExtensions`) to AAC or Apple
    /// Lossless in .m4a files, before anything reads it as a book or plays it: every import
    /// of audio ends in `publishReadableBook`, which calls this first, so a
    /// ZIP of tracks, a folder of tracks, a single file, a feed's episode,
    /// and a DAISY book's audio are all converted here. It comes after an
    /// archive's extraction and its manifest's check, which names the
    /// archive's tracks as they are, and before Reading its audio.
    ///
    /// A folder of tracks has each such track converted beside it and
    /// renamed in the folder's manifest, then the sources are removed. A
    /// single such file is converted, removed, and the book's file becomes
    /// the .m4a. With `keepingOriginals`, each source is moved into the
    /// package's hidden kept originals folder instead of removed
    /// (`ImportAudioConverter.keepSources(of:from:inPackage:)`). It is asked
    /// only once something was converted, so an import that converts
    /// nothing never reads the setting from the main thread. Only the
    /// staged copy is ever changed: the archive, folder, or file imported
    /// from is never touched. A book without such audio, and every other
    /// format, is left as it is.
    /// - Throws: the conversion's errors (`ImportAudioConverter.Failure`), or
    ///   the manifest's or the file system's; the import then fails at
    ///   Converting its audio, with whatever was staged removed.
    static func convertImportedAudio(
        of book: inout Book,
        in staging: ImportStaging,
        keepingOriginals: @autoclosure () -> Bool,
        run: inout ImportRun
    ) throws {
        guard book.format.isAudio else { return }
        let bookURL = URL(fileURLWithPath: book.filePath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: bookURL.path, isDirectory: &isDirectory) else { return }
        if isDirectory.boolValue {
            let sources = ImportAudioConverter.filesToConvert(in: bookURL)
            guard !sources.isEmpty else { return }
            let conversions = try convertTracks(sources, of: staging, run: &run)
            try ImportAudioConverter.renameTracks(of: conversions, inManifestOf: bookURL, bookID: nil)
            try disposeOfSources(of: conversions, from: bookURL, in: staging, keepingOriginals: keepingOriginals())
        } else if ImportAudioConverter.isConvertedAtImport(bookURL) {
            let conversions = try convertTracks([bookURL], of: staging, run: &run)
            guard let converted = conversions.first?.converted else { return }
            try disposeOfSources(
                of: conversions,
                from: bookURL.deletingLastPathComponent(),
                in: staging,
                keepingOriginals: keepingOriginals()
            )
            book.filePath = converted.path
        }
    }

    /// Whether an import keeps the originals of the audio it converts: only
    /// when the setting is on, and never for a feed episode (`feedLink`
    /// non-nil), which can be downloaded again. The setting belongs to the
    /// main actor and an import runs on its own thread, so it is read there:
    /// directly when this is the main thread, through it otherwise.
    static func keepsOriginalsOfConvertedAudio(feedLink: FeedBookLink?) -> Bool {
        guard feedLink == nil else { return false }
        return Thread.isMainThread ? settingOnMainThread() : DispatchQueue.main.sync { settingOnMainThread() }
    }

    /// The "Keep originals of converted audio" setting, read by code that
    /// is already on the main thread.
    private static func settingOnMainThread() -> Bool {
        MainActor.assumeIsolated { ConfigService.shared.config.keepsOriginalOfConvertedAudio }
    }

    /// Takes the sources of `conversions`, files in `staging` whose
    /// converted files have taken their places, out of the way: moved into
    /// the package's kept originals folder when `keepingOriginals`, else
    /// removed. `base` is the folder their paths are kept relative to.
    private static func disposeOfSources(
        of conversions: [ImportAudioConverter.Conversion],
        from base: URL,
        in staging: ImportStaging,
        keepingOriginals: Bool
    ) throws {
        if keepingOriginals {
            try ImportAudioConverter.keepSources(of: conversions, from: base, inPackage: staging.directory)
        } else {
            try ImportAudioConverter.removeSources(of: conversions)
        }
    }

    /// Converts `sources`, files inside `staging` that the import converts,
    /// from the import's own thread, which waits for each group of up to
    /// `ImportAudioConverter.maximumConcurrentConversions` converted at once,
    /// telling the run, and so the overlay, how many are done after each:
    /// "converting its audio: 12 of 176 tracks".
    /// - Throws: the first conversion's error, every file already converted
    ///   being removed first.
    private static func convertTracks(
        _ sources: [URL],
        of staging: ImportStaging,
        run: inout ImportRun
    ) throws -> [ImportAudioConverter.Conversion] {
        try run.begin(.convertingImportedAudio(done: 0, of: sources.count), in: staging.directory)
        var conversions: [ImportAudioConverter.Conversion] = []
        do {
            let size = ImportAudioConverter.maximumConcurrentConversions
            for start in stride(from: 0, to: sources.count, by: size) {
                let group = Array(sources[start..<min(start + size, sources.count)])
                conversions += try AsyncBridge.waitForResult {
                    try await ImportAudioConverter.convertEach(group)
                }
                try run.begin(.convertingImportedAudio(done: conversions.count, of: sources.count), in: staging.directory)
            }
        } catch {
            ImportAudioConverter.discard(conversions)
            throw error
        }
        return conversions
    }
}
