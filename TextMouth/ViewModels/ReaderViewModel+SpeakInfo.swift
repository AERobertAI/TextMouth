import Foundation

// MARK: - Speak Info in a Reader (October 17, 2026)

extension ReaderViewModel {

    /// Speaks the reader's own book's information, as Speak Info does for
    /// that book's row in a Library window: the brief summary for `.brief`
    /// (Shift-Command-I), the full one for `.full` (Shift-Command-I twice).
    ///
    /// The words are the Library's: the book's facts are gathered as the
    /// Library gathers them for its row (`LibraryInfoSubject`) and worded by
    /// the same code (`LibraryInfoSpeaker.text(for:detail:now:)`), so no
    /// sentence is written twice. They are announced as the reader's other
    /// spoken commands announce (`announceToVoiceOver(_:)`), with high
    /// priority, so a full summary asked for a moment after the brief one
    /// is spoken in its place. The book keeps playing: unlike Where Am I?,
    /// whose announcement pauses it, this speaks over it, as VoiceOver
    /// speaks over any app.
    ///
    /// - Parameters:
    ///   - detail: Which summary to speak.
    ///   - now: The moment the summary is worded as of, for the times it
    ///     says relative to it ("added yesterday").
    /// - Returns: The words announced, for tests.
    @discardableResult
    func speakInfo(_ detail: SummaryDetail, now: Date = Date()) -> String {
        // The book as the library holds it now (a hand edit or a rename
        // made since the reader opened shows), or the reader's own copy
        // when the library has let it go.
        let current = libraryViewModel.bookByID(book.id) ?? book
        let subject = LibraryInfoSubject(
            .book(current),
            library: libraryViewModel,
            feedFolders: .shared,
            wordsPerMinute: settingsViewModel.wordsPerMinute,
            cloudStates: .shared,
            keptBooks: .shared,
            // Only the full summary says the file's size, so only it
            // measures the file.
            measuresFileSize: detail == .full,
            now: now
        )
        let words = LibraryInfoSpeaker.text(for: subject, detail: detail, now: now)
        announceToVoiceOver(words)
        return words
    }
}
