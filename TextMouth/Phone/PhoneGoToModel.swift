import Foundation

// MARK: - The Mac's words

/// The words of the Mac's jump panels that sit inline in their view,
/// `JumpFieldPanel` in `ReaderJumpPanels.swift`, held here for the phone's Go
/// To sheet, which puts the Mac's three panels in one sheet (the iPhone
/// interface spec, "The Go To sheet"). `PhoneGoToVocabularyTests` reads the
/// Mac's source and requires each word to be there as it is.
enum PhoneGoToVocabulary {
    /// Each field's button, as it shows.
    static let jump = "Jump"

    /// What a refusal under a field reads, as in "Error: There is no page
    /// 400 in this book. Its pages run from i to 300."
    static func refusal(_ problem: String) -> String {
        "Error: \(problem)"
    }
}

// MARK: - The fields

/// One of the Go To sheet's fields, in VoiceOver's order.
enum PhoneGoToField: Hashable, CaseIterable, Sendable {
    /// "Page": only in a book of more than one page.
    case page
    /// "Percent through the book".
    case percent
    /// "Time in the recording", or "Time at 500 words a minute".
    case time

    /// The label of the field's Jump button, the spec's new words, so each
    /// of the three is told from the others: "Jump to page", "Jump to
    /// percent", "Jump to time".
    var jumpLabel: String {
        switch self {
        case .page: return "Jump to page"
        case .percent: return "Jump to percent"
        case .time: return "Jump to time"
        }
    }
}

// MARK: - The sheet

/// What the phone's Go To sheet offers and decides for one book, opened at
/// one place (the iPhone interface spec, "The Go To sheet"): which fields it
/// has, their words, what each starts at, where focus lands, and what taking
/// a field does. The jumps themselves are the reader's own, the Mac's
/// `goToPage(typed:)`, `goToPercent(typed:)`, and `goToTime(typed:)`, handed
/// in as `submit`, so the phone's fields refuse and jump as the Mac's do.
///
/// Main-actor isolated because the Mac's rule for taking a field,
/// `JumpFieldOutcome.taking`, is.
@MainActor
struct PhoneGoToModel {
    /// The sheet's title, read as its heading: the spec's "Go To".
    static let title = "Go To"

    /// Whether the book is an audiobook, whose time is its recording's.
    let isAudioBook: Bool
    /// The book's pages, for the page field's hint.
    let pages: BookPages
    /// How the book's times are counted, which names the time field.
    let timeCount: ReaderTimeWording.Count
    /// What each field holds as the sheet opens: the place being read, as
    /// the Mac's panels start.
    let startingTexts: [PhoneGoToField: String]
    /// The refusal shown under each field that has one, as the Mac's
    /// sentence; a field edited since loses its refusal, as on the Mac.
    private(set) var refusals: [PhoneGoToField: String] = [:]

    /// A model for a book with `pages`, whose times count by `timeCount`,
    /// its fields starting at `startingTexts`.
    init(
        isAudioBook: Bool,
        pages: BookPages,
        timeCount: ReaderTimeWording.Count,
        startingTexts: [PhoneGoToField: String]
    ) {
        self.isAudioBook = isAudioBook
        self.pages = pages
        self.timeCount = timeCount
        self.startingTexts = startingTexts
    }

    /// The fields the sheet shows, in VoiceOver's order: Page only in a book
    /// of more than one page, as the Mac offers it, then Percent and Time.
    var fields: [PhoneGoToField] {
        pages.count > 1 ? [.page, .percent, .time] : [.percent, .time]
    }

    /// The field VoiceOver's focus lands in as the sheet opens, its text
    /// selected: the time field in an audiobook, else Page where the book
    /// has pages, else Percent, the first field shown.
    var initialFocus: PhoneGoToField {
        if isAudioBook { return .time }
        return fields.first ?? .percent
    }

    /// The field's label, the Mac's: "Page", "Percent through the book",
    /// "Time in the recording", or "Time at 500 words a minute".
    func label(of field: PhoneGoToField) -> String {
        switch field {
        case .page: return ReaderPageWording.fieldLabel
        case .percent: return ReaderTimeWording.percentFieldLabel
        case .time: return ReaderTimeWording.timeFieldLabel(timeCount)
        }
    }

    /// The field's hint, the Mac's, as in "This book has 300 pages, from i
    /// to 300. Type a page as the book numbers it, such as 12 or xii."
    func hint(of field: PhoneGoToField) -> String {
        switch field {
        case .page: return ReaderPageWording.fieldHint(for: pages)
        case .percent: return ReaderTimeWording.percentFieldHint
        case .time: return ReaderTimeWording.timeFieldHint
        }
    }

    /// What the field holds as the sheet opens.
    func startingText(of field: PhoneGoToField) -> String {
        startingTexts[field] ?? ""
    }

    /// What the refusal under the field reads, "Error: " and the Mac's
    /// sentence; nil while the field has none.
    func refusalText(of field: PhoneGoToField) -> String? {
        refusals[field].map(PhoneGoToVocabulary.refusal)
    }

    /// Forgets the field's refusal once its text is edited, since it was
    /// about what was typed before, as the Mac's panel does.
    mutating func noteEdited(_ field: PhoneGoToField) {
        refusals[field] = nil
    }

    /// Takes `text` from `field`, by the Mac's rule (`JumpFieldOutcome`):
    /// the text the field started at closes the sheet without moving,
    /// unless `submitsUnchanged` says it's an answer, as a page label the
    /// book uses twice is; anything else goes to `submit`, the reader's
    /// jump, which returns nil once it has jumped or the refusal. A refusal
    /// is kept for its field, and any other field's is forgotten, so one
    /// sentence shows at a time.
    mutating func take(
        _ text: String,
        from field: PhoneGoToField,
        submitsUnchanged: Bool = false,
        submit: @MainActor (String) -> String?
    ) -> JumpFieldOutcome {
        let outcome = JumpFieldOutcome.taking(
            text,
            startedAt: startingText(of: field),
            submitsUnchanged: submitsUnchanged,
            submit: submit
        )
        refusals = [:]
        if case .refused(let problem) = outcome {
            refusals[field] = problem
        }
        return outcome
    }
}

// MARK: - From a reader

extension PhoneGoToModel {
    /// The model for `reader`'s book, its fields starting at the place being
    /// read, as the Mac's panels start.
    init(reader: ReaderViewModel) {
        self.init(
            isAudioBook: reader.isAudioBook,
            pages: reader.bookPages,
            timeCount: reader.timeCount,
            startingTexts: [
                .page: reader.goToPageStartingText,
                .percent: reader.goToPercentStartingText,
                .time: reader.goToTimeStartingText,
            ]
        )
    }

    /// Takes `text` from `field` for `reader`, through the reader's own jump
    /// for that field, the Mac's.
    mutating func take(_ text: String, from field: PhoneGoToField, in reader: ReaderViewModel) -> JumpFieldOutcome {
        switch field {
        case .page:
            return take(
                text,
                from: field,
                submitsUnchanged: reader.goToPageLabelIsRepeated(text),
                submit: reader.goToPage(typed:)
            )
        case .percent:
            return take(text, from: field, submit: reader.goToPercent(typed:))
        case .time:
            return take(text, from: field, submit: reader.goToTime(typed:))
        }
    }
}
