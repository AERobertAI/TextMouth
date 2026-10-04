import XCTest
@testable import TextMouth

/// Transcripts for the transcription tests (FR05), built from text, so each
/// test states the sentences it needs and nothing else. The words are
/// invented, so a line of the debug log that quoted them would stand out.
enum TranscriptFixtures {
    /// A date in whole seconds, as transcript.json keeps dates (ISO 8601),
    /// so a transcript read back equals the one written.
    static let date = Date(timeIntervalSince1970: 1_790_000_000)

    /// A sentence of `text` spoken from `start` to `end` milliseconds into
    /// its file: one word per run of non-space characters, each lasting an
    /// equal share of the sentence and starting where the one before it
    /// ended, as SpeechTranscriber times them, each with a confidence of
    /// 0.9.
    static func sentence(_ text: String, from start: Int, to end: Int) -> TranscriptSentence {
        let utf16 = Array(text.utf16)
        var ranges: [(offset: Int, count: Int)] = []
        var index = 0
        while index < utf16.count {
            if utf16[index] == UInt16(UInt8(ascii: " ")) {
                index += 1
                continue
            }
            let wordStart = index
            while index < utf16.count, utf16[index] != UInt16(UInt8(ascii: " ")) {
                index += 1
            }
            ranges.append((wordStart, index - wordStart))
        }
        let step = ranges.isEmpty ? 0 : (end - start) / ranges.count
        let words = ranges.enumerated().map { number, range in
            TranscriptWord(
                characterOffset: range.offset,
                characterCount: range.count,
                startMilliseconds: start + number * step,
                endMilliseconds: number == ranges.count - 1 ? end : start + (number + 1) * step,
                confidence: 0.9
            )
        }
        return TranscriptSentence(text: text, startMilliseconds: start, endMilliseconds: end, words: words)
    }

    /// A fingerprint for a file that was never on disk, of `byteCount`
    /// bytes, for tests that never compare it with a file.
    static func fingerprint(byteCount: Int64 = 4_096) -> FileFingerprint {
        FileFingerprint(
            stamp: FileStamp(byteCount: byteCount, modificationTimeNanoseconds: 1_790_000_000_000_000_000),
            digest: "0123456789abcdef0123456789abcdef"
        )
    }

    /// A transcript in English of `files`, each a path, how long the file
    /// plays in milliseconds, and its sentences, made by a fixed build on a
    /// fixed date.
    static func transcript(
        _ files: [(path: String, duration: Int, sentences: [TranscriptSentence])],
        locale: String = "en-US"
    ) -> Transcript {
        Transcript(
            version: Transcript.currentVersion,
            locale: locale,
            model: TranscriptSpeechModel(
                engine: "SpeechTranscriber",
                assetStatus: "installed",
                systemVersion: "Version 26.3.1 (Build 25D2128)"
            ),
            app: TranscriptAppBuild(version: "1.0", build: "42", commit: "abc1234"),
            createdAt: date,
            files: files.map { file in
                TranscriptFile(
                    path: file.path,
                    fingerprint: fingerprint(),
                    durationMilliseconds: file.duration,
                    sentences: file.sentences
                )
            }
        )
    }

    /// Two files of invented narration: three sentences in the first and
    /// two in the second, every word timed.
    static var twoFiles: Transcript {
        transcript([
            (path: "01.wav", duration: 9_000, sentences: [
                sentence("Quillwort grows by the ferry slip.", from: 0, to: 2_400),
                sentence("Tide tables hang in the harbor office.", from: 2_400, to: 5_100),
                sentence("Nobody reads them twice.", from: 5_100, to: 6_960),
            ]),
            (path: "Disc 2/02.wav", duration: 6_000, sentences: [
                sentence("The salt road bends east.", from: 0, to: 1_980),
                sentence("Carts wait at the toll.", from: 1_980, to: 3_900),
            ]),
        ])
    }
}
