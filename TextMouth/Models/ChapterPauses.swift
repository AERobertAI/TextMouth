import Foundation

/// The silence a book keeps after each of its chapters before the next
/// one starts, while the book plays on from one chapter into the next: the
/// one source the reader takes such pauses from
/// (`ReaderViewModel.chapterPauses`), each waited out by the same
/// cancellable start of the next chapter
/// (`ReaderViewModel.startCursorChapter(afterPause:)`).
///
/// For now an audiobook's manifest is the only supplier, for a multi-file
/// audiobook: the pauses its `pauseBetweenTracksMs` and `pauseAfterMs` give
/// (`betweenTracks(of:inAudioFolder:)`, October 13, 2026). A later setting,
/// global or of one book, of a pause between chapters or headings, for
/// audiobooks or text, the user's wish of that day, is another way of
/// making one of these, or of combining one with the manifest's, as the
/// book loads; the reader waits out whatever it gives in the same way.
struct ChapterPauses: Equatable, Sendable {
    /// The seconds of silence after each chapter, by the chapter's index.
    private let seconds: [TimeInterval]

    /// No pause after any chapter: the book plays straight on from each
    /// chapter into the next, as every book did before pauses existed.
    static let none = ChapterPauses(afterEachChapter: [])

    /// Pauses of `seconds` after the chapters, the first after the first
    /// chapter; a chapter past the list has none. A pause below 0, or not a
    /// number, is none.
    init(afterEachChapter seconds: [TimeInterval]) {
        self.seconds = seconds.map { $0.isFinite ? max(0, $0) : 0 }
    }

    /// The seconds of silence after chapter `chapterIndex`; 0 for a chapter
    /// with none.
    func after(chapter chapterIndex: Int) -> TimeInterval {
        seconds.indices.contains(chapterIndex) ? seconds[chapterIndex] : 0
    }
}
