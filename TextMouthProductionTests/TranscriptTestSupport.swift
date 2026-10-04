import XCTest
@testable import TextMouth

/// Transcripts for the transcription tests (FR05), built from text, so each
/// test states the sentences it needs and nothing else. The words are
/// invented, so a line of the debug log that quoted them would stand out.
enum TranscriptFixtures {
    /// A date in whole seconds, as transcript.json keeps dates (ISO 8601),
    /// so a transcript read back equals the one written.
    static let date = Date(timeIntervalSince1970: 1_790_000_000)

    /// A transcription language other than the one this Mac's region makes
    /// the default (`TranscriptionLanguage.defaultIdentifier`), so a test
    /// that sets it always changes the setting, wherever it runs.
    static var languageOtherThanTheDefault: String {
        TranscriptionLanguage.defaultIdentifier == "en-NZ" ? "en-IE" : "en-NZ"
    }

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

    /// A transcript of `book`'s audio as the transcription service makes
    /// one: each of the book's files, in the order it plays them, measured
    /// and fingerprinted as it is now, with `sentences`, by the file's path
    /// in the book, as what was heard in it.
    static func transcript(of book: Book, sentences: [String: [TranscriptSentence]]) throws -> Transcript {
        var transcript = transcript([])
        transcript.files = try TranscriptionPlan.make(for: book).files.map { file in
            TranscriptFile(
                path: file.path,
                fingerprint: try XCTUnwrap(FileFingerprint(of: file.url, hasher: .md5)),
                durationMilliseconds: Transcript.milliseconds(file.duration),
                sentences: sentences[file.path] ?? []
            )
        }
        return transcript
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

// MARK: - This Mac's Recognizer

extension XCTestCase {
    /// The English model's locale, skipping the test unless this Mac can
    /// transcribe English now: macOS 26, a Mac that runs the recognizer,
    /// and the English model installed. Nothing is downloaded to get it.
    /// On the main actor, as the tests that transcribe run.
    @MainActor
    func requireInstalledEnglishModel() async throws -> Locale {
        try XCTSkipUnless(
            TranscriptionAvailability.systemSupport == .available,
            "transcription needs macOS 26 on a Mac that runs its model"
        )
        guard case .installed(let locale) = await TranscriptionAvailability.modelStatus(for: Locale(identifier: "en-US")) else {
            throw XCTSkip("the English speech model is not installed on this Mac, and the tests never download it")
        }
        return locale
    }

    /// The TestData archive `name`, skipping the test when this checkout
    /// does not keep it (git ignores the DAISY audio archives).
    func optionalTestDataArchive(_ name: String) throws -> URL {
        let url = URL(fileURLWithPath: testFilePath(name))
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "\(name) is not in this checkout's TestData")
        return url
    }
}
