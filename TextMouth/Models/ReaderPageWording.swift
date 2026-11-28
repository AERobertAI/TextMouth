import Foundation

/// What the reader says about a book's pages (PG02, PG03, PG04): what a move
/// by page announces, Go to Page's field and what it refuses, and the
/// settings that show or say the page. Every sentence is shown and
/// spoken alike, and pinned by tests. The position's own words, "Page 12 of
/// 300" and "Before page 1", are `PagePosition.label`; callers use them and
/// never rebuild them.
enum ReaderPageWording {
    // MARK: - Moving by page

    /// What a move by page says on reaching a page: "Page 13".
    /// `label` is the page's label as the book names it ("13", "xii").
    static func arrived(at label: String) -> String {
        // Translators: Announcement on reaching a page of a book that has pages, and the start of a sentence naming a page. %@ is the page's label as the book names it, such as 13 or xii, an identifier written without digit grouping.
        InterfaceText.line("common.pageValue", "Page \(label)")
    }

    /// What a page command says in a book that has no pages, and moves
    /// nothing.
    static var noPages: String {
        // Translators: Announcement when a page command is used in a book that has no pages.
        InterfaceText.line("readerPage.noPages", "This book has no pages.")
    }

    /// What a page command says in a book of one page, which has no other
    /// page to go to, and moves nothing (the user's request, November 4,
    /// 2026: such a command "should just warn the user and not do
    /// anything").
    static var onlyOnePage: String {
        // Translators: Announcement when a page command is used in a book that has one page, so there is no other page to go to.
        InterfaceText.line("readerPage.onlyOnePage", "This book has only one page.")
    }

    // MARK: - Go to Page

    /// Go to Page's field name, shown before it and spoken as its label.
    static var fieldLabel: String {
        // Translators: Label of the Go to Page field, where the user types a page of the book.
        InterfaceText.line("common.page", "Page")
    }

    /// How Go to Page's field is filled in, the last sentence of its hint.
    static var typingHint: String {
        // Translators: Last sentence of the Go to Page field's hint: what the user may type. 12 and xii are examples of page labels, a number and a roman numeral.
        InterfaceText.line("readerPage.typingHint", "Type a page as the book numbers it, such as 12 or xii.")
    }

    /// What Go to Page's field takes, spoken as its hint: how many pages the
    /// book has, the N of "Page 12 of N" (`BookPages.total`), from its first
    /// page's label to its last's, then `typingHint`. "This book has 300
    /// pages, from i to 300. Type a page as the book numbers it, such as 12
    /// or xii." A book of one page names it ("This book's only page is 1."),
    /// and a book without pages says so, as a page command does there.
    static func fieldHint(for pages: BookPages) -> String {
        guard let first = pages.breaks.first?.label, let last = pages.breaks.last?.label else {
            return noPages
        }
        let size = pages.count == 1
            // Translators: First sentence of the Go to Page field's hint for a book of one page. %@ is that page's label, an identifier written without digit grouping.
            ? InterfaceText.line("readerPage.fieldHint.only", "This book's only page is \(first).")
            // Translators: First sentence of the Go to Page field's hint. %1$lld is the number of pages in the book; %2$@ is the first page's label and %3$@ the last page's label, identifiers such as i or 300 written without digit grouping.
            : InterfaceText.line("readerPage.fieldHint.pages", "This book has \(number: pages.total) pages, from \(first) to \(last).")
        return SentenceWording.joined([size, typingHint])
    }

    /// What Go to Page says to an empty field.
    static var emptyField: String {
        // Translators: Message when Go to Page is chosen with nothing typed in its field.
        InterfaceText.line("readerPage.emptyField", "Type a page number.")
    }

    /// What Go to Page says to a page the book does not have: "There is no
    /// page 400 in this book. Its pages run from i to 300." For a book of one
    /// page: "There is no page 400 in this book. Its only page is 1."
    /// `typed` is what was typed, trimmed; `first` and `last` are the first
    /// and last pages' labels; `count` is the number of pages.
    static func noSuchPage(_ typed: String, first: String, last: String, count: Int) -> String {
        // Translators: First sentence of the message when Go to Page is given a page the book does not have. %@ is what the user typed.
        let prefix = InterfaceText.line("readerPage.noSuchPage.there", "There is no page \(typed) in this book.")
        let range = count == 1
            // Translators: Second sentence of that message for a book of one page. %@ is that page's label, an identifier written without digit grouping.
            ? InterfaceText.line("readerPage.noSuchPage.only", "Its only page is \(first).")
            // Translators: Second sentence of that message. %1$@ is the first page's label and %2$@ the last page's label, identifiers such as i or 300 written without digit grouping.
            : InterfaceText.line("readerPage.noSuchPage.pages", "Its pages run from \(first) to \(last).")
        return SentenceWording.joined([prefix, range])
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
        guard let occurrence else {
            // Translators: Announcement after Go to Page jumped. %@ is the page's label, an identifier written without digit grouping.
            return InterfaceText.line("readerPage.jumped.numbered", "Jumped to page \(label).")
        }
        // Translators: Announcement after Go to Page jumped to one of several pages that carry the same label. %1$@ is the page's label, an identifier; %2$@ is which of them it is, as an ordinal word such as "second" or "11th".
        return InterfaceText.line("readerPage.jumped.labelled", "Jumped to page \(label), the \(ordinal(occurrence)) page labelled \(label).")
    }

    // MARK: - When Go to Page Leaves the Cursor Elsewhere

    /// What Go to Page says when the page typed has no words of its own, so
    /// the cursor cannot be on it: a blank page shares its place with the
    /// page after it, and a last page that begins after the book's last word
    /// is reached at that word, on the page before it. "Page 7 has no words,
    /// so the cursor is on page 8." Without the reason the listener hears
    /// "Jumped to page 8." for the page they asked for 7. `label` is the page
    /// asked for as the book spells it, and `cursor` where the cursor is
    /// (`cursorPlace(_:occurrence:)`). The reader reads it from the pages
    /// themselves (`DocumentContent.pageHoldsWord(at:outside:)`), never from
    /// the cursor's being elsewhere, which after a jump while the book plays
    /// can have another reason.
    ///
    /// A page asked for whose label other pages carry too is named as which
    /// of them it is, `occurrence` counting from 1 in book order: "The first
    /// page labelled 3 has no words, so the cursor is on the second page
    /// labelled 3." Named "Page 3", the blank one denied the words of the
    /// page 3 the cursor was on.
    static func hasNoWords(_ label: String, occurrence: Int? = nil, cursor: String) -> String {
        let subject = namedAtStart(label, occurrence: occurrence)
        // Translators: Announcement after Go to Page when the page typed has no words of its own. %1$@ names the page, such as "Page 7" or "The first page labelled 3"; %2$@ says where the cursor is, such as "on page 8" or "before page 1".
        return InterfaceText.line("readerPage.hasNoWords", "\(subject) has no words, so the cursor is \(cursor).")
    }

    /// What Go to Page says when every word of the page typed is in a
    /// skipped section, which speech passes over: a jump there while the
    /// book plays goes on with the next words speech reads, on a later page.
    /// "Page 40 is in a skipped section, so the cursor is on page 52." While
    /// the book is stopped, the cursor stays on such a page, as on any other.
    /// `occurrence` names one of several pages of a label, as for
    /// `hasNoWords(_:occurrence:cursor:)`.
    static func isInSkippedSection(_ label: String, occurrence: Int? = nil, cursor: String) -> String {
        let subject = namedAtStart(label, occurrence: occurrence)
        // Translators: Announcement after Go to Page when every word of the page typed is in a skipped section. %1$@ names the page, such as "Page 40" or "The first page labelled 3"; %2$@ says where the cursor is, such as "on page 52" or "before page 1".
        return InterfaceText.line("readerPage.isInSkippedSection", "\(subject) is in a skipped section, so the cursor is \(cursor).")
    }

    /// What Go to Page says when the cursor is not on the page typed and the
    /// book's pages give no reason, as when a text substitution deletes every
    /// word of the page: only where the cursor is, the page the status row
    /// names. "The cursor is on page 52."
    static func cursorIs(_ cursor: String) -> String {
        // Translators: Announcement after Go to Page when the cursor is not on the page typed and there is no known reason. %@ says where the cursor is, such as "on page 52" or "before page 1".
        InterfaceText.line("readerPage.cursorIs", "The cursor is \(cursor).")
    }

    /// Where the cursor is, as Go to Page's sentences say it after "the
    /// cursor is": on the page `position` names, "on page 8", or, for one of
    /// several pages that carry its label (`occurrence`, counting from 1 in
    /// book order), "on the second page labelled 2"; before the book's first
    /// page, "before page 1".
    static func cursorPlace(_ position: PagePosition, occurrence: Int? = nil) -> String {
        guard let reached = position.page else {
            // Before the first page; a book without pages has nothing to say.
            guard let firstLabel = position.firstLabel else { return "" }
            // Translators: Where the cursor is, said after "the cursor is": before the book's first page. %@ is the first page's label, an identifier written without digit grouping.
            return InterfaceText.line("readerPage.cursorPlace.before", "before page \(firstLabel)")
        }
        guard let occurrence else {
            // Translators: Where the cursor is, said after "the cursor is": on a page. %@ is the page's label, an identifier written without digit grouping.
            return InterfaceText.line("readerPage.cursorPlace.numbered", "on page \(reached.label)")
        }
        // Translators: Where the cursor is, said after "the cursor is": on one of several pages that carry the same label. %1$@ is which of them it is, as an ordinal word such as "second" or "11th"; %2$@ is the label, an identifier written without digit grouping.
        return InterfaceText.line("readerPage.cursorPlace.labelled", "on the \(ordinal(occurrence)) page labelled \(reached.label)")
    }

    // MARK: - Naming a Page

    /// A page as a sentence's subject names it: "Page 7", or, for one of
    /// several pages that carry its label, which of them it is, which says
    /// the label too: "The first page labelled 3". A sentence with a reason
    /// names two pages, which "Page 3, the first page labelled 3" would make
    /// long.
    private static func namedAtStart(_ label: String, occurrence: Int?) -> String {
        guard let occurrence else { return arrived(at: label) }
        // Translators: The start of a sentence naming one of several pages that carry the same label. %1$@ is which of them it is, as an ordinal word such as "first" or "11th"; %2$@ is the label, an identifier written without digit grouping.
        return InterfaceText.line("readerPage.namedAtStart", "The \(ordinal(occurrence)) page labelled \(label)")
    }

    /// `number` as an ordinal: in words up to the tenth, and after that in
    /// figures with their ending ("11th", "21st", "112th"), which is how
    /// VoiceOver says them too.
    private static func ordinal(_ number: Int) -> String {
        switch number {
        // Translators: Ordinal word 1st, naming which of several pages that carry the same label a page is. Lower case, as it follows "the".
        case 1: return InterfaceText.line("readerPage.ordinal.first", "first")
        // Translators: Ordinal word 2nd, naming which of several pages that carry the same label a page is. Lower case, as it follows "the".
        case 2: return InterfaceText.line("readerPage.ordinal.second", "second")
        // Translators: Ordinal word 3rd, naming which of several pages that carry the same label a page is. Lower case, as it follows "the".
        case 3: return InterfaceText.line("readerPage.ordinal.third", "third")
        // Translators: Ordinal word 4th, naming which of several pages that carry the same label a page is. Lower case, as it follows "the".
        case 4: return InterfaceText.line("readerPage.ordinal.fourth", "fourth")
        // Translators: Ordinal word 5th, naming which of several pages that carry the same label a page is. Lower case, as it follows "the".
        case 5: return InterfaceText.line("readerPage.ordinal.fifth", "fifth")
        // Translators: Ordinal word 6th, naming which of several pages that carry the same label a page is. Lower case, as it follows "the".
        case 6: return InterfaceText.line("readerPage.ordinal.sixth", "sixth")
        // Translators: Ordinal word 7th, naming which of several pages that carry the same label a page is. Lower case, as it follows "the".
        case 7: return InterfaceText.line("readerPage.ordinal.seventh", "seventh")
        // Translators: Ordinal word 8th, naming which of several pages that carry the same label a page is. Lower case, as it follows "the".
        case 8: return InterfaceText.line("readerPage.ordinal.eighth", "eighth")
        // Translators: Ordinal word 9th, naming which of several pages that carry the same label a page is. Lower case, as it follows "the".
        case 9: return InterfaceText.line("readerPage.ordinal.ninth", "ninth")
        // Translators: Ordinal word 10th, naming which of several pages that carry the same label a page is. Lower case, as it follows "the".
        case 10: return InterfaceText.line("readerPage.ordinal.tenth", "tenth")
        default:
            // Past the tenth, the region's own ordinal figures ("11th",
            // "21st", "112th" in English), as the number formatter writes them.
            let formatter = NumberFormatter()
            formatter.locale = InterfaceLanguage.current.locale
            formatter.numberStyle = .ordinal
            return formatter.string(from: NSNumber(value: number)) ?? String(number)
        }
    }

    // MARK: - The Status Row's Page Button

    /// The page button's hint while no panel is open.
    static var openHint: String {
        // Translators: Hint of the status row's page button while no jump panel is open.
        InterfaceText.line("readerPage.openHint", "Opens jump to page controls")
    }

    /// The page button's hint while the page panel is open.
    static var hideHint: String {
        // Translators: Hint of the status row's page button while the jump to page panel is open.
        InterfaceText.line("readerPage.hideHint", "Hides jump to page controls")
    }

    /// The page button's hint while the percent or time panel is open.
    static var switchHint: String {
        // Translators: Hint of the status row's page button while the jump to percent or time panel is open.
        InterfaceText.line("readerPage.switchHint", "Switches to jump to page controls")
    }

    // MARK: - Settings

    /// The setting group in Playback settings.
    static var settingSection: String {
        // Translators: Heading of the group in Playback settings that holds the settings about pages.
        InterfaceText.line("common.pages", "Pages")
    }

    /// The setting that shows the page on the reader screen.
    static var showInReaderTitle: String {
        // Translators: Label of the Playback setting's checkbox that shows the page being read on the reader screen.
        InterfaceText.line("readerPage.showInReaderTitle", "Show the page on the reader screen")
    }

    /// What showing the page does, as its checkbox's hint says and its
    /// caption shows.
    static var showInReaderHint: String {
        // Translators: Hint and caption of the Playback setting that shows the page on the reader screen. "Page 12 of 300" is an example of how the page is shown.
        InterfaceText.line("readerPage.showInReaderHint", "Shows the page being read, such as Page 12 of 300, beside the percent, for books of more than one page.")
    }

    /// The setting that adds the page to Where Am I?.
    static var sayInWhereAmITitle: String {
        // Translators: Label of the Playback setting's checkbox that adds the page to Where Am I?, a command that says where the reader is.
        InterfaceText.line("readerPage.sayInWhereAmITitle", "Say the page in Where Am I?")
    }

    /// What saying the page does, as its checkbox's hint says and its
    /// caption shows.
    static var sayInWhereAmIHint: String {
        // Translators: Hint and caption of the Playback setting that adds the page to Where Am I?, a command that says where the reader is. "Page 12 of 300" is an example of how the page is said.
        InterfaceText.line("readerPage.sayInWhereAmIHint", "Adds the page, such as Page 12 of 300, to Where Am I?'s summaries, for books of more than one page.")
    }
}
