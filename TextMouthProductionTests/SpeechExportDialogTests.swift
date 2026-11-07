import AppKit
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
    /// size. Its options start at the speed and pitch the library holds for
    /// the book, not those of the copy chosen, name the book's voice, and list
    /// its headings; their view shows only while the kind is checked.
    func testOneTextBookListsSpokenAudioUncheckedWithItsOptions() async throws {
        let dialog = try await makeDialog("Speech Dialog Listing")
        let model = dialog.model

        XCTAssertEqual(model.choices.map(\.kind), [.originalFile, .markdown, .plainText, .spokenAudio])
        let spoken = try XCTUnwrap(model.choices.last)
        XCTAssertEqual(model.label(for: spoken), "Text as spoken audio")
        XCTAssertTrue(spoken.isAvailable)
        XCTAssertEqual(model.checked, [.originalFile], "spoken audio was checked at the start")

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
        XCTAssertEqual(cloud.refusedReads, [], "the text in the cloud was read")
    }

    /// A text cache that cannot be read as text takes the kind away, and
    /// leaves the book's other kinds as they were.
    func testATextCacheThatCannotBeReadTakesTheKindAway() async throws {
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

        XCTAssertEqual(model.choices.map(\.kind), [.originalFile, .markdown, .plainText])
        XCTAssertNil(model.speechOptions)
        XCTAssertEqual(model.phase, .ready)
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
            "Couldn't export \(BookExportService.fileNameStem(for: dialog.book.title)) - Audio.m4b: "
                + "No voice is installed to speak it. Add a voice in System Settings, Accessibility, Spoken Content, then export again."
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

        let words = "Export stopped. Nothing was exported. Kept 2 of 3 chapters: export the same range at the same speed "
            + "and pitch to go on from chapter 3, " + Self.keptUntil + "."
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
            + "even with its brackets made silent. Kept 2 of 3 chapters: export the same range at the same speed and pitch "
            + "to go on from chapter 3, " + Self.keptUntil + "."
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
        let words = "Couldn't export \(stem) - Audio.m4b: “Test Personal” is a Personal Voice, which macOS can't record to a file. "
            + "Choose another voice for this book with the Voice button in its reader, then export again."
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
        try withHostedView(sheet, size: size, until: { self.checkboxes(in: $0).count == 4 && model.phase == .ready }) { hosting in
            let options = try XCTUnwrap(model.speechOptions)
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
                options.formats.map(\.title)
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
            "Stops the export. The chapters already spoken are kept, so exporting the same range at the same speed "
                + "and pitch goes on from there, " + Self.keptUntil + "."
        )
        XCTAssertNil(SpeechExportWording.kept(done: 0, total: 12))
        XCTAssertEqual(
            SpeechExportWording.kept(done: 1, total: 12),
            "Kept 1 of 12 chapters: export the same range at the same speed and pitch to go on from chapter 2, "
                + Self.keptUntil + "."
        )
        XCTAssertEqual(
            SpeechExportWording.kept(done: 11, total: 12),
            "Kept 11 of 12 chapters: export the same range at the same speed and pitch to go on from chapter 12, "
                + Self.keptUntil + "."
        )
        XCTAssertEqual(
            SpeechExportWording.kept(done: 1, total: 1),
            "Kept the spoken chapter: export the same range at the same speed and pitch to make the audio file from it, "
                + Self.keptUntil + "."
        )
        XCTAssertEqual(
            SpeechExportWording.kept(done: 12, total: 12),
            "Kept all 12 spoken chapters: export the same range at the same speed and pitch to make the audio file "
                + "from them, " + Self.keptUntil + "."
        )
    }

    /// The fraction a progress bar shows of each part of an export: the part's
    /// own, held to the bar's ends, and none once it has ended.
    func testTheFractionOfEachProgress() {
        XCTAssertEqual(SpeechExportProgress.speaking(done: 1, total: 3, fraction: 0.25).fraction, 0.25)
        XCTAssertEqual(SpeechExportProgress.encoding(chapters: 3, fraction: 0.75).fraction, 0.75)
        XCTAssertEqual(SpeechExportProgress.encoding(chapters: 3, fraction: 1.2).fraction, 1)
        XCTAssertEqual(SpeechExportProgress.speaking(done: 0, total: 3, fraction: -0.2).fraction, 0)
        XCTAssertNil(SpeechExportProgress.ended(kept: 1, total: 3).fraction)
    }

    // MARK: - Fixtures

    /// The words that say until when spoken chapters are kept, written out
    /// here so that the tests pin them, word for word.
    private static let keptUntil = "before TextMouth quits, a different export of spoken audio starts, "
        + "or the book's voice, text, substitution rules, or pauses change"

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
    }

    /// Imports a book from `markdown`, gives it in the library the voice,
    /// speed, and pitch given, and lists a dialog on the copy chosen before
    /// that, speaking through `synthesizer` with the voices `knownVoices`.
    private func makeDialog(
        _ label: String,
        markdown: String = SpeechExportDialogTests.threeHeadings,
        synthesizer: FakeSpeechBufferSynthesizer = FakeSpeechBufferSynthesizer(framesPerUnit: 1_000),
        bookVoice: String? = SpeechExportDialogTests.ordinaryVoice,
        bookSpeed: Double? = SpeechExportDialogTests.bookSpeed,
        bookPitch: Double? = SpeechExportDialogTests.bookPitch,
        knownVoices: Set<String> = [SpeechExportDialogTests.ordinaryVoice, SpeechExportDialogTests.personalVoice],
        defaults: UserDefaults? = nil,
        substitutions: TextSubstitutionService = TextSubstitutionService(rules: [])
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
            substitutions: substitutions
        )
        await dialog.model.load()
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
        substitutions: TextSubstitutionService = TextSubstitutionService(rules: [])
    ) throws -> Dialog {
        let world = try makeIntegrationWorld(label)
        let chosen = try world.importBook(from: writeSource(named: "Harbour Pilots.md", markdown: markdown))
        world.library.updateLocalVoiceAndSpeed(bookID: chosen.id, voiceID: bookVoice, wpm: bookSpeed, pitch: bookPitch)
        let folder = try makeSandboxDirectory("\(label) Folder")
        let model = BookExportModel(
            books: [chosen],
            library: world.library,
            destination: folder,
            speechEnvironment: try makeEnvironment(synthesizer: synthesizer, knownVoices: knownVoices),
            speechDefaults: defaults ?? makeSandboxedPreferences(label),
            substitutionService: substitutions
        )
        return Dialog(world: world, book: chosen, folder: folder, model: model, synthesizer: synthesizer)
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
