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

    // MARK: - Skipped sections

    /// Hands `body` a check that says whether a page is passed over, as
    /// speech passes over a skipped section: the page starts inside one. Each
    /// chapter's skipped ranges are worked out at most once per move, and
    /// not at all when the book skips nothing.
    private func withPassedOverCheck<Result>(
        _ body: (_ isPassedOver: (PageBreak) -> Bool) -> Result
    ) -> Result {
        let skippedIDs = skippedHeadingIDs
        guard !skippedIDs.isEmpty, let content else { return body { _ in false } }
        var rangesByChapter: [Int: [Range<Int>]] = [:]
        return body { page in
            guard content.chapters.indices.contains(page.chapterIndex) else { return false }
            if rangesByChapter[page.chapterIndex] == nil {
                rangesByChapter[page.chapterIndex] = SkippedSectionFilter.excludedRanges(
                    textLength: content.chapters[page.chapterIndex].text.utf16Length,
                    headings: headings.filter { $0.chapterIndex == page.chapterIndex },
                    skippedIDs: skippedIDs
                )
            }
            return rangesByChapter[page.chapterIndex]?.contains { $0.contains(page.characterOffset) } ?? false
        }
    }

    // MARK: - The commands

    /// Move to the start of the next page and say its label ("Page 13").
    /// Without pages it says so and moves nothing; after the last page it
    /// does nothing, as Next Heading does after the last heading.
    func nextPage() {
        guard hasPages else {
            announceToVoiceOver(ReaderPageWording.noPages)
            return
        }
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
    /// pages it says so and moves nothing; before the first page it does
    /// nothing.
    func previousPage() {
        guard hasPages else {
            announceToVoiceOver(ReaderPageWording.noPages)
            return
        }
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

    /// Navigate to the start of `page`, so that Go Back returns to where the
    /// move began, and say the label of the page holding the place reached:
    /// the last of the pages that share it.
    private func go(to page: PageBreak) {
        navigatePreservingReturnPosition(
            chapterIndex: page.chapterIndex,
            characterOffset: page.characterOffset
        )
        let reached = bookPages.position(atChapter: page.chapterIndex, offset: page.characterOffset)
        announceToVoiceOver(ReaderPageWording.arrived(at: reached.page?.label ?? page.label))
    }
}
