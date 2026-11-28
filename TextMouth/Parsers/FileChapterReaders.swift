import Foundation

/// The chapter lists TextMouth reads from an audio file's own bytes, for a
/// file AVFoundation finds no chapters in (`AudioPlaybackService.extractChapters`):
/// the one place that picks the reader by the file's kind, so every list read
/// by hand takes the same shape (`NeroChapterReader.Chapter`) and is made into
/// a book's chapters the same way.
enum FileChapterReaders {
    /// A book's chapters, as `AudioPlaybackService.extractChapters` returns
    /// them: each one's title, start, and length, in seconds.
    typealias BookChapters = [(title: String, startTime: TimeInterval, duration: TimeInterval)]

    /// The chapters the file at `url`, lasting `duration` seconds, lists in
    /// the place its kind keeps them when AVFoundation reads none, as a
    /// book's chapters:
    ///
    /// - an MPEG-4 file's Nero list (FMT05, `NeroChapterReader`), as it has
    ///   always been read (`NeroChapterReader.bookChapters(from:fileDuration:)`);
    /// - a FLAC file's cue sheet (FMT24, `FLACCueSheetReader`) and a WAVE or
    ///   AIFF file's markers (FMT17, `AudioMarkerList`: a WAVE file's cue
    ///   points and labels, a Broadcast Wave file's among them, and an AIFF
    ///   file's MARK chunk), as places in the file (`placedChapters`), the
    ///   sound before the first titled `leadingTitle`, which is asked only
    ///   then.
    ///
    /// Empty when such a file keeps no list, or its list makes one chapter;
    /// nil for a file of another kind, which keeps no list.
    static func bookChapters(
        of url: URL,
        lasting duration: TimeInterval,
        leadingTitle: () async -> String
    ) async -> BookChapters? {
        if NeroChapterReader.mayHoldChapterList(url) {
            return NeroChapterReader.bookChapters(from: NeroChapterReader.read(at: url), fileDuration: duration)
        }
        let places: [NeroChapterReader.Chapter]
        if FLACCueSheetReader.mayHoldCueSheet(url) {
            places = FLACCueSheetReader.chapters(at: url)
        } else if AudioMarkerList.mayHoldMarkers(url) {
            places = AudioMarkerList.chapters(at: url)
        } else {
            return nil
        }
        guard !places.isEmpty else { return [] }
        return placedChapters(places, lasting: duration, leadingTitle: await leadingTitle())
    }

    /// `places`, a cue sheet's tracks or a file's markers (FMT24, FMT17), or
    /// an Ogg file's chapter comments, in a file lasting `duration` seconds,
    /// as a book's chapters: made as every list read by hand is
    /// (`NeroChapterReader.bookChapters(from:fileDuration:)`: sorted, each
    /// lasting until the next, the last to the end, an untitled one "Chapter
    /// N"), after a chapter titled `leadingTitle` (the book's title) for the
    /// sound before the first place when that isn't at the start, as the
    /// audio editor writes its markers (`AudioEditRenderer.chapterList(of:leadingTitle:)`),
    /// so a marker 30 seconds in begins a heading there and not at the
    /// start. None when that makes a single chapter, which tells no more
    /// than the book's title: a book of one heading keeps its title, as it
    /// did before these lists were read, not "Track 1" or "Chapter 1".
    static func placedChapters(
        _ places: [NeroChapterReader.Chapter],
        lasting duration: TimeInterval,
        leadingTitle: String
    ) -> BookChapters {
        var listed = places
        if let earliest = places.map(\.start).min(), earliest > 0 {
            listed.insert(NeroChapterReader.Chapter(title: leadingTitle, start: 0), at: 0)
        }
        let chapters = NeroChapterReader.bookChapters(from: listed, fileDuration: duration)
        return chapters.count > 1 ? chapters : []
    }
}
