import Foundation

// MARK: - Edited Text (FR05)

/// How an open reader shows its book's text once the user has edited it in
/// their own editor and TextMouth has taken the edit (`BookTextEditor`).
///
/// The library sends the edited text, parsed and indexed, through the
/// readers' usual updates (`LibraryBookEvent.textReplaced`), after the
/// book's row has taken the edit's counts. The reader then shows it in
/// place of the text it had, its cursor as near as can be found to where it
/// was (`EditedTextCursor`); speech of the old text stops, and starts again
/// from there when it was playing.
extension ReaderViewModel {

    /// Shows `edited`, the book's text as the user edited it, in place of
    /// the text this reader shows, unless it shows that very text already.
    ///
    /// A reader still loading keeps it until loading ends, since what it is
    /// loading may be the text from before the edit. A reader whose load
    /// stopped over an edit that could not be taken opens the book with this
    /// text, now that an edit is taken: the text the library committed,
    /// parsed and indexed already, so nothing is read again. Bookmarks keep
    /// their places in the chapters, which an edit may have moved.
    func showEditedText(_ edited: DocumentContent) {
        guard !hasClosed, !isAudioBook else { return }
        if content == nil, !isLoading, loadHeldByTextEdit {
            loadHeldByTextEdit = false
            errorMessage = nil
            showLoadedContent(
                LoadedContent(
                    content: edited,
                    index: edited.contentIndex,
                    audioFiles: nil,
                    audioSegments: nil,
                    audioTags: nil,
                    shouldPersistContentIndex: false,
                    cacheFormatVersion: MarkdownCacheService.currentCacheVersion
                ),
                readFrom: book.filePath
            )
            return
        }
        guard !isLoading, let current = content else {
            editedTextWaitingForLoad = edited
            return
        }
        guard !Self.showsSameText(current, as: edited) else { return }

        let wasPlaying = isCurrentlyPlaying && !isCurrentlyPaused
        let position = EditedTextCursor.position(
            chapterIndex: currentChapterIndex,
            characterOffset: currentCharacterOffset,
            in: current.chapters,
            to: edited.chapters
        )
        // The speech of the old text, its look-ahead, and what was prepared
        // from it all go: none of it is the book's any more.
        if isCurrentlyPlaying || isCurrentlyPaused || isWaitingForChapterSpeech {
            stop()
        }
        discardLookAhead()
        chapterSpeechCache.removeAll()

        // Assigning content also publishes its headings.
        content = edited
        currentChapterIndex = position.chapterIndex
        currentCharacterOffset = position.characterOffset
        // This reader's sleep timer for the end of the heading waits for
        // the heading after the cursor in the edited text.
        if sleepTimerService.waitsForHeadingEnd(ownedBy: readerID) {
            sleepTimerNextHeading = headingAfterCursor
        }
        savePosition()
        refreshPlaybackUI(forceVisibleTextRefresh: true)
        if wasPlaying {
            play()
        } else {
            prepareOpenedChapterSpeech()
        }
    }

    /// Shows the edited text taken while this reader loaded, if any: called
    /// as loading ends.
    func showEditedTextWaitingForLoad() {
        guard let edited = editedTextWaitingForLoad else { return }
        editedTextWaitingForLoad = nil
        showEditedText(edited)
    }

    /// Whether `current`, the text a reader shows, is `edited` already: both
    /// were measured from the same content.md bytes, as a reader that
    /// loaded after the edit was taken shows it.
    nonisolated static func showsSameText(_ current: DocumentContent, as edited: DocumentContent) -> Bool {
        guard let shown = current.contentIndex.textCacheFingerprint?.cache.digest,
              let replacing = edited.contentIndex.textCacheFingerprint?.cache.digest else { return false }
        return shown == replacing
    }
}

// MARK: - Where the Cursor Goes

/// Where a reader's cursor goes when its book's text is replaced by an
/// edit (FR05): as near as can be found to the words it was at.
///
/// The words at the cursor, and failing those the words just before it,
/// are looked for in the edited text: first in the chapter the cursor most
/// likely stays in, nearest where it would be in proportion, then in the
/// other chapters, nearest first. When they are nowhere, as when the
/// passage was rewritten, the cursor keeps its place in proportion within
/// that chapter, at the start of a word.
enum EditedTextCursor {
    /// How many UTF-16 units of the old text at the cursor are looked for.
    static let anchorLength = 48
    /// The fewest non-space characters an anchor must hold to be looked
    /// for, so a cursor at the end of a chapter does not match a stray
    /// space.
    static let minimumAnchorCharacters = 8

    /// The cursor in `new` for one at `characterOffset` (UTF-16) in chapter
    /// `chapterIndex` of `old`, clamped within `new`.
    static func position(
        chapterIndex: Int,
        characterOffset: Int,
        in old: [Chapter],
        to new: [Chapter]
    ) -> (chapterIndex: Int, characterOffset: Int) {
        guard !new.isEmpty else { return (0, 0) }
        guard old.indices.contains(chapterIndex) else {
            let chapter = min(max(chapterIndex, 0), new.count - 1)
            return (chapter, clamped(characterOffset, in: new[chapter].text))
        }
        let oldText = old[chapterIndex].text as NSString
        let offset = min(max(characterOffset, 0), oldText.length)
        let target = likelyChapter(for: chapterIndex, titled: old[chapterIndex].title, oldCount: old.count, in: new)
        let targetText = new[target].text as NSString
        if targetText.isEqual(to: old[chapterIndex].text) {
            return (target, offset)
        }
        let expected = proportionalOffset(offset, from: oldText.length, to: targetText.length)

        // The words at the cursor mark where it was; failing those, the
        // words just before it, after which it stands.
        let anchors = [
            anchor(in: oldText, from: offset, forward: true).map { (text: $0, placesCursorAtEnd: false) },
            anchor(in: oldText, from: offset, forward: false).map { (text: $0, placesCursorAtEnd: true) },
        ].compactMap { $0 }
        for anchor in anchors {
            if let found = nearestRange(of: anchor.text, in: targetText, near: expected) {
                return (target, anchor.placesCursorAtEnd ? NSMaxRange(found) : found.location)
            }
        }
        for anchor in anchors {
            for other in chapters(byDistanceFrom: target, count: new.count) where other != target {
                let text = new[other].text as NSString
                let near = proportionalOffset(offset, from: oldText.length, to: text.length)
                if let found = nearestRange(of: anchor.text, in: text, near: near) {
                    return (other, anchor.placesCursorAtEnd ? NSMaxRange(found) : found.location)
                }
            }
        }
        return (target, ReaderViewModel.snappedWordStart(in: new[target].text, at: expected))
    }

    /// The chapter of `new` the cursor most likely stays in, from chapter
    /// `index` of `oldCount`, titled `title`: the same place when the edit
    /// kept the number of chapters; otherwise the chapter of that title
    /// nearest that place, or the same place clamped.
    private static func likelyChapter(for index: Int, titled title: String, oldCount: Int, in new: [Chapter]) -> Int {
        let samePlace = min(index, new.count - 1)
        guard new.count != oldCount, !title.isEmpty else { return samePlace }
        let titled = new.indices.filter { new[$0].title == title }
        return titled.min { abs($0 - index) < abs($1 - index) } ?? samePlace
    }

    /// The indices of `count` chapters, nearest `index` first, the later of
    /// two equally near first.
    private static func chapters(byDistanceFrom index: Int, count: Int) -> [Int] {
        (0..<count).sorted { first, second in
            let firstDistance = abs(first - index)
            let secondDistance = abs(second - index)
            return firstDistance == secondDistance ? first > second : firstDistance < secondDistance
        }
    }

    /// The text of `text` from `offset` onwards (`forward`) or ending at it,
    /// up to `anchorLength` units, never splitting a character; nil when it
    /// holds too few characters to mark a place.
    private static func anchor(in text: NSString, from offset: Int, forward: Bool) -> String? {
        let start = forward ? offset : max(0, offset - anchorLength)
        let end = forward ? min(text.length, offset + anchorLength) : offset
        guard end > start else { return nil }
        let range = text.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: end - start))
        let anchor = text.substring(with: range)
        guard anchor.filter({ !$0.isWhitespace }).count >= minimumAnchorCharacters else { return nil }
        return anchor
    }

    /// The occurrence of `anchor` in `text` that starts nearest `expected`,
    /// or nil when there is none.
    private static func nearestRange(of anchor: String, in text: NSString, near expected: Int) -> NSRange? {
        let pivot = min(max(expected, 0), text.length)
        let after = text.range(of: anchor, options: .literal, range: NSRange(location: pivot, length: text.length - pivot))
        let searchEnd = min(text.length, pivot + (anchor as NSString).length)
        let before = text.range(of: anchor, options: [.literal, .backwards], range: NSRange(location: 0, length: searchEnd))
        let found = [after, before].filter { $0.location != NSNotFound }
        return found.min { abs($0.location - pivot) < abs($1.location - pivot) }
    }

    /// `offset` in a text of `oldLength` units, carried to the same
    /// proportion of a text of `newLength`.
    private static func proportionalOffset(_ offset: Int, from oldLength: Int, to newLength: Int) -> Int {
        guard oldLength > 0 else { return 0 }
        return Int((Double(offset) / Double(oldLength) * Double(newLength)).rounded(.down))
    }

    /// `offset` held within `text`, from its start to its end.
    private static func clamped(_ offset: Int, in text: String) -> Int {
        min(max(offset, 0), text.utf16Length)
    }
}
