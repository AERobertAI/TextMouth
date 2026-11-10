import Foundation

/// Every word and trait of every reader control, for a plain state (the
/// spec's sections under "The reader", from "Book content" to "Skip
/// backward, Skip forward").
///
/// Pure: the same state always gives the same words, so the Mac's test host
/// checks each sentence. `PhoneControl`, on iOS, reads these at the moment
/// VoiceOver asks, so nothing is pushed to VoiceOver as the book plays
/// (principle 3), and nothing here uses the updates-frequently trait.
@MainActor
enum PhoneReaderControls {
    /// What VoiceOver reads of `control` in `state`.
    static func description(of control: PhoneReaderControl, in state: PhoneReaderState) -> PhoneControlDescription {
        switch control {
        case .bookContent:
            return PhoneControlDescription(
                label: ReaderTextArea.accessibilityLabel,
                hint: state.isPlaying ? PhoneReaderWording.bookContentPlayingHint : PhoneReaderWording.bookContentPausedHint,
                traits: .staticText
            )
        case .play:
            return play(in: state)
        case .whereAmI:
            return PhoneControlDescription(
                label: state.isWhereAmISpeaking
                    ? ReaderWhereAmIToolbarButton.stopLabel
                    : ReaderWhereAmIToolbarButton.title,
                value: whereAmIValue(state.whereAmI),
                // Its answer is spoken by the app, as Play's book is.
                traits: [.button, .startsMediaSession],
                actions: [.whereAmIFullSummary, .copyReadingPosition]
            )
        case .navigationUnit:
            return PhoneControlDescription(
                label: PhoneReaderVocabulary.navigationUnit,
                value: state.unit.rawValue,
                hint: PhoneReaderWording.navigationUnitHint,
                traits: [.button, .adjustable]
            )
        case .speed:
            return speed(in: state)
        case .previousHeading:
            return PhoneControlDescription(
                label: ShortcutAction.previousHeading.title,
                hint: PhoneReaderWording.previousHeadingHint,
                traits: .button
            )
        case .nextHeading:
            return PhoneControlDescription(
                label: ShortcutAction.nextHeading.title,
                hint: PhoneReaderWording.nextHeadingHint,
                traits: .button
            )
        case .addBookmark:
            return PhoneControlDescription(
                label: state.isNearBookmark ? PhoneReaderVocabulary.removeBookmark : PhoneReaderVocabulary.addBookmark,
                traits: .button
            )
        case .bookmarks:
            return PhoneControlDescription(
                label: PhoneReaderVocabulary.bookmarks,
                // The count, left out at none.
                value: state.bookmarkCount > 0 ? CountWording.bookmarks(state.bookmarkCount) : "",
                hint: PhoneReaderWording.bookmarksHint,
                traits: .button
            )
        case .headings:
            return PhoneControlDescription(
                label: PhoneReaderVocabulary.headings,
                value: PhoneReaderWording.headingsValue(state.headingPosition),
                hint: PhoneReaderWording.headingsHint,
                traits: .button
            )
        case .searchInBook:
            return PhoneControlDescription(
                label: PhoneBookSearchVocabulary.title,
                hint: PhoneBookSearchVocabulary.buttonHint,
                traits: .button
            )
        case .goTo:
            return PhoneControlDescription(
                label: PhoneReaderWording.goTo,
                hint: PhoneReaderWording.goToHint,
                traits: .button
            )
        case .returnToPlace:
            return PhoneControlDescription(
                label: PhoneReaderVocabulary.returnToPreviousPosition,
                hint: PhoneReaderWording.returnHint,
                traits: .button
            )
        case .sleepTimer:
            return PhoneControlDescription(
                label: PhoneReaderVocabulary.sleepTimer,
                value: state.sleepTimerStatus.isEmpty ? PhoneReaderWording.sleepTimerOff : state.sleepTimerStatus,
                hint: PhoneReaderWording.sleepTimerHint,
                traits: .button
            )
        case .voice:
            return voice(in: state)
        case .bookInfo:
            return PhoneControlDescription(
                label: PhoneLibraryVocabulary.bookInfo,
                // The phone's library holds no feed items, so a book's
                // information is always its own to read.
                hint: FeedItemBookInfoWording.readerButtonLabel(readOnly: true),
                traits: .button
            )
        case .skipBackward:
            return PhoneControlDescription(label: PhoneReaderVocabulary.skipBackward(by: state.unit), traits: .button)
        case .skipForward:
            return PhoneControlDescription(label: PhoneReaderVocabulary.skipForward(by: state.unit), traits: .button)
        }
    }

    // MARK: - Play

    /// Play's words: "Play" or "Pause" by the Mac's rule; a value of
    /// "Loading" while the book loads, nothing while it plays, and while
    /// paused what the last move said; a hint naming the unit; and the trait
    /// that keeps VoiceOver quiet over the book only in the Play state, so
    /// that after Pause VoiceOver saying "Play" in the silence confirms it.
    private static func play(in state: PhoneReaderState) -> PhoneControlDescription {
        let value: String
        if state.isLoading {
            value = PhoneAppWording.loading
        } else if state.isPlaying {
            value = ""
        } else {
            value = state.moveWords ?? ""
        }
        var traits: PhoneControlTraits = [.button, .adjustable]
        if !state.isPlaying {
            traits.insert(.startsMediaSession)
        }
        return PhoneControlDescription(
            label: PhoneAppWording.playButton(isPlaying: state.isPlaying),
            value: value,
            hint: PhoneReaderWording.playHint(movingBy: state.unit),
            traits: traits
        )
    }

    // MARK: - Speed

    /// Speed's words: a text book's "Speed, 200 words per minute", stepping
    /// by 25; an audiobook's "Audio speed, 1.25 times speed", stepping by
    /// 0.1, both the Mac's.
    private static func speed(in state: PhoneReaderState) -> PhoneControlDescription {
        if state.isAudioBook {
            return PhoneControlDescription(
                label: BookSettingsWording.audioSpeedLabel,
                value: AudioSpeed.spokenLabel(for: state.audioSpeed),
                hint: AudioSpeed.stepHint(AudioSpeed.coarseStep),
                traits: .adjustable
            )
        }
        return PhoneControlDescription(
            label: PhoneVoiceVocabulary.speedLabel,
            value: PhoneReaderVocabulary.wordsPerMinute(state.wordsPerMinute),
            hint: PhoneReaderWording.textSpeedHint,
            traits: .adjustable
        )
    }

    // MARK: - Voice

    /// Voice's words, the Mac's: "Voice" with the hint "Change voice for this
    /// book" for a text book; "Audio Settings" for an audiobook, whose label
    /// says it all.
    private static func voice(in state: PhoneReaderState) -> PhoneControlDescription {
        let label = BookSettingsWording.buttonTitle(isAudioBook: state.isAudioBook)
        let macLabel = BookSettingsWording.buttonLabel(isAudioBook: state.isAudioBook)
        return PhoneControlDescription(
            label: label,
            hint: macLabel == label ? "" : macLabel,
            traits: .button
        )
    }

    // MARK: - Where Am I?

    /// Where Am I?'s value: the heading; the time left in it; the page; an
    /// audiobook's place in its recording; the percent; and the time left in
    /// the book: "The Battle, 12 minutes remaining in this heading, Page 112
    /// of 300, 30 percent, 3 hours remaining". A finished book says the
    /// Mac's "Finished" in place of the percent and the times left. Empty
    /// parts are dropped, so a missing heading is never an audible pause.
    static func whereAmIValue(_ parts: PhoneWhereAmIParts) -> String {
        var pieces: [String] = [parts.heading ?? ""]
        if parts.isFinished {
            pieces.append(parts.pageLabel)
            pieces.append(EndOfBookWording.finishedProgress)
        } else {
            pieces.append(parts.remainingInHeading.map(PhoneReaderVocabulary.remainingInHeading) ?? "")
            pieces.append(parts.pageLabel)
            pieces.append(parts.timeIntoRecording.map(PhoneReaderWording.timeIntoRecording) ?? "")
            pieces.append(PhoneReaderVocabulary.percent(parts.percentComplete))
            pieces.append(PhoneReaderVocabulary.remaining(parts.timeRemaining, speed: parts.speed))
        }
        return pieces.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    // MARK: - Book Content

    /// Book content's text while there's no passage to show: "Loading
    /// Moby-Dick" while the book loads, the Mac's words; for an audiobook
    /// with no transcript, "This audiobook has no text." and the heading
    /// being heard. Nil when the passage is the text.
    static func bookContentStandIn(in state: PhoneReaderState) -> String? {
        if state.isLoading {
            return PhoneReaderVocabulary.loading(state.bookTitle)
        }
        if state.isAudioBook, !state.hasTranscript {
            return PhoneReaderWording.audiobookHasNoText(heading: state.whereAmI.heading)
        }
        return nil
    }
}
