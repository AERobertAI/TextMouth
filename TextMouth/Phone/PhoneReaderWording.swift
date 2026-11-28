import Foundation

/// The words the iPhone's reader needs that the Mac doesn't have, each as the
/// spec gives it ("One vocabulary", under "New words, in one place", and the
/// reader's own sections). Every one is a full, plain sentence, and a hint
/// says what a control does, never a gesture (principle 7).
///
/// The Mac's own words are called from where they live, or held in
/// `PhoneReaderVocabulary` when they sit inline in a Mac view.
enum PhoneReaderWording {
    // MARK: Play

    /// Play's hint, naming the unit in force in lower case: "Moves back or
    /// forward by sentence." It says what adjusting does, since activating
    /// needs no explaining.
    static func playHint(movingBy unit: SkipUnit) -> String {
        // One whole sentence for each unit: a language may not take its name
        // in lower case, or in the same place of the sentence.
        switch unit {
        case .seconds10, .seconds15, .seconds30, .seconds60:
            // Translators: Hint of the iPhone reader's Play button while the navigation unit is a length of time. %lld is how many seconds a move covers: 10, 15, 30, or 60.
            InterfaceText.line("phoneReader.playHint.seconds", "Moves back or forward by \(number: unit.seconds ?? 0) seconds.")
        case .sentence:
            // Translators: Hint of the iPhone reader's Play button while the navigation unit is a sentence.
            InterfaceText.line("phoneReader.playHint.sentence", "Moves back or forward by sentence.")
        case .paragraph:
            // Translators: Hint of the iPhone reader's Play button while the navigation unit is a paragraph.
            InterfaceText.line("phoneReader.playHint.paragraph", "Moves back or forward by paragraph.")
        case .page:
            // Translators: Hint of the iPhone reader's Play button while the navigation unit is a page of the book.
            InterfaceText.line("phoneReader.playHint.page", "Moves back or forward by page.")
        case .heading:
            // Translators: Hint of the iPhone reader's Play button while the navigation unit is a heading.
            InterfaceText.line("phoneReader.playHint.heading", "Moves back or forward by heading.")
        case .subheading:
            // Translators: Hint of the iPhone reader's Play button while the navigation unit is a subheading.
            InterfaceText.line("phoneReader.playHint.subheading", "Moves back or forward by subheading.")
        case .bookmark:
            // Translators: Hint of the iPhone reader's Play button while the navigation unit is a bookmark.
            InterfaceText.line("phoneReader.playHint.bookmark", "Moves back or forward by bookmark.")
        }
    }

    // MARK: Navigation Unit and Speed

    /// Navigation unit's hint.
    static var navigationUnitHint: String {
        // Translators: Hint of the iPhone reader's Navigation unit control.
        InterfaceText.line("phoneReader.navigationUnitHint", "Chooses what Play and the skip buttons move by.")
    }

    /// A text book's speed control's hint, naming the Mac's step of 25 words
    /// per minute (`ReaderViewModel.speechSpeedStep`). An audiobook's is the
    /// Mac's `AudioSpeed.stepHint(_:)`. On the main actor, where the reader's
    /// step lives.
    @MainActor
    static var textSpeedHint: String {
        // Translators: Hint of the iPhone reader's speed control for a text book. %lld is the step, in words a minute.
        InterfaceText.line("phoneReader.textSpeedHint", "Changes the speed in steps of \(number: Int(ReaderViewModel.speechSpeedStep)) words per minute.")
    }

    // MARK: The Heading Buttons

    /// Previous Heading's hint.
    static var previousHeadingHint: String {
        // Translators: Hint of the iPhone reader's Previous Heading button.
        InterfaceText.line("phoneReader.previousHeadingHint", "Moves to the previous heading, keeping the navigation unit.")
    }

    /// Next Heading's hint.
    static var nextHeadingHint: String {
        // Translators: Hint of the iPhone reader's Next Heading button.
        InterfaceText.line("phoneReader.nextHeadingHint", "Moves to the next heading, keeping the navigation unit.")
    }

    // MARK: Book Content

    /// Book content's hint while paused, when activating plays from VoiceOver's
    /// place in the text.
    static var bookContentPausedHint: String {
        // Translators: Hint of the iPhone reader's book text while the book is paused: activating it plays from the place VoiceOver is at.
        InterfaceText.line("phoneReader.bookContentPausedHint", "Plays from here.")
    }

    /// Book content's hint while the book plays, when activating brings the
    /// text to the sentence being spoken.
    static var bookContentPlayingHint: String {
        // Translators: Hint of the iPhone reader's book text while the book plays: activating it moves VoiceOver to the sentence being spoken.
        InterfaceText.line("phoneReader.bookContentPlayingHint", "Brings the text to the sentence being spoken.")
    }

    /// Book content's text for an audiobook with no transcript: "This
    /// audiobook has no text. The Battle.", giving the heading being heard
    /// when there is one. Its chapters are spaces, which a reader must not be
    /// shown.
    static func audiobookHasNoText(heading: String?) -> String {
        // Translators: Text of the iPhone reader's book content for an audiobook that has no transcript.
        let sentence = InterfaceText.line("phoneReader.audiobookHasNoText", "This audiobook has no text.")
        guard let heading = heading?.nonBlank else { return sentence }
        return SentenceWording.joined([sentence, Self.sentence(heading)])
    }

    /// The question before Add bookmark removes a bookmark that has a note:
    /// "Remove Bookmark 3?", with the note as its message. The Bookmarks
    /// sheet asks the same question in the same words (one definition).
    static func removeBookmarkTitle(_ bookmark: Bookmark) -> String {
        PhoneBookmarksWording.removeQuestion(number: bookmark.number)
    }

    /// The question's button that removes the bookmark.
    static var remove: String { PhoneBookmarksWording.removeButton }

    /// The name of Book content's rotor that moves by sentence.
    static var sentencesRotor: String {
        // Translators: Name of the VoiceOver rotor on the iPhone reader's book text that moves between sentences.
        InterfaceText.line("phoneReader.sentencesRotor", "Sentences")
    }

    /// The name of Play's rotor that moves by page.
    static var pagesRotor: String {
        // Translators: Name of the VoiceOver rotor on the iPhone reader's Play button that moves between pages.
        InterfaceText.line("common.pages", "Pages")
    }

    // MARK: The Grid's Buttons

    /// Bookmarks' hint.
    static var bookmarksHint: String {
        // Translators: Hint of the iPhone reader's Bookmarks button.
        InterfaceText.line("phoneReader.bookmarksHint", "Opens the list of bookmarks.")
    }

    /// Headings' hint.
    static var headingsHint: String {
        // Translators: Hint of the iPhone reader's Headings button.
        InterfaceText.line("phoneReader.headingsHint", "Opens the list of headings.")
    }

    /// The Go To button's label.
    static var goTo: String {
        // Translators: Label of the iPhone reader's button that opens the Go To sheet, and that sheet's title.
        InterfaceText.line("phoneReader.goTo", "Go To")
    }

    /// Go To's hint.
    static var goToHint: String {
        // Translators: Hint of the iPhone reader's Go To button.
        InterfaceText.line("phoneReader.goToHint", "Goes to a page, a percent, or a time.")
    }

    /// Return's hint. The Mac's "Go back to where you were before browsing
    /// headings or bookmarks" is too narrow for a phone, where every jump
    /// keeps the place.
    static var returnHint: String {
        // Translators: Hint of the iPhone reader's Return button.
        InterfaceText.line("phoneReader.returnHint", "Goes back to where the last jump began.")
    }

    /// The Book Actions menu's label (FR51). The Mac has no such menu: its
    /// toolbar holds the four actions loose.
    static var bookActions: String {
        // Translators: Label of the iPhone reader's menu button that holds the book's less frequent actions: Sleep Timer, Voice, Book Info, and Export.
        InterfaceText.line("phoneReader.bookActions", "Book Actions")
    }

    /// The Book Actions menu's hint, naming what it holds.
    static var bookActionsHint: String {
        // Translators: Hint of the iPhone reader's Book Actions menu button.
        InterfaceText.line("phoneReader.bookActionsHint", "Sleep timer, voice, book information, and export.")
    }

    /// Sleep Timer's hint, under Play while a timer runs (FR55): what a
    /// double tap does, then what adjusting it does.
    static var sleepTimerHint: String {
        SentenceWording.joined([
            // Translators: First sentence of the hint of the iPhone reader's Sleep Timer button, shown while a sleep timer runs.
            InterfaceText.line("phoneReader.sleepTimerHint", "Opens the sleep timer."),
            // Translators: Last sentence of the hint of the iPhone reader's Sleep Timer button, an adjustable control: adjusting it up (VoiceOver's swipe up) starts the running timer again from its whole length, down cancels it. Names no gesture.
            InterfaceText.line("phoneReader.sleepTimerAdjustHint", "Adjusting up restarts it at its full length, and down cancels it."),
        ])
    }

    /// Sleep Timer's value while no timer runs: the sleep timer's own
    /// localized word (FR35), read here rather than copied.
    static var sleepTimerOff: String { PhoneSleepTimerModel.offValue }

    /// Headings' value: the heading and its place among the book's headings,
    /// "The Battle, 26 of 412"; "26 of 412" for a heading with no words;
    /// the Mac's "Before heading 1 of 412" before the first; nothing for a
    /// book without headings.
    static func headingsValue(_ position: HeadingPosition) -> String {
        guard position.count > 0 else { return "" }
        guard let number = position.number else { return position.label }
        // Translators: Value of the iPhone reader's Headings button: the place of the heading among the book's headings. %1$lld is the heading's number and %2$lld how many headings the book has.
        let place = InterfaceText.line("phoneReader.headingsValue", "\(number: number) of \(number: position.count)")
        guard let text = position.headingText else { return place }
        return SentenceWording.commaJoined([text, place])
    }

    // MARK: What a Move Says

    /// What a move says when there's nothing that way: "No next heading.",
    /// "No previous page.", with the unit's name in lower case; for a move by
    /// seconds, "Start of the book." or "End of the book.". The Mac says
    /// nothing here, but a press that does nothing must be told from a press
    /// that was missed.
    static func nothingThatWay(unit: SkipUnit, forward: Bool) -> String {
        if unit.isTimeBased {
            return forward
                // Translators: What the iPhone reader says when a move forward by a length of time has nothing left to move to.
                ? InterfaceText.line("phoneReader.nothingThatWay.endBook", "End of the book.")
                // Translators: What the iPhone reader says when a move back by a length of time has nothing before it.
                : InterfaceText.line("phoneReader.nothingThatWay.start", "Start of the book.")
        }
        return forward ? nothingNext(unit) : nothingPrevious(unit)
    }

    /// The most characters a paused move's sentence gives, so a run-on
    /// sentence doesn't hold Play's value for a minute.
    static let movedSentenceCharacterLimit = 300

    /// The words at a text book's new place after a paused move by sentence,
    /// paragraph, or seconds: the text from the place to the end of its
    /// sentence, as Play will speak it first, its whitespace closed up, and
    /// cut at a word with "…" past `movedSentenceCharacterLimit`. Nil when
    /// nothing but whitespace follows the place.
    ///
    /// - Parameters:
    ///   - text: The chapter's text.
    ///   - offset: The new place, a UTF-16 offset into `text`.
    static func sentence(in text: String, from offset: Int) -> String? {
        let length = text.utf16Length
        guard offset >= 0, offset < length else { return nil }
        // The sentence ends where the next begins, by the reader's own scan,
        // or with the chapter.
        let end = ReaderViewModel.nextSentenceStart(in: text, after: offset) ?? length
        let start = text.index(atUTF16Offset: offset)
        let stop = text.index(atUTF16Offset: max(offset, end))
        let words = text[start..<stop].split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return nil }
        return capped(words.joined(separator: " "))
    }

    /// `sentence` within `movedSentenceCharacterLimit`: as it is when short
    /// enough, or cut at the last whole word that fits, then "…".
    static func capped(_ sentence: String) -> String {
        guard sentence.count > movedSentenceCharacterLimit else { return sentence }
        var kept = ""
        for word in sentence.split(separator: " ") {
            let next = kept.isEmpty ? String(word) : kept + " " + word
            guard next.count <= movedSentenceCharacterLimit else { break }
            kept = next
        }
        // A first word longer than the limit is cut inside itself.
        if kept.isEmpty {
            kept = String(sentence.prefix(movedSentenceCharacterLimit))
        }
        return kept + "…"
    }

    /// Where an audiobook's place is in its recording, for Where Am I?'s
    /// value: "2 hours, 13 minutes in".
    static func timeIntoRecording(_ time: TimeInterval) -> String {
        // Translators: Part of the iPhone reader's Where Am I? for an audiobook: how far into the recording the place is. %@ is the time in words, as in "2 hours, 13 minutes in".
        InterfaceText.line("phoneReader.timeIntoRecording", "\(TimeFormatting.spoken(time)) in")
    }

    // MARK: Nothing That Way, One Sentence for Each Unit

    /// "No next sentence.", and the like, for a structural `unit`: whole
    /// sentences, so each language keeps its own order and agreement.
    private static func nothingNext(_ unit: SkipUnit) -> String {
        switch unit {
        case .paragraph:
            // Translators: What the iPhone reader says when a move forward by paragraph has no next paragraph.
            InterfaceText.line("phoneReader.nothingNext.paragraph", "No next paragraph.")
        case .page:
            // Translators: What the iPhone reader says when a move forward by page has no next page.
            InterfaceText.line("phoneReader.nothingNext.page", "No next page.")
        case .heading:
            // Translators: What the iPhone reader says when a move forward by heading has no next heading.
            InterfaceText.line("phoneReader.nothingNext.heading", "No next heading.")
        case .subheading:
            // Translators: What the iPhone reader says when a move forward by subheading has no next subheading.
            InterfaceText.line("phoneReader.nothingNext.subheading", "No next subheading.")
        case .bookmark:
            // Translators: What the iPhone reader says when a move forward by bookmark has no next bookmark.
            InterfaceText.line("phoneReader.nothingNext.bookmark", "No next bookmark.")
        default:
            // Translators: What the iPhone reader says when a move forward by sentence has no next sentence.
            InterfaceText.line("phoneReader.nothingNext.other", "No next sentence.")
        }
    }

    /// "No previous sentence.", and the like, for a structural `unit`.
    private static func nothingPrevious(_ unit: SkipUnit) -> String {
        switch unit {
        case .paragraph:
            // Translators: What the iPhone reader says when a move back by paragraph has no previous paragraph.
            InterfaceText.line("phoneReader.nothingPrevious.paragraph", "No previous paragraph.")
        case .page:
            // Translators: What the iPhone reader says when a move back by page has no previous page.
            InterfaceText.line("phoneReader.nothingPrevious.page", "No previous page.")
        case .heading:
            // Translators: What the iPhone reader says when a move back by heading has no previous heading.
            InterfaceText.line("phoneReader.nothingPrevious.heading", "No previous heading.")
        case .subheading:
            // Translators: What the iPhone reader says when a move back by subheading has no previous subheading.
            InterfaceText.line("phoneReader.nothingPrevious.subheading", "No previous subheading.")
        case .bookmark:
            // Translators: What the iPhone reader says when a move back by bookmark has no previous bookmark.
            InterfaceText.line("phoneReader.nothingPrevious.bookmark", "No previous bookmark.")
        default:
            // Translators: What the iPhone reader says when a move back by sentence has no previous sentence.
            InterfaceText.line("phoneReader.nothingPrevious.other", "No previous sentence.")
        }
    }

    // MARK: Helpers

    /// `words` ended as a sentence: with a full stop unless it ends in one
    /// of its own, so a heading "Coda?" isn't read "Coda?.".
    private static func sentence(_ words: String) -> String {
        guard let last = words.last, !".!?…".contains(last) else { return words }
        return words + "."
    }
}
