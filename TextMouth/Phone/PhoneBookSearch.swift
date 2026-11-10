import Foundation

/// The words of the phone's Search in Book sheet and of the button that opens
/// it. The field, the switch, the list, and the status line are the Mac's own
/// words (`BookSearchWording`, `BookSearchModel.Status`); only what the phone
/// adds sits here, each a full, plain sentence that says what a control does
/// and never a gesture (principle 7).
enum PhoneBookSearchVocabulary {
    /// The button's label and the sheet's title: the Mac's command, "Search in
    /// Book".
    static var title: String { ShortcutAction.searchInBook.title }

    /// The button's hint.
    static let buttonHint = "Opens a search of the book's text."

    /// A result row's hint. The Mac's "Activate to navigate to this result"
    /// names a gesture.
    static let rowHint = "Goes to this result."

    /// How long typing must pause before a search runs and its count is said:
    /// one second, as the Library's search waits (the spec, "Searching"), so
    /// that a listener typing with a display or Braille Screen Input is not
    /// told "No matches" between letters. The Mac waits a quarter second.
    static let typingPause: Duration = .seconds(1)

    /// The sheet's button that closes it: the word the headings sheet uses.
    /// Its hint is the Mac's (`BookSearchWording.backToBookHint`).
    static let backToBook = PhoneHeadingsVocabulary.backToBook
}

/// What a search of an open book reads, copied from the reader so that the
/// search can run off the main actor, with what each result's row needs to
/// say where its match is. Shared with the Mac's test host: it names no UIKit.
struct PhoneBookSearchSource: Sendable {
    /// The book's text, titles, and headings to search, with the timing of a
    /// transcribed audiobook's.
    let corpus: BookSearchCorpus
    /// The book's length in characters, which a text book's estimated places
    /// are counted against.
    let totalCharacterCount: Int
    /// The book's length in words.
    let totalWordCount: Int
    /// The speed a text book's estimated times count at.
    let wordsPerMinute: Double

    /// Whether the book searched is a transcript, whose results have the
    /// exact time they are heard and move the audio to it.
    var isTranscript: Bool { corpus.timing != nil }

    /// A source of nothing, for a reader that has no text to search.
    static let empty = PhoneBookSearchSource(
        corpus: BookSearchCorpus(chapterTexts: [], chapterTitles: [], headings: [], bookTitle: ""),
        totalCharacterCount: 0,
        totalWordCount: 0,
        wordsPerMinute: 0
    )

    /// The model that runs the searches of this book: it waits for typing to
    /// pause (`PhoneBookSearchVocabulary.typingPause`), searches off the main
    /// actor, and says each completed search's status through `announce`.
    @MainActor
    func makeModel(announce: @escaping @MainActor (String) -> Void) -> BookSearchModel {
        BookSearchModel(corpus: corpus, debounceInterval: PhoneBookSearchVocabulary.typingPause, announce: announce)
    }

    /// The row of `result`: the words VoiceOver and the screen give it. On the
    /// main actor, as the Mac's row view that says them is.
    @MainActor
    func row(for result: BookSearchResult) -> PhoneBookSearchRow {
        PhoneBookSearchRow(result: result, source: self)
    }
}

extension PhoneBookSearchSource {
    /// What `reader`'s book offers to search, or an empty source when the
    /// book has no text (`ReaderViewModel.canSearchText`).
    @MainActor
    init(reader: ReaderViewModel) {
        guard let corpus = reader.searchCorpus, let content = reader.content else {
            self = .empty
            return
        }
        self.init(
            corpus: corpus,
            totalCharacterCount: content.totalCharacterCount,
            totalWordCount: content.totalWordCount,
            wordsPerMinute: reader.speechService.wordsPerMinute
        )
    }
}

/// One result's row: what it shows and what VoiceOver and braille read, in
/// the Mac's words and order (`SearchResultRow`).
///
/// A text book's result says where its match is as a percent of the book, as
/// the Mac's sheet does at its default; a transcript's says the exact time it
/// is heard. The phone has no Display picker: the percent is the Mac's
/// default, and a second control for a number most listeners read once is
/// not worth a stop in the order.
struct PhoneBookSearchRow: Identifiable, Equatable, Sendable {
    /// The result's own ID, stable across searches and refreshes, so
    /// VoiceOver's cursor stays on a row while results update.
    let id: String
    /// The match with up to 30 characters around it.
    let context: String
    /// The heading holding the match, if there is one to name.
    let location: String?
    /// Where the match is, as the row shows it: "42.5%", or a transcript's
    /// "1:02:03".
    let position: String
    /// What VoiceOver and braille read: the context and location, then the
    /// position, as "...Alice was beginning, Chapter 1, at 0.3 percent of
    /// book".
    let label: String

    /// The row of `result` in the book `source` describes. On the main actor,
    /// as the Mac's row view that says it is.
    @MainActor
    init(result: BookSearchResult, source: PhoneBookSearchSource) {
        // The Mac's own row says it, at its default display.
        let mac = SearchResultRow(
            result: result,
            displayMode: .percentage,
            totalCharacterCount: source.totalCharacterCount,
            totalWordCount: source.totalWordCount,
            currentWPM: source.wordsPerMinute
        )
        id = result.id
        context = result.contextSnippet
        location = result.locationTitle
        position = mac.positionText
        label = mac.accessibilityDescription
    }
}
