import Foundation

/// The chapter lists TextMouth reads from an audio file's own bytes, for a
/// file AVFoundation finds no chapters in (`AudioPlaybackService.extractChapters`):
/// the one place that picks the reader by the file's kind, so every list read
/// by hand takes the same shape (`NeroChapterReader.Chapter`) and is made into
/// a book's chapters the same way (`NeroChapterReader.bookChapters(from:fileDuration:)`).
enum FileChapterReaders {
    /// The chapters the file at `url` lists in the place its kind keeps
    /// them when AVFoundation reads none: an MPEG-4 file's Nero list (FMT05,
    /// `NeroChapterReader`), and a FLAC file's cue sheet (FMT24,
    /// `FLACCueSheetReader`). Empty when such a file keeps no list; nil for
    /// a file of another kind, which has no list to read.
    static func chapters(of url: URL) -> [NeroChapterReader.Chapter]? {
        if NeroChapterReader.mayHoldChapterList(url) {
            return NeroChapterReader.read(at: url)
        }
        if FLACCueSheetReader.mayHoldCueSheet(url) {
            return FLACCueSheetReader.chapters(at: url)
        }
        return nil
    }
}
