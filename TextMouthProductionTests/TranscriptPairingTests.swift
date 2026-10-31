import XCTest
import ZIPFoundation
@testable import TextMouth

/// A transcript beside a track, attached at import (FMT23): a WebVTT or
/// SubRip file named as an imported audio file is, or as a track of a folder
/// of tracks, an audio ZIP, or a playlist, becomes the book's transcript,
/// timed on its track, with nothing transcribed; WebVTT wins over SubRip. A
/// file found but not usable is named in the import's notice, with why, and
/// the import goes on without it; a book with no such file imports as
/// before.
///
/// Each test makes its own files in a sandbox folder of its own, from copies
/// of the format samples or from silent tracks, and imports them into the
/// library's top (`importedForTest`, which removes the package) or into a
/// library folder of its own, removed when the test ends. Nothing is played
/// or transcribed, and the sentences are invented, so a line of the debug
/// log that quoted one would stand out.
@MainActor
final class TranscriptPairingTests: XCTestCase {

    // MARK: - Failures Once a File Is Found

    /// The tracks are looked through before any is measured: with no
    /// transcript file beside them, a track that cannot be measured
    /// matters not at all, and nothing is written or logged. Once a file is
    /// there, that track keeps it from being attached, and the file is named
    /// with why.
    func testATrackThatCannotBeMeasuredMattersOnlyOnceAFileIsFound() throws {
        let tracks = try makeTracks(["01.wav", "02.wav"], inFolderNamed: "Ferry Talks")
        let library = makeIntegrationLibraryFolder("Transcript Pairing")
        let book = try FileImportService.importAudioFolderWithReport(from: tracks, toFolder: library.path).book
        let index = try savedIndex(of: book)
        try FileManager.default.removeItem(at: URL(fileURLWithPath: book.filePath).appendingPathComponent("02.wav"))

        XCTAssertNil(TranscriptPairing.attach(.inFolder(tracks), to: book, index: index))
        XCTAssertEqual(refusals(of: book.title), [])

        try write(Self.oneWebVTTCue, to: tracks.appendingPathComponent("01.vtt"))
        let reason = TranscriptionError.unreadableFile(file: "02.wav", reason: TranscriptionError.unreadableAudioReason)
            .localizedDescription
        XCTAssertEqual(
            TranscriptPairing.attach(.inFolder(tracks), to: book, index: index),
            TranscriptionWording.transcriptNotAttached(fileName: "01.vtt", reason: reason)
        )
        XCTAssertEqual(TranscriptStore.read(from: book.tmbDirectory), .missing)
        XCTAssertEqual(refusals(of: book.title), ["01.vtt: \(reason)"])
    }

    /// A transcript that cannot be written into its package sets aside the
    /// file it was made from, named with the system's reason: the book is
    /// left without a transcript, nothing is thrown, and the debug log names
    /// the file set aside and no transcript attached.
    func testATranscriptThatCannotBeWrittenSetsItsFileAside() throws {
        let tracks = try makeTracks(["01.wav", "02.wav"], inFolderNamed: "Ferry Talks")
        let library = makeIntegrationLibraryFolder("Transcript Pairing")
        let book = try FileImportService.importAudioFolderWithReport(from: tracks, toFolder: library.path).book
        let index = try savedIndex(of: book)
        try write(Self.oneWebVTTCue, to: tracks.appendingPathComponent("01.vtt"))
        let package = book.tmbDirectory
        // A package no file can be added to; the library folder's removal
        // gives the permission back too, should this test stop early.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: package.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: package.path) }

        let notice = TranscriptPairing.attach(.inFolder(tracks), to: book, index: index)

        let start = "“01.vtt” was beside the audio but wasn't attached as the book's transcript: "
        let reason = try XCTUnwrap(notice.flatMap { $0.hasPrefix(start) ? String($0.dropFirst(start.count)) : nil }, notice ?? "no notice")
        XCTAssertFalse(reason.isEmpty)
        XCTAssertEqual(TranscriptStore.read(from: package), .missing)
        XCTAssertEqual(refusals(of: book.title), ["01.vtt: \(reason)"])
        XCTAssertEqual(debugLogLines(containing: "TRANSCRIPT_FOUND_AT_IMPORT: \(book.title):"), [])
    }

    // MARK: - Where a Transcript File Is Looked For

    /// Beside one file, its name with .srt is found when no .vtt is there,
    /// and with .vtt once one is; the track's own path, which a conversion
    /// may have renamed, is not used.
    func testBesideOneFileTheVTTIsFoundBeforeTheSRTWhateverTheTracksPath() throws {
        let folder = try makeSandboxDirectory("pairing-beside")
        let pairing = TranscriptPairing.besideFile(folder.appendingPathComponent("lecture.ogg"))
        try write(Self.oneSubRipCue, to: folder.appendingPathComponent("lecture.srt"))

        XCTAssertEqual(pairing.transcriptFile(forTrack: "lecture.m4a")?.path, folder.appendingPathComponent("lecture.srt").path)
        try write(Self.oneWebVTTCue, to: folder.appendingPathComponent("lecture.vtt"))
        XCTAssertEqual(pairing.transcriptFile(forTrack: "lecture.m4a")?.path, folder.appendingPathComponent("lecture.vtt").path)
        XCTAssertEqual(pairing.foundFile(forTrack: "another name.m4a")?.format, .webVTT)
        XCTAssertEqual(pairing.foundFile(forTrack: "lecture.m4a")?.name, "lecture.vtt")
    }

    /// An extension in uppercase is found, and the file is named as it is
    /// stored, whatever case it was looked for in.
    func testAnUppercaseExtensionIsFoundAndNamedAsStored() throws {
        let folder = try makeSandboxDirectory("pairing-uppercase")
        try write(Self.oneWebVTTCue, to: folder.appendingPathComponent("lecture.VTT"))

        let found = TranscriptPairing.besideFile(folder.appendingPathComponent("lecture.mp3")).foundFile(forTrack: "lecture.mp3")

        XCTAssertEqual(found?.format, .webVTT)
        XCTAssertEqual(found?.name, "lecture.VTT")
    }

    /// A folder, a symbolic link, and a named pipe named as a track's
    /// transcript are passed over, so the next file is found, or none; a
    /// pipe is never opened, which would wait forever.
    func testAFolderALinkAndANamedPipeAreNoTranscripts() throws {
        let folder = try makeSandboxDirectory("pairing-not-files")
        let elsewhere = try write(Self.oneWebVTTCue, to: try makeSandboxDirectory("pairing-elsewhere").appendingPathComponent("talk.vtt"))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("a.vtt"), withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("b.vtt"), withDestinationURL: elsewhere)
        XCTAssertEqual(mkfifo(folder.appendingPathComponent("c.vtt").path, 0o600), 0)
        try write(Self.oneSubRipCue, to: folder.appendingPathComponent("c.srt"))
        let pairing = TranscriptPairing.inFolder(folder)

        XCTAssertNil(pairing.transcriptFile(forTrack: "a.wav"))
        XCTAssertNil(pairing.transcriptFile(forTrack: "b.wav"))
        XCTAssertEqual(pairing.foundFile(forTrack: "c.wav")?.name, "c.srt")
    }

    /// In a folder, a track in a subfolder is paired with the file beside
    /// it there, named with its folders; a path that is empty, absolute, or
    /// climbs out of the folder is never looked up, even where a file of
    /// that name lies.
    func testInAFolderOnlyTheTracksOwnPlaceIsLookedAt() throws {
        let outer = try makeSandboxDirectory("pairing-outer")
        let folder = outer.appendingPathComponent("Tracks", isDirectory: true)
        try write(Self.oneWebVTTCue, to: folder.appendingPathComponent("Disc 2/01.vtt"))
        try write(Self.oneWebVTTCue, to: outer.appendingPathComponent("talk.vtt"))
        let pairing = TranscriptPairing.inFolder(folder)

        let found = pairing.foundFile(forTrack: "Disc 2/01.mp3")
        XCTAssertEqual(found?.url.path, folder.appendingPathComponent("Disc 2/01.vtt").path)
        XCTAssertEqual(found?.name, "Disc 2/01.vtt")
        XCTAssertEqual(found?.trackPath, "Disc 2/01.mp3")
        XCTAssertNil(pairing.transcriptFile(forTrack: "Disc 1/01.mp3"))
        XCTAssertNil(pairing.transcriptFile(forTrack: "../talk.wav"))
        XCTAssertNil(pairing.transcriptFile(forTrack: outer.appendingPathComponent("talk.wav").path))
        XCTAssertNil(pairing.transcriptFile(forTrack: ""))
    }

    // MARK: - The Notice's Words

    /// One file set aside is named with why, the reason as its error words
    /// it.
    func testTheWordsForOneFileSetAside() {
        XCTAssertEqual(
            TranscriptionWording.transcriptNotAttached(
                fileName: "lecture.vtt",
                reason: "The file isn't a WebVTT transcript TextMouth can read."
            ),
            "“lecture.vtt” was beside the audio but wasn't attached as the book's transcript: "
                + "The file isn't a WebVTT transcript TextMouth can read."
        )
    }

    /// Several files set aside are named as a sentence lists them, in the
    /// order given: two joined by "and", three or more with a comma before
    /// "and", and at most five, the rest counted.
    func testTheWordsForSeveralFilesSetAside() {
        let start = "These transcript files were beside the audio but weren't attached: "
        let end = ". The debug log says why."
        XCTAssertEqual(
            TranscriptionWording.transcriptsNotAttached(fileNames: ["a.vtt", "b.vtt"]),
            start + "“a.vtt” and “b.vtt”" + end
        )
        XCTAssertEqual(
            TranscriptionWording.transcriptsNotAttached(fileNames: ["03.vtt", "07.vtt", "09.srt"]),
            start + "“03.vtt”, “07.vtt”, and “09.srt”" + end
        )
        XCTAssertEqual(
            TranscriptionWording.transcriptsNotAttached(fileNames: (1...5).map { "0\($0).vtt" }),
            start + "“01.vtt”, “02.vtt”, “03.vtt”, “04.vtt”, and “05.vtt”" + end
        )
        XCTAssertEqual(
            TranscriptionWording.transcriptsNotAttached(fileNames: (1...6).map { "0\($0).vtt" }),
            start + "“01.vtt”, “02.vtt”, “03.vtt”, “04.vtt”, “05.vtt”, and 1 more" + end
        )
        XCTAssertEqual(
            TranscriptionWording.transcriptsNotAttached(fileNames: (1...7).map { "0\($0).vtt" }),
            start + "“01.vtt”, “02.vtt”, “03.vtt”, “04.vtt”, “05.vtt”, and 2 more" + end
        )
        XCTAssertEqual(TranscriptionWording.transcriptFilesNamedAtMost, 5)
    }

    /// The notice of the files set aside: none for none, the one file's own
    /// words for one, and the list for several.
    func testTheNoticeIsWordedByHowManyFilesWereSetAside() {
        XCTAssertNil(TranscriptPairing.notice(forSetAside: []))
        XCTAssertEqual(
            TranscriptPairing.notice(forSetAside: [("a.vtt", "Why it was not.")]),
            TranscriptionWording.transcriptNotAttached(fileName: "a.vtt", reason: "Why it was not.")
        )
        XCTAssertEqual(
            TranscriptPairing.notice(forSetAside: [("a.vtt", "Why it was not."), ("b.srt", "Nor this.")]),
            TranscriptionWording.transcriptsNotAttached(fileNames: ["a.vtt", "b.srt"])
        )
    }

    // MARK: - Fixtures

    /// A WebVTT file of one cue, from the start to one second in.
    private static let oneWebVTTCue = "WEBVTT\n\n00:00.000 --> 00:01.000\nThe ferry leaves at nine.\n"

    /// A SubRip file of one cue, from the start to one second in.
    private static let oneSubRipCue = "1\n00:00:00,000 --> 00:00:01,000\nThe ferry leaves at nine.\n"

    /// The sentence either one-cue file gives its track.
    private static let ferrySentence = TranscriptSentence(
        text: "The ferry leaves at nine.",
        startMilliseconds: 0,
        endMilliseconds: 1_000,
        words: []
    )

    /// Thrown after a failed assertion that a package holds a transcript, to
    /// end the test that asked.
    private struct NoTranscript: Error {}

    /// The transcript in `book`'s package, failing the test when it holds
    /// none that can be used.
    private func storedTranscript(of book: Book, file: StaticString = #filePath, line: UInt = #line) throws -> Transcript {
        let lookup = TranscriptStore.read(from: book.tmbDirectory)
        guard case .found(let transcript) = lookup else {
            XCTFail("\(book.title)'s package holds no transcript: \(lookup)", file: file, line: line)
            throw NoTranscript()
        }
        return transcript
    }

    /// Each of `transcript`'s files' sentences, by the file's path.
    private func sentences(in transcript: Transcript) -> [String: [TranscriptSentence]] {
        Dictionary(transcript.files.map { ($0.path, $0.sentences) }, uniquingKeysWith: { earlier, _ in earlier })
    }

    /// The index saved in `book`'s package.
    private func savedIndex(of book: Book) throws -> BookContentIndex {
        try XCTUnwrap(try BookInfo.load(from: book.tmbDirectory).contentIndex)
    }

    /// The vtt sample's four-second tone, copied alone into a sandbox folder
    /// of this test's own under a name no other test's book has, so a line
    /// of the shared debug log names this test's book alone.
    private func uniquelyNamedTone() throws -> URL {
        let tone = try makeSandboxDirectory("pairing-tone")
            .appendingPathComponent("Harbour Tone \(UUID().uuidString.prefix(8)).wav")
        try FileManager.default.copyItem(at: try formatSampleURL("vtt/tone4.wav"), to: tone)
        return tone
    }

    /// A uniquely named tone (`uniquelyNamedTone()`) with `transcript`
    /// written beside it under the same name with `fileExtension`, and that
    /// file's name.
    private func makeTone(
        besideTranscript transcript: String,
        ofExtension fileExtension: String
    ) throws -> (audio: URL, transcriptName: String) {
        let audio = try uniquelyNamedTone()
        let transcriptFile = audio.deletingPathExtension().appendingPathExtension(fileExtension)
        try write(transcript, to: transcriptFile)
        return (audio, transcriptFile.lastPathComponent)
    }

    /// A folder named `name` and a few characters no other test's has, so a
    /// line of the shared debug log names this test's book alone, in a
    /// sandbox folder of this test's own, holding a track at each of
    /// `paths`: two seconds of silence each.
    private func makeTracks(_ paths: [String], inFolderNamed name: String) throws -> URL {
        let folder = try makeSandboxDirectory("pairing-tracks")
            .appendingPathComponent("\(name) \(UUID().uuidString.prefix(8))", isDirectory: true)
        for path in paths {
            try AudioTestFixtures.writeSilence(to: folder.appendingPathComponent(path), duration: 2)
        }
        return folder
    }

    /// Writes `text` to `url`, making its folders, and returns `url`.
    @discardableResult
    private func write(_ text: String, to url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    /// What the debug log's TRANSCRIPT_FOUND_AT_IMPORT_REFUSED lines say of
    /// the book titled `title`, each from after the title on: a file's name
    /// and why it was set aside.
    private func refusals(of title: String) -> [String] {
        let prefix = "TRANSCRIPT_FOUND_AT_IMPORT_REFUSED: \(title): "
        return debugLogLines(containing: prefix).compactMap { line in
            line.range(of: prefix).map { String(line[$0.upperBound...]) }
        }
    }
}
