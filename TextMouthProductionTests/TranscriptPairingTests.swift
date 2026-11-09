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

    // MARK: - Beside the One File Imported

    /// The WebVTT sample beside its tone becomes the tone's transcript: the
    /// package holds a transcript.json recording the file it came from, its
    /// sentences read with their voices named, no notice is given, no
    /// transcription is offered, and the book shows the transcript's text as
    /// it opens.
    func testAWebVTTFileBesideTheOneFileBecomesItsTranscript() throws {
        preservePreferences([TranscriptionPreferences.offerAfterImport.key])
        TranscriptionPreferences.offerAfterImport.write(true, to: TextMouthRuntime.current.preferences)
        let folder = try copyOfFormatSample("vtt")

        let imported = try importedForTest(folder.appendingPathComponent("tone4.wav"))

        let transcript = try storedTranscript(of: imported.book)
        XCTAssertEqual(transcript.source, TranscriptSource(origin: .imported, format: .webVTT, fileName: "tone4.vtt"))
        XCTAssertEqual(transcript.files.count, 1)
        XCTAssertEqual(transcript.files.first?.sentences.count, 4)
        XCTAssertEqual(transcript.files.first?.sentences.first?.text, "Ana: First tone, 440 hertz.")
        XCTAssertNil(imported.notice)
        XCTAssertTrue(TranscriptStore.hasTranscript(of: imported.book))
        XCTAssertFalse(TranscriptionOffers.offersTranscription(of: imported.book))
        let load = TranscriptTextLoader.load(for: imported.book, audioIndex: try savedIndex(of: imported.book))
        XCTAssertNil(load.withheld)
        let text = try XCTUnwrap(load.text?.chapterText(0))
        XCTAssertTrue(text.contains("Ana: First tone, 440 hertz."), text)
        XCTAssertTrue(text.contains("The fourth, 880 hertz, with no speaker."), text)
    }

    /// The SubRip sample beside its tone becomes the tone's transcript as
    /// WebVTT does.
    func testASubRipFileBesideTheOneFileBecomesItsTranscript() throws {
        let folder = try copyOfFormatSample("srt")

        let imported = try importedForTest(folder.appendingPathComponent("tone4.wav"))

        let transcript = try storedTranscript(of: imported.book)
        XCTAssertEqual(transcript.source, TranscriptSource(origin: .imported, format: .subRip, fileName: "tone4.srt"))
        XCTAssertEqual(transcript.files.first?.sentences.first?.text, "This sentence belongs to the first tone, 440 hertz.")
        XCTAssertNil(imported.notice)
    }

    /// With a WebVTT file and a SubRip file both beside the one file, the
    /// WebVTT file becomes its transcript.
    func testWebVTTIsPreferredToSubRipBesideTheOneFile() throws {
        let folder = try copyOfFormatSample("vtt")
        try FileManager.default.copyItem(
            at: try formatSampleURL("srt/tone4.srt"),
            to: folder.appendingPathComponent("tone4.srt")
        )

        let imported = try importedForTest(folder.appendingPathComponent("tone4.wav"))

        XCTAssertEqual(
            try storedTranscript(of: imported.book).source,
            TranscriptSource(origin: .imported, format: .webVTT, fileName: "tone4.vtt")
        )
        XCTAssertNil(imported.notice)
    }

    /// A file with no transcript beside it imports as before: no
    /// transcript.json, no notice, no line in the debug log, and the offer to
    /// transcribe it is made as for any audiobook on a Mac that can
    /// transcribe.
    func testAFileWithNoTranscriptBesideItImportsAsBefore() throws {
        preservePreferences([TranscriptionPreferences.offerAfterImport.key])
        TranscriptionPreferences.offerAfterImport.write(true, to: TextMouthRuntime.current.preferences)
        let tone = try uniquelyNamedTone()

        let imported = try importedForTest(tone)

        XCTAssertEqual(TranscriptStore.read(from: imported.book.tmbDirectory), .missing)
        XCTAssertNil(imported.notice)
        XCTAssertEqual(
            TranscriptionOffers.offersTranscription(of: imported.book),
            TranscriptionAvailability.systemSupport == .available
        )
        XCTAssertEqual(debugLogLines(containing: "TRANSCRIPT_FOUND_AT_IMPORT: \(imported.book.title):"), [])
        XCTAssertEqual(refusals(of: imported.book.title), [])
    }

    /// A WebVTT file whose last cue ends at 20 seconds, beside a tone of 4,
    /// was made for other audio: it is not attached, the import goes on, and
    /// the notice names it with the reason, which the debug log gives too.
    func testATranscriptRunningPastTheEndIsNamedAndNotAttached() throws {
        let tone = try makeTone(besideTranscript: "WEBVTT\n\n00:00.000 --> 00:20.000\nThe ferry leaves at nine.\n", ofExtension: "vtt")

        let imported = try importedForTest(tone.audio)

        XCTAssertEqual(TranscriptStore.read(from: imported.book.tmbDirectory), .missing)
        let reason = OutsideTranscriptError.runsPastTheEnd(transcriptEnd: 20_000, audioEnd: 4_000).localizedDescription
        XCTAssertEqual(imported.notice, TranscriptionWording.transcriptNotAttached(fileName: tone.transcriptName, reason: reason))
        XCTAssertEqual(
            imported.notice,
            "“\(tone.transcriptName)” was beside the audio but wasn't attached as the book's transcript: "
                + "The transcript runs to 20 seconds, past the end of the audio at 4 seconds, so it was made for other audio."
        )
        XCTAssertEqual(refusals(of: imported.book.title), ["\(tone.transcriptName): \(reason)"])
    }

    /// A .vtt file that is no WebVTT file is named with the reader's reason,
    /// and neither the notice nor the debug log quotes what it holds.
    func testAFileThatIsNoWebVTTIsNamedAndNotAttached() throws {
        let tone = try makeTone(besideTranscript: "Minutes of the Quayside Rowing Club, typed by hand.\n", ofExtension: "vtt")

        let imported = try importedForTest(tone.audio)

        XCTAssertEqual(TranscriptStore.read(from: imported.book.tmbDirectory), .missing)
        let reason = TimedTextError.notTimedText(.webVTT).localizedDescription
        XCTAssertEqual(imported.notice, TranscriptionWording.transcriptNotAttached(fileName: tone.transcriptName, reason: reason))
        XCTAssertEqual(refusals(of: imported.book.title), ["\(tone.transcriptName): \(reason)"])
        XCTAssertEqual(debugLogLines(containing: "Quayside Rowing Club"), [])
    }

    // MARK: - Beside a Track of Several

    /// In a folder of two tracks, 01.vtt beside 01.wav times that track: the
    /// transcript holds its sentence for 01.wav and none for 02.wav, names
    /// 01.vtt, the one file it came from, and the debug log says one of two
    /// tracks' transcripts was attached.
    func testATranscriptBesideOneTrackOfAFolderTimesThatTrack() throws {
        let tracks = try makeTracks(["01.wav", "02.wav"], inFolderNamed: "Ferry Talks")
        try write(Self.oneWebVTTCue, to: tracks.appendingPathComponent("01.vtt"))
        let library = makeIntegrationLibraryFolder("Transcript Pairing")

        let imported = try FileImportService.importAudioFolderWithReport(from: tracks, toFolder: library.path)

        let transcript = try storedTranscript(of: imported.book)
        XCTAssertEqual(sentences(in: transcript), ["01.wav": [Self.ferrySentence], "02.wav": []])
        XCTAssertEqual(transcript.source, TranscriptSource(origin: .imported, format: .webVTT, fileName: "01.vtt"))
        XCTAssertNil(imported.notice)
        XCTAssertEqual(
            debugLogLines(containing: "TRANSCRIPT_FOUND_AT_IMPORT: \(imported.book.title): 1 of 2 tracks' transcripts attached").count,
            1
        )
    }

    /// 01.vtt beside 01.wav and 02.srt beside 02.wav record both formats, in
    /// the order the tracks play, naming no one file.
    func testFilesOfTwoFormatsRecordEachFormat() throws {
        let tracks = try makeTracks(["01.wav", "02.wav"], inFolderNamed: "Ferry Talks")
        try write(Self.oneWebVTTCue, to: tracks.appendingPathComponent("01.vtt"))
        try write(Self.oneSubRipCue, to: tracks.appendingPathComponent("02.srt"))
        let library = makeIntegrationLibraryFolder("Transcript Pairing")

        let mixed = try storedTranscript(of: try FileImportService.importAudioFolderWithReport(from: tracks, toFolder: library.path).book)

        XCTAssertEqual(mixed.source?.knownFormats, [.webVTT, .subRip], "01.vtt beside 02.srt did not record each format")
        XCTAssertEqual(mixed.source?.formats, ["webvtt", "srt"])
        XCTAssertEqual(mixed.source?.format, "webvtt", "the first file's format is still the one old TextMouths read")
        XCTAssertNil(mixed.source?.fileName)
    }

    /// Two files of one format record that one format alone, as every
    /// transcript did before this field.
    func testFilesOfOneFormatRecordThatFormatAlone() throws {
        let tracks = try makeTracks(["01.wav", "02.wav"], inFolderNamed: "Ferry Talks")
        try write(Self.oneWebVTTCue, to: tracks.appendingPathComponent("01.vtt"))
        try write(Self.oneWebVTTCue, to: tracks.appendingPathComponent("02.vtt"))
        let library = makeIntegrationLibraryFolder("Transcript Pairing")

        let alike = try storedTranscript(of: try FileImportService.importAudioFolderWithReport(from: tracks, toFolder: library.path).book)

        XCTAssertEqual(alike.source, TranscriptSource(origin: .imported, format: .webVTT))
        XCTAssertNil(alike.source?.formats)
    }

    /// Two tracks named alike but for their extension (01.wav and 01.m4a)
    /// both look for 01.vtt: the file times the track that plays first and
    /// no other, so the book's text never reads the same passage twice, and
    /// the debug log counts one track's transcript attached.
    func testTwoTracksOfOneNameShareNoTranscriptFile() throws {
        let tracks = try makeTracks(["01.wav"], inFolderNamed: "Ferry Talks")
        try AudioTestFixtures.writeAACSilence(to: tracks.appendingPathComponent("01.m4a"), duration: 2)
        try write(Self.oneWebVTTCue, to: tracks.appendingPathComponent("01.vtt"))
        let library = makeIntegrationLibraryFolder("Transcript Pairing")

        let imported = try FileImportService.importAudioFolderWithReport(from: tracks, toFolder: library.path)

        let transcript = try storedTranscript(of: imported.book)
        XCTAssertEqual(transcript.files.count, 2, "the book's two tracks were not both listed")
        XCTAssertEqual(
            transcript.files.map(\.sentences.count).reduce(0, +),
            1,
            "the file's sentences were laid over both tracks: \(sentences(in: transcript))"
        )
        XCTAssertEqual(transcript.files.first?.sentences, [Self.ferrySentence], "the track playing first did not take the file")
        XCTAssertNil(imported.notice)
        XCTAssertEqual(
            debugLogLines(containing: "TRANSCRIPT_FOUND_AT_IMPORT: \(imported.book.title): 1 of 2 tracks' transcripts attached").count,
            1
        )
    }

    /// Without a second track taking a file an earlier one has, the files
    /// found keep their order; a file found beside two tracks is kept for
    /// the first only.
    func testADistinctFileIsKeptForTheFirstTrackThatFoundIt() {
        func found(_ track: String, _ file: String) -> TranscriptPairing.FoundFile {
            TranscriptPairing.FoundFile(
                trackPath: track,
                url: URL(fileURLWithPath: "/Talks/\(file)"),
                format: .webVTT,
                name: file
            )
        }
        let files = [found("01.flac", "01.vtt"), found("01.mp3", "01.vtt"), found("02.mp3", "02.vtt")]

        XCTAssertEqual(TranscriptPairing.distinctFiles(files).map(\.trackPath), ["01.flac", "02.mp3"])
        XCTAssertEqual(TranscriptPairing.distinctFiles([]), [])
    }

    /// An audio ZIP made as Finder's Compress makes one, its tracks and
    /// 02.srt inside one folder, imports with 02.srt timing 02.wav.
    func testASubRipFileInAnAudioZIPTimesItsTrack() throws {
        let tracks = try makeTracks(["01.wav", "02.wav"], inFolderNamed: "Ferry Talks")
        try write(Self.oneSubRipCue, to: tracks.appendingPathComponent("02.srt"))
        let archive = tracks.deletingLastPathComponent().appendingPathComponent("\(tracks.lastPathComponent).zip")
        try FileManager.default.zipItem(at: tracks, to: archive, shouldKeepParent: true)
        let library = makeIntegrationLibraryFolder("Transcript Pairing")

        let imported = try FileImportService.importAudioZipWithReport(from: archive, toFolder: library.path)

        let transcript = try storedTranscript(of: imported.book)
        let folder = tracks.lastPathComponent
        XCTAssertEqual(sentences(in: transcript), ["\(folder)/01.wav": [], "\(folder)/02.wav": [Self.ferrySentence]])
        XCTAssertEqual(transcript.source, TranscriptSource(origin: .imported, format: .subRip, fileName: "02.srt"))
        XCTAssertNil(imported.notice)
    }

    /// A track in a subfolder is paired with the file beside it there; a
    /// file set aside in another subfolder is named with its folder, so the
    /// listener can tell two discs' files of the same name apart, while the
    /// transcript of the file kept names that file alone.
    func testTracksInSubfoldersArePairedThereAndAFileSetAsideIsNamedWithItsFolder() throws {
        let tracks = try makeTracks(["Disc 1/01.wav", "Disc 2/01.wav"], inFolderNamed: "Ferry Talks")
        try write("Minutes of the Quayside Rowing Club.\n", to: tracks.appendingPathComponent("Disc 1/01.vtt"))
        try write(Self.oneWebVTTCue, to: tracks.appendingPathComponent("Disc 2/01.vtt"))
        let library = makeIntegrationLibraryFolder("Transcript Pairing")

        let imported = try FileImportService.importAudioFolderWithReport(from: tracks, toFolder: library.path)

        let transcript = try storedTranscript(of: imported.book)
        XCTAssertEqual(sentences(in: transcript), ["Disc 1/01.wav": [], "Disc 2/01.wav": [Self.ferrySentence]])
        XCTAssertEqual(transcript.source, TranscriptSource(origin: .imported, format: .webVTT, fileName: "01.vtt"))
        XCTAssertEqual(
            imported.notice,
            "“Disc 1/01.vtt” was beside the audio but wasn't attached as the book's transcript: "
                + "The file isn't a WebVTT transcript TextMouth can read."
        )
    }

    /// Two files set aside are named together, in the order of their
    /// tracks, the debug log saying why for each without quoting either,
    /// and the book has no transcript.
    func testTwoFilesSetAsideAreNamedTogetherAndTheLogSaysWhy() throws {
        let tracks = try makeTracks(["01.wav", "02.wav"], inFolderNamed: "Ferry Talks")
        try write("Minutes of the Quayside Rowing Club.\n", to: tracks.appendingPathComponent("01.vtt"))
        try write("1\n00:00:00,000 --> 00:00:30,000\nThe ferry leaves at nine.\n", to: tracks.appendingPathComponent("02.srt"))
        let library = makeIntegrationLibraryFolder("Transcript Pairing")

        let imported = try FileImportService.importAudioFolderWithReport(from: tracks, toFolder: library.path)

        XCTAssertEqual(
            imported.notice,
            "These transcript files were beside the audio but weren't attached: “01.vtt” and “02.srt”. The debug log says why."
        )
        XCTAssertEqual(TranscriptStore.read(from: imported.book.tmbDirectory), .missing)
        XCTAssertEqual(refusals(of: imported.book.title), [
            "01.vtt: \(TimedTextError.notTimedText(.webVTT).localizedDescription)",
            "02.srt: \(OutsideTranscriptError.runsPastTheEnd(transcriptEnd: 30_000, audioEnd: 2_000).localizedDescription)",
        ])
        XCTAssertEqual(debugLogLines(containing: "Quayside Rowing Club"), [])
    }

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

    // MARK: - A Playlist

    /// A playlist of the two tracks, with 01.vtt beside the first in the
    /// playlist's folder, imports with 01.vtt timing that track.
    func testATranscriptBesideAPlaylistsTrackTimesThatTrack() throws {
        let tracks = try makeTracks(["01.wav", "02.wav"], inFolderNamed: "Ferry Talks")
        try write(Self.oneWebVTTCue, to: tracks.appendingPathComponent("01.vtt"))
        let playlist = try write("01.wav\n02.wav\n", to: tracks.appendingPathComponent("talks.m3u"))
        let library = makeIntegrationLibraryFolder("Transcript Pairing")

        let imported = try FileImportService.importPlaylistWithReport(from: playlist, toFolder: library.path)

        XCTAssertEqual(sentences(in: try storedTranscript(of: imported.book)), ["01.wav": [Self.ferrySentence], "02.wav": []])
        XCTAssertNil(imported.notice)
    }

    /// A playlist's notice of the entries it skipped is still said after the
    /// notice of a transcript not attached, as one message, the pairing's
    /// first.
    func testAPlaylistsSkippedEntriesAreToldAfterTheTranscriptNotAttached() throws {
        let tracks = try makeTracks(["01.wav", "02.wav"], inFolderNamed: "Ferry Talks")
        try write("Minutes of the Quayside Rowing Club.\n", to: tracks.appendingPathComponent("02.vtt"))
        let playlist = try write("01.wav\nmissing.wav\n02.wav\n", to: tracks.appendingPathComponent("talks.m3u"))
        let library = makeIntegrationLibraryFolder("Transcript Pairing")

        let imported = try FileImportService.importPlaylistWithReport(from: playlist, toFolder: library.path)

        XCTAssertEqual(
            imported.notice,
            "“02.vtt” was beside the audio but wasn't attached as the book's transcript: "
                + "The file isn't a WebVTT transcript TextMouth can read. "
                + "TextMouth skipped 1 entry of “talks.m3u”: “missing.wav” (not found)."
        )
        XCTAssertEqual(TranscriptStore.read(from: imported.book.tmbDirectory), .missing)
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

    // MARK: - Chosen With Their Audio

    /// A WebVTT or SubRip file chosen in the import panel together with the
    /// audio it sits beside is left out of the books to import, since the
    /// audio's import attaches it; a transcript file chosen alone, one whose
    /// audio is not chosen, one the audio does not find (the .srt beside a
    /// .vtt), and one beside a text book stay, to be refused as they were.
    /// The other items keep their order.
    func testATranscriptChosenWithItsAudioIsNotImportedAsABook() throws {
        let folder = try makeSandboxDirectory("pairing-chosen")
        func touch(_ name: String) throws -> URL {
            let url = folder.appendingPathComponent(name)
            try Data("x".utf8).write(to: url)
            return url
        }
        let tide = try touch("Tide.wav")
        let tideCaptions = try touch("Tide.vtt")
        let loneCaptions = try touch("Lone.srt")
        let both = try touch("Both.m4a")
        let bothWebVTT = try touch("Both.vtt")
        let bothSubRip = try touch("Both.srt")
        let upper = try touch("Loud.mp3")
        let upperCaptions = try touch("Loud.VTT")
        let novel = try touch("Novel.txt")
        let novelCaptions = try touch("Novel.vtt")
        let chosen = [tideCaptions, tide, loneCaptions, bothSubRip, both, bothWebVTT, upperCaptions, upper, novelCaptions, novel]

        let kept = TranscriptPairing.droppingTranscriptsChosenWithTheirAudio(chosen)

        XCTAssertEqual(
            kept.map(\.lastPathComponent),
            ["Tide.wav", "Lone.srt", "Both.srt", "Both.m4a", "Loud.mp3", "Novel.vtt", "Novel.txt"],
            "the transcript files chosen with their audio (Tide.vtt, Both.vtt, Loud.VTT) were not all left out, or others were"
        )
        // Nothing among the items to drop: the list comes back as it is.
        XCTAssertEqual(TranscriptPairing.droppingTranscriptsChosenWithTheirAudio([tide, both]), [tide, both])
        XCTAssertEqual(TranscriptPairing.droppingTranscriptsChosenWithTheirAudio([]), [])
    }

    /// A transcript file refused as a book says how to use it: import its
    /// audio and attach it, or name it like its audio; another unsupported
    /// file says only what it always did.
    func testATranscriptFileRefusedAsABookSaysHowToAttachIt() {
        let vtt = FileImportError.unsupportedFormat("vtt").errorDescription ?? ""
        XCTAssertEqual(
            vtt,
            "Unsupported file format: .vtt. A .vtt file is a transcript, not a book. To use it, import its audio, then choose "
                + "Attach Transcript… from the Book menu. A transcript named like its audio and beside it "
                + "is attached when the audio is imported."
        )
        XCTAssertTrue(FileImportError.unsupportedFormat("SRT").errorDescription?.contains("Attach Transcript…") == true)
        XCTAssertEqual(FileImportError.unsupportedFormat("xyz").errorDescription, "Unsupported file format: .xyz")
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
