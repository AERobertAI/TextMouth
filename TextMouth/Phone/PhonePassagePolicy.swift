import Foundation

/// When Book content's text changes, what passage it holds, and where Listen
/// from Here plays from (the spec, under "Book content"; the engineering
/// review's F16).
///
/// Pure, so every rule is a test on the Mac: `PhoneBookTextView`, on iOS,
/// tells it what happened and assigns the passage only when it differs.
///
/// The passage starts at the start of the sentence at the reading position,
/// so a person who pauses and moves to it hears the sentence just spoken
/// first. It holds up to the Mac's 20,000 characters, and ends on a whole word
/// by the Mac's own rule (`VisibleTextWindowPolicy`).
enum PhonePassagePolicy {
    /// What happened, that may change the passage.
    enum Event: Equatable, Sendable {
        /// The book has loaded.
        case loaded
        /// The book paused or stopped: the passage starts at the sentence just
        /// spoken.
        case paused
        /// The place moved while paused: by Play, a skip, a jump, a page.
        case movedWhilePaused
        /// The 10-second tick while the book plays.
        case playingTick
        /// VoiceOver's focus left Book content.
        case focusLeft
        /// The app came back from the background.
        case cameBack
        /// The listener activated Book content while the book plays: bring
        /// the text to the sentence being spoken, a Follow in Braille by hand.
        case followAsked
    }

    /// How often the passage may follow the book while it plays and Book
    /// content doesn't have focus.
    static let refreshInterval: TimeInterval = 10

    /// Whether `event` changes the passage. A focused text view must not
    /// change under a reader, in speech or in braille, so with focus on Book
    /// content only the listener's own requests change it, and the book's
    /// playing does only while Follow in Braille is on.
    ///
    /// - Parameters:
    ///   - event: What happened.
    ///   - hasFocus: Whether Book content has VoiceOver's focus.
    ///   - isPlaying: Whether the book plays.
    ///   - followsInBraille: Whether Settings' Follow in Braille is on.
    static func changesPassage(
        on event: Event,
        hasFocus: Bool,
        isPlaying: Bool,
        followsInBraille: Bool
    ) -> Bool {
        switch event {
        case .loaded, .movedWhilePaused, .focusLeft, .followAsked:
            return true
        case .paused:
            return !hasFocus
        case .playingTick:
            return isPlaying && (!hasFocus || followsInBraille)
        case .cameBack:
            // The spec says always; with focus on the text, a reader in the
            // middle of it keeps it, as everywhere else.
            return !hasFocus || followsInBraille
        }
    }

    /// Where Book content's passage is taken from, given the reading place
    /// `offset` in chapter `chapter`: that place when its chapter has words to
    /// say, and otherwise the start of the next chapter that has, where Play
    /// would begin reading. A book whose first chapter is only an image (a
    /// Project Gutenberg EPUB's "Cover") is placed there when it's new, and
    /// would otherwise open to an empty Book content.
    ///
    /// Nil when no chapter from `chapter` on has words, so Book content has
    /// nothing to show and keeps its stand-in.
    ///
    /// - Parameters:
    ///   - chapter: The chapter of the reading place.
    ///   - offset: The place in that chapter, as a UTF-16 offset.
    ///   - chapterCount: How many chapters the book has.
    ///   - hasWords: Whether chapter `index` has anything to say, by the same
    ///     rule as playback's (`ReaderViewModel.hasSpeakableText`).
    static func placeToShow(
        chapter: Int,
        offset: Int,
        chapterCount: Int,
        hasWords: (Int) -> Bool
    ) -> (chapter: Int, offset: Int)? {
        guard chapter >= 0, chapter < chapterCount else { return nil }
        if hasWords(chapter) { return (chapter: chapter, offset: offset) }
        // The same forward-only search that playback makes over silent
        // chapters, so Book content shows what Play would read.
        return ReaderViewModel.nextSpeakableChapterIndex(
            from: chapter + 1,
            chapterCount: chapterCount,
            isSpeakable: hasWords
        ).map { (chapter: $0, offset: 0) }
    }

    /// The passage of `text` for a reading position at `offset`, as UTF-16
    /// offsets: from the start of the sentence holding `offset`, at most
    /// `maximumLength` long, ending on a whole word.
    static func passage(in text: String, at offset: Int, maximumLength: Int) -> Range<Int> {
        let length = text.utf16Length
        guard length > 0, maximumLength > 0 else { return 0..<0 }
        let place = min(max(offset, 0), length)
        let start = ReaderViewModel.sentenceStart(in: text, before: place)
        guard length - start > maximumLength else { return start..<length }
        // The Mac's window, cut from the passage's start: a window around its
        // first character begins there, and its end moves back to a whole
        // word, as the Mac's does. One character past the limit is enough for
        // it to see the cut's two sides.
        let sliceStart = text.index(atUTF16Offset: start)
        let sliceEnd = text.index(atUTF16Offset: start + maximumLength + 1)
        let slice = String(text[sliceStart..<sliceEnd])
        let window = VisibleTextWindowPolicy.bounds(in: slice, around: 0, maximumLength: maximumLength)
        return start..<(start + window.upperBound)
    }

    /// Where the passage after or before one showing `shown` of chapter
    /// `chapter` begins, for paging through Book content across chapters:
    /// the next passage starts where this one ends, or at the next chapter
    /// with words in it; the previous one a passage's length before this
    /// one's start, or at the last passage of the chapter with words before.
    /// Nil at either end of the book.
    ///
    /// - Parameters:
    ///   - chapters: Every chapter's text, in order.
    ///   - chapter: The chapter shown.
    ///   - shown: The passage shown, as UTF-16 offsets in that chapter.
    ///   - forward: Whether to page forward.
    ///   - maximumLength: The longest a passage is.
    static func pageTarget(
        chapters: [String],
        chapter: Int,
        shown: Range<Int>,
        forward: Bool,
        maximumLength: Int
    ) -> (chapter: Int, offset: Int)? {
        guard chapters.indices.contains(chapter) else { return nil }
        let hasWords: (Int) -> Bool = { !chapters[$0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if forward {
            if shown.upperBound < chapters[chapter].utf16Length {
                return (chapter: chapter, offset: shown.upperBound)
            }
            let next = chapters.indices.dropFirst(chapter + 1).first(where: hasWords)
            return next.map { (chapter: $0, offset: 0) }
        }
        if shown.lowerBound > 0 {
            return (chapter: chapter, offset: max(0, shown.lowerBound - maximumLength))
        }
        let before = chapters.indices.prefix(chapter).last(where: hasWords)
        return before.map { (chapter: $0, offset: max(0, chapters[$0].utf16Length - maximumLength)) }
    }

    /// Where Listen from Here plays from, as an offset in the chapter:
    /// VoiceOver's cursor in the text, found in the spec's order. First the
    /// text view's selection, if VoiceOver or a braille display's router key
    /// has moved it; then the sentence last reached through the Sentences
    /// rotor; otherwise the passage's start.
    ///
    /// - Parameters:
    ///   - passageStart: Where the passage begins in the chapter.
    ///   - movedSelection: The selection's place in the passage, when it has
    ///     moved since the passage was shown; nil when it hasn't.
    ///   - rotorSentence: The passage offset the Sentences rotor last reached,
    ///     or nil.
    ///   - passageLength: The passage's length, which a place can't pass.
    static func listeningPlace(
        passageStart: Int,
        movedSelection: Int?,
        rotorSentence: Int?,
        passageLength: Int
    ) -> Int {
        let inPassage = movedSelection ?? rotorSentence ?? 0
        return passageStart + min(max(inPassage, 0), max(passageLength - 1, 0))
    }

    /// The sentence before or after the one at `offset` in `passage`, for
    /// the Sentences rotor, as a range in the passage; nil at either end.
    ///
    /// - Parameters:
    ///   - passage: The passage's text.
    ///   - offset: Where the rotor stands, a UTF-16 offset in the passage.
    ///   - forward: Whether to go to the next sentence, else the previous.
    static func sentence(in passage: String, from offset: Int, forward: Bool) -> Range<Int>? {
        let length = passage.utf16Length
        guard length > 0 else { return nil }
        let place = min(max(offset, 0), length)
        let start: Int
        if forward {
            guard let next = ReaderViewModel.nextSentenceStart(in: passage, after: place) else { return nil }
            start = next
        } else {
            let current = ReaderViewModel.sentenceStart(in: passage, before: place)
            if current < place {
                // Inside a sentence: back to its start.
                start = current
            } else {
                // At a sentence's start: back to the one before, found from
                // just before this one.
                guard current > 0 else { return nil }
                start = ReaderViewModel.sentenceStart(in: passage, before: current - 1)
                guard start < current else { return nil }
            }
        }
        let end = ReaderViewModel.nextSentenceStart(in: passage, after: start) ?? length
        return start..<max(start, end)
    }
}
