import Foundation

// MARK: - Audio Converted at Import (B06, FMT09)

extension FileImportService {
    /// Converts the audio of `book`, staged in `staging`, that the import
    /// converts to AAC or Apple Lossless in .m4a files, before anything
    /// reads it as a book or plays it. The content decides, not the
    /// extension: a track is converted when its extension is one the import
    /// converts (`ImportAudioConverter.convertedExtensions`) or its bytes are
    /// of a format it converts, and `afinfo` names the codec of an MPEG-4 or
    /// unrecognized file (`ImportAudioConverter.needsConversion(among:using:)`),
    /// so an Ogg file named .m4a, or an MP2 file a feed served as .mp3, is
    /// converted all the same. Every import of audio ends in
    /// `publishReadableBook`, which calls this first, so a ZIP of tracks, a
    /// folder of tracks, a single file, a feed's episode, and a DAISY book's
    /// audio are all converted here. It comes after an archive's extraction
    /// and its manifest's check, which names the archive's tracks as they
    /// are, and before Reading its audio.
    ///
    /// A folder of tracks has each such track converted beside it, under a
    /// hidden name; then the sources are removed; then each converted file
    /// takes its source's stem with .m4a (even the name of the source it
    /// replaces) and is renamed in the folder's manifest. A single such file
    /// is converted, removed, and the book's file becomes the .m4a. With
    /// `keepingOriginals`, each source is moved into the
    /// package's hidden kept originals folder instead of removed
    /// (`ImportAudioConverter.keepSources(of:from:inPackage:)`). It is asked
    /// only once something was converted, so an import that converts
    /// nothing never reads the setting from the main thread. Only the
    /// staged copy is ever changed: the archive, folder, or file imported
    /// from is never touched. A book without such audio, and every other
    /// format, is left as it is.
    ///
    /// A folder of tracks leaves out the files only ffmpeg reads that can't
    /// be converted here (`leavingOutWhatOnlyFFmpegReads(_:from:located:)`)
    /// when it has other tracks, and the notice returned names them.
    /// - Returns: that notice, or nil when nothing was left out.
    /// - Throws: the conversion's errors (`ImportAudioConverter.Failure`), or
    ///   the manifest's or the file system's; the import then fails at
    ///   Converting its audio, with whatever was staged removed. When the
    ///   reader cancels the import, the running conversions are killed at
    ///   once and `ImportCancelled` is thrown, which is no failure.
    static func convertImportedAudio(
        of book: inout Book,
        in staging: ImportStaging,
        keepingOriginals: @autoclosure () -> Bool,
        run: inout ImportRun
    ) throws -> String? {
        guard book.format.isAudio else { return nil }
        let bookURL = URL(fileURLWithPath: book.filePath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: bookURL.path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue {
            // The content decides, not the extension: a track named .m4a may hold Ogg or AC-3.
            let found = try AsyncBridge.waitForResult { try await ImportAudioConverter.tracksNeedingConversion(in: bookURL) }
            guard !found.isEmpty else { return nil }
            let (sources, notice) = try leavingOutWhatOnlyFFmpegReads(found, from: bookURL) { FFmpegAudioConverter.tool.locate() }
            #if os(iOS)
            // The iPhone converts in the app itself what only FFmpeg reads
            // (FMT54) and what TextMouth's own readers decode, and has no
            // converter for the rest: a copy-protected file is told first,
            // then the rest refused, naming the kind. The
            // conversion's step begins first: a copy-protected file's refusal
            // is the Mac's own failure, told under the step under way, as on
            // the Mac (the FMT54 review, finding 3); the phone's own refusals
            // name no step.
            if !sources.isEmpty { try run.begin(.convertingImportedAudio(done: 0, of: sources.count), in: staging.directory) }
            try PhoneImportRefusal.refuseConversion(of: sources)
            #endif
            guard !sources.isEmpty else { return notice }
            let unnamed = try convertTracks(sources, inPackage: staging.directory, run: &run)
            // The sources' paths are read now, while they exist to be resolved.
            let sourceNames = unnamed.map { AudioBookParser.relativeName(of: $0.source, in: bookURL) }
            try disposeOfSources(of: unnamed, from: bookURL, in: staging, keepingOriginals: keepingOriginals())
            let conversions = try givingFinalNames(to: unnamed)
            try ImportAudioConverter.renameTracks(of: conversions, inManifestOf: bookURL, bookID: nil, sourceNames: sourceNames)
            return joinedNotices(notice, partlyDecodedNotice(of: conversions))
        } else {
            let needed = try AsyncBridge.waitForResult { try await ImportAudioConverter.needsConversion(among: [bookURL]) }
            guard !needed.isEmpty else { return nil }
            #if os(iOS)
            // The iPhone converts in the app itself a file only FFmpeg reads
            // (FMT54) or one of TextMouth's own readers decodes; any other it
            // has no converter for, and the book is refused, naming the kind,
            // a copy-protected file told first, under the conversion's step,
            // as above.
            try run.begin(.convertingImportedAudio(done: 0, of: needed.count), in: staging.directory)
            try PhoneImportRefusal.refuseConversion(of: needed)
            #endif
            let unnamed = try convertTracks([bookURL], inPackage: staging.directory, run: &run)
            try disposeOfSources(
                of: unnamed,
                from: bookURL.deletingLastPathComponent(),
                in: staging,
                keepingOriginals: keepingOriginals()
            )
            let conversions = try givingFinalNames(to: unnamed)
            guard let converted = conversions.first?.converted else { return nil }
            book.filePath = converted.path
            return partlyDecodedNotice(of: conversions)
        }
    }

    /// What the import tells of the converted tracks whose sound the decoder
    /// refused in part (`FFmpegImportWording.partlyDecodedNotice(_:)`), named
    /// by their sources; nil when none was.
    static func partlyDecodedNotice(of conversions: [ImportAudioConverter.Conversion]) -> String? {
        FFmpegImportWording.partlyDecodedNotice(conversions.filter(\.partlyDecoded).map { $0.source.lastPathComponent })
    }

    /// Leaves out of the book whose staged folder of tracks is `folder` the
    /// files among `sources`, its tracks the import converts, that only
    /// FFmpeg reads and that can't be converted here
    /// (`FFmpegAudioConverter.tracksToLeaveOut(of:located:)`, review9
    /// finding 2): a stray video in a folder, ZIP, or playlist of MP3s, or a
    /// file merely named like one. Their staged copies are removed, so no
    /// reader or player meets them; what was imported from is never touched.
    /// `located` says where the FFmpeg session runs: the Mac app's helper,
    /// or none when the app is damaged, and on the iPhone the session in the
    /// app (FMT54), which converts every such file a Mac would. It is asked
    /// only when some source is a file only FFmpeg reads. A book that would
    /// have no track left leaves nothing out, so it is refused as a single
    /// such file is, with what to do.
    /// - Returns: the sources still to convert, and the notice that names
    ///   what was left out (nil when nothing was).
    /// - Throws: the file system's error when a staged copy can't be removed.
    private static func leavingOutWhatOnlyFFmpegReads(
        _ sources: [URL],
        from folder: URL,
        located: () -> FFmpegAudioConverter.Located
    ) throws -> (sources: [URL], notice: String?) {
        let leftOut = FFmpegAudioConverter.tracksToLeaveOut(of: sources, located: located)
        // Paths as the scan spells them, which both lists come from: a
        // standardized URL drops "/private" only while its file exists, so it
        // can't be compared once a file is removed.
        let leaving = Set(leftOut.all.map(\.path))
        guard !leaving.isEmpty else { return (sources, nil) }
        let tracks = (try? AudioBookParser.audioFiles(in: folder, scan: .importing)) ?? []
        guard tracks.contains(where: { !leaving.contains($0.path) }) else { return (sources, nil) }
        // What is kept, and the names, are read while the files exist.
        let kept = sources.filter { !leaving.contains($0.path) }
        let named = { (files: [URL]) in files.map { AudioBookParser.relativeName(of: $0, in: folder) } }
        let needingNames = named(leftOut.needingConverter)
        let needing = leftOut.located.flatMap { FFmpegImportWording.leftOutNeedingConverter(needingNames, located: $0) }
        let notice = FFmpegImportWording.tracksLeftOutNotice(needingConverter: needing, holdingNoSound: named(leftOut.holdingNoSound))
        for file in leftOut.all {
            try FileManager.default.removeItem(at: file)
        }
        return (kept, notice)
    }

    /// Gives each of `conversions`, written under a hidden temporary name
    /// beside its source, its final name (`ImportAudioConverter.givingFinalName(_:)`):
    /// its source's stem with .m4a. It is called once the sources have been
    /// removed or kept, so a file named x.m4a that held AC-3 is replaced by
    /// the x.m4a converted from it, not by "x 2.m4a". Names are taken one
    /// after another, in the order of `conversions`.
    /// - Throws: `ImportAudioConverter.Failure.cannotName`, every converted
    ///   file (named or not) being removed first.
    private static func givingFinalNames(
        to conversions: [ImportAudioConverter.Conversion]
    ) throws -> [ImportAudioConverter.Conversion] {
        var named: [ImportAudioConverter.Conversion] = []
        do {
            for conversion in conversions {
                named.append(try ImportAudioConverter.givingFinalName(conversion))
            }
        } catch {
            // The ones named so far, and the ones still under temporary names.
            ImportAudioConverter.discard(named + conversions.dropFirst(named.count))
            throw error
        }
        return named
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
    /// each left under its hidden temporary name (`givingFinalNames(to:)`
    /// names them once their sources are out of the way), from the import's
    /// own thread, which waits for each group of up to
    /// `ImportAudioConverter.maximumConcurrentConversions` converted at once,
    /// telling the run, and so the overlay, how many are done after each:
    /// "converting its audio: 12 of 176 tracks". `directory` is the staged
    /// package the run reports its steps in; `tool` is what converts (a
    /// stand-in in tests). Each source's chapters, an Ogg file's CHAPTER
    /// comments or another format's markers, are kept in the .m4a's chapter
    /// track (FMT17, `ImportAudioConverter.convert(_:naming:using:keepingChapters:)`).
    ///
    /// An import's Cancel (`ImportCancellation.current`, read here on the
    /// import's own thread, since the task the wait runs in does not inherit
    /// task-locals) kills the running conversions at once. The tool that
    /// converts the files only ffmpeg reads (`FFmpegAudioConverter.tool`,
    /// FMT31) is read here for the same reason, unless `tool` names its own.
    /// - Throws: the first conversion's error, every file already converted
    ///   being removed first; `ImportCancelled` when the reader cancelled.
    static func convertTracks(
        _ sources: [URL],
        inPackage directory: URL,
        using tool: ImportAudioConverter.Tool = .afconvert,
        run: inout ImportRun
    ) throws -> [ImportAudioConverter.Conversion] {
        try run.begin(.convertingImportedAudio(done: 0, of: sources.count), in: directory)
        let cancellation = ImportCancellation.current
        let tool = tool.resolvingFFmpeg()
        var conversions: [ImportAudioConverter.Conversion] = []
        do {
            let size = ImportAudioConverter.maximumConcurrentConversions
            for start in stride(from: 0, to: sources.count, by: size) {
                let group = Array(sources[start..<min(start + size, sources.count)])
                conversions += try AsyncBridge.waitForResult(cancelledBy: cancellation) {
                    try await ImportAudioConverter.convertEach(group, naming: false, using: tool, keepingChapters: true)
                }
                try run.begin(.convertingImportedAudio(done: conversions.count, of: sources.count), in: directory)
            }
        } catch {
            ImportAudioConverter.discard(conversions)
            // The reader cancelled the import: the conversions are killed
            // (and what they had made removed), and the import ends as a
            // cancelled one does rather than as a failed one.
            if error is CancellationError, cancellation?.isCancelled == true { throw ImportCancelled() }
            throw error
        }
        return conversions
    }
}
