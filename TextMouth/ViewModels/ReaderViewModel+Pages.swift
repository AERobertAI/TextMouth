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

    /// The page holding the reading cursor, as "Page 12 of 300".
    var currentPagePosition: PagePosition {
        bookPages.position(atChapter: currentChapterIndex, offset: currentCharacterOffset)
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
    /// shows them: every unit, except Page when the book has no pages (an
    /// audiobook, or a text book whose format or file gives none), which
    /// would have nothing to move by. A unit already in force stays in the
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
        Self.navigationUnitChoices(bookHasPages: hasPages, keeping: selected)
    }

    // MARK: - Skipped sections

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
            let textLength = content.chapters[page.chapterIndex].text.utf16Length
            if page.characterOffset >= textLength { return true }
            guard !skippedIDs.isEmpty else { return false }
            if rangesByChapter[page.chapterIndex] == nil {
                rangesByChapter[page.chapterIndex] = SkippedSectionFilter.excludedRanges(
                    textLength: textLength,
                    headings: headings.filter { $0.chapterIndex == page.chapterIndex },
                    skippedIDs: skippedIDs
                )
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
    /// (`ReaderPageWording.noPages`).
    private func pageCommandHasPages() -> Bool {
        guard content != nil else { return false }
        guard hasPages else {
            announceToVoiceOver(ReaderPageWording.noPages)
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
    /// stands after the jump (`labelShown(afterMovingTo:)`), which is not
    /// always the page typed: a blank page shares its place with the page
    /// after it, and the row names the later one. Saying the typed label
    /// then told the listener one page while the row, Where Am I?, and Next
    /// Page all named another.
    func goToPage(typed text: String) -> String? {
        let pages = bookPages
        let currentIndex = pages.index(ofPageAtChapter: currentChapterIndex, offset: currentCharacterOffset)
        switch JumpInputValidator.page(text, in: pages, currentIndex: currentIndex) {
        case .page(let index):
            // The index comes from the pages themselves; check it anyway.
            guard pages.breaks.indices.contains(index) else { return ReaderPageWording.noPages }
            let page = pages.breaks[index]
            navigatePreservingReturnPosition(chapterIndex: page.chapterIndex, characterOffset: page.characterOffset)
            announceToVoiceOver(ReaderPageWording.jumped(to: labelShown(afterMovingTo: page)))
            return nil
        case .error(let message):
            return message
        }
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
    /// no other page shares its place. What every command that lands on a
    /// page says is this label, so the words spoken, the row, and Where Am
    /// I? always agree. The cursor is read after the move, not worked out
    /// from `page`, because a move may stop short of a page's place (the
    /// last word of the book is as far as the reader goes). `page`'s own
    /// label is the fallback for a cursor no page holds, which a move to one
    /// of the book's pages rules out.
    private func labelShown(afterMovingTo page: PageBreak) -> String {
        currentPagePosition.page?.label ?? page.label
    }
}
