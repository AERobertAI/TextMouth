import Foundation

/// What the reader says about a book's pages (PG02, PG03, PG04): what Next
/// Page and Previous Page announce, Go to Page's field and what it refuses,
/// and the settings that show or say the page. Every sentence is shown and
/// spoken alike, and pinned by tests. The position's own words, "Page 12 of
/// 300" and "Before page 1", are `PagePosition.label`; callers use them and
/// never rebuild them.
enum ReaderPageWording {
    // MARK: - Next Page and Previous Page

    /// What Next Page and Previous Page say on reaching a page: "Page 13".
    /// `label` is the page's label as the book names it ("13", "xii").
    static func arrived(at label: String) -> String {
        "Page \(label)"
    }

    /// What a page command says in a book that has no pages, and moves
    /// nothing.
    static let noPages = "This book has no pages."

    // MARK: - Go to Page

    /// Go to Page's field name, shown before it and spoken as its label.
    static let fieldLabel = "Page"

    /// What Go to Page's field takes, spoken as its hint.
    static let fieldHint = "Type a page as the book numbers it, such as 12 or xii."

    /// What Go to Page says to an empty field.
    static let emptyField = "Type a page number."

    /// What Go to Page says to a page the book does not have: "There is no
    /// page 400 in this book. Its pages run from i to 300." For a book of one
    /// page: "There is no page 400 in this book. Its only page is 1."
    /// `typed` is what was typed, trimmed; `first` and `last` are the first
    /// and last pages' labels; `count` is the number of pages.
    static func noSuchPage(_ typed: String, first: String, last: String, count: Int) -> String {
        let prefix = "There is no page \(typed) in this book."
        return count == 1
            ? "\(prefix) Its only page is \(first)."
            : "\(prefix) Its pages run from \(first) to \(last)."
    }

    /// What Go to Page says after a jump: "Jumped to page 12." `label` is
    /// the label of the page the place reached is on.
    ///
    /// A label that more than one page carries ("2" on the plates and again
    /// in the text) would be said alike for each of them, and a listener
    /// pressing Return to go from one to the next could not tell which they
    /// were on, or that the last had wrapped round to the first. `occurrence`
    /// is which of them the page is, counting from 1 in book order, and the
    /// sentence says so: "Jumped to page 2, the second page labelled 2."
    /// Nil, for a label of one page, leaves the sentence as it was.
    static func jumped(to label: String, occurrence: Int? = nil) -> String {
        "Jumped to \(page(label, occurrence: occurrence))."
    }

    /// What Go to Page says when the page typed has no words of its own, so
    /// the cursor cannot be on it: a blank page shares its place with the
    /// page after it, and a last page that begins after the book's last word
    /// is reached at that word, on the page before it. "Page 7 has no words,
    /// so the cursor is on page 8." Without the reason the listener hears
    /// "Jumped to page 8." for the page they asked for 7. `label` is the page
    /// asked for as the book spells it, `reached` the page the cursor is on
    /// (the one the status row names), and `occurrence` which of the pages
    /// with that label it is, as `jumped(to:occurrence:)` says it.
    static func hasNoWords(_ label: String, cursorOn reached: String, occurrence: Int? = nil) -> String {
        "Page \(label) has no words, so the cursor is on \(page(reached, occurrence: occurrence))."
    }

    /// A page as a sentence names it: "page 12", or, for one of several
    /// pages that carry its label, "page 2, the second page labelled 2".
    private static func page(_ label: String, occurrence: Int?) -> String {
        guard let occurrence else { return "page \(label)" }
        return "page \(label), the \(ordinal(occurrence)) page labelled \(label)"
    }

    /// The first ten ordinals, as they are said.
    private static let ordinalWords = [
        "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth",
    ]

    /// `number` as an ordinal, in words up to the tenth, and after that in
    /// figures with their ending ("11th", "21st", "112th"), which is how
    /// VoiceOver says them too.
    private static func ordinal(_ number: Int) -> String {
        if ordinalWords.indices.contains(number - 1) { return ordinalWords[number - 1] }
        // 11, 12, and 13 end in "th" (not "st", "nd", "rd") like every
        // number of a hundred's teens.
        let ending: String
        switch (number % 100, number % 10) {
        case (11...13, _): ending = "th"
        case (_, 1): ending = "st"
        case (_, 2): ending = "nd"
        case (_, 3): ending = "rd"
        default: ending = "th"
        }
        return "\(number)\(ending)"
    }

    // MARK: - The Status Row's Page Button

    /// The page button's hint while no panel is open.
    static let openHint = "Opens jump to page controls"

    /// The page button's hint while the page panel is open.
    static let hideHint = "Hides jump to page controls"

    /// The page button's hint while the percent or time panel is open.
    static let switchHint = "Switches to jump to page controls"

    // MARK: - Settings

    /// The setting group in Playback settings.
    static let settingSection = "Pages"

    /// The setting that shows the page on the reader screen.
    static let showInReaderTitle = "Show the page on the reader screen"

    /// What showing the page does, as its checkbox's hint says and its
    /// caption shows.
    static let showInReaderHint = "Shows the page being read, such as Page 12 of 300, beside the percent, for books with pages."

    /// The setting that adds the page to Where Am I?.
    static let sayInWhereAmITitle = "Say the page in Where Am I?"

    /// What saying the page does, as its checkbox's hint says and its
    /// caption shows.
    static let sayInWhereAmIHint = "Adds the page, such as Page 12 of 300, to Where Am I?'s summaries, for books with pages."
}
