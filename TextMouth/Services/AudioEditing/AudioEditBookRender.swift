import AVFoundation

/// Renders the edits of one audio file of a book into that file, replacing
/// it (FR04): what saving in the editor does. The library model runs it off
/// the main thread, as storage work, while it holds a use of the book
/// (`LibraryViewModel.saveAudioEdits`), and then publishes the book's new
/// file, content index, and fingerprint.
///
/// The steps, each safe to stop after:
///
/// 1. Under the edit history's lock: an imported file never rendered into,
///    under a policy that keeps originals, has its original kept first, a
///    clone of the file as it is (`AudioEditPackage.keepOriginal`).
/// 2. The edits not yet in the audio they start from are applied to it, and
///    the result is rendered into a hidden file beside the book's file, in
///    the file's own format wherever TextMouth can write it
///    (`AudioRenderFormat.inPlace`).
/// 3. The rendered file is read back: it must open as audio and last as
///    long as the edits say, to within a few milliseconds.
/// 4. It takes the place of the book's file in one step: an atomic replace
///    under the same name, or, for a format of another extension, a move to
///    the new name, the old file staying until the book's record names the
///    new one (the caller removes it).
/// 5. Under the lock again: the list notes the edits the file now holds,
///    and follows a renamed file.
enum AudioEditBookRender {
    /// What to render.
    struct Request: Sendable {
        /// The book's package.
        let package: URL
        /// The book's file, by its path inside the package: a recording's
        /// take is the original of this file (`AudioEditHistoryStore`).
        let bookFile: String
        /// The audio file to render, by its path inside the package.
        let audioFile: String
        /// The global original policy, which the book's own may override.
        let globalPolicy: AudioOriginalPolicy
        /// The tags the rendered file gets.
        let metadata: AudioRenderMetadata
        /// This Mac's scratch folder for the book (`AudioEditScratch`).
        let scratch: URL
        /// Makes what renders filters and gain changes for edits whose
        /// stretches come from the sources given; nil refuses them.
        let makeProcessor: AudioEditProcessorFactory
        /// The installed ffmpeg TextMouth may use, which writes an MP3
        /// book's file should the LAME built in be unavailable (`MP3Route`);
        /// with neither, an MP3 book is written as AAC in an .m4a file.
        let ffmpeg: FFmpeg?
        /// Asked just before the book's file is replaced: false, as when the
        /// book was opened in a reader meanwhile, stops the render with
        /// `AudioEditError.bookIsOpen`.
        let mayReplace: @Sendable () -> Bool
    }

    /// What a render did.
    struct Result: Equatable, Sendable {
        /// The audio file, by its path inside the package now: another name
        /// when its format's extension changed.
        let audioFile: String
        /// The file's old path inside the package, when the render wrote the
        /// audio under a new name; the old file stays until the book's
        /// record names the new one.
        let replacedFile: String?
        /// How long the audio lasts now, in seconds.
        let duration: TimeInterval
        /// Whether anything was rendered: false when the file already held
        /// every applied edit.
        let rendered: Bool
        /// How many edits the file holds now: none when every edit was
        /// undone and the original audio was rendered back, which the
        /// podcast chapters kept beside it fit again.
        let appliedEditCount: Int
    }

    /// Renders `request` at `now`, telling `progress` how far it is.
    /// - Throws: the history store's errors; `AudioEditError.originalNeeded`
    ///   when the edits wait for an original that is gone; the timeline's,
    ///   composition's, and renderer's errors; `.bookIsOpen`; or
    ///   `CancellationError`. Nothing the book plays is changed by a failure.
    static func run(
        _ request: Request,
        now: Date = Date(),
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Result {
        let package = request.package
        guard let bookFileURL = AudioEditPackage.url(of: request.audioFile, in: package) else {
            throw AudioEditError.fileOutsidePackage
        }

        // 1. The list as it is now, with an original kept first when it is
        // the file's first render and the policy keeps one.
        let list = try AudioEditHistoryStore.update(package: package, bookFile: request.bookFile) { history in
            var list = history.listOrNew(for: request.audioFile)
            guard !list.isRendered else { return list }
            if list.original == nil {
                guard list.lastRenderedAt == nil else {
                    // Edits waiting for an original that is gone: only the
                    // audio as last rendered can be built on, and the list's
                    // state isn't that audio plus later edits.
                    guard let rendered = list.renderedCursor, rendered <= list.cursor else {
                        throw AudioEditError.originalNeeded
                    }
                    return list
                }
                if history.effectivePolicy(global: request.globalPolicy) != .delete {
                    list.keepOriginal(try AudioEditPackage.keepOriginal(
                        ofAudioFile: request.audioFile,
                        inPackage: package,
                        at: now
                    ))
                    history.setList(list)
                }
            }
            return list
        }
        guard !list.isRendered else {
            let current = try await AudioEditBase.load(bookFileURL, name: request.audioFile)
            return Result(
                audioFile: request.audioFile,
                replacedFile: nil,
                duration: Double(current.frames) / current.sampleRate,
                rendered: false,
                appliedEditCount: list.appliedEntries.count
            )
        }
        let renderedIDs = list.appliedEntries.map(\.id)

        // 2. The edits applied to the audio they start from, rendered beside
        // the book's file.
        let baseFile = list.original?.file ?? request.audioFile
        guard let baseURL = AudioEditPackage.url(of: baseFile, in: package) else { throw AudioEditError.fileOutsidePackage }
        let base = try await AudioEditBase.load(baseURL, name: baseFile)
        let sources = AudioEditComposition.Sources(base: base, package: package, scratch: request.scratch)
        let processor = request.makeProcessor(sources)
        var timeline = base.timeline
        for entry in list.entriesOverBase {
            try await timeline.apply(entry.edit, processor: processor)
        }
        let current = baseFile == request.audioFile ? base : try await AudioEditBase.load(bookFileURL, name: request.audioFile)
        let format = AudioRenderFormat.inPlace(
            forFileNamed: bookFileURL.lastPathComponent,
            stored: current.format,
            ffmpeg: request.ffmpeg
        )
        let folder = bookFileURL.deletingLastPathComponent()
        let newName = format.fileName(replacing: bookFileURL.lastPathComponent)
        let destination = newName == bookFileURL.lastPathComponent
            ? bookFileURL
            : freeURL(named: newName, in: folder)
        let staged = folder.appendingPathComponent(".\(UUID().uuidString).editing.\(format.fileExtension)")
        defer { try? FileManager.default.removeItem(at: staged) }
        _ = try await AudioEditRenderer.render(
            timeline,
            sources: sources,
            to: staged,
            format: format,
            metadata: request.metadata,
            ffmpeg: request.ffmpeg,
            progress: progress
        )

        // 3. The rendered file, read back.
        let written = try await AudioEditBase.load(staged, name: request.audioFile)
        let writtenSeconds = Double(written.frames) / written.sampleRate
        // An MP3 the LAME built in writes carries the gapless numbers, so it
        // measures as long as its sound; one ffmpeg writes measures longer
        // by LAME's delay and padding, which is allowed for.
        let excess = writtenSeconds - timeline.duration
        let allowed = format == .mp3 ? FFmpeg.mp3Excess(sampleRate: written.sampleRate) : 0
        guard excess >= -Self.lengthTolerance, excess <= allowed + Self.lengthTolerance else {
            throw AudioEditError.renderFailed(
                "the rendered file lasts \(writtenSeconds) seconds, not \(timeline.duration)"
            )
        }

        // 4. In the book file's place.
        guard request.mayReplace() else { throw AudioEditError.bookIsOpen }
        do {
            if destination == bookFileURL {
                _ = try FileManager.default.replaceItemAt(bookFileURL, withItemAt: staged)
            } else {
                try FileManager.default.moveItem(at: staged, to: destination)
            }
        } catch {
            let failure = error as NSError
            throw AudioEditError.renderFailed("\(failure.domain) \(failure.code)")
        }
        let newPath = AudioEditPackage.path(of: destination, in: package) ?? request.audioFile

        // 5. The list notes what the file holds now.
        try AudioEditHistoryStore.update(package: package, bookFile: request.bookFile) { history in
            var list = history.listOrNew(for: request.audioFile)
            list.markRendered(entryIDs: renderedIDs, at: now)
            if newPath != request.audioFile {
                list.renameFile(to: newPath)
            }
            history.setList(list)
        }
        return Result(
            audioFile: newPath,
            replacedFile: newPath == request.audioFile ? nil : request.audioFile,
            duration: writtenSeconds,
            rendered: true,
            appliedEditCount: renderedIDs.count
        )
    }

    /// Follows a track of the book `bookID`, a book of several, renamed by a
    /// render from `old` to `new` (paths inside the package), in the
    /// manifest of the book's audio folder `folder`, which is at
    /// `folderInPackage` inside the package, wherever the reader finds it,
    /// inside the folder's one folder too (`AudioManifestLocation`): its
    /// tracks, its order, its chapter titles, and its sections' clips, each
    /// naming the track as the manifest spells it. So an edited Ogg track,
    /// which renders to .m4a, keeps its place, its title, and its group
    /// (FR17, board finding #2457). The manifest is changed as JSON and
    /// written through the one write of a manifest (`BookManifestFile`),
    /// which tells an Edit Manifest session of the book. A folder without a
    /// manifest, or one not naming the track, is left as it is.
    static func renameTrack(_ old: String, to new: String, inManifestOf folder: URL, folderInPackage: String, bookID: UUID? = nil) throws {
        let prefix = folderInPackage + "/"
        guard old.hasPrefix(prefix), new.hasPrefix(prefix), let location = AudioManifestLocation.find(in: folder) else { return }
        let oldName = location.name(ofTrackAt: String(old.dropFirst(prefix.count)))
        let newName = location.name(ofTrackAt: String(new.dropFirst(prefix.count)))
        try BookManifestFile.change(manifestAt: location, of: bookID) { object in
            BookManifestFile.renameTrack(oldName, to: newName, in: &object)
        }
    }

    /// How far a rendered file's length may differ from the edits' length
    /// and still be taken: 20 milliseconds, more than AAC's padding at the
    /// lowest rate audiobooks use, and far less than any edit.
    static let lengthTolerance: TimeInterval = 0.02

    /// `name` in `folder`, or, when a file has that name already, the first
    /// of "<stem> 2.<ext>", "<stem> 3.<ext>", … that is free.
    private static func freeURL(named name: String, in folder: URL) -> URL {
        let file = name as NSString
        var candidate = folder.appendingPathComponent(name)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(file.deletingPathExtension) \(number).\(file.pathExtension)")
            number += 1
        }
        return candidate
    }
}
