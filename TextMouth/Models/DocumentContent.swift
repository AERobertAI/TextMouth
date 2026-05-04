import Foundation

/// Represents a parsed document ready for reading
struct DocumentContent {
    var title: String
    var author: String
    var chapters: [Chapter]

    var allText: String {
        chapters.map { $0.text }.joined(separator: "\n\n")
    }

    var totalWordCount: Int {
        chapters.reduce(0) { $0 + $1.wordCount }
    }

    var allHeadings: [Heading] {
        var result: [Heading] = []
        for (chapterIndex, chapter) in chapters.enumerated() {
            for heading in chapter.headings {
                var h = heading
                h.chapterIndex = chapterIndex
                // Regenerate stable ID with the correct chapterIndex
                h.id = "\(chapterIndex)-\(h.characterOffset)-\(h.level)-\(h.text)"
                result.append(h)
            }
        }
        return result
    }

    /// Returns the total character count across all chapters
    var totalCharacterCount: Int {
        chapters.reduce(0) { $0 + $1.text.count }
    }

    /// Cumulative character offset for the start of each chapter.
    /// Returns 0 for chapter 0 or invalid indices.
    func chapterStartOffset(_ chapterIndex: Int) -> Int {
        guard chapterIndex > 0 else { return 0 }
        let clamped = min(chapterIndex, chapters.count)
        return chapters[0..<clamped].reduce(0) { $0 + $1.text.count }
    }

    /// Global character offset for a position in (chapter, localOffset)
    func globalOffset(chapterIndex: Int, localOffset: Int) -> Int {
        chapterStartOffset(chapterIndex) + localOffset
    }

    /// Estimated reading time in seconds at a given WPM
    func estimatedReadingTime(wpm: Double) -> TimeInterval {
        guard wpm > 0 else { return 0 }
        return Double(totalWordCount) / wpm * 60.0
    }

    /// Estimated time to read from a given global character offset to the end
    func estimatedTimeRemaining(fromGlobalOffset offset: Int, wpm: Double) -> TimeInterval {
        guard wpm > 0, totalCharacterCount > 0 else { return 0 }
        let remainingFraction = Double(max(totalCharacterCount - offset, 0)) / Double(totalCharacterCount)
        return estimatedReadingTime(wpm: wpm) * remainingFraction
    }

    /// Percentage through the book for a given global offset
    func percentComplete(globalOffset: Int) -> Double {
        guard totalCharacterCount > 0 else { return 0 }
        return min(Double(globalOffset) / Double(totalCharacterCount) * 100.0, 100.0)
    }

    /// Reverse of `globalOffset(chapterIndex:localOffset:)` — given a
    /// global character offset, find which chapter contains it and the
    /// position within that chapter. Used by jump-to-percent and
    /// jump-to-time to translate a target into a (chapter, offset)
    /// pair the navigation system can act on.
    /// Clamps out-of-range inputs: a negative target returns
    /// (0, 0); a target past the end returns the last chapter's last
    /// position. An empty document returns (0, 0).
    func location(forGlobalOffset globalOffset: Int) -> (chapterIndex: Int, localOffset: Int) {
        guard !chapters.isEmpty else { return (0, 0) }
        let clampedTarget = max(0, min(globalOffset, totalCharacterCount))

        // Walk chapters accumulating their lengths until the target
        // falls within the current one. Chapters with empty text count
        // as zero-length so they don't trap the cursor.
        var cumulative = 0
        for (index, chapter) in chapters.enumerated() {
            let chapterLen = chapter.text.count
            // Target inside this chapter: localOffset is the residual.
            // Use < (not <=) so a target exactly at a chapter boundary
            // lands on the START of the next chapter, not the END of
            // the previous one — that matches the user expectation
            // when jumping to a chapter boundary.
            if clampedTarget < cumulative + chapterLen {
                return (index, clampedTarget - cumulative)
            }
            cumulative += chapterLen
        }

        // Target is at or past the end — clamp to the last chapter.
        let lastIndex = chapters.count - 1
        let lastLen = chapters[lastIndex].text.count
        return (lastIndex, max(0, lastLen - 1))
    }
}

struct Chapter {
    var title: String
    var text: String
    var headings: [Heading]

    /// Character ranges for each heading within this chapter's text
    var headingRanges: [(heading: Heading, range: Range<String.Index>)]

    var wordCount: Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    init(title: String = "", text: String = "", headings: [Heading] = [], headingRanges: [(heading: Heading, range: Range<String.Index>)] = []) {
        self.title = title
        self.text = text
        self.headings = headings
        self.headingRanges = headingRanges
    }
}

struct Heading: Identifiable, Hashable {
    /// Stable ID derived from content and position so SwiftUI/VoiceOver rotors
    /// don't see headings as new elements on every recompute.
    var id: String
    var level: Int  // 1-6
    var text: String
    var chapterIndex: Int
    var characterOffset: Int  // offset within the chapter text

    init(level: Int, text: String, chapterIndex: Int = 0, characterOffset: Int = 0) {
        self.level = level
        self.text = text
        self.chapterIndex = chapterIndex
        self.characterOffset = characterOffset
        self.id = "\(chapterIndex)-\(characterOffset)-\(level)-\(text)"
    }
}

enum SleepTimerDuration: Hashable {
    case minutes(Int)
    case endOfHeading
    case endOfDocument

    var displayName: String {
        switch self {
        case .minutes(let m): return "\(m) minutes"
        case .endOfHeading: return "End of heading"
        case .endOfDocument: return "End of document"
        }
    }

    static let presets: [SleepTimerDuration] = [
        .minutes(10), .minutes(15), .minutes(30),
        .minutes(45), .minutes(60),
        .endOfHeading, .endOfDocument
    ]
}

// MARK: - Time Formatting Helper

enum TimeFormatting {
    /// Format seconds to h:mm:ss or m:ss (for visual display)
    static func format(_ seconds: TimeInterval) -> String {
        let totalSeconds = Int(max(seconds, 0))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    /// Format seconds as spoken words for VoiceOver (e.g. "1 hour, 3 minutes, 45 seconds").
    /// Omits zero-valued leading fields so "0:54:35" becomes "54 minutes, 35 seconds".
    static func spoken(_ seconds: TimeInterval) -> String {
        let totalSeconds = Int(max(seconds, 0))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60

        var parts: [String] = []
        if hours > 0 {
            parts.append("\(hours) \(hours == 1 ? "hour" : "hours")")
        }
        if minutes > 0 {
            parts.append("\(minutes) \(minutes == 1 ? "minute" : "minutes")")
        }
        if secs > 0 || parts.isEmpty {
            parts.append("\(secs) \(secs == 1 ? "second" : "seconds")")
        }
        return parts.joined(separator: ", ")
    }
}
