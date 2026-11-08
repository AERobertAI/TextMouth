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
        "Moves back or forward by \(PhoneNavigationUnits.lowercasedName(of: unit))."
    }

    // MARK: Navigation Unit and Speed

    /// Navigation unit's hint.
    static let navigationUnitHint = "Chooses what Play and the skip buttons move by."

    /// A text book's speed control's label. An audiobook's is the Mac's
    /// `BookSettingsWording.audioSpeedLabel`.
    static let speedLabel = "Speed"

    /// A text book's speed control's hint, naming the Mac's step of 25 words
    /// per minute (`ReaderViewModel.speechSpeedStep`). An audiobook's is the
    /// Mac's `AudioSpeed.stepHint(_:)`. On the main actor, where the reader's
    /// step lives.
    @MainActor
    static var textSpeedHint: String {
        "Changes the speed in steps of \(Int(ReaderViewModel.speechSpeedStep)) words per minute."
    }

    // MARK: The Heading Buttons

    /// Previous Heading's hint.
    static let previousHeadingHint = "Moves to the heading before, leaving the navigation unit as it is."

    /// Next Heading's hint.
    static let nextHeadingHint = "Moves to the next heading, leaving the navigation unit as it is."

    // MARK: Book Content

    /// Book content's hint while paused, when activating plays from VoiceOver's
    /// place in the text.
    static let bookContentPausedHint = "Plays from here."

    /// Book content's hint while the book plays, when activating brings the
    /// text to the sentence being spoken.
    static let bookContentPlayingHint = "Brings the text to the sentence being spoken."

    /// Book content's text for an audiobook with no transcript: "This
    /// audiobook has no text. The Battle.", giving the heading being heard
    /// when there is one. Its chapters are spaces, which a reader must not be
    /// shown.
    static func audiobookHasNoText(heading: String?) -> String {
        let sentence = "This audiobook has no text."
        guard let heading = heading?.nonBlank else { return sentence }
        return "\(sentence) \(Self.sentence(heading))"
    }

    /// The question before Add bookmark removes a bookmark that has a note:
    /// "Remove Bookmark 3?", with the note as its message.
    static func removeBookmarkTitle(_ bookmark: Bookmark) -> String {
        "Remove Bookmark \(bookmark.number)?"
    }

    /// The question's button that removes the bookmark.
    static let remove = "Remove"

    /// The name of Book content's rotor that moves by sentence.
    static let sentencesRotor = "Sentences"

    /// The name of Play's rotor that moves by page.
    static let pagesRotor = "Pages"

    // MARK: The Grid's Buttons

    /// Bookmarks' hint.
    static let bookmarksHint = "Opens the list of bookmarks."

    /// Headings' hint.
    static let headingsHint = "Opens the list of headings."

    /// The Go To button's label.
    static let goTo = "Go To"

    /// Go To's hint.
    static let goToHint = "Goes to a page, a percent, or a time."

    /// Return's hint. The Mac's "Go back to where you were before browsing
    /// headings or bookmarks" is too narrow for a phone, where every jump
    /// keeps the place.
    static let returnHint = "Goes back to where the last jump began."

    /// Sleep Timer's hint.
    static let sleepTimerHint = "Opens the sleep timer."

    /// Sleep Timer's value while no timer runs.
    static let sleepTimerOff = "Off"

    /// Headings' value: the heading and its place among the book's headings,
    /// "The Battle, 26 of 412"; "26 of 412" for a heading with no words;
    /// the Mac's "Before heading 1 of 412" before the first; nothing for a
    /// book without headings.
    static func headingsValue(_ position: HeadingPosition) -> String {
        guard position.count > 0 else { return "" }
        guard let number = position.number else { return position.label }
        let place = "\(number) of \(position.count)"
        guard let text = position.headingText else { return place }
        return "\(text), \(place)"
    }

    // MARK: What a Move Says

    /// What a move says when there's nothing that way: "No next heading.",
    /// "No previous page.", with the unit's name in lower case; for a move by
    /// seconds, "Start of the book." or "End of the book.". The Mac says
    /// nothing here, but a press that does nothing must be told from a press
    /// that was missed.
    static func nothingThatWay(unit: SkipUnit, forward: Bool) -> String {
        if unit.isTimeBased {
            return forward ? "End of the book." : "Start of the book."
        }
        let direction = forward ? "next" : "previous"
        return "No \(direction) \(PhoneNavigationUnits.lowercasedName(of: unit))."
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
        "\(TimeFormatting.spoken(time)) in"
    }

    // MARK: Helpers

    /// `words` ended as a sentence: with a full stop unless it ends in one
    /// of its own, so a heading "Coda?" isn't read "Coda?.".
    private static func sentence(_ words: String) -> String {
        guard let last = words.last, !".!?…".contains(last) else { return words }
        return words + "."
    }
}
