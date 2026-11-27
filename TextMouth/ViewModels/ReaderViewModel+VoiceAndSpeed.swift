import SwiftUI
import AVFoundation

// MARK: - Voice, Speed, Pitch, and Skip Sections

extension ReaderViewModel {

    // MARK: - Speed & Voice

    /// Words per minute added or removed by one text-book speed step.
    static let speechSpeedStep: Double = 25

    /// Use the same step for keyboard commands, menus, and playback buttons.
    /// Audio multipliers and speech WPM are different units: audio books move
    /// by `AudioSpeed.coarseStep`, text books by `speechSpeedStep` WPM.
    func stepSpeed(forward: Bool) {
        let step = isAudioBook ? AudioSpeed.coarseStep : Self.speechSpeedStep
        adjustSpeed(delta: forward ? step : -step)
    }

    /// VoiceOver label for the playback bar's speed buttons, stating the
    /// exact step `stepSpeed(forward:)` applies in this book's unit.
    func speedStepButtonLabel(forward: Bool) -> String {
        if isAudioBook {
            return AudioSpeed.stepButtonLabel(increasing: forward, by: AudioSpeed.coarseStep)
        }
        return VoiceAndSpeedWording.speedStepLabel(forward: forward, wordsPerMinute: Int(Self.speechSpeedStep))
    }

    /// Adjust TTS speed by a delta (e.g. +25 or -25 WPM).
    /// For audio books, delegates to adjustAudioSpeed instead.
    func adjustSpeed(delta: Double) {
        if isAudioBook {
            adjustAudioSpeed(delta: delta)
            return
        }
        let newWPM = max(speechService.minimumWPM, min(speechService.wordsPerMinute + delta, speechService.maximumWPM))
        speechService.setSpeedRealtime(newWPM)
        book.localWPM = speechService.wordsPerMinute
        saveLocalVoiceSettings()
        announceToVoiceOver(VoiceAndSpeedWording.speedAnnouncement(wordsPerMinute: Int(speechService.wordsPerMinute)))
    }

    /// Set pitch for this book (multiplier 0.5-2.0)
    func adjustPitch(to newPitch: Double) {
        speechService.setPitchRealtime(newPitch)
        book.localPitch = speechService.pitchMultiplier
        saveLocalVoiceSettings()
        let formatted = String(format: "%.1f", speechService.pitchMultiplier)
        announceToVoiceOver(VoiceAndSpeedWording.pitchAnnouncement(formatted))
    }

    /// Set voice for this book only. The next chapter, if already rendered
    /// ahead in the old voice, is rendered again in this one, and the voice
    /// is loaded ahead of Play.
    func setLocalVoice(_ voice: AVSpeechSynthesisVoice) {
        speechService.currentVoice = voice
        book.localVoiceID = voice.identifier
        saveLocalVoiceSettings()
        refreshLookAhead()
        warmUpVoice()
        announceToVoiceOver(VoiceAndSpeedWording.voiceChanged(to: voice.name))
    }

    /// Have the render queue load the voice speech uses now into the system
    /// synthesizer, ahead of Play: a session's first word otherwise waited
    /// 3 to 4.5 s while the voice loaded (PERF03). Each voice is loaded once
    /// per process, so asking again costs nothing. An audiobook speaks no
    /// chapters, so it loads nothing.
    func warmUpVoice() {
        guard !isAudioBook else { return }
        renderScheduler.warmUp(speechService.currentVoice)
    }

    /// Apply this book's saved voice, speed, and pitch overrides to the speech
    /// engine. Runs when the reader opens and again after global speech
    /// settings change, because per-book overrides take priority. A voice
    /// that changed either way also brings the look-ahead up to date, and the
    /// voice in effect is loaded ahead of Play.
    ///
    /// Audio books store their playback multiplier in `localWPM`, so their
    /// saved speed must never reach the speech engine: 1.25 would clamp to
    /// the 50 WPM minimum and make "Where Am I?" speak at a crawl. Voice and
    /// pitch mean the same thing for every format and are still applied.
    func applyLocalSpeechOverrides() {
        if !isAudioBook, let localWPM = book.localWPM {
            speechService.setSpeedRealtime(localWPM)
        }
        if let localPitch = book.localPitch {
            speechService.setPitchRealtime(localPitch)
        }
        if let localVoiceID = book.localVoiceID,
           let voice = AVSpeechSynthesisVoice(identifier: localVoiceID) {
            speechService.currentVoice = voice
        }
        // Speed and pitch are applied as the audio plays, so only a voice
        // other than the one the next chapter renders in makes the look-ahead
        // stale: each speed or pitch step in Settings, which every playing
        // reader hears, leaves a look-ahead in the voice in effect alone
        // (PERF02). The global voice may have changed before this runs, so
        // the look-ahead's own voice is what is compared. A look-ahead whose
        // render still waits for the lead (`lookAheadWait`) has no voice yet:
        // it renders in the voice in effect when it falls due, so no step
        // makes it stale.
        let lookAheadVoiceIsCurrent = lookAheadWait != nil || lookAhead.map {
            $0.signature.voiceIdentifier == speechService.currentVoice?.identifier
        } ?? false
        if !lookAheadVoiceIsCurrent {
            refreshLookAhead()
        }
        warmUpVoice()
    }

    /// Persist all local voice settings (voice, speed, pitch) to library and bookInfo
    func saveLocalVoiceSettings() {
        libraryViewModel.updateLocalVoiceAndSpeed(
            bookID: book.id,
            voiceID: book.localVoiceID,
            wpm: book.localWPM,
            pitch: book.localPitch
        )
    }

    /// Copy this book's local voice, speed, and pitch to the global settings.
    ///
    /// VoiceOver hears that the settings were applied, not that they were
    /// saved (TODO A09): the settings model saves them to config.json itself,
    /// and a save that fails is reported to `PersistenceFailureCenter`, whose
    /// banner in the Library window announces it, so no second message is
    /// needed here.
    func saveSettingsToGlobal() {
        // Global speed is measured in WPM; audio multipliers cannot be copied
        // into it. Audio speed remains a per-book setting.
        guard !isAudioBook else { return }
        let localSettings = book.localVoiceSettings
        if let localWPM = localSettings.wordsPerMinute {
            settingsViewModel.wordsPerMinute = localWPM
        }
        if let localPitch = localSettings.pitch {
            settingsViewModel.pitchMultiplier = localPitch
        }
        if let localVoiceID = localSettings.voiceID {
            settingsViewModel.selectedVoiceID = localVoiceID
        }
        announceToVoiceOver(VoiceAndSpeedWording.appliedAsGlobalDefaults)
    }

    /// Reset this book to use global voice, speed, and pitch settings
    func resetToGlobalSettings() {
        book.clearLocalVoiceSettings()
        libraryViewModel.updateLocalVoiceAndSpeed(
            bookID: book.id,
            voiceID: nil,
            wpm: nil,
            pitch: nil
        )
        if isAudioBook {
            audioSpeed = AudioSpeed.normal
            audioPlaybackService.setSpeed(audioSpeed)
            announceToVoiceOver(VoiceAndSpeedWording.audioSpeedReset(to: AudioSpeed.spokenLabel(for: audioSpeed)))
            return
        }
        // Apply global settings: the book keeps none of its own now.
        applyGlobalSpeechSettingsWhereTheBookKeepsNone()
        refreshLookAhead()
        warmUpVoice()
        announceToVoiceOver(BookSettingsWording.resetDone)
    }

    /// Gives the speech service the global speed, pitch, and voice for each
    /// of the three this book keeps no setting of its own for. A text book
    /// only: an audiobook's speed is its player's (`audioSpeed`).
    private func applyGlobalSpeechSettingsWhereTheBookKeepsNone() {
        if book.localWPM == nil {
            speechService.setSpeedRealtime(settingsViewModel.wordsPerMinute)
        }
        if book.localPitch == nil {
            speechService.setPitchRealtime(settingsViewModel.pitchMultiplier)
        }
        if book.localVoiceID == nil, let voice = settingsViewModel.selectedVoice {
            speechService.currentVoice = voice
        }
    }

    /// Applies this book's voice, speed, and pitch as they are now, and the
    /// global ones for those it keeps none of, as a reader must when the
    /// book's own settings change under it: the settings its record held,
    /// taken as the book opened (`takeNewerRecordedState(_:)`, risk 2), which
    /// may clear one the reader opened with. An audiobook takes its own
    /// speed, or the normal one, as the reader takes it when it opens.
    func applySpeechSettingsOfTheBook() {
        if isAudioBook {
            audioSpeed = book.localWPM.map { AudioSpeed.normalized($0) } ?? AudioSpeed.normal
            return
        }
        applyGlobalSpeechSettingsWhereTheBookKeepsNone()
        applyLocalSpeechOverrides()
    }

    /// Whether this book has local voice/speed/pitch overrides
    var hasLocalSettings: Bool {
        book.hasLocalVoiceSettings
    }

    // MARK: - Skip Sections

    /// Set of heading IDs marked as "skip" for this book
    var skippedHeadingIDs: Set<String> {
        Set(book.skippedHeadingIDs ?? [])
    }

    /// Check whether a heading is marked as skipped
    func isHeadingSkipped(_ heading: Heading) -> Bool {
        skippedHeadingIDs.contains(heading.id)
    }

    /// Toggle the skip state for a heading section. A next chapter already
    /// rendered ahead is rendered again when the change alters what it says,
    /// or which chapter comes next.
    ///
    /// The skips are saved as the headings themselves (`SkippedHeading`,
    /// T06's branch B), each with the words at its start as the text reads
    /// now, by which a later text of the book can find it again, in the
    /// reader's copy of the book and in the library; their IDs, which the
    /// reader's filter matches, are written from them.
    func toggleHeadingSkip(_ heading: Heading) {
        // A skipped heading is saved with its words (its label, and its ID),
        // which a protected book never lets into a record (FR41).
        guard !book.isPasswordProtected else {
            announceToVoiceOver(ProtectionWording.cannotSkipSections)
            return
        }
        var skipped = book.skippedHeadings ?? []
        if skipped.contains(where: { $0.id == heading.id }) {
            skipped.removeAll { $0.id == heading.id }
            announceToVoiceOver(VoiceAndSpeedWording.sectionIncluded(heading.text))
        } else {
            let start = TextPlace(chapter: heading.chapterIndex, offset: heading.characterOffset)
            skipped.append(SkippedHeading(heading, anchor: capturedAnchor(at: start)))
            announceToVoiceOver(VoiceAndSpeedWording.sectionSkipped(heading.text))
        }
        book.setSkippedHeadings(skipped)
        libraryViewModel.updateSkippedHeadings(bookID: book.id, headings: skipped)
        refreshLookAhead()
    }
}

/// Removes excluded heading ranges while preserving the source/filtered offset
/// relationship required by seeking and playback highlighting. Speech
/// preparation applies it to each chapter with the chapter's own headings
/// (`ChapterSpeechInputs.prepare()`).
enum SkippedSectionFilter {
    /// The ranges, in UTF-16 offsets of a chapter's text, that skipped
    /// headings take out: each skipped heading's section, from the heading to
    /// the next heading (or the chapter's end). Empty when nothing is skipped.
    /// `apply` removes them from the speech, and the page commands (PG02) use
    /// them to pass over a page that begins inside one.
    static func excludedRanges(
        textLength: Int,
        headings: [Heading],
        skippedIDs: Set<String>
    ) -> [Range<Int>] {
        guard !skippedIDs.isEmpty, !headings.isEmpty else { return [] }

        // Build ranges to exclude
        var excludeRanges: [Range<Int>] = []
        let sortedHeadings = headings.sortedStably { $0.characterOffset < $1.characterOffset }
        for (i, heading) in sortedHeadings.enumerated() {
            guard skippedIDs.contains(heading.id) else { continue }
            let start = min(max(0, heading.characterOffset), textLength)
            let end: Int
            if i + 1 < sortedHeadings.count {
                end = min(max(start, sortedHeadings[i + 1].characterOffset), textLength)
            } else {
                end = textLength
            }
            if start < end { excludeRanges.append(start..<end) }
        }
        return excludeRanges
    }

    static func apply(
        text: String,
        headings: [Heading],
        skippedIDs: Set<String>
    ) -> (text: String, offsetMap: OffsetMap) {
        let excludeRanges = excludedRanges(
            textLength: text.utf16Length,
            headings: headings,
            skippedIDs: skippedIDs
        )

        guard !excludeRanges.isEmpty else { return (text, .identity) }

        // Build filtered text and offset map by tracking deletions.
        // Each excluded range shifts all subsequent target positions by the range's length.
        var result = ""
        var pos = 0
        var cumulativeDelta = 0
        var points: [(targetPos: Int, cumulativeDelta: Int)] = []

        for range in excludeRanges.sortedStably(by: { $0.lowerBound < $1.lowerBound }) {
            if pos < range.lowerBound {
                let startIdx = text.index(atUTF16Offset: pos)
                let endIdx = text.index(atUTF16Offset: min(range.lowerBound, text.utf16Length))
                result += text[startIdx..<endIdx]
            }
            // Record the deletion: at the current target position, delta increases
            // by the number of characters removed in this range.
            let deletedCount = range.upperBound - range.lowerBound
            cumulativeDelta += deletedCount
            let targetPos = range.lowerBound - (cumulativeDelta - deletedCount)
            points.append((targetPos: targetPos, cumulativeDelta: cumulativeDelta))

            pos = range.upperBound
        }
        if pos < text.utf16Length {
            let startIdx = text.index(atUTF16Offset: pos)
            result += text[startIdx...]
        }
        return (result, OffsetMap(points: points))
    }
}

// MARK: - The Words

/// What VoiceOver hears, and the speed buttons are named, as the voice, the
/// speed, the pitch, and the skipped sections change.
enum VoiceAndSpeedWording {
    /// The label of a text book's speed button: "Increase speed by 25 words
    /// per minute".
    static func speedStepLabel(forward: Bool, wordsPerMinute: Int) -> String {
        if forward {
            // Translators: VoiceOver label of the playback bar's button that raises a text book's speed. %lld is the size of one step in words per minute.
            return InterfaceText.line("voiceAndSpeed.speedStepLabel.increase", "Increase speed by \(number: wordsPerMinute) words per minute")
        }
        // Translators: VoiceOver label of the playback bar's button that lowers a text book's speed. %lld is the size of one step in words per minute.
        return InterfaceText.line("voiceAndSpeed.speedStepLabel.decrease", "Decrease speed by \(number: wordsPerMinute) words per minute")
    }

    /// Said after a text book's speed changes: "200 words per minute".
    static func speedAnnouncement(wordsPerMinute: Int) -> String {
        // Translators: Announcement of a text book's new speed after it changed. %lld is the speed in words per minute.
        InterfaceText.line("common.countWordsPerMinute", "\(number: wordsPerMinute) words per minute")
    }

    /// Said after the pitch changes: "Pitch 1.2". `pitch` is the multiplier
    /// with one decimal.
    static func pitchAnnouncement(_ pitch: String) -> String {
        // Translators: Announcement of the voice's new pitch after it changed. %@ is the pitch multiplier with one decimal, such as 1.2.
        InterfaceText.line("voiceAndSpeed.pitchAnnouncement", "Pitch \(pitch)")
    }

    /// Said after a voice is chosen for the book alone.
    static func voiceChanged(to name: String) -> String {
        // Translators: Announcement after a voice was chosen for the open book. %@ is the voice's name.
        InterfaceText.line("voiceAndSpeed.voiceChanged", "Voice changed to \(name)")
    }

    /// Said after the book's own voice, speed, and pitch are applied to the global settings.
    static var appliedAsGlobalDefaults: String {
        // Translators: Announcement after the open book's own voice, speed, and pitch were applied as the global settings.
        InterfaceText.line("voiceAndSpeed.appliedAsGlobalDefaults", "Settings applied as global defaults")
    }

    /// Said after an audiobook's speed goes back to the normal one: "Audio
    /// speed reset to 1.0 times speed".
    static func audioSpeedReset(to speed: String) -> String {
        // Translators: Announcement after an audiobook's speed returned to normal. %@ is the speed as VoiceOver says it, such as "1.0 times speed".
        InterfaceText.line("voiceAndSpeed.audioSpeedReset", "Audio speed reset to \(speed)")
    }

    /// Said after a skipped section is included again.
    static func sectionIncluded(_ heading: String) -> String {
        // Translators: Announcement after a heading's section that was skipped is read again. %@ is the heading's text.
        InterfaceText.line("voiceAndSpeed.sectionIncluded", "Section included: \(heading)")
    }

    /// Said after a section is set to be skipped.
    static func sectionSkipped(_ heading: String) -> String {
        // Translators: Announcement after a heading's section is set to be skipped. %@ is the heading's text.
        InterfaceText.line("voiceAndSpeed.sectionSkipped", "Section skipped: \(heading)")
    }
}
