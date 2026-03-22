import SwiftUI
import AVFoundation

// MARK: - Voice, Speed, Pitch, and Skip Sections

extension ReaderViewModel {

    // MARK: - Speed & Voice

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

    /// Set voice for this book only
    func setLocalVoice(_ voice: AVSpeechSynthesisVoice) {
        speechService.currentVoice = voice
        book.localVoiceID = voice.identifier
        saveLocalVoiceSettings()
        announceToVoiceOver("Voice changed to \(voice.name)")
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

    /// Copy this book's local voice, speed, and pitch to the global settings
    func saveSettingsToGlobal() {
        if let localWPM = book.localWPM {
            settingsViewModel.wordsPerMinute = localWPM
        }
        if let localPitch = book.localPitch {
            settingsViewModel.pitchMultiplier = localPitch
        }
        if let localVoiceID = book.localVoiceID {
            settingsViewModel.selectedVoiceID = localVoiceID
        }
        announceToVoiceOver("Settings saved to global defaults")
    }

    /// Reset this book to use global voice, speed, and pitch settings
    func resetToGlobalSettings() {
        book.localVoiceID = nil
        book.localWPM = nil
        book.localPitch = nil
        libraryViewModel.updateLocalVoiceAndSpeed(
            bookID: book.id,
            voiceID: nil,
            wpm: nil,
            pitch: nil
        )
        // Apply global settings
        speechService.setSpeedRealtime(settingsViewModel.wordsPerMinute)
        speechService.setPitchRealtime(settingsViewModel.pitchMultiplier)
        if let voice = settingsViewModel.selectedVoice {
            speechService.currentVoice = voice
        }
        announceToVoiceOver("Using global voice and speed settings")
    }

    /// Whether this book has local voice/speed/pitch overrides
    var hasLocalSettings: Bool {
        book.localVoiceID != nil || book.localWPM != nil || book.localPitch != nil
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

    /// Toggle the skip state for a heading section
    func toggleHeadingSkip(_ heading: Heading) {
        var ids = book.skippedHeadingIDs ?? []
        if ids.contains(heading.id) {
            ids.removeAll { $0 == heading.id }
            announceToVoiceOver("Section included: \(heading.text)")
        } else {
            ids.append(heading.id)
            announceToVoiceOver("Section skipped: \(heading.text)")
        }
        book.skippedHeadingIDs = ids
        libraryViewModel.updateSkippedHeadings(bookID: book.id, skippedIDs: ids)
    }

    /// Remove text under skipped headings from a chapter's text.
    /// Returns the filtered text for TTS.
    func filterSkippedSections(chapterIndex: Int, text: String) -> String {
        guard let content = content else { return text }
        let skipped = skippedHeadingIDs
        guard !skipped.isEmpty else { return text }

        let chapterHeadings = content.allHeadings.filter { $0.chapterIndex == chapterIndex }
        guard !chapterHeadings.isEmpty else { return text }

        // Build ranges to exclude
        var excludeRanges: [Range<Int>] = []
        for (i, heading) in chapterHeadings.enumerated() {
            guard skipped.contains(heading.id) else { continue }
            let start = heading.characterOffset
            let end: Int
            if i + 1 < chapterHeadings.count {
                end = chapterHeadings[i + 1].characterOffset
            } else {
                end = text.count
            }
            excludeRanges.append(start..<end)
        }

        guard !excludeRanges.isEmpty else { return text }

        // Build filtered text by including only non-excluded ranges
        var result = ""
        var pos = 0
        for range in excludeRanges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if pos < range.lowerBound {
                let startIdx = text.index(text.startIndex, offsetBy: pos)
                let endIdx = text.index(text.startIndex, offsetBy: min(range.lowerBound, text.count))
                result += text[startIdx..<endIdx]
            }
            pos = range.upperBound
        }
        if pos < text.count {
            let startIdx = text.index(text.startIndex, offsetBy: pos)
            result += text[startIdx...]
        }
        return result
    }
}
