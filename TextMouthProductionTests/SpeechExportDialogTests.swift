import AppKit
import Combine
import os
import SwiftUI
import XCTest
@testable import TextMouth

/// "Text as spoken audio" in the Export dialog (FMT43), from the dialog's model
/// and its sheet down to the file: the kind is listed for one text book,
/// unchecked, with options that start at the book's own voice, speed, and
/// pitch; while it is checked its options are drawn under it, and its
/// conversion is exactly what they ask for; Export speaks and encodes, showing
/// which chapter is being spoken; Stop and a failure keep the chapters spoken,
/// and say so once, and the next export goes on from them; and every word.
///
/// Every book lives in a library folder of the test's own, and every export
/// goes to a sandbox folder. Nothing is spoken by a real synthesizer and no
/// sound is played: speech comes from `FakeSpeechBufferSynthesizer`, the voices
/// from a lookup of the test's own (its Personal Voice is a name in that
/// lookup, never one the Mac has), the power assertion is a fake that keeps
/// nothing awake, and the chapters are kept in a sandbox folder. Each wait has
/// a limit, so a failure never hangs the suite.
@MainActor
final class SpeechExportDialogTests: XCTestCase {

    // MARK: - Listing

    /// One text book lists spoken audio last of its kinds, unchecked, with no
    /// size, and no options yet. Checked, it has its options made: they start
    /// at the speed and pitch the library holds for the book, not those of the
    /// copy chosen, name the book's voice, and list its headings; their view
    /// shows only while the kind is checked.
    func testOneTextBookListsSpokenAudioUncheckedWithItsOptions() async throws {
        let dialog = try await makeDialog("Speech Dialog Listing", makesSpeechOptions: false)
        let model = dialog.model

        XCTAssertEqual(model.choices.map(\.kind), [.originalFile, .markdown, .plainText, .spokenAudio])
        let spoken = try XCTUnwrap(model.choices.last)
        XCTAssertEqual(model.label(for: spoken), "Text as spoken audio")
        XCTAssertTrue(spoken.isAvailable)
        XCTAssertEqual(model.checked, [.originalFile], "spoken audio was checked at the start")
        XCTAssertNil(model.speechOptions, "the options were made before the kind was checked")

        model.setChecked(true, for: .spokenAudio)
        let made = await eventually { model.speechOptions != nil }
        XCTAssertTrue(made, "the options were not made when the kind was checked")
        model.setChecked(false, for: .spokenAudio)
        let options = try XCTUnwrap(model.speechOptions)
        XCTAssertEqual(options.wordsPerMinute, Self.bookSpeed)
        XCTAssertEqual(options.pitch, Self.bookPitch, accuracy: 0.000_1)
        XCTAssertEqual(options.voice?.identifier, Self.ordinaryVoice)
        XCTAssertEqual(options.voice?.name, "Test Voice")
        XCTAssertEqual(options.headings.map(\.text), ["First", "Second", "Later"])
        XCTAssertEqual(options.format, .m4b)
        XCTAssertEqual(options.choices.range, .wholeBook)

        XCTAssertNil(model.optionsView(for: .spokenAudio), "the options showed before the kind was checked")
        model.setChecked(true, for: .spokenAudio)
        XCTAssertNotNil(model.optionsView(for: .spokenAudio))
        model.setChecked(false, for: .spokenAudio)
        XCTAssertNil(model.optionsView(for: .spokenAudio))
    }

    /// Two books have no such checkbox and no options: the range and sliders
    /// are one book's.
    func testTwoBooksHaveNoSpokenAudio() async throws {
        let world = try makeIntegrationWorld("Speech Dialog Two Books")
        let first = try world.importBook(from: writeSource(named: "Harbour Pilots.md"))
        let second = try world.importBook(from: writeSource(named: "Lock Keeper.md"))
        let model = BookExportModel(
            books: [first, second],
            library: world.library,
            destination: try makeSandboxDirectory("Speech Dialog Two Books Folder"),
            speechEnvironment: try makeEnvironment(synthesizer: FakeSpeechBufferSynthesizer())
        )

        await model.load()

        XCTAssertFalse(model.choices.contains { $0.kind == .spokenAudio })
        XCTAssertNil(model.speechOptions)
        XCTAssertNil(model.optionsView(for: .spokenAudio))
    }

    /// A book's own voice wins over the global one, which speaks a book
    /// without its own; so too the global speed and pitch.
    func testABookWithoutItsOwnSettingsStartsAtTheGlobalOnes() async throws {
        let defaults = makeSandboxedPreferences("Speech Dialog Global Settings")
        defaults.set(Self.ordinaryVoice, forKey: SpeechExportVoiceSettings.globalVoiceKey)
        defaults.set(275.0, forKey: SettingsPolicy.wordsPerMinute.key)
        defaults.set(0.8, forKey: SettingsPolicy.pitchMultiplier.key)

        let dialog = try await makeDialog(
            "Speech Dialog Global",
            bookVoice: nil,
            bookSpeed: nil,
            bookPitch: nil,
            defaults: defaults
        )

        let options = try XCTUnwrap(dialog.model.speechOptions)
        XCTAssertEqual(options.voice?.identifier, Self.ordinaryVoice)
        XCTAssertEqual(options.wordsPerMinute, 275)
        XCTAssertEqual(options.pitch, 0.8, accuracy: 0.000_1)
    }

    /// A text cache only in the cloud lists the kind unavailable, saying so,
    /// and is never read for its headings: there are no options.
    func testATextCacheInTheCloudHasNoOptionsAndIsNotRead() async throws {
        let world = try makeIntegrationWorld("Speech Dialog Cloud")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md"))
        let cache = MarkdownCacheService.cacheURL(for: book)
        let cloud = FakeCloudFiles()
        cloud.markDataless(cache)
        cloud.refuseReads(of: cache)
        let model = BookExportModel(
            books: [book],
            library: world.library,
            destination: try makeSandboxDirectory("Speech Dialog Cloud Folder"),
            access: cloud.access,
            speechEnvironment: try makeEnvironment(synthesizer: FakeSpeechBufferSynthesizer())
        )

        await model.load()

        let spoken = try XCTUnwrap(model.choices.first { $0.kind == .spokenAudio })
        XCTAssertFalse(spoken.isAvailable)
        XCTAssertEqual(model.label(for: spoken), "Text as spoken audio, in the cloud")
        XCTAssertNil(model.speechOptions)
        model.setChecked(true, for: .spokenAudio)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(model.speechOptions)
        if case .notMade = model.speechOptionsMaking {} else {
            XCTFail("options were made for spoken audio in the cloud")
        }
        XCTAssertEqual(cloud.refusedReads, [], "the text in the cloud was read")
    }

    /// A text cache that cannot be read as text says so under the kind once
    /// it is checked, in place of the options: there is nothing to speak, so
    /// Export can't be pressed for it alone, and it makes no conversion. The
    /// book's other kinds are as they were.
    func testATextCacheThatCanNotBeReadSaysSoWhenTheKindIsChecked() async throws {
        let world = try makeIntegrationWorld("Speech Dialog Unreadable")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md"))
        try Data([0xFF, 0xFE, 0xFF, 0x00, 0xC0]).write(to: MarkdownCacheService.cacheURL(for: book))
        let model = BookExportModel(
            books: [book],
            library: world.library,
            destination: try makeSandboxDirectory("Speech Dialog Unreadable Folder"),
            speechEnvironment: try makeEnvironment(synthesizer: FakeSpeechBufferSynthesizer())
        )

        await model.load()
        XCTAssertEqual(model.choices.map(\.kind), [.originalFile, .markdown, .plainText, .spokenAudio])
        checkOnlySpokenAudio(model)
        let decided = await eventually {
            if case .unreadable = model.speechOptionsMaking { return true }
            return false
        }

        XCTAssertTrue(decided, "the unreadable text was not found out")
        XCTAssertNil(model.speechOptions)
        XCTAssertNotNil(model.optionsView(for: .spokenAudio), "the dialog said nothing of the unreadable text")
        XCTAssertFalse(model.canExport, "Export could be pressed for a text that can't be spoken")
        XCTAssertNil(model.conversions[.spokenAudio])
        model.setChecked(true, for: .plainText)
        XCTAssertTrue(model.canExport, "the other kinds could not be exported")
    }

    /// Opening the dialog reads no book's text, however large: the options'
    /// headings are read the first time spoken audio is checked, and only
    /// then. A text cache whose every read is refused shows it: nothing reads
    /// it as the dialog opens, and checking the kind does.
    func testOpeningTheDialogReadsNoBooksText() async throws {
        let world = try makeIntegrationWorld("Speech Dialog Open")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md"))
        let cache = MarkdownCacheService.cacheURL(for: book)
        let cloud = FakeCloudFiles()
        cloud.refuseReads(of: cache)
        let model = BookExportModel(
            books: [book],
            library: world.library,
            destination: try makeSandboxDirectory("Speech Dialog Open Folder"),
            access: cloud.access,
            speechEnvironment: try makeEnvironment(synthesizer: FakeSpeechBufferSynthesizer())
        )

        await model.load()

        XCTAssertEqual(model.phase, .ready)
        XCTAssertTrue(model.choices.contains { $0.kind == .spokenAudio && $0.isAvailable })
        if case .notMade = model.speechOptionsMaking {} else {
            XCTFail("the options were being made as the dialog opened")
        }
        // A read started as the dialog opened would come on the main actor a
        // moment later: give it the time to show.
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(cloud.refusedReads, [], "opening the dialog read the book's text")

        model.setChecked(true, for: .spokenAudio)
        let read = await eventually { !cloud.refusedReads.isEmpty }
        XCTAssertTrue(read, "checking spoken audio did not read the book's text")
        XCTAssertEqual(cloud.refusedReads, [FakeCloudFiles.key(cache)])
    }

    // MARK: - The Conversion

    /// While the kind is checked, its conversion is the speech the options
    /// ask for, as they stand when asked: the book as the library holds it,
    /// the sliders, the format, the range, and the settings speech is
    /// prepared with now. A range is titled as its file is named; unchecked,
    /// there is no conversion.
    func testTheConversionIsTheSpeechTheOptionsAskFor() async throws {
        let defaults = makeSandboxedPreferences("Speech Dialog Conversion")
        defaults.set(2.0, forKey: SettingsPolicy.punctuationPauseLevel.key)
        let service = TextSubstitutionService(rules: [SubstitutionRule(pattern: "Four", replacement: "Quattro")])
        let dialog = try await makeDialog("Speech Dialog Conversion", defaults: defaults, substitutions: service)
        let model = dialog.model
        let options = try XCTUnwrap(model.speechOptions)
        let stem = BookExportService.fileNameStem(for: dialog.book.title)
        let second = try XCTUnwrap(options.headings.first { $0.text == "Second" })
        let later = try XCTUnwrap(options.headings.first { $0.text == "Later" })
        dialog.world.library.updateBook(id: dialog.book.id) { book in
            book.author = "Ottilie Varga"
            book.skippedHeadingIDs = [later.id]
        }

        XCTAssertNil(model.conversions[.spokenAudio], "a conversion was made before the kind was checked")
        model.setChecked(true, for: .spokenAudio)

        // The whole book at first, under the book's own title.
        var expected = SpeechExportRequest(
            bookID: dialog.book.id,
            bookTitle: dialog.book.title,
            fileTitle: "\(stem) - Audio",
            titleTag: dialog.book.title,
            author: "Ottilie Varga",
            format: .m4b,
            range: .wholeBook,
            voice: SpeechExportVoiceSettings(voiceIdentifier: Self.ordinaryVoice, wordsPerMinute: Self.bookSpeed, pitch: Self.bookPitch),
            skippedHeadingIDs: [later.id],
            preparation: SpeechPreparationSettings.current(substitutions: service, defaults: defaults)
        )
        XCTAssertEqual(model.conversions[.spokenAudio], .speech(expected))
        XCTAssertEqual(expected.preparation.punctuationPauseLevel, 2, "the pause level was not the test's")
        XCTAssertNotEqual(expected.preparation.substitutions, .none, "the rules were not the test's")

        // Each change in the options reaches the conversion.
        options.format = .mp3
        options.wordsPerMinute = 250
        options.pitch = 0.9
        options.setFrom(second.id)
        options.setThrough(second.id)
        expected.fileTitle = "\(stem) - Second"
        expected.titleTag = "\(stem) - Second"
        expected.format = .mp3
        expected.range = SpeechExportRange(fromHeadingID: second.id, throughHeadingID: second.id)
        expected.voice = SpeechExportVoiceSettings(voiceIdentifier: Self.ordinaryVoice, wordsPerMinute: 250, pitch: 0.9)
        XCTAssertEqual(model.conversions[.spokenAudio], .speech(expected))

        model.setChecked(false, for: .spokenAudio)
        XCTAssertNil(model.conversions[.spokenAudio], "a conversion was left after the kind was unchecked")
    }

    /// With no voice installed, the conversion names none, and the export
    /// refuses with the sentence the options' line says.
    func testNoVoiceIsRefusedWithTheSentenceTheOptionsSay() async throws {
        let dialog = try await makeDialog("Speech Dialog No Voice", bookVoice: nil, knownVoices: [])
        let model = dialog.model
        let options = try XCTUnwrap(model.speechOptions)
        XCTAssertNil(options.voice)
        XCTAssertEqual(SpeechExportWording.voiceLine(options.voice), SpeechExportError.noVoice.errorDescription)

        checkOnlySpokenAudio(model)
        let outcome = try await end(of: ExportRun(of: model))

        XCTAssertEqual(dialog.synthesizer.written, [], "a word was spoken")
        XCTAssertEqual(outcome.exported, [])
        XCTAssertEqual(
            model.summary,
            "Couldn't export \(BookExportService.fileNameStem(for: dialog.book.title)) - Audio.m4b: No voice "
                + "is installed. Add one in System Settings, Accessibility, Spoken Content, then export "
                + "again."
        )
    }

    // MARK: - Exporting

    /// Export with only the kind checked writes "<stem> - Audio.m4b" with a
    /// chapter for each heading, spoken with the substitution rules in force,
    /// at the sliders' rate and pitch. While it speaks, the progress says
    /// which chapter, and the bar moves; the Stop button's hint is the
    /// speech's. It ends with one announcement, closes (`didEverything`), and
    /// shows no progress or summary.
    func testExportingWritesTheFileShowsWhichChapterAndAnnouncesOnce() async throws {
        let gate = Gate()
        defer { gate.open() }
        let synthesizer = FakeSpeechBufferSynthesizer(framesPerUnit: 1_000, beforeWrite: { utterance in
            if utterance.text.contains("Six") {
                gate.pass()
            }
        })
        let service = TextSubstitutionService(rules: [SubstitutionRule(pattern: "Four", replacement: "Quattro")])
        let dialog = try await makeDialog("Speech Dialog Export", synthesizer: synthesizer, substitutions: service)
        let model = dialog.model
        let options = try XCTUnwrap(model.speechOptions)
        options.wordsPerMinute = 250
        options.pitch = 0.9
        checkOnlySpokenAudio(model)
        let announcements = AnnouncementCapture()
        defer { announcements.stop() }
        XCTAssertFalse(model.isExportingSpeech)
        XCTAssertNil(model.progressFraction)

        let run = ExportRun(of: model)

        // Held as the third and last chapter begins: two are done.
        let reached = await eventually { model.progressText == "Speaking chapter 3 of 3…" }
        XCTAssertTrue(reached, "the progress says \(String(describing: model.progressText))")
        let fraction = try XCTUnwrap(model.progressFraction)
        XCTAssertGreaterThan(fraction, 0)
        XCTAssertLessThan(fraction, 1)
        XCTAssertEqual(model.speechProgress?.fraction, fraction)
        XCTAssertTrue(model.isExportingSpeech)
        XCTAssertEqual(announcements.messages, [], "the export announced something before it ended")

        gate.open()
        let outcome = try await end(of: run)

        let file = dialog.folder.appendingPathComponent("\(BookExportService.fileNameStem(for: dialog.book.title)) - Audio.m4b")
        XCTAssertEqual(outcome.exported, [file])
        XCTAssertEqual(outcome.failures, [])
        XCTAssertTrue(BookExportModel.didEverything(outcome))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dialog.folder.path), [file.lastPathComponent])
        let chapters = await AudioPlaybackService.extractChapters(from: file)
        XCTAssertEqual(chapters.map(\.title), ["First", "Second", "Later"])

        let spoken = synthesizer.written
        XCTAssertEqual(Set(spoken.map(\.voiceIdentifier)), [Self.ordinaryVoice])
        XCTAssertEqual(Set(spoken.map(\.rate)), [SpeechService.rateForWPM(250)])
        XCTAssertEqual(Set(spoken.map(\.pitchMultiplier)), [Float(SpeechService.clampedPitch(0.9))])
        XCTAssertTrue(spoken.contains { $0.text.contains("Quattro five.") }, "the substitution rule was not applied: \(spoken.map(\.text))")

        XCTAssertEqual(announcements.messages, ["Exported 1 item to \(BookExportWording.folderName(of: dialog.folder))."])
        XCTAssertNil(model.summary)
        XCTAssertNil(model.speechProgress)
        XCTAssertNil(model.progressText)
        XCTAssertNil(model.progressFraction)
        XCTAssertFalse(model.isExportingSpeech)
    }

    /// The progress the dialog shows, whatever the export tells it: the
    /// encoding by its own words and fraction, each out-of-range fraction held
    /// to the bar's ends, and, once the speech export has ended while the
    /// export goes on, the items done. Nothing changes it once the export has
    /// ended.
    func testTheProgressTheDialogShowsForEachStage() async throws {
        let gate = Gate()
        defer { gate.open() }
        let synthesizer = FakeSpeechBufferSynthesizer(framesPerUnit: 1_000, beforeWrite: { _ in gate.pass() })
        let dialog = try await makeDialog("Speech Dialog Stages", synthesizer: synthesizer)
        let model = dialog.model
        checkOnlySpokenAudio(model)

        let run = ExportRun(of: model)
        let reached = await eventually { model.progressText == "Speaking chapter 1 of 3…" }
        XCTAssertTrue(reached, "the progress says \(String(describing: model.progressText))")
        XCTAssertEqual(model.progressFraction, 0)

        model.showSpeechProgress(.encoding(chapters: 3, fraction: 0.5))
        XCTAssertEqual(model.progressText, "Encoding the audio file…")
        XCTAssertEqual(model.progressFraction, 0.5)

        model.showSpeechProgress(.encoding(chapters: 3, fraction: 1.5))
        XCTAssertEqual(model.progressFraction, 1, "a fraction past the end was shown as it is")

        // The first file is not done yet, and the items are not yet counted.
        model.showSpeechProgress(.ended(kept: 0, total: 3))
        XCTAssertNil(model.speechProgress)
        XCTAssertEqual(model.progressText, "Exporting…")
        XCTAssertNil(model.progressFraction)

        gate.open()
        _ = try await end(of: run)

        model.showSpeechProgress(.speaking(done: 1, total: 3, fraction: 0.5))
        XCTAssertNil(model.speechProgress, "a report after the export ended was shown")
    }

    /// Stop during the third chapter ends the export, keeping the two chapters
    /// spoken: the summary and the one announcement say so, and how to go on.
    /// The next export of the same range and speech speaks only the rest,
    /// writes the whole file, and closes.
    func testStopKeepsTheChaptersSaysSoAndTheNextExportGoesOn() async throws {
        let gate = Gate()
        defer { gate.open() }
        let synthesizer = FakeSpeechBufferSynthesizer(framesPerUnit: 1_000, beforeWrite: { utterance in
            if utterance.text.contains("Six") {
                gate.pass()
            }
        })
        let dialog = try await makeDialog("Speech Dialog Stop", synthesizer: synthesizer)
        let model = dialog.model
        checkOnlySpokenAudio(model)
        let announcements = AnnouncementCapture()
        defer { announcements.stop() }

        let stopped = ExportRun(of: model)
        let reached = await eventually { model.progressText == "Speaking chapter 3 of 3…" }
        XCTAssertTrue(reached, "the progress says \(String(describing: model.progressText))")
        model.stop()
        gate.open()
        let outcome = try await end(of: stopped)

        let words = "Export stopped. Nothing was exported. Kept 2 of 3 chapters " + Self.keptUntil
            + ". To go on from chapter 3, export the same range at the same speed and pitch."
        XCTAssertTrue(outcome.wasCancelled)
        XCTAssertEqual(outcome.exported, [])
        XCTAssertEqual(model.summary, words)
        XCTAssertEqual(announcements.messages, [words])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dialog.folder.path), [], "a stopped export left a file")
        XCTAssertTrue(model.canExport, "Export could not be pressed again")
        XCTAssertNil(model.speechProgress)

        let spokenBefore = synthesizer.written.count
        let again = try await end(of: ExportRun(of: model))

        let spokenAgain = synthesizer.written.dropFirst(spokenBefore).map(\.text)
        XCTAssertEqual(spokenAgain.count, 1, "the next export spoke \(spokenAgain)")
        XCTAssertTrue(spokenAgain.first?.contains("Six seven eight.") == true, "the next export spoke \(spokenAgain)")
        let file = dialog.folder.appendingPathComponent("\(BookExportService.fileNameStem(for: dialog.book.title)) - Audio.m4b")
        XCTAssertEqual(again.exported, [file])
        XCTAssertTrue(BookExportModel.didEverything(again))
        XCTAssertNil(model.summary, "the last export's words were left")
        let chapters = await AudioPlaybackService.extractChapters(from: file)
        XCTAssertEqual(chapters.map(\.title), ["First", "Second", "Later"])
    }

    /// Stop before a word is spoken keeps nothing, and says only that the
    /// export stopped.
    func testStopBeforeTheFirstChapterEndsKeepsNothingAndSaysNothingOfIt() async throws {
        let gate = Gate()
        defer { gate.open() }
        let synthesizer = FakeSpeechBufferSynthesizer(framesPerUnit: 1_000, beforeWrite: { _ in gate.pass() })
        let dialog = try await makeDialog("Speech Dialog Early Stop", synthesizer: synthesizer)
        let model = dialog.model
        checkOnlySpokenAudio(model)

        let stopped = ExportRun(of: model)
        let reached = await eventually { model.progressText == "Speaking chapter 1 of 3…" }
        XCTAssertTrue(reached, "the progress says \(String(describing: model.progressText))")
        model.stop()
        gate.open()
        _ = try await end(of: stopped)

        XCTAssertEqual(model.summary, "Export stopped. Nothing was exported.")
    }

    /// A chapter the speech engine refuses fails the file by name, with the
    /// reason, and the chapters before it are kept, as the same words say.
    func testAChapterRefusedSaysWhyAndWhatIsKept() async throws {
        let synthesizer = FakeSpeechBufferSynthesizer(framesPerUnit: 1_000, refuses: { $0.text.contains("Six") })
        let dialog = try await makeDialog("Speech Dialog Refused", synthesizer: synthesizer)
        let model = dialog.model
        checkOnlySpokenAudio(model)
        let announcements = AnnouncementCapture()
        defer { announcements.stop() }

        let outcome = try await end(of: ExportRun(of: model))

        let stem = BookExportService.fileNameStem(for: dialog.book.title)
        let words = "Couldn't export \(stem) - Audio.m4b: The Mac's speech engine refused to speak part of “Later”, "
            + "even with its brackets made silent. Kept 2 of 3 chapters " + Self.keptUntil
            + ". To go on from chapter 3, export the same range at the same speed and pitch."
        XCTAssertEqual(outcome.exported, [])
        XCTAssertEqual(model.summary, words)
        XCTAssertEqual(announcements.messages, [words])
    }

    /// A Personal Voice is refused before anything is spoken: the options'
    /// line says so as the dialog opens, the summary names the file with the
    /// same sentence, and it says nothing of chapters kept.
    func testAPersonalVoiceNamesTheFileAndKeepsNothing() async throws {
        let dialog = try await makeDialog("Speech Dialog Personal Voice", bookVoice: Self.personalVoice)
        let model = dialog.model
        let options = try XCTUnwrap(model.speechOptions)
        let refusal = try XCTUnwrap(SpeechExportError.personalVoice(name: "Test Personal").errorDescription)
        XCTAssertEqual(SpeechExportWording.voiceLine(options.voice), refusal)
        checkOnlySpokenAudio(model)
        let announcements = AnnouncementCapture()
        defer { announcements.stop() }

        let outcome = try await end(of: ExportRun(of: model))

        let stem = BookExportService.fileNameStem(for: dialog.book.title)
        let words = "Couldn't export \(stem) - Audio.m4b: “Test Personal” is a Personal Voice, which macOS "
            + "can't record to a file. Choose another voice with the Voice button in the reader, then export "
            + "again."
        XCTAssertEqual(outcome.exported, [])
        XCTAssertEqual(model.summary, words)
        XCTAssertEqual(announcements.messages, [words])
        XCTAssertEqual(dialog.synthesizer.written, [], "a word was spoken")
    }

    /// Spoken audio checked beside the plain text writes both: the plain text
    /// first, as the dialog lists them, then the audio. The announcement counts
    /// both, and says nothing kept, since the chapters went with the file.
    func testSpokenAudioBesideAnotherKindWritesBoth() async throws {
        let dialog = try await makeDialog("Speech Dialog Two Kinds")
        let model = dialog.model
        model.setChecked(false, for: .originalFile)
        model.setChecked(true, for: .plainText)
        model.setChecked(true, for: .spokenAudio)
        let announcements = AnnouncementCapture()
        defer { announcements.stop() }

        let outcome = try await end(of: ExportRun(of: model))

        let stem = BookExportService.fileNameStem(for: dialog.book.title)
        XCTAssertEqual(outcome.exported.map(\.lastPathComponent), ["\(stem) - Text.txt", "\(stem) - Audio.m4b"])
        XCTAssertEqual(announcements.messages, ["Exported 2 items to \(BookExportWording.folderName(of: dialog.folder))."])
        XCTAssertNil(model.summary)
    }

    /// An MP3 made of more headings than it has chapters for, 256 of them,
    /// says so at its end, suggesting M4B; an MP3 of fewer, or an M4B of as
    /// many, says nothing of it.
    func testAnMP3OfMoreHeadingsThanItHasChaptersForSaysSoAtItsEnd() async throws {
        let markdown = (1...256).map { "# Heading \($0)\n\nWord.\n" }.joined(separator: "\n")
        let dialog = try await makeDialog(
            "Speech Dialog MP3 Chapters",
            markdown: markdown,
            synthesizer: FakeSpeechBufferSynthesizer(framesPerUnit: 200)
        )
        let model = dialog.model
        let options = try XCTUnwrap(model.speechOptions)
        options.format = .mp3
        XCTAssertEqual(options.mp3ChapterNote, SpeechExportWording.mp3ChapterLimit(headings: 256))
        checkOnlySpokenAudio(model)
        let announcements = AnnouncementCapture()
        defer { announcements.stop() }

        let outcome = try await end(of: ExportRun(of: model), within: 120)

        let stem = BookExportService.fileNameStem(for: dialog.book.title)
        XCTAssertEqual(outcome.exported.map(\.lastPathComponent), ["\(stem) - Audio.mp3"])
        XCTAssertEqual(
            announcements.messages,
            ["Exported 1 item to \(BookExportWording.folderName(of: dialog.folder)). "
                + SpeechExportWording.mp3ChaptersKept(of: 256)]
        )

        options.format = .m4b
        _ = try await end(of: ExportRun(of: model), within: 120)
        XCTAssertEqual(announcements.messages.last, "Exported 1 item to \(BookExportWording.folderName(of: dialog.folder)).")
    }

    // MARK: - The Folder

    /// Export refuses the folder speech exports keep their chapters in, and
    /// any folder inside it, which TextMouth empties: it says why, once, and
    /// writes nothing there.
    func testExportRefusesTheFolderOfKeptChapters() async throws {
        let dialog = try await makeDialog("Speech Dialog Kept Folder")
        let model = dialog.model
        let inside = dialog.storeRoot.appendingPathComponent("Inside", isDirectory: true)
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        model.setChecked(true, for: .plainText)
        let announcements = AnnouncementCapture()
        defer { announcements.stop() }

        for folder in [inside, dialog.storeRoot] {
            model.destination = folder
            let run = ExportRun(of: model)
            let ended = await eventually { run.hasEnded }
            XCTAssertTrue(ended, "the export did not end")
            XCTAssertNil(run.outcome, "an export began into \(folder.lastPathComponent)")
            XCTAssertEqual(model.summary, SpeechExportWording.destinationInKeptChapters)
        }
        XCTAssertEqual(announcements.messages, Array(repeating: SpeechExportWording.destinationInKeptChapters, count: 2))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: inside.path), [], "a file was written there")
    }

    // MARK: - Quitting

    /// The record of speech exports under way holds a quit while one runs,
    /// and only then: stopping them stops each as Stop does, and the quit is
    /// answered once every one has ended.
    func testTheRecordOfExportsHoldsAQuitWhileOneRuns() async throws {
        let underWay = SpeechExportsUnderWay()
        var replies: [Bool] = []
        XCTAssertFalse(QuitHold.hold([underWay.quitWork()]) { _ in XCTFail("no export under way held the quit") })

        let first = BookExportCancellation()
        let second = BookExportCancellation()
        let firstID = underWay.begin(first)
        let secondID = underWay.begin(second)
        XCTAssertTrue(underWay.isRunning)
        XCTAssertTrue(QuitHold.hold([underWay.quitWork()]) { replies.append($0) }, "the quit was not held")
        let stopped = await eventually { first.isCancelled && second.isCancelled }
        XCTAssertTrue(stopped, "the quit did not stop the exports")
        underWay.ended(firstID)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(replies, [], "the quit went ahead while an export was still ending")

        underWay.ended(secondID)
        let answered = await eventually { !replies.isEmpty }
        XCTAssertTrue(answered, "the quit was not answered once the exports had ended")
        XCTAssertEqual(replies, [true])
        XCTAssertFalse(underWay.isRunning)
    }

    /// A quit while a dialog speaks a book waits for its export to stop as
    /// Stop stops it: the two chapters spoken are kept, and the dialog says
    /// so, and the quit goes ahead once the export has ended.
    func testAQuitStopsASpeechExportCleanlyKeepingItsChapters() async throws {
        let gate = Gate()
        defer { gate.open() }
        let synthesizer = FakeSpeechBufferSynthesizer(framesPerUnit: 1_000, beforeWrite: { utterance in
            if utterance.text.contains("Six") {
                gate.pass()
            }
        })
        let underWay = SpeechExportsUnderWay()
        let dialog = try await makeDialog("Speech Dialog Quit", synthesizer: synthesizer, speechExportsUnderWay: underWay)
        let model = dialog.model
        checkOnlySpokenAudio(model)
        let announcements = AnnouncementCapture()
        defer { announcements.stop() }
        var replies: [Bool] = []

        let run = ExportRun(of: model)
        let reached = await eventually { model.progressText == "Speaking chapter 3 of 3…" }
        XCTAssertTrue(reached, "the progress says \(String(describing: model.progressText))")
        XCTAssertTrue(underWay.isRunning, "the export did not say it was under way")
        XCTAssertTrue(QuitHold.hold([underWay.quitWork()]) { replies.append($0) }, "the quit was not held")
        gate.open()
        let outcome = try await end(of: run)

        XCTAssertTrue(outcome.wasCancelled, "the quit did not stop the export")
        XCTAssertEqual(outcome.exported, [])
        XCTAssertTrue(
            model.summary?.hasSuffix(SpeechExportWording.kept(done: 2, total: 3) ?? "-") == true,
            "\(String(describing: model.summary))"
        )
        let answered = await eventually { !replies.isEmpty }
        XCTAssertTrue(answered, "the quit was not answered once the export had ended")
        XCTAssertEqual(replies, [true])
        XCTAssertFalse(underWay.isRunning)
    }

    /// An export of other kinds alone holds no quit.
    func testAnExportWithoutSpokenAudioHoldsNoQuit() async throws {
        let underWay = SpeechExportsUnderWay()
        let dialog = try await makeDialog("Speech Dialog Quit Other", speechExportsUnderWay: underWay)
        let model = dialog.model
        model.setChecked(true, for: .plainText)
        model.setChecked(false, for: .originalFile)
        var seenRunning = false

        let run = ExportRun(of: model)
        let ended = await eventually {
            seenRunning = seenRunning || underWay.isRunning
            return run.hasEnded
        }

        XCTAssertTrue(ended)
        XCTAssertFalse(seenRunning, "an export without spoken audio said it was making some")
    }

    // MARK: - Drawn

    /// Checking the kind draws its options' three pop-ups and two sliders
    /// under it; unchecking takes them away. While an export runs they are
    /// disabled with the kinds' checkboxes, Stop's hint is the speech's, and
    /// the export's end enables them again.
    func testTheSheetDrawsTheOptionsWhileCheckedAndDisablesThemWhileExporting() throws {
        let gate = Gate()
        defer { gate.open() }
        let synthesizer = FakeSpeechBufferSynthesizer(framesPerUnit: 1_000, beforeWrite: { _ in gate.pass() })
        let dialog = try makeUnlistedDialog("Speech Dialog Drawn", synthesizer: synthesizer)
        let model = dialog.model
        let announcements = AnnouncementCapture()
        defer { announcements.stop() }
        let size = NSSize(width: 560, height: 700)
        let sheet = BookExportSheet(model: model, close: {}).frame(width: size.width, height: size.height)

        // Hosting the sheet runs its own `load()`, which lists the book.
        withHostedView(sheet, size: size, until: { self.checkboxes(in: $0).count == 4 && model.phase == .ready }) { hosting in
            XCTAssertTrue(self.popUps(in: hosting).isEmpty, "the options were drawn before the kind was checked")
            XCTAssertTrue(self.sliders(in: hosting).isEmpty, "the options were drawn before the kind was checked")

            model.setChecked(false, for: .originalFile)
            model.setChecked(true, for: .spokenAudio)
            XCTAssertTrue(waitUntil(timeout: 5) {
                hosting.layoutSubtreeIfNeeded()
                return self.popUps(in: hosting).count == 3 && self.sliders(in: hosting).count == 2
            }, "the options were not drawn when the kind was checked")
            XCTAssertEqual(
                self.popUps(in: hosting).first?.itemTitles,
                SpeechExportFormat.available.map(\.title)
            )

            model.setChecked(false, for: .spokenAudio)
            XCTAssertTrue(waitUntil(timeout: 5) {
                hosting.layoutSubtreeIfNeeded()
                return self.popUps(in: hosting).isEmpty && self.sliders(in: hosting).isEmpty
            }, "the options stayed when the kind was unchecked")

            model.setChecked(true, for: .spokenAudio)
            XCTAssertTrue(waitUntil(timeout: 5) {
                hosting.layoutSubtreeIfNeeded()
                return self.popUps(in: hosting).count == 3 && self.sliders(in: hosting).allSatisfy(\.isEnabled)
            }, "the options were not drawn enabled while nothing is exported")

            let export = Task { await model.export() }
            _ = export
            XCTAssertTrue(waitUntil(timeout: 10) { !synthesizer.written.isEmpty && model.isExporting }, "the export did not begin to speak")
            XCTAssertTrue(waitUntil(timeout: 5) {
                hosting.layoutSubtreeIfNeeded()
                return self.popUps(in: hosting).allSatisfy { !$0.isEnabled } && self.sliders(in: hosting).allSatisfy { !$0.isEnabled }
            }, "the options stayed enabled while the export ran")
            XCTAssertTrue(self.checkboxes(in: hosting).allSatisfy { !$0.isEnabled }, "a kind's checkbox stayed enabled")
            XCTAssertTrue(model.isExportingSpeech)

            gate.open()
            XCTAssertTrue(waitUntil(timeout: 20) {
                if case .finished = model.phase { return true }
                return false
            }, "the export did not end")
            XCTAssertTrue(waitUntil(timeout: 5) {
                hosting.layoutSubtreeIfNeeded()
                return self.sliders(in: hosting).allSatisfy(\.isEnabled) && self.popUps(in: hosting).allSatisfy(\.isEnabled)
            }, "the options stayed disabled after the export ended")
        }
    }

    /// The sheet with the options shown, and a heading of 300 characters, is
    /// no wider than 560 points and no taller than 700: it fits any Mac's
    /// screen, and a long heading never widens it. Nor does a long folder
    /// name: the sandbox folder it exports to is named by its label and a
    /// UUID, 61 characters, which made the sheet 669 points wide until the
    /// folder line stopped growing to show a name whole (train 1107-0800).
    func testTheSheetWithTheOptionsFits() async throws {
        let long = String(repeating: "W", count: 300)
        let markdown = """
        <!-- chapter: First -->
        # First

        One two three.

        <!-- chapter: Second -->
        # \(long)

        Four five.
        """
        let dialog = try await makeDialog("Speech Dialog Fit", markdown: markdown)
        let model = dialog.model
        let options = try XCTUnwrap(model.speechOptions)
        let longHeading = try XCTUnwrap(options.headings.first { $0.text == long }, "the long heading was not read")
        options.setFrom(longHeading.id)
        checkOnlySpokenAudio(model)

        let size = NSHostingView(rootView: BookExportSheet(model: model, close: {})).fittingSize

        XCTAssertGreaterThan(size.width, 0)
        XCTAssertLessThanOrEqual(size.width, 560)
        XCTAssertGreaterThan(size.height, 0)
        XCTAssertLessThanOrEqual(size.height, 700)
    }

    // MARK: - The Words

    /// What the dialog says while a speech export runs and when it ends,
    /// exactly.
    func testTheWords() {
        XCTAssertEqual(
            SpeechExportWording.progress(.speaking(done: 0, total: 12, fraction: 0)),
            "Speaking chapter 1 of 12…"
        )
        XCTAssertEqual(
            SpeechExportWording.progress(.speaking(done: 11, total: 12, fraction: 0.9)),
            "Speaking chapter 12 of 12…"
        )
        XCTAssertEqual(
            SpeechExportWording.progress(.speaking(done: 12, total: 12, fraction: 1)),
            "Speaking chapter 12 of 12…",
            "every chapter done, as when all were kept, counted a chapter past the last"
        )
        XCTAssertEqual(SpeechExportWording.progress(.encoding(chapters: 12, fraction: 0.5)), "Encoding the audio file…")
        XCTAssertNil(SpeechExportWording.progress(.ended(kept: 3, total: 12)))
        XCTAssertEqual(
            SpeechExportWording.stopHint,
            "Stops the export and keeps the chapters already spoken " + Self.keptUntil
                + ". Exporting the same range at the same speed and pitch goes on from them."
        )
        XCTAssertNil(SpeechExportWording.kept(done: 0, total: 12))
        XCTAssertEqual(
            SpeechExportWording.kept(done: 1, total: 12),
            "Kept 1 of 12 chapters " + Self.keptUntil
                + ". To go on from chapter 2, export the same range at the same speed and pitch."
        )
        XCTAssertEqual(
            SpeechExportWording.kept(done: 11, total: 12),
            "Kept 11 of 12 chapters " + Self.keptUntil
                + ". To go on from chapter 12, export the same range at the same speed and pitch."
        )
        XCTAssertEqual(
            SpeechExportWording.kept(done: 1, total: 1),
            "Kept the spoken chapter " + Self.keptUntil
                + ". To make the audio file from it, export the same range at the same speed and pitch."
        )
        XCTAssertEqual(
            SpeechExportWording.kept(done: 12, total: 12),
            "Kept all 12 spoken chapters " + Self.keptUntil
                + ". To make the audio file from them, export the same range at the same speed and pitch."
        )
    }

    /// The fraction a progress bar shows of each part of an export: the part's
    /// own, held to the bar's ends, and none once it has ended.
    func testTheFractionOfEachProgress() {
        XCTAssertEqual(SpeechExportProgress.speaking(done: 1, total: 3, fraction: 0.25).fraction, 0.25)
        XCTAssertEqual(
            SpeechExportWording.destinationInKeptChapters,
            "Export can't write into the folder where TextMouth keeps spoken chapters, which it empties. "
                + "Choose another folder."
        )
        XCTAssertEqual(SpeechExportWording.readingHeadings, "Reading the book's headings…")
        XCTAssertEqual(
            SpeechExportWording.unreadableText,
            "This book's text can't be read, so it can't be spoken into an audio file."
        )
        XCTAssertEqual(SpeechExportProgress.encoding(chapters: 3, fraction: 0.75).fraction, 0.75)
        XCTAssertEqual(SpeechExportProgress.encoding(chapters: 3, fraction: 1.2).fraction, 1)
        XCTAssertEqual(SpeechExportProgress.speaking(done: 0, total: 3, fraction: -0.2).fraction, 0)
        XCTAssertNil(SpeechExportProgress.ended(kept: 1, total: 3).fraction)
    }

    // MARK: - The iPhone's Session

    /// A spoken audio export run through the session (FR31, phase 2) asks for the system's continued task as it begins,
    /// titled as the sheet is and subtitled before any progress, tells it the progress as the chapters are spoken, and
    /// ends it, a success, with the export. Nothing is spoken aloud: the synthesizer is the fake.
    func testTheSessionCarriesASpokenAudioExportThroughItsTask() async throws {
        let gate = Gate()
        defer { gate.open() }
        let synthesizer = FakeSpeechBufferSynthesizer(framesPerUnit: 1_000, beforeWrite: { utterance in
            if utterance.text.contains("Six") { gate.pass() }
        })
        let dialog = try await makeDialog("Speech Session Task", synthesizer: synthesizer)
        let model = dialog.model
        checkOnlySpokenAudio(model)
        let tasks = RecordedTasks()
        let session = PhoneExportSession(tasking: tasks.tasking)

        let run = ExportRun(of: model, through: session)
        let reached = await eventually { model.progressText == "Speaking chapter 3 of 3…" }
        XCTAssertTrue(reached, "the progress says \(String(describing: model.progressText))")
        let carried = await eventually { tasks.task.updates.contains { $0.subtitle == "Speaking chapter 3 of 3…" } }
        XCTAssertTrue(carried, "the task heard \(tasks.task.updates.map(\.subtitle))")
        XCTAssertEqual(tasks.begun.map(\.title), [model.title], "one task, titled as the sheet is")
        XCTAssertEqual(tasks.task.finishes, [], "the task ended before the export did")

        gate.open()
        let outcome = try await end(of: run)

        XCTAssertTrue(BookExportModel.didEverything(outcome))
        let ended = await eventually { tasks.task.finishes == [true] }
        XCTAssertTrue(ended, "the task's ends were \(tasks.task.finishes)")
        let units = tasks.task.updates.map(\.completedUnits)
        XCTAssertEqual(units, units.sorted(), "the task's progress went back: \(units)")
        XCTAssertGreaterThan(units.last ?? 0, 0)
    }

    /// The task's bar measures the whole export, so it moves all through a spoken audio file: speaking fills four fifths
    /// of the file's part and the encoding the rest, where the speech's own fraction starts again at 0 for the encoding and
    /// a bar that never goes back would stand still through it, which the system takes for a stalled task. Files before
    /// the spoken audio count as written, and until the first is written, the file under way stands for the whole.
    /// (Here and not in the plain values' `PhoneExportSpeechTests`, which the iPhone's bundle shares: its sound census
    /// reads the progress's `speaking` case as speech.)
    func testTheTasksBarMeasuresTheWholeExportAndMovesThroughTheEncoding() {
        typealias Mirror = PhoneExportTaskMirror
        // The steps one spoken audio file goes through, alone in its export (its count not known yet).
        let steps: [(SpeechExportProgress, Double)] = [
            (.speaking(done: 0, total: 3, fraction: 0), 0),
            (.speaking(done: 1, total: 3, fraction: 0.5), 0.4),
            (.speaking(done: 3, total: 3, fraction: 1), 0.8),
            (.encoding(chapters: 3, fraction: 0), 0.8),
            (.encoding(chapters: 3, fraction: 0.5), 0.9),
            (.encoding(chapters: 3, fraction: 1), 1)
        ]
        for (speech, expected) in steps {
            XCTAssertEqual(Mirror.fraction(done: 0, total: 0, speech: speech), expected, accuracy: 1e-9, "\(speech)")
        }
        // Through the floor the session passes them through, the bar rises from the speaking's end through the encoding.
        var told = Mirror.NeverBackwards()
        let units = steps.map { step in
            told.next(Mirror.update(title: "t", progressText: "w", fraction: Mirror.fraction(done: 0, total: 0, speech: step.0))).completedUnits
        }
        XCTAssertEqual(units, [0, 400, 800, 800, 900, 1_000], "the bar stood still through the encoding")

        // One file written of two, the spoken audio second: its part is the second half of the bar.
        XCTAssertEqual(Mirror.fraction(done: 1, total: 2, speech: nil), 0.5, accuracy: 1e-9)
        XCTAssertEqual(Mirror.fraction(done: 1, total: 2, speech: .speaking(done: 0, total: 4, fraction: 0.5)), 0.7, accuracy: 1e-9)
        XCTAssertEqual(Mirror.fraction(done: 1, total: 2, speech: .encoding(chapters: 4, fraction: 1)), 1, accuracy: 1e-9)
        // An ended speech, or no speech, counts only the files written; a count out of range is held to it.
        XCTAssertEqual(Mirror.fraction(done: 1, total: 4, speech: .ended(kept: 2, total: 3)), 0.25, accuracy: 1e-9)
        XCTAssertEqual(Mirror.fraction(done: 0, total: 0, speech: nil), 0)
        XCTAssertEqual(Mirror.fraction(done: 5, total: 2, speech: nil), 1)
        XCTAssertEqual(Mirror.fraction(done: -1, total: 2, speech: .speaking(done: 0, total: 1, fraction: 7)), 0.4, accuracy: 1e-9)
    }

    /// The task's bar moves on through the encoding: the sheet's bar starts again at 0 when the file is encoded, and the
    /// task's, which never goes back, measures the whole export, so it rises from where the speaking left it to the end
    /// (the system expires a task that reports no progress, and a long book's encoding takes minutes). The export is held
    /// in its last chapter while the test shows each stage, as the export would tell it.
    func testTheTasksBarMovesOnThroughTheEncoding() async throws {
        let gate = Gate()
        defer { gate.open() }
        let synthesizer = FakeSpeechBufferSynthesizer(framesPerUnit: 1_000, beforeWrite: { utterance in
            if utterance.text.contains("Six") { gate.pass() }
        })
        let dialog = try await makeDialog("Speech Session Encoding Bar", synthesizer: synthesizer)
        let model = dialog.model
        checkOnlySpokenAudio(model)
        let tasks = RecordedTasks()
        let session = PhoneExportSession(tasking: tasks.tasking)
        let run = ExportRun(of: model, through: session)
        let reached = await eventually { model.progressText == "Speaking chapter 3 of 3…" }
        XCTAssertTrue(reached, "the progress says \(String(describing: model.progressText))")

        // Each stage as the export tells it, carried to the task at once: the last chapter spoken, then the encoding.
        var units: [Int64] = []
        for stage in [
            SpeechExportProgress.speaking(done: 3, total: 3, fraction: 1),
            .encoding(chapters: 3, fraction: 0),
            .encoding(chapters: 3, fraction: 0.5),
            .encoding(chapters: 3, fraction: 1)
        ] {
            model.showSpeechProgress(stage)
            session.carry(model)
            units.append(tasks.task.updates.last?.completedUnits ?? -1)
        }

        XCTAssertEqual(tasks.task.updates.last?.subtitle, "Encoding the audio file…")
        // The speaking fills its share of the bar, and the encoding moves it on from there to the whole.
        let share = PhoneExportTaskMirror.speakingShare
        let expected = [share, share, share + (1 - share) / 2, 1].map {
            PhoneExportTaskMirror.update(title: "", progressText: nil, fraction: $0).completedUnits
        }
        XCTAssertEqual(units, expected, "the task's bar stood still through the encoding, or did not end whole")
        gate.open()
        let outcome = try await end(of: run)
        XCTAssertTrue(BookExportModel.didEverything(outcome))
        let ended = await eventually { tasks.task.finishes == [true] }
        XCTAssertTrue(ended, "the task's ends were \(tasks.task.finishes)")
    }

    /// The system's expiry, or Cancel in its Live Activity, is Stop: the export ends stopped, its chapters kept, and the
    /// task ends as no success.
    func testTheTasksExpiryStopsTheExportAndEndsTheTaskAsNoSuccess() async throws {
        let gate = Gate()
        defer { gate.open() }
        let synthesizer = FakeSpeechBufferSynthesizer(framesPerUnit: 1_000, beforeWrite: { utterance in
            if utterance.text.contains("Six") { gate.pass() }
        })
        let dialog = try await makeDialog("Speech Session Expiry", synthesizer: synthesizer)
        let model = dialog.model
        checkOnlySpokenAudio(model)
        let tasks = RecordedTasks()
        let session = PhoneExportSession(tasking: tasks.tasking)
        let run = ExportRun(of: model, through: session)
        let reached = await eventually { model.progressText == "Speaking chapter 3 of 3…" }
        XCTAssertTrue(reached)

        tasks.expire()
        gate.open()
        let outcome = try await end(of: run)

        XCTAssertTrue(outcome.wasCancelled, "the expiry did not stop the export")
        XCTAssertEqual(model.finishedWords?.hasPrefix("iOS stopped this export. Export stopped."), true, "\(String(describing: model.finishedWords))")
        XCTAssertNil(model.wordsBeforeTheEnd, "the note outlived the export it was for")
        let ended = await eventually { tasks.task.finishes == [false] }
        XCTAssertTrue(ended, "the task's ends were \(tasks.task.finishes)")
        XCTAssertTrue(model.summary?.contains("Kept 2 of 3 chapters") == true, "\(String(describing: model.summary))")
    }

    /// An export of no spoken audio asks for no task: it takes seconds, and the background task every export holds
    /// is enough. One that cannot start, for want of a folder, asks for none either.
    func testAnExportWithoutSpokenAudioOrWithoutAFolderAsksForNoTask() async throws {
        let dialog = try await makeDialog("Speech Session No Task")
        let model = dialog.model
        let tasks = RecordedTasks()
        let session = PhoneExportSession(tasking: tasks.tasking)

        let text = try await end(of: ExportRun(of: model, through: session))

        XCTAssertTrue(BookExportModel.didEverything(text))
        XCTAssertEqual(tasks.begun.count, 0, "a text export asked for a task")

        // No folder is chosen: Export cannot be pressed, and the session asks for no task.
        let none = BookExportModel(books: [dialog.book], library: dialog.world.library, destinationIsChosen: false)
        await none.load()
        none.setChecked(true, for: .spokenAudio)
        _ = await session.export(none)
        XCTAssertEqual(tasks.begun.count, 0, "an export that cannot start asked for a task")
    }

    /// A task the system will not take leaves the export as it is: it goes on and ends, with nothing to tell.
    func testAnExportGoesOnWhenTheSystemTakesNoTask() async throws {
        let dialog = try await makeDialog("Speech Session Refused")
        let model = dialog.model
        checkOnlySpokenAudio(model)
        let session = PhoneExportSession(tasking: .none)

        let outcome = try await end(of: ExportRun(of: model, through: session))

        XCTAssertTrue(BookExportModel.didEverything(outcome))
    }

    /// The sheet may close once the spoken audio file is made: the export then goes on, with a card, whose end is announced
    /// low; before then, and for any other export, the sheet's closing stops it. The card closes only once the export
    /// has ended.
    func testTheSheetMayCloseOnlyWhileTheSpokenAudioFileIsMade() async throws {
        let gate = Gate()
        defer { gate.open() }
        let synthesizer = FakeSpeechBufferSynthesizer(framesPerUnit: 1_000, beforeWrite: { utterance in
            if utterance.text.contains("Six") { gate.pass() }
        })
        let dialog = try await makeDialog("Speech Session Close", synthesizer: synthesizer)
        let model = dialog.model
        checkOnlySpokenAudio(model)
        let session = PhoneExportSession(tasking: .none)
        XCTAssertFalse(session.letsGo(on: model), "nothing runs yet")

        let run = ExportRun(of: model, through: session)
        let reached = await eventually { model.progressText == "Speaking chapter 3 of 3…" }
        XCTAssertTrue(reached)
        XCTAssertTrue(model.isMakingSpeech)
        XCTAssertTrue(session.letsGo(on: model))
        XCTAssertNil(session.cardModel)

        session.sheetClosed(model)
        XCTAssertTrue(session.cardModel === model, "the sheet closed on a running export and left no card")
        XCTAssertEqual(model.announcementPriority, .low)
        session.closeCard()
        XCTAssertTrue(session.cardModel === model, "the card closed while its export ran")

        gate.open()
        _ = try await end(of: run)
        XCTAssertFalse(session.letsGo(on: model), "an ended export was let go on")
        session.closeCard()
        XCTAssertNil(session.cardModel, "the card did not close once the export had ended")
    }

    /// Stop from the card stops the export under way, its chapters kept.
    func testStopFromTheCardStopsTheExport() async throws {
        let gate = Gate()
        defer { gate.open() }
        let synthesizer = FakeSpeechBufferSynthesizer(framesPerUnit: 1_000, beforeWrite: { utterance in
            if utterance.text.contains("Six") { gate.pass() }
        })
        let dialog = try await makeDialog("Speech Session Card Stop", synthesizer: synthesizer)
        let model = dialog.model
        checkOnlySpokenAudio(model)
        let session = PhoneExportSession(tasking: .none)
        let run = ExportRun(of: model, through: session)
        let reached = await eventually { model.progressText == "Speaking chapter 3 of 3…" }
        XCTAssertTrue(reached)
        session.sheetClosed(model)

        session.stop()
        gate.open()
        let outcome = try await end(of: run)

        XCTAssertTrue(outcome.wasCancelled)
        XCTAssertEqual(model.announcementPriority, .low)
        XCTAssertEqual(model.finishedWords?.hasPrefix("Export stopped."), true, "the person's own Stop was blamed on iOS: \(String(describing: model.finishedWords))")
    }

    /// A second export cannot begin while one runs: Export is dimmed in the second sheet (`isBusy`), and the session refuses
    /// it, so the first export's task and card are left as they are. When the first ends, the second may begin.
    func testASecondExportIsRefusedWhileOneRuns() async throws {
        let gate = Gate()
        defer { gate.open() }
        let synthesizer = FakeSpeechBufferSynthesizer(framesPerUnit: 1_000, beforeWrite: { utterance in
            if utterance.text.contains("Six") { gate.pass() }
        })
        let first = try await makeDialog("Speech Session First", synthesizer: synthesizer)
        checkOnlySpokenAudio(first.model)
        let second = try await makeDialog("Speech Session Second")
        let tasks = RecordedTasks()
        let session = PhoneExportSession(tasking: tasks.tasking)
        XCTAssertFalse(session.isBusy(for: second.model), "busy with nothing running")

        let run = ExportRun(of: first.model, through: session)
        let reached = await eventually { first.model.progressText == "Speaking chapter 3 of 3…" }
        XCTAssertTrue(reached)
        session.sheetClosed(first.model)
        let card = session.cardModel
        XCTAssertTrue(session.isBusy(for: second.model), "the second sheet's Export is not dimmed")
        XCTAssertFalse(session.isBusy(for: first.model), "the running export is busy with itself")

        let refused = await session.export(second.model)

        XCTAssertNil(refused, "a second export began while the first ran")
        XCTAssertTrue(session.cardModel === card && card === first.model, "the first export's card was taken away")
        XCTAssertEqual(tasks.begun.count, 1, "the second export asked for a task of its own")
        XCTAssertEqual(tasks.task.finishes, [], "the first export's task was ended")
        XCTAssertTrue(first.model.isExporting, "the first export was stopped")
        XCTAssertFalse(second.model.isExporting)

        gate.open()
        let outcome = try await end(of: run)
        XCTAssertTrue(BookExportModel.didEverything(outcome))
        XCTAssertFalse(session.isBusy(for: second.model), "the second sheet's Export stayed dimmed after the first ended")
        let again = await session.export(second.model)
        XCTAssertNotNil(again, "the second export could not begin after the first ended")
    }

    /// The card's lifecycle: it appears when the sheet closes on an export under way, says when that export ends, and is
    /// closed by the person once it has; each is told once, for VoiceOver's focus to follow, and a sheet that closes for
    /// any other export, or twice, or after the end, leaves no card.
    func testTheCardsLifecycleIsToldOnce() async throws {
        let gate = Gate()
        defer { gate.open() }
        let synthesizer = FakeSpeechBufferSynthesizer(framesPerUnit: 1_000, beforeWrite: { utterance in
            if utterance.text.contains("Six") { gate.pass() }
        })
        let dialog = try await makeDialog("Speech Session Lifecycle", synthesizer: synthesizer)
        let model = dialog.model
        checkOnlySpokenAudio(model)
        let stranger = try await makeDialog("Speech Session Stranger").model
        let session = PhoneExportSession(tasking: .none)
        let events = CardEvents(session)

        // No export yet: a sheet closing leaves no card, and closing none changes nothing.
        session.sheetClosed(model)
        session.closeCard()
        XCTAssertNil(session.cardModel)
        XCTAssertEqual(events.seen, [])

        let run = ExportRun(of: model, through: session)
        let reached = await eventually { model.progressText == "Speaking chapter 3 of 3…" }
        XCTAssertTrue(reached)
        // Another model's sheet closing is no concern of this export's.
        session.sheetClosed(stranger)
        XCTAssertNil(session.cardModel, "a sheet of no export under way made a card")
        session.sheetClosed(model)
        session.sheetClosed(model)
        XCTAssertTrue(session.cardModel === model)
        XCTAssertEqual(events.seen, [.appeared], "the card's appearing was told more than once")
        session.closeCard()
        XCTAssertTrue(session.cardModel === model, "the card closed while its export ran")
        XCTAssertEqual(events.seen, [.appeared])

        gate.open()
        _ = try await end(of: run)
        XCTAssertEqual(events.seen, [.appeared, .ended])
        XCTAssertTrue(session.cardModel === model, "the card went when its export ended")
        session.closeCard()
        session.closeCard()
        XCTAssertNil(session.cardModel)
        XCTAssertEqual(events.seen, [.appeared, .ended, .closed], "the close was told twice, or not at all")
        // A sheet closing after the end leaves no card.
        session.sheetClosed(model)
        XCTAssertNil(session.cardModel)
    }

    /// A new export takes the place of a card whose export has ended, and says so as a replacement, not as the person's
    /// close: it is begun in a sheet the person is in, and a close sends the Library's focus to its first row, behind that
    /// sheet, on every Library screen in the stack. The replacement asks for no focus at all.
    func testANewExportReplacesAnEndedCardWithoutAskingForFocus() async throws {
        let gate = Gate()
        defer { gate.open() }
        let synthesizer = FakeSpeechBufferSynthesizer(framesPerUnit: 1_000, beforeWrite: { utterance in
            if utterance.text.contains("Six") { gate.pass() }
        })
        let first = try await makeDialog("Speech Session Replaced First", synthesizer: synthesizer)
        checkOnlySpokenAudio(first.model)
        let second = try await makeDialog("Speech Session Replaced Second")
        let session = PhoneExportSession(tasking: .none)
        let events = CardEvents(session)
        let run = ExportRun(of: first.model, through: session)
        let reached = await eventually { first.model.progressText == "Speaking chapter 3 of 3…" }
        XCTAssertTrue(reached)
        session.sheetClosed(first.model)
        gate.open()
        _ = try await end(of: run)
        XCTAssertTrue(session.cardModel === first.model, "the ended export's card went before the person closed it")
        XCTAssertEqual(events.seen, [.appeared, .ended])

        let outcome = try await end(of: ExportRun(of: second.model, through: session))

        XCTAssertTrue(BookExportModel.didEverything(outcome))
        XCTAssertNil(session.cardModel, "the ended export's card stayed under the new export")
        XCTAssertEqual(events.seen, [.appeared, .ended, .replaced], "the card's replacement was told as \(events.seen.last.map { "\($0)" } ?? "nothing")")
        let replacement = try XCTUnwrap(events.seen.last, "no event for the card's replacement")
        XCTAssertNil(PhoneExportCardFocus.target(for: replacement, focusWasOnStop: false), "the replacement asked for focus behind the sheet")
    }

    /// A file of the same book can follow the spoken audio: a transcript, an original recording or audio come after it in
    /// the dialog's order, and the plan writes them after it, so a question about a chapter nested too deeply can come
    /// with the sheet closed, which is why the iPhone's prompt answers Cancel Export at once then. A transcribed book is
    /// stood in for by its own offer with a transcript item added; spoken audio is offered for one book alone.
    func testAFileCanFollowTheSpokenAudioSoThePromptHasToAnswerForAClosedSheet() async throws {
        let dialog = try await makeDialog("Speech Session Order")
        let model = dialog.model
        model.setChecked(true, for: .spokenAudio)
        let offer = try XCTUnwrap(model.offers.first)
        let transcript = BookExportItem(
            kind: .transcript, folderName: nil,
            files: [BookExportFile(source: .copy(dialog.folder.appendingPathComponent("transcript.json")), path: "Harbour Pilots - Transcript.json", byteCount: 1)],
            fileInCloud: nil
        )
        let withTranscript = BookExportOffer(
            book: offer.book, items: (offer.items + [transcript]).sorted { $0.kind.order < $1.kind.order }, isPackageInCloud: false
        )
        for later in [BookExportKind.originalRecording, .originalAudio, .transcript] {
            XCTAssertLessThan(BookExportKind.spokenAudio.order, later.order, "\(later) does not come after spoken audio")
        }

        let plan = BookExportService.plan(
            [withTranscript], kinds: [.spokenAudio, .transcript], conversions: model.conversions, in: dialog.folder, fileExists: { _ in false }
        ).files

        let names = plan.map(\.target.lastPathComponent)
        XCTAssertEqual(plan.map(\.target.pathExtension), ["m4b", "json"], "the plan holds \(names)")
        // And two books are offered no spoken audio.
        let second = try makeUnlistedDialog("Speech Session Order Two").book
        let two = BookExportModel(books: [dialog.book, second], library: dialog.world.library, destination: dialog.folder)
        await two.load()
        XCTAssertFalse(two.choices.contains { $0.kind == .spokenAudio }, "spoken audio is offered for two books")
    }

    /// iOS's words start the end only for an export it stopped: one that finished before the stop took effect says it
    /// finished, and the note is cleared for the next export.
    func testIOSsWordsAreOnlyForAnExportItStopped() async throws {
        let dialog = try await makeDialog("Speech Session Finished First")
        let model = dialog.model
        model.wordsBeforeTheEnd = PhoneExportWording.stoppedBySystem

        let outcome = try await end(of: ExportRun(of: model))

        XCTAssertFalse(outcome.wasCancelled)
        XCTAssertEqual(model.finishedWords, "Exported 1 item to \(BookExportWording.folderName(of: dialog.folder)).")
        XCTAssertNil(model.wordsBeforeTheEnd, "the note outlived the export it was for")
    }

    /// iOS's words do not outlive an export that never began: one the system stopped in its first moments, while it
    /// waited for a braille table's check, returns without an end to take them, and the next export, stopped by the
    /// person, would begin "iOS stopped this export." The session clears them however the export ended.
    func testIOSsWordsDoNotOutliveAnExportThatNeverBegan() async throws {
        let dialog = try await makeDialog("Speech Session Never Began")
        // No folder chosen: the export returns at once, without an end, as one stopped before it began does.
        let model = BookExportModel(books: [dialog.book], library: dialog.world.library, destinationIsChosen: false)
        await model.load()
        let session = PhoneExportSession(tasking: .none)
        model.wordsBeforeTheEnd = PhoneExportWording.stoppedBySystem

        let outcome = await session.export(model)

        XCTAssertNil(outcome, "the export began")
        XCTAssertNil(model.wordsBeforeTheEnd, "iOS's words outlived an export that never began, for the next one's end")
    }

    // MARK: - Fixtures

    /// The words that say until when spoken chapters are kept, written out
    /// here so that the tests pin them, word for word.
    private static let keptUntil = "until TextMouth quits, a different spoken audio export starts, "
        + "or the book's voice, text, substitutions, or pauses change"

    /// The identifier of the tests' voice, which no Mac has: only the test's
    /// own lookup knows it.
    private static let ordinaryVoice = "com.textmouth.tests.speech-export-dialog"

    /// The identifier of the tests' Personal Voice, a name in the same lookup.
    private static let personalVoice = "com.textmouth.tests.speech-export-dialog.personal"

    /// The speed the library holds for the tests' book.
    private static let bookSpeed = 300.0

    /// The pitch the library holds for the tests' book.
    private static let bookPitch = 1.2

    /// Two chapters with three headings, the last of level 2, as a Markdown
    /// book with chapter markers holds them: one chapter of the spoken file
    /// for each heading.
    private static let threeHeadings = """
    <!-- chapter: First -->
    # First

    One two three.

    <!-- chapter: Second -->
    # Second

    Four five.

    ## Later

    Six seven eight.
    """

    /// A dialog on a one-book library, listed, with what it exports through.
    private struct Dialog {
        /// Keeps the library alive for the test's length.
        let world: IntegrationWorld
        /// The book the dialog exports, as it was chosen, before the library
        /// gave it its own voice, speed, and pitch.
        let book: Book
        /// The sandbox folder the export goes to.
        let folder: URL
        /// The dialog's model, listed.
        let model: BookExportModel
        /// What speaks.
        let synthesizer: FakeSpeechBufferSynthesizer
        /// The folder the dialog's speech exports keep their chapters in.
        let storeRoot: URL
    }

    /// Imports a book from `markdown`, gives it in the library the voice,
    /// speed, and pitch given, and lists a dialog on the copy chosen before
    /// that, speaking through `synthesizer` with the voices `knownVoices`.
    /// Unless told not to, it then makes the spoken audio options, as
    /// checking the kind first does, and unchecks it again.
    private func makeDialog(
        _ label: String,
        markdown: String = SpeechExportDialogTests.threeHeadings,
        synthesizer: FakeSpeechBufferSynthesizer = FakeSpeechBufferSynthesizer(framesPerUnit: 1_000),
        bookVoice: String? = SpeechExportDialogTests.ordinaryVoice,
        bookSpeed: Double? = SpeechExportDialogTests.bookSpeed,
        bookPitch: Double? = SpeechExportDialogTests.bookPitch,
        knownVoices: Set<String> = [SpeechExportDialogTests.ordinaryVoice, SpeechExportDialogTests.personalVoice],
        defaults: UserDefaults? = nil,
        substitutions: TextSubstitutionService = TextSubstitutionService(rules: []),
        speechExportsUnderWay: SpeechExportsUnderWay = SpeechExportsUnderWay(),
        makesSpeechOptions: Bool = true
    ) async throws -> Dialog {
        let dialog = try makeUnlistedDialog(
            label,
            markdown: markdown,
            synthesizer: synthesizer,
            bookVoice: bookVoice,
            bookSpeed: bookSpeed,
            bookPitch: bookPitch,
            knownVoices: knownVoices,
            defaults: defaults,
            substitutions: substitutions,
            speechExportsUnderWay: speechExportsUnderWay
        )
        await dialog.model.load()
        if makesSpeechOptions {
            // The options are made the first time the kind is checked; the
            // kind is then left unchecked, as the dialog opens.
            dialog.model.setChecked(true, for: .spokenAudio)
            let made = await eventually { dialog.model.speechOptions != nil }
            XCTAssertTrue(made, "the spoken audio options were not made")
            dialog.model.setChecked(false, for: .spokenAudio)
        }
        return dialog
    }

    /// The dialog `makeDialog` makes, before it lists the book: what a sheet
    /// hosted in a test lists for itself.
    private func makeUnlistedDialog(
        _ label: String,
        markdown: String = SpeechExportDialogTests.threeHeadings,
        synthesizer: FakeSpeechBufferSynthesizer = FakeSpeechBufferSynthesizer(framesPerUnit: 1_000),
        bookVoice: String? = SpeechExportDialogTests.ordinaryVoice,
        bookSpeed: Double? = SpeechExportDialogTests.bookSpeed,
        bookPitch: Double? = SpeechExportDialogTests.bookPitch,
        knownVoices: Set<String> = [SpeechExportDialogTests.ordinaryVoice, SpeechExportDialogTests.personalVoice],
        defaults: UserDefaults? = nil,
        substitutions: TextSubstitutionService = TextSubstitutionService(rules: []),
        speechExportsUnderWay: SpeechExportsUnderWay = SpeechExportsUnderWay()
    ) throws -> Dialog {
        let world = try makeIntegrationWorld(label)
        let chosen = try world.importBook(from: writeSource(named: "Harbour Pilots.md", markdown: markdown))
        world.library.updateLocalVoiceAndSpeed(bookID: chosen.id, voiceID: bookVoice, wpm: bookSpeed, pitch: bookPitch)
        let folder = try makeSandboxDirectory("\(label) Folder")
        let environment = try makeEnvironment(synthesizer: synthesizer, knownVoices: knownVoices)
        let model = BookExportModel(
            books: [chosen],
            library: world.library,
            destination: folder,
            speechEnvironment: environment,
            speechDefaults: defaults ?? makeSandboxedPreferences(label),
            substitutionService: substitutions,
            speechExportsUnderWay: speechExportsUnderWay
        )
        return Dialog(world: world, book: chosen, folder: folder, model: model, synthesizer: synthesizer, storeRoot: environment.storeRoot)
    }

    /// Writes `markdown`, by default the three-heading book, as a file named
    /// `name` in a sandbox folder of its own, for an import to read.
    private func writeSource(named name: String, markdown: String = SpeechExportDialogTests.threeHeadings) throws -> URL {
        let file = try makeSandboxDirectory("Speech Dialog Source").appendingPathComponent(name)
        try Data(markdown.utf8).write(to: file)
        return file
    }

    /// What a speech export runs with in these tests: `synthesizer`; a voice
    /// lookup that knows only `knownVoices`, "Test Voice" and the Personal
    /// Voice "Test Personal"; a power assertion the system never takes, so
    /// nothing is kept awake; 100 GB free on every disk, all one volume; and a
    /// store root in a sandbox folder of its own.
    private func makeEnvironment(
        synthesizer: FakeSpeechBufferSynthesizer,
        knownVoices: Set<String> = [SpeechExportDialogTests.ordinaryVoice, SpeechExportDialogTests.personalVoice]
    ) throws -> SpeechExportEnvironment {
        let personal = Self.personalVoice
        return SpeechExportEnvironment(
            synthesizer: synthesizer,
            voiceInfo: { identifier in
                guard knownVoices.contains(identifier) else { return nil }
                let isPersonal = identifier == personal
                return SpeechExportVoiceInfo(
                    identifier: identifier,
                    name: isPersonal ? "Test Personal" : "Test Voice",
                    isPersonalVoice: isPersonal
                )
            },
            power: SpeechExportPower(hold: { _ in nil }, release: { _ in }),
            freeSpace: { _ in 100_000_000_000 },
            sameVolume: { _, _ in true },
            storeRoot: try makeSandboxDirectory("Speech Dialog Store").appendingPathComponent("Speech Export", isDirectory: true)
        )
    }

    /// Leaves only "Text as spoken audio" checked in `model`.
    private func checkOnlySpokenAudio(_ model: BookExportModel) {
        for kind in model.checked {
            model.setChecked(false, for: kind)
        }
        model.setChecked(true, for: .spokenAudio)
    }

    /// Whether `condition` holds within `seconds`, looked at every 10 ms,
    /// leaving the main actor free between looks for what the export shows.
    private func eventually(within seconds: Int = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    /// What the export `run` did, once it has ended. It is waited for with a
    /// limit, `seconds`, 30 unless given: the test fails, rather than waits
    /// for ever, should the export not end in time, or should it never have
    /// begun.
    private func end(of run: ExportRun, within seconds: Int = 30) async throws -> BookExportOutcome {
        let hasEnded = await eventually(within: seconds) { run.hasEnded }
        XCTAssertTrue(hasEnded, "the export did not end within \(seconds) seconds")
        return try XCTUnwrap(run.outcome, "the export did not end, or did not begin")
    }

    /// The checkboxes SwiftUI drew inside `view`: the untitled AppKit buttons,
    /// leaving out the pop-up buttons.
    private func checkboxes(in view: NSView) -> [NSButton] {
        descendants(of: view, as: NSButton.self).filter { !($0 is NSPopUpButton) && $0.title.isEmpty }
    }

    /// The pop-up buttons SwiftUI drew inside `view`.
    private func popUps(in view: NSView) -> [NSPopUpButton] {
        descendants(of: view, as: NSPopUpButton.self)
    }

    /// The sliders SwiftUI drew inside `view`.
    private func sliders(in view: NSView) -> [NSSlider] {
        descendants(of: view, as: NSSlider.self)
    }
}

// MARK: - One Export

/// One export under way in a test, begun as it is made, whose end a test waits
/// for with a limit (`end(of:)`), never with a bare `await`.
@MainActor
private final class ExportRun {
    /// What the export did, once it has ended; nil before then, and if it
    /// could not begin.
    private(set) var outcome: BookExportOutcome?
    /// Whether the export has ended.
    private(set) var hasEnded = false

    /// Begins the export of `model`.
    init(of model: BookExportModel) {
        Task { [self] in
            outcome = await model.export()
            hasEnded = true
        }
    }

    /// Begins the export of `model` through `session`, as the iPhone's sheet does when Export is pressed.
    init(of model: BookExportModel, through session: PhoneExportSession) {
        Task { [self] in
            outcome = await session.export(model)
            hasEnded = true
        }
    }
}

// MARK: - The Card's Events, Recorded

/// What a session told about its card, in order.
@MainActor
private final class CardEvents {
    /// The events seen.
    private(set) var seen: [PhoneExportSession.CardEvent] = []
    /// What listens.
    private var listening: AnyCancellable?

    /// Listens to `session`.
    init(_ session: PhoneExportSession) {
        listening = session.cardEvents.sink { [weak self] event in self?.seen.append(event) }
    }
}

// MARK: - The System's Task, Recorded

/// A continued task that records what the session tells it, in place of the system's: its title and subtitle as it began,
/// each update, and how it ended. Never a real task.
private final class RecordedTask: PhoneExportTaskHandle {
    /// What was told, under one lock: the export tells from its own threads.
    private let record = OSAllocatedUnfairLock(initialState: (updates: [PhoneExportTaskMirror.Update](), finishes: [Bool]()))

    /// Every update, in order.
    var updates: [PhoneExportTaskMirror.Update] { record.withLock { $0.updates } }
    /// Every end told, which should be one.
    var finishes: [Bool] { record.withLock { $0.finishes } }

    func update(_ update: PhoneExportTaskMirror.Update) {
        record.withLock { $0.updates.append(update) }
    }

    func finish(success: Bool) {
        record.withLock { $0.finishes.append(success) }
    }
}

/// The session's way to start a task, as the tests make it: it records what it was asked and gives one `RecordedTask`.
private final class RecordedTasks: Sendable {
    /// The task the session was given.
    let task = RecordedTask()
    /// What the session asked for and was given to call at an expiry, under one lock.
    private struct Asked: Sendable {
        var begun: [(title: String, subtitle: String)] = []
        var expire: (@Sendable () -> Void)?
    }

    /// What was asked, which the session's main actor writes and a test reads.
    private let asked = OSAllocatedUnfairLock(initialState: Asked())

    /// What the session asked for, in order.
    var begun: [(title: String, subtitle: String)] { asked.withLock { $0.begun } }

    /// The tasking the session is made with.
    var tasking: PhoneExportTasking {
        PhoneExportTasking { [self] title, subtitle, onExpire in
            asked.withLock {
                $0.begun.append((title, subtitle))
                $0.expire = onExpire
            }
            return task
        }
    }

    /// The system expires the task: the expiration handler runs.
    func expire() {
        asked.withLock { $0.expire }?()
    }
}

// MARK: - Holding a Speech Export

/// Holds a speech export's thread at a chosen utterance until the test has
/// looked: `pass()` waits until `open()`, or for ten seconds at the most, so a
/// failing test never hangs; once open, it stays open.
private final class Gate: Sendable {
    /// Wakes the thread waiting at the gate.
    private let wake = DispatchSemaphore(value: 0)
    /// Whether the gate has been opened.
    private let isOpen = OSAllocatedUnfairLock(initialState: false)

    /// Waits until the gate is open, for ten seconds at the most.
    func pass() {
        guard !isOpen.withLock({ $0 }) else { return }
        _ = wake.wait(timeout: .now() + 10)
    }

    /// Opens the gate, for the thread waiting there and every one after it.
    func open() {
        let wasOpen = isOpen.withLock { open -> Bool in
            defer { open = true }
            return open
        }
        if !wasOpen {
            wake.signal()
        }
    }
}
