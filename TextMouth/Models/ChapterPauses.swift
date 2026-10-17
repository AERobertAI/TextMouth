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
///
/// Two values are equal when they give the same pause after every chapter,
/// whatever list made them: a list that ends in chapters with no pause is the
/// same value as the list without those entries.
struct ChapterPauses: Equatable, Sendable {
    /// The seconds of silence after each chapter, by the chapter's index.
    private let seconds: [TimeInterval]

    /// No pause after any chapter: the book plays straight on from each
    /// chapter into the next, as every book did before pauses existed. Equal
    /// to every list of zeros, such as the one a manifest with no pause gives.
    static let none = ChapterPauses(afterEachChapter: [])

    /// Pauses of `seconds` after the chapters, the first after the first
    /// chapter; a chapter past the list has none. A pause below 0, or not a
    /// number, is none. Trailing entries of no pause are dropped, so the
    /// stored list is the shortest one that gives these pauses, which is what
    /// makes the synthesized `==` compare what the pauses mean.
    init(afterEachChapter seconds: [TimeInterval]) {
        var cleaned = seconds.map { $0.isFinite ? max(0, $0) : 0 }
        // A chapter past the end of the list has no pause, so a trailing 0 adds nothing.
        while cleaned.last == 0 { cleaned.removeLast() }
        self.seconds = cleaned
    }

    /// The seconds of silence after chapter `chapterIndex`; 0 for a chapter
    /// with none.
    func after(chapter chapterIndex: Int) -> TimeInterval {
        seconds.indices.contains(chapterIndex) ? seconds[chapterIndex] : 0
    }
}
