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
        let direction = forward ? "Increase" : "Decrease"
        return "\(direction) speed by \(Int(Self.speechSpeedStep)) words per minute"
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
        announceToVoiceOver("\(Int(speechService.wordsPerMinute)) words per minute")
    }

    /// Set pitch for this book (multiplier 0.5-2.0)
    func adjustPitch(to newPitch: Double) {
        speechService.setPitchRealtime(newPitch)
        book.localPitch = speechService.pitchMultiplier
        saveLocalVoiceSettings()
        let formatted = String(format: "%.1f", speechService.pitchMultiplier)
        announceToVoiceOver("Pitch \(formatted)")
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
        announceToVoiceOver("Voice changed to \(voice.name)")
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
        // the look-ahead's own voice is what is compared.
        let lookAheadVoiceIsCurrent = lookAhead.map {
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
        announceToVoiceOver("Settings applied as global defaults")
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
            announceToVoiceOver("Audio speed reset to \(AudioSpeed.spokenLabel(for: audioSpeed))")
            return
        }
        // Apply global settings
        speechService.setSpeedRealtime(settingsViewModel.wordsPerMinute)
        speechService.setPitchRealtime(settingsViewModel.pitchMultiplier)
        if let voice = settingsViewModel.selectedVoice {
            speechService.currentVoice = voice
        }
        refreshLookAhead()
        warmUpVoice()
        announceToVoiceOver(BookSettingsWording.resetDone)
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
        var skipped = book.skippedHeadings ?? []
        if skipped.contains(where: { $0.id == heading.id }) {
            skipped.removeAll { $0.id == heading.id }
            announceToVoiceOver("Section included: \(heading.text)")
        } else {
            let start = TextPlace(chapter: heading.chapterIndex, offset: heading.characterOffset)
            skipped.append(SkippedHeading(heading, anchor: capturedAnchor(at: start)))
            announceToVoiceOver("Section skipped: \(heading.text)")
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
