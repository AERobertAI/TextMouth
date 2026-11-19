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
            String(localized: "Moves back or forward by \(unit.seconds ?? 0) seconds.",
                   comment: "Hint of the iPhone reader's Play button while the navigation unit is a length of time. %lld is how many seconds a move covers: 10, 15, 30, or 60.")
        case .sentence:
            String(localized: "Moves back or forward by sentence.",
                   comment: "Hint of the iPhone reader's Play button while the navigation unit is a sentence.")
        case .paragraph:
            String(localized: "Moves back or forward by paragraph.",
                   comment: "Hint of the iPhone reader's Play button while the navigation unit is a paragraph.")
        case .page:
            String(localized: "Moves back or forward by page.",
                   comment: "Hint of the iPhone reader's Play button while the navigation unit is a page of the book.")
        case .heading:
            String(localized: "Moves back or forward by heading.",
                   comment: "Hint of the iPhone reader's Play button while the navigation unit is a heading.")
        case .subheading:
            String(localized: "Moves back or forward by subheading.",
                   comment: "Hint of the iPhone reader's Play button while the navigation unit is a subheading.")
        case .bookmark:
            String(localized: "Moves back or forward by bookmark.",
                   comment: "Hint of the iPhone reader's Play button while the navigation unit is a bookmark.")
        }
    }

    // MARK: Navigation Unit and Speed

    /// Navigation unit's hint.
    static var navigationUnitHint: String {
        String(localized: "Chooses what Play and the skip buttons move by.",
               comment: "Hint of the iPhone reader's Navigation unit control.")
    }

    /// A text book's speed control's hint, naming the Mac's step of 25 words
    /// per minute (`ReaderViewModel.speechSpeedStep`). An audiobook's is the
    /// Mac's `AudioSpeed.stepHint(_:)`. On the main actor, where the reader's
    /// step lives.
    @MainActor
    static var textSpeedHint: String {
        String(localized: "Changes the speed in steps of \(Int(ReaderViewModel.speechSpeedStep)) words per minute.",
               comment: "Hint of the iPhone reader's speed control for a text book. %lld is the step, in words a minute.")
    }

    // MARK: The Heading Buttons

    /// Previous Heading's hint.
    static var previousHeadingHint: String {
        String(localized: "Moves to the previous heading, keeping the navigation unit.",
               comment: "Hint of the iPhone reader's Previous Heading button.")
    }

    /// Next Heading's hint.
    static var nextHeadingHint: String {
        String(localized: "Moves to the next heading, keeping the navigation unit.",
               comment: "Hint of the iPhone reader's Next Heading button.")
    }

    // MARK: Book Content

    /// Book content's hint while paused, when activating plays from VoiceOver's
    /// place in the text.
    static var bookContentPausedHint: String {
        String(localized: "Plays from here.",
               comment: "Hint of the iPhone reader's book text while the book is paused: activating it plays from the place VoiceOver is at.")
    }

    /// Book content's hint while the book plays, when activating brings the
    /// text to the sentence being spoken.
    static var bookContentPlayingHint: String {
        String(localized: "Brings the text to the sentence being spoken.",
               comment: "Hint of the iPhone reader's book text while the book plays: activating it moves VoiceOver to the sentence being spoken.")
    }

    /// Book content's text for an audiobook with no transcript: "This
    /// audiobook has no text. The Battle.", giving the heading being heard
    /// when there is one. Its chapters are spaces, which a reader must not be
    /// shown.
    static func audiobookHasNoText(heading: String?) -> String {
        let sentence = String(localized: "This audiobook has no text.",
                              comment: "Text of the iPhone reader's book content for an audiobook that has no transcript.")
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
        String(localized: "Sentences",
               comment: "Name of the VoiceOver rotor on the iPhone reader's book text that moves between sentences.")
    }

    /// The name of Play's rotor that moves by page.
    static var pagesRotor: String {
        String(localized: "Pages",
               comment: "Name of the VoiceOver rotor on the iPhone reader's Play button that moves between pages.")
    }

    // MARK: The Grid's Buttons

    /// Bookmarks' hint.
    static var bookmarksHint: String {
        String(localized: "Opens the list of bookmarks.",
               comment: "Hint of the iPhone reader's Bookmarks button.")
    }

    /// Headings' hint.
    static var headingsHint: String {
        String(localized: "Opens the list of headings.",
               comment: "Hint of the iPhone reader's Headings button.")
    }

    /// The Go To button's label.
    static var goTo: String {
        String(localized: "Go To",
               comment: "Label of the iPhone reader's button that opens the Go To sheet, and that sheet's title.")
    }

    /// Go To's hint.
    static var goToHint: String {
        String(localized: "Goes to a page, a percent, or a time.",
               comment: "Hint of the iPhone reader's Go To button.")
    }

    /// Return's hint. The Mac's "Go back to where you were before browsing
    /// headings or bookmarks" is too narrow for a phone, where every jump
    /// keeps the place.
    static var returnHint: String {
        String(localized: "Goes back to where the last jump began.",
               comment: "Hint of the iPhone reader's Return button.")
    }

    /// Sleep Timer's hint.
    static var sleepTimerHint: String {
        String(localized: "Opens the sleep timer.",
               comment: "Hint of the iPhone reader's Sleep Timer button.")
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
        let place = String(localized: "\(number) of \(position.count)",
                           comment: "Value of the iPhone reader's Headings button: the place of the heading among the book's headings. %1$lld is the heading's number and %2$lld how many headings the book has.")
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
                ? String(localized: "End of the book.",
                         comment: "What the iPhone reader says when a move forward by a length of time has nothing left to move to.")
                : String(localized: "Start of the book.",
                         comment: "What the iPhone reader says when a move back by a length of time has nothing before it.")
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
        String(localized: "\(TimeFormatting.spoken(time)) in",
               comment: "Part of the iPhone reader's Where Am I? for an audiobook: how far into the recording the place is. %@ is the time in words, as in \"2 hours, 13 minutes in\".")
    }

    // MARK: Nothing That Way, One Sentence for Each Unit

    /// "No next sentence.", and the like, for a structural `unit`: whole
    /// sentences, so each language keeps its own order and agreement.
    private static func nothingNext(_ unit: SkipUnit) -> String {
        switch unit {
        case .paragraph:
            String(localized: "No next paragraph.", comment: "What the iPhone reader says when a move forward by paragraph has no next paragraph.")
        case .page:
            String(localized: "No next page.", comment: "What the iPhone reader says when a move forward by page has no next page.")
        case .heading:
            String(localized: "No next heading.", comment: "What the iPhone reader says when a move forward by heading has no next heading.")
        case .subheading:
            String(localized: "No next subheading.", comment: "What the iPhone reader says when a move forward by subheading has no next subheading.")
        case .bookmark:
            String(localized: "No next bookmark.", comment: "What the iPhone reader says when a move forward by bookmark has no next bookmark.")
        default:
            String(localized: "No next sentence.", comment: "What the iPhone reader says when a move forward by sentence has no next sentence.")
        }
    }

    /// "No previous sentence.", and the like, for a structural `unit`.
    private static func nothingPrevious(_ unit: SkipUnit) -> String {
        switch unit {
        case .paragraph:
            String(localized: "No previous paragraph.", comment: "What the iPhone reader says when a move back by paragraph has no previous paragraph.")
        case .page:
            String(localized: "No previous page.", comment: "What the iPhone reader says when a move back by page has no previous page.")
        case .heading:
            String(localized: "No previous heading.", comment: "What the iPhone reader says when a move back by heading has no previous heading.")
        case .subheading:
            String(localized: "No previous subheading.", comment: "What the iPhone reader says when a move back by subheading has no previous subheading.")
        case .bookmark:
            String(localized: "No previous bookmark.", comment: "What the iPhone reader says when a move back by bookmark has no previous bookmark.")
        default:
            String(localized: "No previous sentence.", comment: "What the iPhone reader says when a move back by sentence has no previous sentence.")
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
