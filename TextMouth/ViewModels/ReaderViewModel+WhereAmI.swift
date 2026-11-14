import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import AVFoundation

// MARK: - Where Am I, Copy Reading Position, VoiceOver Announcements

extension ReaderViewModel {

    // MARK: - Where Am I?

    /// Handles a press of Where Am I? (`.brief`, the W key) or Where Am I?
    /// Full Summary (`.full`, W twice), as `SummaryPress` decides (FR12,
    /// section 3 of the design). An announcement speaks through a
    /// synthesizer of its own, so the book's engine state is preserved.
    /// - With no announcement speaking, the book pauses, if it plays, and
    ///   the summary pressed for speaks after the start sound: the brief one
    ///   (the heading, its number, the percentage, and the time left) or the
    ///   full one (adding the time left in the heading and the book's whole
    ///   time). The book resumes when it ends (`whereAmIAnnouncementFinished()`).
    /// - A brief press while an announcement speaks stops it, resuming the
    ///   book it paused or starting the play it held, as a command that
    ///   interrupts it does (`cancelWhereAmIIfActive()`); so does a full
    ///   press while the full summary speaks.
    /// - A full press while the brief summary speaks, the second press of W
    ///   twice, switches to the full summary, the book still paused until
    ///   the full one ends.
    ///
    /// No press depends on when the last one came: the three-second rule
    /// is retired (question 4), so W always speaks the brief summary.
    func whereAmI(_ detail: SummaryDetail = .brief) {
        switch SummaryPress.outcome(pressing: detail, while: isWhereAmISpeaking ? whereAmIDetail : nil) {
        case .stop:
            cancelWhereAmIIfActive()
        case .replace(with: let replacement):
            // The announcement goes on in more detail: the book stays as the
            // first left it, and no second start sound plays. It speaks on a
            // fresh synthesizer, the one saying the brief summary stopped and
            // let go with its delegate: an utterance handed to a synthesizer
            // just told to stop can be cancelled with what it was saying, and
            // that cancel, of the announcement speaking, would end the full
            // summary at once, taken for one nobody asked for, with the book
            // left paused.
            replaceWhereAmISynthesizer()
            speakWhereAmISummary(replacement)
        case .speak(let summary):
            #if os(iOS)
            // The announcement speaks through the app's audio session, which
            // must be the app's first (the engineer's review, F7).
            guard phoneHooks.audioMayStart() else { return }
            #endif
            pauseBookForWhereAmI()
            speakWhereAmISummary(summary)
        }
    }

    /// Begins an announcement: records whether the book plays, plays the
    /// start sound, and pauses the book if it plays.
    ///
    /// A book the announcement before still owes its resume, pressed for
    /// again within its end sound (`isWhereAmIResumePending`), is paused
    /// already and counts as playing: the new announcement takes the resume
    /// over and plays the book as it ends. Before, the book counted as not
    /// playing, and the first announcement's resume played it under the new
    /// one (REV11).
    private func pauseBookForWhereAmI() {
        let isPlaying: Bool
        if isAudioBook {
            isPlaying = audioPlaybackService.isPlaying && !audioPlaybackService.isPaused
        } else {
            isPlaying = speechService.isSpeaking && !speechService.isPaused
        }
        wasPlayingBeforeWhereAmI = isPlaying || isWhereAmIResumePending
        isWhereAmIResumePending = false

        soundEffectService?.play(for: .whereAmIStart)

        // Pause the book if it's currently playing (without the normal pause sound).
        // This deliberately bypasses ReaderViewModel.pause() — Where Am I is a
        // brief announcement (a few seconds), and we don't want it to fire the
        // pause sound effect, end the reading-stats session, or halt the sleep
        // timer countdown. The companion resume calls below are likewise direct;
        // an announcement that ends with the book left paused settles the pause
        // then (`settlePauseLeftByWhereAmI()`).
        if isPlaying {
            if isAudioBook {
                audioPlaybackService.pause()
            } else {
                speechService.pause()
            }
            nowPlayingService.updateNowPlayingInfo(
                title: book.title, author: book.author, isPlaying: false
            )
            savePosition()
        }
    }

    /// Speaks the `detail` summary of the position as it is now, or, with
    /// no book loaded, says so, and records which summary speaks.
    private func speakWhereAmISummary(_ detail: SummaryDetail) {
        whereAmIDetail = detail
        guard let content else {
            speakWhereAmI("No book is loaded.")
            return
        }
        speakWhereAmI(detail == .full ? buildFullWhereAmI(content: content) : buildBriefWhereAmI())
    }

    /// The page Where Am I? says (PG04): the reading position's "Page 112 of
    /// 300" (or "Before page 1") while the setting that adds the page is on,
    /// and nothing otherwise. A book without pages has no label to say, and
    /// a book of one page none worth saying (`hasSeveralPages`).
    var whereAmIPageLabel: String {
        settingsViewModel.saysPageInWhereAmI && hasSeveralPages ? currentPagePosition.label : ""
    }

    /// Brief summary: book title, current heading, heading number, the page
    /// (for a book with pages), percentage, and time remaining, then, for a
    /// transcribed audiobook, the sentence being heard.
    func buildBriefWhereAmI() -> String {
        let position = currentHeadingPosition
        return Self.briefWhereAmISummary(
            bookTitle: book.title,
            locationTitle: locationTitle(for: position, chapterIndex: currentChapterIndex),
            headingPosition: position,
            pageLabel: whereAmIPageLabel,
            percentComplete: percentComplete,
            timeRemaining: timeRemaining,
            isFinished: cursorRestsAtEnd,
            speed: namedListeningSpeed,
            heardSentence: heardTranscriptSentence
        )
    }

    /// Pure formatter for the brief announcement, shared with regression tests.
    /// Example: "Dune. The Battle. Heading 26 of 412. Page 112 of 300. 30 percent. 3 hours remaining."
    /// The page (`pageLabel`, PG04) follows the heading number; a book
    /// without pages, or the setting off, gives none, and the summary is as
    /// it was.
    /// A book resting at its end, finished (`isFinished`), says "Finished" in
    /// place of its percent and time left (TODO P07): "Dune. Appendix.
    /// Heading 40 of 40. Finished."
    /// With the setting that names the speed on (`speed`, P08), the time
    /// left says the speed it counts at: "3 hours remaining at 2.0 times
    /// speed"; nil, or an audiobook at 1x, says it as before.
    /// A transcribed audiobook's `heardSentence` follows, quoted as it is:
    /// "… 3 hours remaining. The salt road bends east."
    nonisolated static func briefWhereAmISummary(
        bookTitle: String,
        locationTitle: String?,
        headingPosition: HeadingPosition,
        pageLabel: String = "",
        percentComplete: Double,
        timeRemaining: TimeInterval,
        isFinished: Bool = false,
        speed: ReaderTimeWording.ListeningSpeed? = nil,
        heardSentence: String? = nil
    ) -> String {
        let progress = isFinished
            ? [EndOfBookWording.finishedProgress]
            : [
                String(format: "%.0f percent", percentComplete),
                "\(TimeFormatting.spoken(timeRemaining)) remaining\(ReaderTimeWording.spokenSpeed(speed))",
            ]
        let parts = whereAmILocationParts(
            bookTitle: bookTitle,
            locationTitle: locationTitle,
            headingPosition: headingPosition,
            pageLabel: pageLabel
        ) + progress
        return whereAmISummary(parts: parts, quoting: heardSentence)
    }

    /// Full summary: the brief summary's location, then time remaining in the
    /// book and in the current heading, and the total book time, then, for a
    /// book read from the reading list, where it stands in the list (FR09),
    /// and, for a transcribed audiobook, the sentence being heard.
    func buildFullWhereAmI(content: DocumentContent) -> String {
        let position = currentHeadingPosition
        return Self.fullWhereAmISummary(
            bookTitle: book.title,
            locationTitle: locationTitle(for: position, chapterIndex: currentChapterIndex),
            headingPosition: position,
            pageLabel: whereAmIPageLabel,
            percentComplete: percentComplete,
            timeRemaining: timeRemaining,
            timeRemainingInHeading: position.heading.flatMap { remainingTime(inHeading: $0, content: content) },
            totalTime: totalEstimatedTime,
            isFinished: cursorRestsAtEnd,
            speed: namedListeningSpeed,
            readingListPlace: readingListPlace,
            heardSentence: heardTranscriptSentence
        )
    }

    /// Pure formatter for the full announcement, shared with regression tests.
    /// The heading is named exactly once, followed by its number, so the
    /// listener never hears two different names for the same place. The page
    /// (`pageLabel`, PG04), for a book with pages while the setting is on,
    /// follows the heading number: "Dune. The Battle. Heading 26 of 412.
    /// Page 112 of 300. 30 percent through the book. …". A book
    /// read from the reading list says its place there after the times
    /// ("Reading list, book 3 of 12", FR09), the broader setting, which only
    /// this second announcement gives: the brief one is the quick check of
    /// a place in the book, pressed often while listening, and the window's
    /// title and header say the book is read from the list. A transcribed
    /// audiobook's `heardSentence` follows last. A book resting at its end,
    /// finished (`isFinished`), says "Finished" in place of its percent and
    /// the times left in the book and the heading, and still gives its
    /// whole time (TODO P07). With the setting that names the speed on
    /// (`speed`, P08), the book's time left and its total say the speed they
    /// count at ("at 2.0 times speed"); the heading's time left, said just
    /// after the book's, says none.
    nonisolated static func fullWhereAmISummary(
        bookTitle: String,
        locationTitle: String?,
        headingPosition: HeadingPosition,
        pageLabel: String = "",
        percentComplete: Double,
        timeRemaining: TimeInterval,
        timeRemainingInHeading: TimeInterval?,
        totalTime: TimeInterval,
        isFinished: Bool = false,
        speed: ReaderTimeWording.ListeningSpeed? = nil,
        readingListPlace: ReadingListPlace? = nil,
        heardSentence: String? = nil
    ) -> String {
        var parts = whereAmILocationParts(
            bookTitle: bookTitle,
            locationTitle: locationTitle,
            headingPosition: headingPosition,
            pageLabel: pageLabel
        )
        let namedSpeed = ReaderTimeWording.spokenSpeed(speed)
        if isFinished {
            parts.append(EndOfBookWording.finishedProgress)
        } else {
            parts.append(String(format: "%.0f percent through the book", percentComplete))
            parts.append("\(TimeFormatting.spoken(timeRemaining)) remaining\(namedSpeed)")
            if let timeRemainingInHeading {
                parts.append("\(TimeFormatting.spoken(timeRemainingInHeading)) remaining in this heading")
            }
        }
        parts.append("Total book time: \(TimeFormatting.spoken(totalTime))\(namedSpeed)")
        if let readingListPlace {
            parts.append(ReadingListReaderWording.place(readingListPlace))
        }
        return whereAmISummary(parts: parts, quoting: heardSentence)
    }

    /// Opening shared by both announcements: the book, the heading being read
    /// (empty when there is none to name), the heading number, and the page
    /// (empty when the book has none or the setting is off; empty parts are
    /// dropped when the summary is joined).
    private nonisolated static func whereAmILocationParts(
        bookTitle: String,
        locationTitle: String?,
        headingPosition: HeadingPosition,
        pageLabel: String
    ) -> [String] {
        [bookTitle, locationTitle ?? "", headingPosition.label, pageLabel]
    }

    /// Joins announcement fields into spoken sentences, dropping empty fields
    /// so a missing heading or label never becomes an audible pause, then
    /// quotes `heardSentence`, when there is one, after them as it is, with
    /// its own punctuation.
    nonisolated static func whereAmISummary(parts: [String], quoting heardSentence: String? = nil) -> String {
        let summary = parts.filter { !$0.isEmpty }.joined(separator: ". ") + "."
        guard let heardSentence, !heardSentence.isEmpty else { return summary }
        return summary + " " + heardSentence
    }

    // MARK: - The Transcript Sentence Being Heard

    /// The most words of the sentence being heard that Where Am I quotes. A
    /// recognizer's sentence can run on for a paragraph, and Where Am I is
    /// for finding one's place in a few seconds.
    nonisolated static let whereAmIQuoteWordLimit = 40

    /// For a transcribed audiobook (FR05), the transcript's sentence being
    /// heard at the cursor, as Where Am I quotes it (`whereAmIQuote(of:)`):
    /// the sentence the reader's text is shown around
    /// (`shownText(of:chapterIndex:cursorOffset:)`). Nil for any other
    /// book, before a chapter's first sentence, and in a chapter the
    /// transcript has no sentences for.
    var heardTranscriptSentence: String? {
        guard isAudioBook,
              let sentence = content?.transcript?.sentenceText(
                  atAudioOffset: currentCharacterOffset,
                  inChapter: currentChapterIndex
              ) else { return nil }
        return Self.whereAmIQuote(of: sentence)
    }

    /// `sentence` as Where Am I quotes it: its words, one space apart, as a
    /// sentence wrapped across lines is read; past `whereAmIQuoteWordLimit`
    /// words, the first that many and an ellipsis. Nil when it holds no
    /// words.
    nonisolated static func whereAmIQuote(of sentence: String) -> String? {
        let words = sentence.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return nil }
        guard words.count > whereAmIQuoteWordLimit else {
            return words.joined(separator: " ")
        }
        return words.prefix(whereAmIQuoteWordLimit).joined(separator: " ") + "…"
    }

    /// Time left in `heading` from the live cursor at the current speed, or
    /// nil when the heading spans no text to measure. The iPhone's Where Am
    /// I? value reads it too.
    func remainingTime(inHeading heading: Heading, content: DocumentContent) -> TimeInterval? {
        let totalHeadingChars = estimatedCharsInHeading(heading)
        guard totalHeadingChars > 0 else { return nil }
        let headingStart = content.globalOffset(chapterIndex: heading.chapterIndex, localOffset: heading.characterOffset)
        let elapsed = currentGlobalOffset - headingStart
        let fractionRemaining = max(0, 1.0 - Double(elapsed) / Double(totalHeadingChars))
        return timeEstimateForHeading(heading) * fractionRemaining
    }

    /// Whether a Where Am I announcement speaks, or one that ended by itself
    /// is still sounding its end (`isWhereAmIEndSoundPlaying`): the whole
    /// time audio must not start over it. A chapter's download or a package's
    /// move that ends in this time holds the audio for the end sound's work,
    /// which plays it once (`startPlayHeldByWhereAmI()`), as it would hold it
    /// while the announcement speaks. The places that ask it are the ones
    /// that start audio on their own, and must not start it over the sound:
    /// a chapter's download and a package's move that end
    /// (`ReaderViewModel+CloudDownload`, `ReaderViewModel+LibraryUpdates`),
    /// and the two plays that wait, the pause between chapters
    /// (`startChapterAfterPause()`) and the speech a play waits for
    /// (`continueWaitingPlay()`). Every other test of `isWhereAmISpeaking` is
    /// about the announcement itself.
    var isWhereAmISpeakingOrSoundingItsEnd: Bool {
        isWhereAmISpeaking || isWhereAmIEndSoundPlaying
    }

    /// Whether Where Am I? still has the book in hand: an announcement
    /// speaking, or one that ended by itself and resumes the book it paused
    /// once its end sound has played (`isWhereAmIResumePending`), starts the
    /// book for a Play pressed during it (`isPlayHeldByWhereAmI`), or plays
    /// an audiobook's chapter held for its end (`isChapterHeldByWhereAmI`),
    /// whose files came, or whose package's move ended, while it spoke.
    ///
    /// Nothing but Where Am I plays the book meanwhile: a Play waits for it
    /// (`holdPlayForWhereAmI()`), so a Play in the moment after an
    /// announcement ends, before its end sound has played, starts nothing
    /// then, and the book or the chapter starts once, as the end sound
    /// passes, with no play sound over it. Whatever pauses or stops the book
    /// ends what it holds without resuming it (`stopWhereAmIWithoutResuming()`,
    /// `endWhereAmIAsTheBookStops()`), and pauses a held chapter as it
    /// pauses any play waiting to start. A held chapter was once left out,
    /// and a Play in that moment started it at once, under the end sound,
    /// with the play sound (open after the where-am-i-followups merge).
    ///
    /// The end sound's window (`isWhereAmIEndSoundPlaying`) has no term of
    /// its own here: what the announcement leaves for it, a resume, a held
    /// Play or a held chapter, is counted already. A reader with none of
    /// these, one that was not playing when the announcement began, has
    /// nothing in Where Am I?'s hands, so a Play pressed in the window
    /// starts it at once, as it always did. A chapter's download or a
    /// package's move that ends in the window adds the held chapter
    /// (`isWhereAmISpeakingOrSoundingItsEnd`).
    var isWhereAmIUnderWay: Bool {
        isWhereAmISpeaking || isWhereAmIResumePending || isPlayHeldByWhereAmI || isChapterHeldByWhereAmI
    }

    /// Whether Where Am I? will play the book once it is over: the
    /// announcement speaking paused the book as it played, or one that
    /// ended by itself resumes it once its end sound has played, or a Play
    /// pressed during it, or a chapter whose files were downloaded, or whose
    /// package's move ended, during it (`isChapterHeldByWhereAmI`), waits
    /// for its end. The book counts as
    /// playing meanwhile, for the system's media commands (the Now Playing
    /// session's `isCurrentlyPlaying`) and for Next in Reading List, so that
    /// whatever pauses a playing book pauses this one too, for good (REV11).
    var whereAmIWillPlayBook: Bool {
        (isWhereAmISpeaking && wasPlayingBeforeWhereAmI) || isWhereAmIResumePending || isPlayHeldByWhereAmI
            || isChapterHeldByWhereAmI
    }

    /// Holds a Play pressed while Where Am I? has the book in hand
    /// (`isWhereAmIUnderWay`), so that the book starts once the announcement
    /// is over (`startPlayHeldByWhereAmI()`), as a play waiting for its
    /// chapter's speech is held: the Play waits for the announcement, as
    /// Play always has, where a Play for a book paused before the
    /// announcement was once dropped without a word (REV11).
    ///
    /// A Play for the book the announcement speaking paused is held too,
    /// though the announcement's end resumes that book anyway, which answers
    /// the Play (`resumeBookPausedForWhereAmI()`): a cancel nobody asked for
    /// ends the announcement without that resume, and the held Play then
    /// starts the book, where the cancel once dropped it (REV13's
    /// leftovers). A book whose resume an announcement that ended still
    /// owes, one a Play is held for already, a chapter held for the
    /// announcement's end, and a book playing or waiting to play need
    /// nothing held: each plays as the announcement ends, by itself or by a
    /// cancel, with no help from the Play.
    func holdPlayForWhereAmI() {
        let isPausedByTheAnnouncement = isWhereAmISpeaking && wasPlayingBeforeWhereAmI
        guard isPausedByTheAnnouncement || (!whereAmIWillPlayBook && !isPlaybackUnderWay) else {
            DiagnosticLog.trace(.playback, "play: Where Am I has the book in hand; it plays as the announcement ends")
            return
        }
        isPlayHeldByWhereAmI = true
        DiagnosticLog.trace(.playback, "play: Where Am I speaks; the book starts as it ends")
    }

    /// Cancel a Where Am I announcement if one is active, resuming book
    /// playback if it was playing before, or starting the play the
    /// announcement held (`startPlayHeldByWhereAmI()`). The book an
    /// announcement that ended by itself paused, whose resume waits for the
    /// end sound (`isWhereAmIResumePending`), resumes at once, so that the
    /// command acts on the book playing, as it would a moment later.
    /// Used by skips and every jump (`navigateTo(chapterIndex:characterOffset:)`)
    /// to cleanly interrupt an announcement, by a book continuing to this
    /// one (`claimAutoplayRequest()`), and by a press of Where Am I? that
    /// stops one (`whereAmI(_:)`).
    func cancelWhereAmIIfActive() {
        guard isWhereAmIUnderWay else { return }
        silenceWhereAmI()
        // The book the announcement paused as it played resumes, as does one
        // whose resume an announcement that ended by itself still owes.
        if wasPlayingBeforeWhereAmI || isWhereAmIResumePending {
            wasPlayingBeforeWhereAmI = false
            isWhereAmIResumePending = false
            resumeBookPausedForWhereAmI()
        }
        startPlayHeldByWhereAmI()
    }

    /// How long after a Where Am I announcement ends by itself the book
    /// resumes, or the play it held starts: long enough for the end sound
    /// to play first.
    nonisolated static let whereAmIEndSoundDelay: TimeInterval = 0.3

    /// Speak a Where Am I announcement using the dedicated synthesizer (not the book reader).
    /// Sets up a delegate that hears how the announcement ends: a finish
    /// resumes book playback, and a cancel the reader did not ask for ends
    /// the announcement without it (`whereAmISynthesizerCancelled(_:)`).
    func speakWhereAmI(_ text: String) {
        stopWhereAmISynthesizer()

        // Set self as delegate via the WhereAmIDelegateHelper
        let delegate = WhereAmIDelegateHelper(
            onFinished: { [weak self] finished in self?.whereAmISynthesizerFinished(finished) },
            onCancelled: { [weak self] cancelled in self?.whereAmISynthesizerCancelled(cancelled) }
        )
        self.whereAmIDelegate = delegate
        whereAmISynth.delegate = delegate

        // Guarded like the book's own speech: the announcement quotes the
        // book, and the engine reads tag-shaped text as markup.
        let utterance = AVSpeechUtterance(string: SpeechMarkupGuard.neutralized(text))
        utterance.voice = speechService.currentVoice
        utterance.rate = SpeechService.rateForWPM(speechService.wordsPerMinute)
        utterance.prefersAssistiveTechnologySettings = false

        isWhereAmISpeaking = true
        liveWhereAmIUtterance = utterance
        handWhereAmIToSynthesizer(utterance)
    }

    /// Hands `utterance` to the Where Am I synthesizer, or to the test's
    /// recorder in its place (`_whereAmIUtteranceRecorderForTesting`).
    private func handWhereAmIToSynthesizer(_ utterance: AVSpeechUtterance) {
        if let record = _whereAmIUtteranceRecorderForTesting {
            record(utterance)
        } else {
            whereAmISynth.speak(utterance)
        }
    }

    /// Silences the Where Am I synthesizer because the reader asked: a
    /// press while an announcement speaks, a command that interrupts it, a
    /// new announcement, the book stopping, or the reader closing. The
    /// announcement speaking is forgotten first, so that the cancel the
    /// synthesizer then reports for it is known for one the reader asked
    /// for, handled where it was asked, once (`whereAmISynthesizerCancelled(_:)`).
    func stopWhereAmISynthesizer() {
        liveWhereAmIUtterance = nil
        whereAmISynth.stopSpeaking(at: .immediate)
    }

    /// Silences an announcement speaking, as the reader asks
    /// (`stopWhereAmISynthesizer()`), and records that none speaks: what
    /// the announcement holds of the book, the book it paused, the resume
    /// it owes, or a Play or a chapter it held, is the caller's to settle.
    /// Nothing happens while none speaks. Every end of an announcement the
    /// reader makes goes through here: a command that interrupts it
    /// (`cancelWhereAmIIfActive()`), anything that pauses the book
    /// (`stopWhereAmIWithoutResuming()`), and the book stopping
    /// (`endWhereAmIAsTheBookStops()`).
    func silenceWhereAmI() {
        guard isWhereAmISpeaking else { return }
        stopWhereAmISynthesizer()
        isWhereAmISpeaking = false
    }

    /// The synthesizer says `finished` ended by itself, on the main queue.
    /// When it is the announcement speaking, the announcement ends as one
    /// that finished does (`whereAmIAnnouncementFinished()`); the end of
    /// one the reader stopped or replaced since is ignored, so it can
    /// neither play the end sound again nor end a newer announcement.
    func whereAmISynthesizerFinished(_ finished: ReportedUtterance) {
        guard isLiveWhereAmIUtterance(finished) else { return }
        liveWhereAmIUtterance = nil
        whereAmIAnnouncementFinished()
    }

    /// The synthesizer says `cancelled` was cancelled, on the main queue
    /// (#1296). A cancel the reader asked for, of an utterance it forgot as
    /// it stopped it (`stopWhereAmISynthesizer()`), was handled where it
    /// was asked and changes nothing here.
    ///
    /// A cancel of the announcement speaking, which the reader did not ask
    /// for, as when the speech engine refuses its text, ends it without the
    /// end sound or the resume a finished announcement makes: the book it
    /// paused stays paused, its pause settled (`endWhereAmIWithoutResuming()`),
    /// so Play/Pause works at once instead of only ending an announcement
    /// nobody hears. Its synthesizer is replaced, since one the engine
    /// refused never speaks again, as the speech service replaces its own.
    ///
    /// Every play that waited for the announcement starts as its end would
    /// have started it, now that it has ended (`startPlayHeldByWhereAmI()`):
    /// a Play pressed during it (`isPlayHeldByWhereAmI`) starts the book as
    /// Play does, the book the announcement paused included, which a Play
    /// asked for; an audiobook's chapter whose files came during it
    /// (`isChapterHeldByWhereAmI`) plays; and a play waiting for its
    /// chapter's speech starts from the cursor, at once when the speech is
    /// ready, or as soon as it is. A play still waiting for its chapter's
    /// files goes on waiting, and plays once they are here. Each was the
    /// listener's own and waited only for the announcement. The cancel once
    /// let the held Play go with the rest, dropping it without a word
    /// (REV12), and then paused a play that was waiting, as Play/Pause
    /// does, so a Play pressed just before the announcement was lost (REV13).
    func whereAmISynthesizerCancelled(_ cancelled: ReportedUtterance) {
        guard isLiveWhereAmIUtterance(cancelled) else { return }
        let playWaits = isPlayHeldByWhereAmI || isChapterHeldByWhereAmI || isPlaybackUnderWay
        DiagnosticLog.event(
            .playback,
            "WHERE_AM_I_CANCEL_UNEXPECTED: the announcement was cancelled before it ended; synthesizer replaced, "
                + (playWaits ? "the play that waited for it goes on as at its end" : "book left paused")
        )
        liveWhereAmIUtterance = nil
        replaceWhereAmISynthesizer()
        endWhereAmIWithoutResuming()
        startPlayHeldByWhereAmI()
    }

    /// Whether `reported` is the announcement speaking now
    /// (`liveWhereAmIUtterance`).
    private func isLiveWhereAmIUtterance(_ reported: ReportedUtterance) -> Bool {
        liveWhereAmIUtterance.map(ObjectIdentifier.init) == reported.id
    }

    /// Replaces the Where Am I synthesizer with a fresh one, the old one
    /// stopped and its delegate let go, so that nothing it still reports
    /// reaches the reader. The next announcement gives the fresh one its
    /// delegate (`speakWhereAmI(_:)`).
    private func replaceWhereAmISynthesizer() {
        whereAmISynth.delegate = nil
        whereAmISynth.stopSpeaking(at: .immediate)
        whereAmISynth = AVSpeechSynthesizer()
    }

    /// End a Where Am I announcement that finished by itself: play the end
    /// sound, then, once it has played (`whereAmIEndSoundDelay`), resume
    /// the book the announcement paused, or start the play it held
    /// (`resumeAfterWhereAmIEndSound()`). The synthesizer's delegate calls
    /// it on the main queue, for the announcement speaking
    /// (`whereAmISynthesizerFinished(_:)`); tests call it in the
    /// announcement's place.
    ///
    /// The end sound plays for `whereAmIEndSoundDelay`, a window in which the
    /// announcement no longer speaks but still has the book
    /// (`isWhereAmIEndSoundPlaying`): a chapter's download or a package's
    /// move that ends then holds its audio for the end sound's work, as one
    /// that ends while the announcement speaks does, and the audio plays
    /// once, after the sound.
    ///
    /// Until the book resumes, the resume is owed (`isWhereAmIResumePending`)
    /// and the book counts as playing (`whereAmIWillPlayBook`), so whatever
    /// pauses or stops the book in that moment, a sleep timer running out,
    /// a Pause from the AirPods or their leaving, a recording or another
    /// book starting, takes the resume, and the pause stands. Before, the
    /// book counted as paused then, nothing paused it, and it resumed
    /// anyway: after a sleep timer, at full volume and with no timer (REV11).
    func whereAmIAnnouncementFinished() {
        isWhereAmISpeaking = false
        soundEffectService?.play(for: .whereAmIEnd)
        // The book the announcement paused as it played resumes once the
        // end sound has played; a book paused or stopped before it stays as
        // it was, unless a Play was held for it.
        if wasPlayingBeforeWhereAmI {
            wasPlayingBeforeWhereAmI = false
            isWhereAmIResumePending = true
        }
        // The window opens; the work below closes it.
        isWhereAmIEndSoundPlaying = true
        #if os(iOS)
        // Nothing of the book plays while the end sound does, and the book it
        // paused resumes only after it.
        phoneHooks.silentGapBegan?()
        #endif
        afterWhereAmIEndSound { [weak self] in
            self?.resumeAfterWhereAmIEndSound()
        }
    }

    /// Runs `work` once the end sound of an announcement that ended by
    /// itself has played: on the main queue after `whereAmIEndSoundDelay`,
    /// or when a test runs it (`_afterWhereAmIEndSoundForTesting`).
    private func afterWhereAmIEndSound(_ work: @escaping @MainActor @Sendable () -> Void) {
        if let takeWork = _afterWhereAmIEndSoundForTesting {
            takeWork(work)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.whereAmIEndSoundDelay) {
            work()
        }
    }

    /// What an announcement that ended by itself leaves for once its end
    /// sound has played: the book it paused resumes, unless whatever settled
    /// the book meanwhile took the resume (`isWhereAmIResumePending`), and
    /// the play it held starts (`startPlayHeldByWhereAmI()`).
    private func resumeAfterWhereAmIEndSound() {
        // The end sound has played: audio may start again.
        isWhereAmIEndSoundPlaying = false
        if isWhereAmIResumePending {
            isWhereAmIResumePending = false
            resumeBookPausedForWhereAmI()
        }
        // Asked only now: a pause, or another announcement, since the
        // end leaves no play to start.
        startPlayHeldByWhereAmI()
    }

    /// Settles the pause a Where Am I announcement made, now that the
    /// announcement ends with the book left paused: by Play/Pause or a
    /// pause during it, or before the resume it owes once it has ended, or
    /// by a cancel nobody asked for (`endWhereAmIWithoutResuming()`). The
    /// announcement paused the book without the rest of a pause, expecting
    /// to resume it seconds later; left paused, the book gets the rest now,
    /// as `pause()` would have given it: the listening session ends, a
    /// minutes sleep timer's countdown waits for Play, the stop is recorded
    /// for rewind-on-resume, and an audiobook shows paused, so its
    /// Play/Pause button says Play rather than Pause. Its place was saved,
    /// and Now Playing told, as the announcement paused it.
    func settlePauseLeftByWhereAmI() {
        sleepTimerService.pauseCountdown(by: readerID)
        readingStatsService.endSession(bookID: book.id)
        recordPlaybackStopped()
        // An audiobook's Playing state is the reader's own, which the
        // announcement's direct pause left showing Playing; still loaded,
        // it shows paused, as `pause()` leaves it. A text book's follows
        // its speech service, which shows the pause already.
        if isAudioBook, audioPlaybackService.isPaused {
            isCurrentlyPlaying = true
            isCurrentlyPaused = true
        }
    }

    /// Ends a Where Am I announcement as the book stops: by `stop()`, which
    /// Release Media Controls, Edit Text, a chapter that cannot be
    /// downloaded, and closing the window all go through, or by a playback
    /// failure, which stops the book as `stop()` does. An announcement
    /// speaking is silenced, and the book it paused is forgotten, as are the
    /// resume one that ended by itself still owes and a Play or a downloaded
    /// chapter held for its end, so that nothing resumes or starts the
    /// stopped book, nor tells Now Playing that it plays, when the
    /// announcement would have ended. The stop does the rest itself: it
    /// closes the listening session, takes the book out of Now Playing, and
    /// records the stop.
    ///
    /// Left speaking, the announcement resumed nothing as it ended, the book
    /// being stopped, but told Now Playing that the book played: a book that
    /// had just let go of the media controls (Shift-R) took the AirPods back,
    /// and Shift-R then said it did not hold them (REV11).
    func endWhereAmIAsTheBookStops() {
        silenceWhereAmI()
        wasPlayingBeforeWhereAmI = false
        isWhereAmIResumePending = false
        isPlayHeldByWhereAmI = false
        isChapterHeldByWhereAmI = false
    }

    /// Resume the book a Where Am I announcement paused, as it was paused:
    /// directly, without the play sound or a new listening session, and
    /// tell Now Playing it plays again once it does. A Play pressed for the
    /// book during the announcement (`isPlayHeldByWhereAmI`) is answered by
    /// the resume and let go.
    ///
    /// A book whose playback would not resume, its speech or its player
    /// gone since the announcement paused it, plays nothing, so the system
    /// is told nothing: told the book played, it would send the AirPods to
    /// a book that plays nothing. The book is left paused, its pause settled
    /// as one left by an announcement that ends without resuming
    /// (`settlePauseLeftByWhereAmI()`), and the next Play starts it afresh:
    /// a Play held for it then starts it so at once (`startPlayHeldByWhereAmI()`).
    ///
    /// A book whose output changed during the announcement, as when AirPods
    /// connect, or whose files the library moved meanwhile, is marked to be
    /// played afresh (`restartPlaybackBackendOnNextResume`), since its paused
    /// engine, synthesizer, or player may stay bound to the old output or
    /// files. It plays on afresh from the cursor instead, as Play's resume
    /// plays such a book (`restartPlaybackAtCursor()`): a text book in direct
    /// speech, the voice, never moved to rendered audio. Before, this resume
    /// took up the paused backend whatever the mark said, so a book playing
    /// rendered audio could resume on the output it began on (REV13's
    /// leftovers).
    private func resumeBookPausedForWhereAmI() {
        guard !restartPlaybackBackendOnNextResume else {
            DiagnosticLog.trace(.playback, "Where Am I ended; the book's output or files changed during it, so it plays on afresh from the cursor")
            isPlayHeldByWhereAmI = false
            restartPlaybackAtCursor()
            return
        }
        let resumed = isAudioBook ? audioPlaybackService.resume() : speechService.resume()
        guard resumed else {
            DiagnosticLog.event(
                .playback,
                "WHERE_AM_I_RESUME_REJECTED: the book the announcement paused would not resume; left paused"
            )
            settlePauseLeftByWhereAmI()
            return
        }
        isPlayHeldByWhereAmI = false
        nowPlayingService.updateNowPlayingInfo(
            title: book.title, author: book.author, isPlaying: true
        )
    }

    // MARK: - Heading Location

    /// Heading-based location of the live reading cursor, used by Where Am I,
    /// the copied reading position, and navigation announcements.
    var currentHeadingPosition: HeadingPosition {
        HeadingPosition(in: headings, chapterIndex: currentChapterIndex, characterOffset: currentCharacterOffset)
    }

    /// Heading-based location of the throttled display cursor. The reader
    /// header reads it, so the header follows playback across headings
    /// without re-rendering on every spoken word.
    var displayHeadingPosition: HeadingPosition {
        HeadingPosition(in: headings, chapterIndex: displayChapterIndex, characterOffset: displayCharacterOffset)
    }

    /// Name for `position`, which lies in content unit `chapterIndex`: the
    /// containing heading's text, or for a book without headings that unit's
    /// own title (see `HeadingPosition.title(contentTitle:bookTitle:)`).
    func locationTitle(for position: HeadingPosition, chapterIndex: Int) -> String? {
        let chapters = content?.chapters ?? []
        let contentTitle = chapters.indices.contains(chapterIndex) ? chapters[chapterIndex].title : nil
        return position.title(contentTitle: contentTitle, bookTitle: book.title)
    }

    /// Find the heading at or before the current reading position
    func currentHeadingAtPosition() -> Heading? {
        currentHeadingPosition.heading
    }

    /// Estimated character count for a heading section (from heading start to next heading or end of book)
    func estimatedCharsInHeading(_ heading: Heading) -> Int {
        guard let content = content else { return 0 }
        let allHeadings = headings
        let headingGlobalStart = content.globalOffset(chapterIndex: heading.chapterIndex, localOffset: heading.characterOffset)
        var nextOffset = content.totalCharacterCount
        if let idx = allHeadings.firstIndex(where: { $0.id == heading.id }),
           idx + 1 < allHeadings.count {
            let next = allHeadings[idx + 1]
            nextOffset = content.globalOffset(chapterIndex: next.chapterIndex, localOffset: next.characterOffset)
        }
        return nextOffset - headingGlobalStart
    }

    // MARK: - Copy Reading Position

    /// Copy a formatted summary of the current reading position to the system clipboard
    func copyReadingPosition() {
        guard content != nil else { return }

        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(readingPositionText, forType: .string)
        #else
        // iOS's pasteboard replaces its contents when a string is set.
        UIPasteboard.general.string = readingPositionText
        #endif
        announceToVoiceOver("Reading position copied to clipboard")
    }

    /// The reading position as Copy Reading Position copies it
    /// (`readingPositionSummary`): the book, its heading, its percent, the
    /// place's time on the book's clock, which Go to Time takes back ("at
    /// 2:13:05 of 9:41:07 in the recording", P08), and its time left, naming
    /// the speed while the setting asks for it; "Finished" for a book
    /// resting at its end. Tests read it without the pasteboard.
    var readingPositionText: String {
        let position = currentHeadingPosition
        return Self.readingPositionSummary(
            bookTitle: book.title,
            author: book.author,
            locationTitle: locationTitle(for: position, chapterIndex: currentChapterIndex),
            headingPosition: position,
            percentComplete: percentComplete,
            formattedTimeRemaining: formattedTimeRemaining,
            isFinished: cursorRestsAtEnd,
            place: copiedPlace,
            speed: namedListeningSpeed
        )
    }

    /// The reading position's place as Copy Reading Position names it (P08,
    /// `ReaderTimeWording.copiedPlace`): its time on the book's clock and the
    /// clock's whole length; nil before the book's content loads.
    private var copiedPlace: String? {
        guard let clock = placeClock else { return nil }
        return ReaderTimeWording.copiedPlace(
            clock.time(chapterIndex: currentChapterIndex, characterOffset: currentCharacterOffset),
            of: clock.length,
            timeCount
        )
    }

    /// Pure formatter for the copied reading position, using the same heading
    /// vocabulary as Where Am I. Example:
    /// "My Book | by An Author | The Battle | Heading 26 of 412 | 30.0% through | 3:00:00 remaining"
    /// The place (`place`, P08) goes between the percent and the time left:
    /// "… | 22.9% through | at 2:13:05 of 9:41:07 in the recording | 3:44:01
    /// remaining". With the setting that names the speed on (`speed`), the
    /// time left says it: "3:44:01 remaining at 2.0x"; nil, or an audiobook
    /// at 1x, leaves it as before.
    /// A book resting at its end, finished (`isFinished`), says "Finished" in
    /// place of its percent, place, and time left (TODO P07): "Dune | by
    /// Frank Herbert | Appendix | Heading 40 of 40 | Finished".
    nonisolated static func readingPositionSummary(
        bookTitle: String,
        author: String,
        locationTitle: String?,
        headingPosition: HeadingPosition,
        percentComplete: Double,
        formattedTimeRemaining: String,
        isFinished: Bool = false,
        place: String? = nil,
        speed: ReaderTimeWording.ListeningSpeed? = nil
    ) -> String {
        let progress = isFinished
            ? [EndOfBookWording.finishedProgress]
            : [
                String(format: "%.1f%% through", percentComplete),
                place ?? "",
                "\(formattedTimeRemaining) remaining\(ReaderTimeWording.shownSpeed(speed))",
            ]
        return readingPositionSummary(parts: [
            bookTitle,
            author.isEmpty ? "" : "by \(author)",
            locationTitle ?? "",
            headingPosition.label,
        ] + progress)
    }

    /// Joins copied-position fields with " | ", dropping empty fields and the
    /// placeholder "Unknown" author.
    nonisolated static func readingPositionSummary(parts: [String]) -> String {
        parts.filter { !$0.isEmpty && $0 != "by \(Book.unknownAuthor)" }.joined(separator: " | ")
    }

    // MARK: - VoiceOver Announcement

    /// Post a VoiceOver announcement from the key (or main) window with high
    /// priority, and remember it in `lastAnnouncement` for tests.
    func announceToVoiceOver(_ message: String) {
        postAnnouncement(message, priority: .high)
    }

    /// Post a VoiceOver announcement with medium priority, which VoiceOver
    /// speaks after what it is saying rather than over it, and remember it
    /// in `lastAnnouncement` for tests.
    func announceToVoiceOverAfterCurrentSpeech(_ message: String) {
        postAnnouncement(message, priority: .medium)
    }

    /// Post `message` from the key (or main) window at `priority`, and
    /// remember it in `lastAnnouncement`.
    private func postAnnouncement(_ message: String, priority: NSAccessibilityPriorityLevel) {
        lastAnnouncement = message
        VoiceOverAnnouncer.announce(message, priority: priority)
    }
}
