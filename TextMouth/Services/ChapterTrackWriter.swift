import AVFoundation

/// Writes chapters into an MPEG-4 audio file the import has just converted
/// (FMT17): an Ogg file's CHAPTERnnn comments, or another format's markers,
/// which `afconvert` does not carry, as the chapter track AVFoundation reads
/// back (`AudioPlaybackService.extractChapters`): the audio editor's own
/// (`AudioChapterTrack`), laid out ahead of the audio as the editor lays it.
///
/// The file's samples are copied exactly as they are stored, never decoded
/// and encoded again, so a chapter list costs no second lossy generation;
/// its tags are kept. The copy is written to a new file the caller names
/// (the import's own hidden name beside the old, which a leftover sweep
/// knows, `ImportAudioConverter.temporaryURL(beside:)`), which the caller
/// checks before it takes the old file's place; the old file is never
/// changed.
///
/// Only a file of TextMouth's own converting is opened: an .m4a whose bytes
/// are no Ogg (`ImportAudioConverter.isNeverDecodedInApp`), the one file kind
/// the import's conversion writes.
enum ChapterTrackWriter {
    /// Writes the .m4a at `file`, which lasts `duration` seconds, to a new
    /// .m4a at `destination` with the chapters `chapters` lists, made into a
    /// book's chapters as every list of places read by hand is
    /// (`FileChapterReaders.placedChapters`: sorted, each lasting until the
    /// next, the sound before the first titled as the book will be, by the
    /// file's own title tag or `fallbackTitle`, and none when they make one
    /// chapter).
    /// - Returns: whether anything was written: a list that makes no chapter,
    ///   or only one, writes nothing.
    /// - Throws: `AudioEditError.unreadableAudio` for a file this writer
    ///   never opens or that has no audio track, `AudioEditError.renderFailed`
    ///   when AVFoundation refuses the copy, or `CancellationError`; nothing
    ///   is left at `destination`.
    @discardableResult
    static func write(
        _ chapters: [NeroChapterReader.Chapter],
        from file: URL,
        to destination: URL,
        lasting duration: TimeInterval,
        titled fallbackTitle: String
    ) async throws -> Bool {
        guard !chapters.isEmpty else { return false }
        guard !ImportAudioConverter.isNeverDecodedInApp(file) else { throw AudioEditError.unreadableAudio }
        let title = await AudioPlaybackService.extractMetadata(from: file).title ?? fallbackTitle
        let list = FileChapterReaders.placedChapters(chapters, lasting: duration, leadingTitle: title)
        guard !list.isEmpty else { return false }

        let asset = AVURLAsset(url: file) // lint-ok: the import's own .m4a, refused above when it is of a converted format or Ogg
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AudioEditError.unreadableAudio
        }
        let hint = try await track.load(.formatDescriptions).first
        let tags = (try? await asset.load(.metadata)) ?? []
        do {
            try await copy(track, of: asset, hint: hint, tags: tags, chapters: list, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return true
    }

    /// Writes `track` of `asset`, its samples as they are stored (their
    /// format `hint`), with `tags` and the chapter track of `chapters`, to a
    /// new .m4a at `destination`.
    private static func copy(
        _ track: AVAssetTrack,
        of asset: AVURLAsset,
        hint: CMFormatDescription?,
        tags: [AVMetadataItem],
        chapters: [(title: String, startTime: TimeInterval, duration: TimeInterval)],
        to destination: URL
    ) async throws {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset) // lint-ok: the same own .m4a, its samples copied, never decoded
        } catch {
            throw AudioEditRenderer.failure(error)
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AudioEditError.renderFailed("the reader refused the audio") } // l10n: no (a fragment inside AudioEditError's English sentences until that area converts)
        reader.add(output)

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: destination, fileType: .m4a)
        } catch {
            throw AudioEditRenderer.failure(error)
        }
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: hint)
        audio.expectsMediaDataInRealTime = false
        guard writer.canAdd(audio) else { throw AudioEditError.renderFailed("the writer refused the audio") } // l10n: no (a fragment inside AudioEditError's English sentences until that area converts)
        writer.add(audio)

        // The chapter list, as the audio editor writes one: a disabled text
        // track the audio names as its chapters, ahead of the audio.
        let format = try AudioChapterTrack.formatDescription()
        let titles = AVAssetWriterInput(mediaType: .text, outputSettings: nil, sourceFormatHint: format)
        titles.marksOutputTrackAsEnabled = false
        titles.mediaDataLocation = .beforeMainMediaDataNotInterleaved
        guard writer.canAdd(titles) else { throw AudioEditError.renderFailed("the writer refused the chapter list") } // l10n: no (a fragment inside AudioEditError's English sentences until that area converts)
        writer.add(titles)
        audio.addTrackAssociation(withTrackOf: titles, type: AVAssetTrack.AssociationType.chapterList.rawValue)
        writer.metadata = tags

        guard reader.startReading() else { throw AudioEditRenderer.failure(reader.error) }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw AudioEditRenderer.failure(writer.error)
        }
        writer.startSession(atSourceTime: .zero)
        do {
            for chapter in chapters {
                let marker = AudioRenderChapter(start: chapter.startTime, duration: chapter.duration, title: chapter.title)
                try await AudioEditRenderer.append(try AudioChapterTrack.sample(marker, format: format), to: titles, of: writer)
            }
            titles.markAsFinished()
            while let buffer = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                try await AudioEditRenderer.append(buffer, to: audio, of: writer)
            }
            guard reader.status == .completed else { throw AudioEditRenderer.failure(reader.error) }
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            throw error
        }
        audio.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw AudioEditRenderer.failure(writer.error) }
    }
}
