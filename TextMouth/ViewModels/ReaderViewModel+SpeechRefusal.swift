#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - The Report of a Speech Refusal (B05)

extension ReaderViewModel {
    /// Where this reader's window stands for the listener now
    /// (`SpeechRefusalWindowStanding`), read from AppKit: as the report of a
    /// refusal comes, and as its sheet is made. A reader with no window, as
    /// in a test, stands behind.
    var speechRefusalWindowStanding: SpeechRefusalWindowStanding {
        let keyWindow = NSApp.keyWindow
        return .of(
            appIsActive: NSApp.isActive,
            windowIsKey: hostWindow.map { $0 === keyWindow } ?? false,
            windowHasSheet: hostWindow?.attachedSheet != nil,
            keyWindowIsItsSheet: hostWindow.map { keyWindow?.sheetParent === $0 } ?? false
        )
    }

    /// Shows the report of `refusal`, which stopped this reader's speech
    /// where the cursor now is because the Mac's speech engine refused a
    /// passage twice (B05), and tells the listener once. The report joins
    /// what the reader knows of the place (the book, the position as Where
    /// Am I? says it, the chapter, and the chapter's text as the book has
    /// it) to what speech handed over, and takes the place of any report
    /// shown, counting the refusals at its place
    /// (`SpeechRefusalAlert.show(_:)`). One line, of offsets only, records
    /// it in speech's log, after the line that ended speech.
    ///
    /// The listener hears one message, not two that talk over each other:
    /// the sheet's own, VoiceOver moving to it, when it opens at once in
    /// front of the listener; anywhere else, where the sheet waits on its
    /// window or is open already, `SpeechRefusalWording.announcement`.
    ///
    /// A refusal comes only while a chapter of a text book speaks, so the
    /// chapter's text is always there; were it not, no report could be
    /// made, and the listener would hear speech's own announcement.
    func showSpeechRefusalReport(_ refusal: SpeechRefusal) {
        // Read before the report changes, which opens the sheet.
        let standing = speechRefusalWindowStanding
        guard let report = makeSpeechRefusalReport(of: refusal) else {
            VoiceOverAnnouncer.announce(SpeechService.engineRefusedAnnouncement, from: hostWindow)
            return
        }
        speechRefusalAlert.show(report)
        let announced = !standing.sheetSpeaksForItself
        if announced {
            VoiceOverAnnouncer.announce(SpeechRefusalWording.announcement, from: hostWindow)
        }
        let shown = speechRefusalAlert.report ?? report
        DiagnosticLog.event(
            .playback,
            "SPEECH_REFUSAL_REPORTED: chapter=\(shown.chapterIndex) offset=\(shown.chapterOffset) "
                + "spokenOffset=\(refusal.offset) chunkStart=\(refusal.refusedRange.lowerBound) "
                + "chunkEnd=\(refusal.refusedRange.upperBound) timesHere=\(shown.timesRefusedHere) "
                + "announced=\(announced)",
            in: .speechTransitions
        )
    }

    /// Closes the report of a refusal. How often each place was refused is
    /// kept while the window is open.
    func closeSpeechRefusalReport() {
        speechRefusalAlert.report = nil
    }

    /// The report of `refusal`, which stopped speech in the cursor's
    /// chapter, made now; nil when the reader holds no text for that
    /// chapter.
    private func makeSpeechRefusalReport(of refusal: SpeechRefusal) -> SpeechRefusalReport? {
        guard let content, content.chapters.indices.contains(currentChapterIndex) else { return nil }
        let chapter = content.chapters[currentChapterIndex]
        // The speech's offsets count the chapter after the substitutions,
        // skipped sections, and pauses; the reader's map leads back to the
        // book's own text.
        let map = currentOffsetMap
        let position = currentHeadingPosition
        return SpeechRefusalReport(
            bookTitle: book.title,
            bookFormat: book.format.displayName,
            // Where Am I?'s own words, the book's title left to the report.
            position: Self.briefWhereAmISummary(
                bookTitle: "",
                locationTitle: locationTitle(for: position, chapterIndex: currentChapterIndex),
                headingPosition: position,
                percentComplete: percentComplete,
                timeRemaining: timeRemaining
            ),
            chapterIndex: currentChapterIndex,
            chapterCount: content.chapters.count,
            chapterTitle: chapter.title,
            chapterText: chapter.text,
            toChapterOffset: { map?.toOriginal($0) ?? $0 },
            refusal: refusal,
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            build: .current,
            time: Date()
        )
    }
}
