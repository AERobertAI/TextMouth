import AVFoundation

// MARK: - The Formats

/// A format a speech export writes its one audio file in (FMT43), as the
/// Export dialog's Format pop-up lists them: the audio editor's AAC and MP3
/// formats, each holding a chapter for each heading. M4B, the audiobook,
/// comes first, as the dialog's default.
enum SpeechExportFormat: String, CaseIterable, Sendable {
    /// AAC in an .m4b audiobook file, with chapter markers.
    case m4b
    /// AAC in an .m4a file, with chapter markers.
    case m4a
    /// MP3, with ID3 chapter frames.
    case mp3

    /// The audio editor's export format it is, which says how the editor's
    /// renderer writes it.
    var exportFormat: AudioExportFormat {
        switch self {
        case .m4b: return .m4b
        case .m4a: return .m4a
        case .mp3: return .mp3
        }
    }

    /// Its name as the dialog lists it and VoiceOver reads it: the audio
    /// editor's words for the same format.
    var title: String {
        exportFormat.title
    }

    /// The extension of a file exported in it, without the dot.
    var fileExtension: String {
        exportFormat.fileExtension
    }

    /// The formats the dialog offers, in order: those the audio editor's
    /// Export offers without an installed ffmpeg, which a speech export
    /// never uses. That is all three while the LAME built into TextMouth can
    /// write MP3, as it always can, and only M4B and M4A should it not.
    static var available: [SpeechExportFormat] {
        let offered = AudioExportFormat.available(ffmpeg: nil)
        return allCases.filter { offered.contains($0.exportFormat) }
    }
}

// MARK: - The Chapter Files

/// One chapter of a speech export as the encoder joins it (FMT43): the file
/// its speech was rendered into, and the title of the chapter marker at its
/// start.
struct SpeechExportChapterFile: Equatable, Sendable {
    /// The file's plain name in the encoder's folder, with no folder of its
    /// own, so it names no file anywhere else.
    let name: String
    /// The title of its chapter marker, as the joined file lists it.
    let title: String
}

// MARK: - The Encoder

/// Joins a speech export's chapter files into the one audio file the export
/// makes (FMT43): an AAC M4B or M4A with a chapter marker at the start of
/// each file, or an MP3 with an ID3 chapter frame at each. The audio
/// editor's renderer writes it (`AudioEditRenderer`), with the chapters,
/// tags, and progress it gives every render, from a timeline of the files
/// played whole, one after another
/// (`AudioEditTimeline.init(sampleRate:joining:)`): the export has no
/// encoder of its own.
///
/// An encode blocks the thread it runs on, as the export's other steps do,
/// so the export calls it on its background thread, never the main one.
/// Stop reaches it through the export's `BookExportCancellation`, which the
/// encode watches while the renderer works, so a long book's encode ends
/// within a fraction of a second of Stop, leaving nothing at its
/// destination.
enum SpeechExportEncoder {
    /// How often a running encode looks at its cancellation: every tenth of
    /// a second, so Stop ends it within a fraction of a second.
    private static let cancellationCheckInterval: Duration = .milliseconds(100)

    /// Joins `chapters`, files in `folder` by their plain names, into one
    /// new file of `format` at `destination`: their sound one after another,
    /// with a chapter starting where each file does, titled as given, and
    /// `metadata`'s title and artist as the file's tags. `progress` is told
    /// how far the encode has come, from 0 to 1, on the encode's own thread.
    /// A file already at `destination` is replaced. A chapter whose file
    /// holds no sound is left out, its chapter marker with it.
    ///
    /// Blocks the calling thread until the file is written: call it off the
    /// main thread.
    /// - Throws: `CancellationError` once `cancellation` is set: at once,
    ///   touching nothing, when it already is, or while the file is written,
    ///   leaving nothing at `destination`. `AudioEditError.renderFailed` for
    ///   no chapters, no sound in any of them, or files that differ in
    ///   sample rate or channels; `.fileOutsidePackage` for a name that is
    ///   not a plain file name; `.unreadableAudio` for a file that can't be
    ///   read as audio; or the renderer's errors, after which nothing is left
    ///   at `destination` either.
    static func encode(
        _ chapters: [SpeechExportChapterFile],
        in folder: URL,
        format: SpeechExportFormat,
        metadata: AudioRenderMetadata,
        to destination: URL,
        cancellation: BookExportCancellation,
        progress: @escaping @Sendable (Double) -> Void
    ) throws {
        // Stopped before it began: nothing is read, and nothing is written.
        try cancellation.checkCancelled()
        // Every name is checked before any file is opened, so none can reach
        // a file outside the folder.
        guard chapters.allSatisfy({ BookOrigin.isPlainFileName($0.name) }) else {
            throw AudioEditError.fileOutsidePackage
        }
        let files = try chapters.map { try ChapterAudio(reading: folder.appendingPathComponent($0.name)) }
        guard let first = files.first else {
            throw AudioEditError.renderFailed("no chapters")
        }
        // One file's sound has one rate and one set of channels.
        guard files.allSatisfy({ $0.sampleRate == first.sampleRate && $0.channelCount == first.channelCount }) else {
            throw AudioEditError.renderFailed("the chapters' audio differs")
        }
        // The renderer takes the settings it writes with from the audio the
        // edits start from: here the first chapter with sound, as a file of
        // no frames is no audio to the editor (`AudioEditBase.load`), and is
        // left out of the timeline.
        guard let base = zip(chapters, files).first(where: { $0.1.frames > 0 })?.0 else {
            throw AudioEditError.renderFailed("the chapters hold no sound")
        }
        let timeline = AudioEditTimeline(
            sampleRate: first.sampleRate,
            joining: zip(chapters, files).map { chapter, file in
                (name: chapter.name, frames: file.frames, title: chapter.title)
            }
        )
        let renderFormat = format.exportFormat.renderFormat

        do {
            try AsyncBridge.waitForResult {
                let loaded = try await AudioEditBase.load(folder.appendingPathComponent(base.name), name: base.name)
                // The chapter files are the processed stretches the timeline
                // names, which come from the scratch folder; a joined
                // timeline has no takes, which would come from the package.
                let sources = AudioEditComposition.Sources(base: loaded, package: folder, scratch: folder)
                try await Self.run(stoppingAt: cancellation) {
                    _ = try await AudioEditRenderer.render(
                        timeline,
                        sources: sources,
                        to: destination,
                        format: renderFormat,
                        metadata: metadata,
                        progress: progress
                    )
                }
            }
        } catch let stop as CancellationError {
            // The renderer removes its file when Stop ends it partway; a file
            // it finished just as Stop came is removed here, so a stopped
            // encode never leaves one behind.
            try? FileManager.default.removeItem(at: destination)
            throw stop
        }
    }

    /// Runs `work` until it ends or `cancellation` is set, whichever comes
    /// first: beside it, a watch looks at the token every
    /// `cancellationCheckInterval` and throws `CancellationError` once it is
    /// set. The first of the two to end decides, with the work's own end or
    /// error, or the watch's `CancellationError`; the other is then
    /// cancelled. Both have ended when this returns or throws, so work that
    /// follows its task's cancellation, as the renderer does, has cleaned up
    /// by then.
    private static func run(
        stoppingAt cancellation: BookExportCancellation,
        _ work: @escaping @Sendable () async throws -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask(operation: work)
            group.addTask {
                while !cancellation.isCancelled {
                    try await Task.sleep(for: Self.cancellationCheckInterval)
                }
                throw CancellationError()
            }
            // The first task to end: an error, the work's or the watch's, is
            // thrown here, and throwing out of the group cancels the other
            // task and waits for it.
            _ = try await group.next()
            // The work ended first: the watch is stopped, and the group waits
            // for it as it leaves.
            group.cancelAll()
        }
    }

    /// What the encoder reads of one chapter's file before joining it.
    private struct ChapterAudio {
        /// How many frames the file holds.
        let frames: Int64
        /// Its frames a second.
        let sampleRate: Double
        /// How many channels it has.
        let channelCount: AVAudioChannelCount

        /// Reads the length and format of the file at `url` with Core Audio.
        /// A format the import converts, Ogg first, is never decoded in the
        /// app (B09, FMT09), so it is refused before Core Audio sees it.
        /// - Throws: `AudioEditError.unreadableAudio` for a file that is not
        ///   there, is not audio, or is of a format never decoded in the app.
        init(reading url: URL) throws {
            guard !ImportAudioConverter.isNeverDecodedInApp(url),
                  let file = try? AVAudioFile(forReading: url) else { // lint-ok: isNeverDecodedInApp refuses every format the import converts first
                throw AudioEditError.unreadableAudio
            }
            // A file's header is read as it is written, so a damaged one can
            // claim any rate, channel count, or length; one out of bounds is
            // no chapter of speech, and its frames, added to the others',
            // could overflow the timeline's count.
            let format = file.fileFormat
            guard Self.sampleRates.contains(format.sampleRate),
                  Self.channelCounts.contains(format.channelCount),
                  file.length >= 0,
                  Double(file.length) <= format.sampleRate * Self.longestSeconds else {
                throw AudioEditError.unreadableAudio
            }
            frames = file.length
            sampleRate = format.sampleRate
            channelCount = format.channelCount
        }

        /// The sample rates a chapter's file may have: any a voice speaks
        /// in, 8 kHz to 384 kHz.
        static let sampleRates: ClosedRange<Double> = 8_000...384_000

        /// The channel counts a chapter's file may have.
        static let channelCounts: ClosedRange<AVAudioChannelCount> = 1...8

        /// The longest a chapter's file may last: two days. A chapter spoken
        /// from a book lasts minutes or hours, so a file claiming more is
        /// damaged; at most 10,000 such files at 384 kHz stay far inside the
        /// frames a timeline can count.
        static let longestSeconds: Double = 48 * 60 * 60
    }
}
