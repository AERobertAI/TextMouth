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
        announceToVoiceOver("Settings saved to global defaults")
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
    /// Returns the filtered text and an OffsetMap tracking which characters were removed,
    /// so downstream offset conversions can map back to original-text positions.
    func filterSkippedSections(chapterIndex: Int, text: String) -> (text: String, offsetMap: OffsetMap) {
        guard let content = content else { return (text, .identity) }
        let skipped = skippedHeadingIDs
        guard !skipped.isEmpty else { return (text, .identity) }

        let chapterHeadings = content.allHeadings.filter { $0.chapterIndex == chapterIndex }
        guard !chapterHeadings.isEmpty else { return (text, .identity) }

        // Build ranges to exclude
        var excludeRanges: [Range<Int>] = []
        for (i, heading) in chapterHeadings.enumerated() {
            guard skipped.contains(heading.id) else { continue }
            let start = heading.characterOffset
            let end: Int
            if i + 1 < chapterHeadings.count {
                end = chapterHeadings[i + 1].characterOffset
            } else {
                end = text.utf16Length
            }
            excludeRanges.append(start..<end)
        }

        guard !excludeRanges.isEmpty else { return (text, .identity) }

        // Build filtered text and offset map by tracking deletions.
        // Each excluded range shifts all subsequent target positions by the range's length.
        var result = ""
        var pos = 0
        var cumulativeDelta = 0
        var points: [(targetPos: Int, cumulativeDelta: Int)] = []

        for range in excludeRanges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
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
