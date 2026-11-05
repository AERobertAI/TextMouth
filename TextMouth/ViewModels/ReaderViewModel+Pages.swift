import Foundation

/// Pages as a navigation unit (PG02): Next Page and Previous Page move the
/// reader by the book's pages as it numbers them, as Next Heading and
/// Previous Heading move it by headings. A page is a place in the reading
/// text and adds no text, so moving by page changes no saved position
/// beyond the move itself.
extension ReaderViewModel {
    // MARK: - The book's pages

    /// The book's pages in book order; none for a book without pages or one
    /// that is not loaded.
    var bookPages: BookPages {
        content?.pages ?? .none
    }

    /// Whether the book has any page to move by.
    var hasPages: Bool {
        !bookPages.isEmpty
    }

    /// Whether the book has more than one page, and so pages to move by.
    /// A book of one page would say "Page 1 of 1" wherever it is read,
    /// and has no other page to go to, so its page shows nowhere (the
    /// user's requests, November 4, 2026): the status row's page button,
    /// the Navigate menu's page commands (dimmed), the pickers' Page unit,
    /// and Where Am I?'s page are left out, and the page commands' keys say
    /// so and move nothing (`pageCommandHasPages()`).
    var hasSeveralPages: Bool {
        bookPages.count > 1
    }

    /// The index in `bookPages.breaks` of the page holding the reading
    /// cursor: the last page that begins at or before it, nil before the
    /// first page and in a book without pages.
    var currentPageIndex: Int? {
        bookPages.index(ofPageAtChapter: currentChapterIndex, offset: currentCharacterOffset)
    }

    /// The page holding the reading cursor, as "Page 12 of 300".
    var currentPagePosition: PagePosition {
        PagePosition(pages: bookPages, index: currentPageIndex)
    }

    /// The page holding the place the reader screen shows (the throttled
    /// display mirrors of the cursor), for the status row.
    var displayPagePosition: PagePosition {
        bookPages.position(atChapter: displayChapterIndex, offset: displayCharacterOffset)
    }

    // MARK: - Choosing the page

    /// The first page that starts after a place and is not passed over; nil
    /// at and after the last such page. Pages at one place are one stop: the
    /// scan starts just after the page that holds the place, which is the
    /// last of any that share it.
    nonisolated static func nextPage(
        in pages: BookPages,
        chapterIndex: Int,
        characterOffset: Int,
        isPassedOver: (PageBreak) -> Bool
    ) -> PageBreak? {
        let start = (pages.index(ofPageAtChapter: chapterIndex, offset: characterOffset) ?? -1) + 1
        guard start < pages.breaks.count else { return nil }
        return pages.breaks[start...].first { !isPassedOver($0) }
    }

    /// The last page in an earlier chapter, or in this chapter more than
    /// `graceZone` units before the place, that is not passed over; nil when
    /// there is none. The grace zone is `previousHeading`'s: Previous Page
    /// from inside a page, or just after its start, goes to that page's
    /// start, and repeated Previous commands keep moving.
    nonisolated static func previousPage(
        in pages: BookPages,
        chapterIndex: Int,
        characterOffset: Int,
        graceZone: Int = 10,
        isPassedOver: (PageBreak) -> Bool
    ) -> PageBreak? {
        // The last page at or before the place's grace-zone edge; every page
        // from there back starts before the zone.
        guard var index = pages.index(ofPageAtChapter: chapterIndex, offset: characterOffset - graceZone - 1)
        else { return nil }
        while index >= 0 {
            let page = pages.breaks[index]
            if !isPassedOver(page) { return page }
            index -= 1
        }
        return nil
    }

    /// The navigation unit after `unit` in the cycle, passing over `.page`
    /// when the book has no pages: a book without pages has none to move by.
    nonisolated static func unit(after unit: SkipUnit, bookHasPages: Bool) -> SkipUnit {
        let next = unit.nextNavigationUnit
        return next == .page && !bookHasPages ? next.nextNavigationUnit : next
    }

    /// The units a picker for one book offers, in the order every picker
    /// shows them: every unit, except Page when the book has no pages to
    /// move by (an audiobook, a text book whose format or file gives none,
    /// or a book of only one page). A unit already in force stays in the
    /// list even then, so the picker always holds the value it shows: a
    /// global default of Page reaches a book without pages (its skip says
    /// "This book has no pages."), and a picker whose selection is not among
    /// its choices shows no value. Settings' own pickers choose the units of
    /// every book at once and offer them all.
    nonisolated static func navigationUnitChoices(bookHasPages: Bool, keeping selected: SkipUnit) -> [SkipUnit] {
        SkipUnit.allCases.filter { $0 != .page || bookHasPages || $0 == selected }
    }

    /// The units the playback bar's pickers offer for this book, one of
    /// whose pickers is showing `selected` (`navigationUnitChoices(bookHasPages:keeping:)`).
    func navigationUnitChoices(keeping selected: SkipUnit) -> [SkipUnit] {
        Self.navigationUnitChoices(bookHasPages: hasSeveralPages, keeping: selected)
    }

    // MARK: - Skipped sections

    /// The ranges of chapter `chapterIndex`'s text, in UTF-16 offsets, that
    /// the sections headed by `skippedIDs` take out, as speech passes over
    /// them (`SkippedSectionFilter.excludedRanges`): none for a chapter the
    /// book does not have, and none when it skips nothing.
    private func skippedRanges(inChapter chapterIndex: Int, skipping skippedIDs: Set<String>) -> [Range<Int>] {
        guard !skippedIDs.isEmpty, let content, content.chapters.indices.contains(chapterIndex) else { return [] }
        return SkippedSectionFilter.excludedRanges(
            textLength: content.chapters[chapterIndex].text.utf16Length,
            headings: headings.filter { $0.chapterIndex == chapterIndex },
            skippedIDs: skippedIDs
        )
    }

    /// Hands `body` a check that says whether a page is passed over: it
    /// starts inside a skipped section, as speech passes over the section, or
    /// after the book's last word, where it has no words and the reader
    /// cannot rest (`DocumentContent` moves a page after any other chapter's
    /// last word to the next chapter's first). Landing there, Next Page would
    /// stop on the page before and find the same page at every press. Each
    /// chapter's skipped ranges are worked out at most once per move, and
    /// not at all when the book skips nothing.
    private func withPassedOverCheck<Result>(
        _ body: (_ isPassedOver: (PageBreak) -> Bool) -> Result
    ) -> Result {
        guard let content else { return body { _ in false } }
        let skippedIDs = skippedHeadingIDs
        var rangesByChapter: [Int: [Range<Int>]] = [:]
        return body { page in
            guard content.chapters.indices.contains(page.chapterIndex) else { return false }
            if page.characterOffset >= content.chapters[page.chapterIndex].text.utf16Length { return true }
            guard !skippedIDs.isEmpty else { return false }
            if rangesByChapter[page.chapterIndex] == nil {
                rangesByChapter[page.chapterIndex] = skippedRanges(inChapter: page.chapterIndex, skipping: skippedIDs)
            }
            return rangesByChapter[page.chapterIndex]?.contains { $0.contains(page.characterOffset) } ?? false
        }
    }

    // MARK: - The commands

    /// Whether a page command has pages to work on. A reader that has not
    /// loaded its book yet has nothing to ask, so the command does nothing,
    /// as Next Heading does: the book may well have pages, and saying that it
    /// had none, for the moments it takes to load, would tell the listener
    /// otherwise. A loaded book without pages says so and moves nothing
    /// (`ReaderPageWording.noPages`), and so does a book of one page, which
    /// has no other page to go to (`ReaderPageWording.onlyOnePage`).
    private func pageCommandHasPages() -> Bool {
        guard content != nil else { return false }
        guard hasPages else {
            announceToVoiceOver(ReaderPageWording.noPages)
            return false
        }
        guard hasSeveralPages else {
            announceToVoiceOver(ReaderPageWording.onlyOnePage)
            return false
        }
        return true
    }

    /// Move to the start of the next page and say its label ("Page 13").
    /// Without pages it says so and moves nothing (while the book loads, it
    /// does nothing); after the last page it does nothing, as Next Heading
    /// does after the last heading. A page after the book's last word has no
    /// words to move to, and is passed over (`withPassedOverCheck(_:)`).
    func nextPage() {
        guard pageCommandHasPages() else { return }
        let pages = bookPages
        let page = withPassedOverCheck { isPassedOver in
            Self.nextPage(
                in: pages,
                chapterIndex: currentChapterIndex,
                characterOffset: currentCharacterOffset,
                isPassedOver: isPassedOver
            )
        }
        if let page { go(to: page) }
    }

    /// Move to the start of the page being read, or of the one before when
    /// the place is already at a page's start, and say its label. Without
    /// pages it says so and moves nothing (while the book loads, it does
    /// nothing); before the first page it does nothing.
    func previousPage() {
        guard pageCommandHasPages() else { return }
        let pages = bookPages
        let page = withPassedOverCheck { isPassedOver in
            Self.previousPage(
                in: pages,
                chapterIndex: currentChapterIndex,
                characterOffset: currentCharacterOffset,
                isPassedOver: isPassedOver
            )
        }
        if let page { go(to: page) }
    }

    // MARK: - Go to Page (PG03)

    /// Go to Page's starting value: the label of the page holding the
    /// reading position, or nothing before the first page, so typing the
    /// first page's label still jumps there. The panel does not take the
    /// value it started at as an answer (`JumpFieldOutcome.unchanged`),
    /// except a label that more than one page carries
    /// (`goToPageLabelIsRepeated(_:)`).
    var goToPageStartingText: String {
        currentPagePosition.page?.label ?? ""
    }

    /// Whether the label `text` names more than one page of this book (a "2"
    /// on the plates and another in the text). Return in the page panel on
    /// its starting label is no change for a label of one page, which the
    /// reader is on already, but for a repeated label it asks for that
    /// label's next page: `goToPage(typed:)` takes the first page with the
    /// label after the page being read, else wraps to the book's first, so
    /// each press reaches the next of them and the last goes round to the
    /// first. A book without pages repeats nothing.
    func goToPageLabelIsRepeated(_ text: String) -> Bool {
        JumpInputValidator.pageIndices(named: text, in: bookPages).count > 1
    }

    /// Go to Page's answer: jumps to the start of the page `text` names,
    /// keeping a Return position, says "Jumped to page 12." and returns nil;
    /// or returns why it will not do (`JumpInputValidator.page`), as a
    /// sentence the panel shows and announces, and moves nothing.
    ///
    /// The page it says is the one the status row names where the reader
    /// stands after the jump (`jumpAnnouncement(toPage:at:)`), which is not
    /// always the page typed: a blank page shares its place with the page
    /// after it, and the row names the later one; and a jump while the book
    /// plays restarts speech, which passes over a page whose words are all
    /// in skipped sections to the next words it reads. Saying the typed
    /// label then told the listener one page while the row, Where Am I?, and
    /// Next Page all named another; now it names the row's page, and says
    /// why the cursor is not on the page asked for when the pages say.
    func goToPage(typed text: String) -> String? {
        let pages = bookPages
        switch JumpInputValidator.page(text, in: pages, currentIndex: currentPageIndex) {
        case .page(let index):
            // The index comes from the pages themselves; check it anyway.
            guard pages.breaks.indices.contains(index) else { return ReaderPageWording.noPages }
            let page = pages.breaks[index]
            navigatePreservingReturnPosition(chapterIndex: page.chapterIndex, characterOffset: page.characterOffset)
            announceToVoiceOver(jumpAnnouncement(toPage: page, at: index))
            return nil
        case .error(let message):
            return message
        }
    }

    /// What Go to Page says once it has moved to the start of `page`, the
    /// page at `index` of the book's pages.
    ///
    /// With the cursor on that page, the page the status row names, it says
    /// the page, and, when more than one page carries its label, which of
    /// them it is (`occurrence(ofPageAt:)`): "Jumped to page 2, the second
    /// page labelled 2."
    ///
    /// With the cursor elsewhere, it says where, as the row names it (a page,
    /// or before the first page: `ReaderPageWording.cursorPlace(_:occurrence:)`),
    /// and why, when the book's pages say: the page has no words of its own
    /// (a blank page shares its place with the page after it, and a last
    /// page that begins after the book's last word is reached at that word),
    /// or every word of it is in a skipped section, which a jump while the
    /// book plays passes over to the next words speech reads. The reason is
    /// read from the pages and the skipped sections themselves, never from
    /// the cursor's being elsewhere: that alone once made a page full of
    /// words, skipped while the book played, "a page with no words". When
    /// they give no reason, as when a text substitution deletes the page's
    /// words, the sentence says only where the cursor is. A page of a label
    /// that other pages carry too is named as which of them it is, the page
    /// asked for as much as the cursor's: "The first page labelled 3 has no
    /// words, so the cursor is on the second page labelled 3."
    private func jumpAnnouncement(toPage page: PageBreak, at index: Int) -> String {
        let reached = currentPageIndex
        guard reached != index else {
            return ReaderPageWording.jumped(to: page.label, occurrence: occurrence(ofPageAt: index))
        }
        let cursor = ReaderPageWording.cursorPlace(
            currentPagePosition,
            occurrence: reached.flatMap(occurrence(ofPageAt:))
        )
        // Which of the pages with its label the page asked for is, if
        // several carry it, so the reason never denies another's words.
        let asked = occurrence(ofPageAt: index)
        guard let content else { return ReaderPageWording.cursorIs(cursor) }
        if !content.pageHoldsWord(at: index) {
            return ReaderPageWording.hasNoWords(page.label, occurrence: asked, cursor: cursor)
        }
        let skippedIDs = skippedHeadingIDs
        if !content.pageHoldsWord(at: index, outside: { skippedRanges(inChapter: $0, skipping: skippedIDs) }) {
            return ReaderPageWording.isInSkippedSection(page.label, occurrence: asked, cursor: cursor)
        }
        return ReaderPageWording.cursorIs(cursor)
    }

    /// Which of the pages that carry the label of the page at `index` it is,
    /// counting from 1 in book order; nil when it is the only page with its
    /// label. Labels are matched as Go to Page matches what is typed
    /// (`JumpInputValidator.pageIndices(named:in:)`), so two pages the
    /// field would reach by one label are two of one label here.
    private func occurrence(ofPageAt index: Int) -> Int? {
        let pages = bookPages
        guard pages.breaks.indices.contains(index) else { return nil }
        let sharing = JumpInputValidator.pageIndices(named: pages.breaks[index].label, in: pages)
        guard sharing.count > 1, let position = sharing.firstIndex(of: index) else { return nil }
        return position + 1
    }

    /// Ask for the page field (Go to Page…, PG03): the status row opens it at
    /// each request, and puts the keyboard in it. A book without pages says
    /// so and opens nothing (while the book loads, it does nothing).
    func requestGoToPage() {
        guard pageCommandHasPages() else { return }
        goToPageRequests += 1
    }

    /// Navigate to the start of `page`, so that Go Back returns to where the
    /// move began, and say the label of the page holding the place reached:
    /// the last of the pages that share it.
    private func go(to page: PageBreak) {
        navigatePreservingReturnPosition(
            chapterIndex: page.chapterIndex,
            characterOffset: page.characterOffset
        )
        announceToVoiceOver(ReaderPageWording.arrived(at: labelShown(afterMovingTo: page)))
    }

    /// The label of the page the status row names where the reader stands
    /// once it has moved to the start of `page`: the page holding the cursor,
    /// which is the last of the pages that begin at that place
    /// (`BookPages.index(ofPageAtChapter:offset:)`) and so `page` itself when
    /// no other page shares its place. What Next Page and Previous Page say
    /// is this label, as Go to Page names the row's page too, so the words
    /// spoken, the row, and Where Am I? always agree. The cursor is read
    /// after the move, not worked out from `page`, because a move may stop
    /// short of a page's place (the last word of the book is as far as the
    /// reader goes). `page`'s own label is the fallback for a cursor no page
    /// holds, which a move to one of the book's pages rules out while the
    /// book is stopped.
    private func labelShown(afterMovingTo page: PageBreak) -> String {
        currentPagePosition.page?.label ?? page.label
    }
}
