import Foundation

/// The pace speech was measured at, for the first run's log (the engineer's
/// review, F35): the speed table (`SpeechService.rateTable`) and the render's
/// assumed pace (`AudioEngineService.renderWPM`) were measured on a Mac, and
/// what a phone's voices do at the same rates is unknown.
enum PhoneAudioPace {
    /// The words in `text`: its runs of letters and digits, as a listener
    /// would count them.
    static func wordCount(in text: String) -> Int {
        var count = 0
        var inWord = false
        for scalar in text.unicodeScalars {
            let isWordScalar = CharacterSet.alphanumerics.contains(scalar)
            if isWordScalar && !inWord { count += 1 }
            inWord = isWordScalar
        }
        return count
    }

    /// Words per minute for `words` words over `seconds`, or nil when too
    /// little was timed to say: under a second, or no words.
    static func wordsPerMinute(words: Int, seconds: TimeInterval) -> Double? {
        guard words > 0, seconds.isFinite, seconds >= 1 else { return nil }
        return Double(words) * 60 / seconds
    }

    /// The log's words for a measured pace: the measured and the expected
    /// words per minute, whole, or that too little was timed.
    static func description(words: Int, seconds: TimeInterval, expectedWordsPerMinute: Double) -> String {
        guard let measured = wordsPerMinute(words: words, seconds: seconds) else {
            return "words=\(words) seconds=\(String(format: "%.1f", seconds)) wpm=unmeasured"
        }
        return "words=\(words) seconds=\(String(format: "%.1f", seconds)) "
            + "wpm=\(Int(measured.rounded())) expected=\(Int(expectedWordsPerMinute.rounded()))"
    }
}
