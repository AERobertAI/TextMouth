import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

/// Clean Up Transcript (Experimental)… and its sheet (FR05), as the user
/// meets them: the command offered beside Transcribe Audio… for a
/// transcribed audiobook; the sheet naming the rules and what they would
/// change, rule by rule with examples; Apply cleaning up the transcript,
/// telling open readers and VoiceOver; Undo Cleanup putting it back; the
/// lines about the user's copy of the rules; and the sheet as drawn, with
/// VoiceOver's focus on its first control and its keys.
///
/// Every sheet reaches services of the test's own: rules the test names,
/// announcements kept, and an editor that never opens. The books are silent
/// audiobooks with invented narration.
@MainActor
final class TranscriptCleanupSheetTests: XCTestCase {

    // MARK: - The Command

    /// Clean Up Transcript (Experimental)… is offered for one transcribed
    /// audiobook, between Transcribe Audio… and Delete Transcript…, after
    /// Edit Audio… (FR04), under the same name in the menu and among
    /// VoiceOver's actions.
    func testCleanUpIsOfferedForOneTranscribedAudiobookBesideTranscribe() {
        let book = TranscriptionSheetTests.audiobook("Harbour Bells")
        let other = TranscriptionSheetTests.audiobook("Tide Clock")
        let transcribed: (UUID) -> Bool = { $0 == book.id }

        XCTAssertEqual(
            LibraryTranscriptionCommand.commands(for: [book], isTranscribed: transcribed),
            [.editAudio(book), .transcribe([book]), .cleanUpTranscript(book), .deleteTranscript(book)]
        )
        XCTAssertEqual(
            LibraryTranscriptionCommand.commands(for: [other], isTranscribed: transcribed),
            [.editAudio(other), .transcribe([other])]
        )
        XCTAssertEqual(
            LibraryTranscriptionCommand.commands(for: [book, other], isTranscribed: transcribed),
            [.transcribe([book, other])]
        )
        XCTAssertEqual(LibraryTranscriptionCommand.cleanUpTranscript(book).title, "Clean Up Transcript (Experimental)…")
        let row = BookRow(
            book: book,
            transcriptionNote: .transcribed,
            transcriptionCommands: LibraryTranscriptionCommand.commands(for: [book], isTranscribed: transcribed)
        )
        XCTAssertEqual(
            row.accessibilityActionNames,
            ["Edit Audio…", "Transcribe Audio…", "Clean Up Transcript (Experimental)…", "Delete Transcript…"]
        )
    }

    /// The command opens the sheet for its book, once however often it is
    /// chosen while the sheet shows.
    func testTheCommandOpensOneSheetForItsBook() throws {
        let world = try makeIntegrationWorld("Transcript Cleanup Command")
        let book = try transcribedBook(in: world)
        let presenter = TranscriptionPresenter(services: { self.makeSheetServices() }, cleanupServices: { self.makeCleanupServices() })

        presenter.perform(.cleanUpTranscript(book), library: world.library, window: nil)
        let first = presenter.cleanup
        presenter.perform(.cleanUpTranscript(book), library: world.library, window: nil)

        XCTAssertEqual(first?.book.id, book.id)
        XCTAssertTrue(presenter.cleanup === first, "a second sheet replaced the first")
        first?.close()
        XCTAssertNil(presenter.cleanup)
    }

    // MARK: - What the Sheet Shows

    /// The ready sheet names the rules and what they would change, lists
    /// each rule's changes with examples, offers Apply first, and hears its
    /// lines together.
    func testTheSheetShowsTheRulesAndWhatTheyWouldChange() async throws {
        let world = try makeIntegrationWorld("Transcript Cleanup Sheet")
        let book = try transcribedBook(in: world)
        let model = TranscriptCleanupSheetModel(book: book, library: world.library, services: makeCleanupServices())

        await model.load()

        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.heading, "Clean Up the Transcript of Breakwater Notes")
        XCTAssertEqual(model.rulesLine, "Rules: TextMouth's own, version 4 of \(TranscriptCleanupRuleSet.dayName("2026-10-04")), 2 rules.")
        XCTAssertEqual(model.summaryLine, "2 corrections in 2 sentences.")
        XCTAssertEqual(model.changeRows.map(\.title), [
            "“breakwater” becomes “break-water”: 1 correction.",
            "“pier” becomes “jetty”: 1 correction.",
        ])
        XCTAssertEqual(model.changeRows.first?.examples, [
            "Before: …wings fold over the breakwater. After: …wings fold over the break-water.",
        ])
        XCTAssertEqual(model.changeRows.first?.accessibilityLabel,
                       "“breakwater” becomes “break-water”: 1 correction. Before: …wings fold over the breakwater. "
                        + "After: …wings fold over the break-water.")
        XCTAssertTrue(model.rulesNoticeLines.isEmpty)
        XCTAssertTrue(model.historyLines.isEmpty)
        XCTAssertFalse(model.canUndo)
        XCTAssertTrue(model.canApply)
        XCTAssertEqual(model.focusTarget, .apply)
        XCTAssertEqual(model.announcement, model.readyLines.joined(separator: " "))
        XCTAssertEqual(model.readyLines.first, model.heading)
        XCTAssertTrue(model.readyLines.contains(TranscriptCleanupWording.experimentalLine))
    }

    /// Rules that change nothing say so, and leave Apply unavailable, with
    /// Cancel first.
    func testRulesThatChangeNothingSaySo() async throws {
        let world = try makeIntegrationWorld("Transcript Cleanup Nothing")
        let book = try transcribedBook(in: world)
        let rules = TranscriptCleanupRuleSet(version: 1, date: "2026-10-04", rules: [rule("quillwort", "quill-wort")])
        let model = TranscriptCleanupSheetModel(book: book, library: world.library, services: makeCleanupServices(rules: lookup(rules)))

        await model.load()

        XCTAssertEqual(model.summaryLine, TranscriptCleanupWording.nothingToChange)
        XCTAssertTrue(model.changeRows.isEmpty)
        XCTAssertFalse(model.canApply)
        XCTAssertEqual(model.focusTarget, .cancel)
    }

    /// A list of rules without a rule says why, and how to add some: TextMouth
    /// comes with none, and the user's copy may hold none yet.
    func testAnEmptyRuleListSaysHowToAddRules() async throws {
        let world = try makeIntegrationWorld("Transcript Cleanup No Rules")
        let book = try transcribedBook(in: world)
        let empty = TranscriptCleanupRuleSet(version: 1, date: "2026-10-04", rules: [])
        let own = TranscriptCleanupSheetModel(book: book, library: world.library, services: makeCleanupServices(rules: lookup(empty)))
        let users = TranscriptCleanupSheetModel(book: book, library: world.library, services: makeCleanupServices(
            rules: TranscriptCleanupRuleFile.Lookup(rules: empty, source: .user, userCopy: .used, builtInVersion: 1)
        ))

        await own.load()
        await users.load()

        XCTAssertEqual(own.rulesLine, "Rules: TextMouth's own, version 1 of \(TranscriptCleanupRuleSet.dayName("2026-10-04")), 0 rules.")
        XCTAssertEqual(own.rulesNoticeLines, [TranscriptCleanupWording.noRules(source: .builtIn)])
        XCTAssertTrue(own.readyLines.contains(TranscriptCleanupWording.noRules(source: .builtIn)))
        XCTAssertEqual(own.summaryLine, TranscriptCleanupWording.nothingToChange)
        XCTAssertEqual(users.rulesNoticeLines, ["Your copy of the rules has no rules yet. Edit Rules… opens it, so you can add some."])
    }

    /// Coming back to TextMouth reads the rules again: when they changed, as
    /// after Edit Rules…, the sheet shows what they would change now and
    /// VoiceOver hears its lines; when nothing changed, it stays quiet.
    func testComingBackReadsTheRulesAgain() async throws {
        let world = try makeIntegrationWorld("Transcript Cleanup Refresh")
        let book = try transcribedBook(in: world)
        let supply = RulesSupply(lookup(TranscriptCleanupRuleSet(version: 1, date: "2026-10-04", rules: [rule("quillwort", "quill-wort")])))
        let announcements = SheetAnnouncements()
        let model = TranscriptCleanupSheetModel(book: book, library: world.library, services: makeCleanupServices(
            supply: supply,
            announcements: announcements
        ))
        await model.load()
        XCTAssertFalse(model.canApply)

        await model.refresh()
        XCTAssertTrue(announcements.messages.isEmpty, "nothing changed, yet VoiceOver heard the sheet again")

        supply.lookup = TranscriptCleanupRuleFile.Lookup(rules: Self.rules, source: .user, userCopy: .used, builtInVersion: 1)
        await model.refresh()

        XCTAssertTrue(model.canApply)
        XCTAssertEqual(model.summaryLine, "2 corrections in 2 sentences.")
        XCTAssertEqual(model.rulesLine, "Rules: your copy, version 4 of \(TranscriptCleanupRuleSet.dayName("2026-10-04")), 2 rules.")
        XCTAssertEqual(announcements.messages, [model.announcement].compactMap { $0 })
    }

    /// While the book is being transcribed, or without a transcript, the
    /// sheet only says why, with OK, which Escape presses too.
    func testTheSheetSaysWhyWhenNothingCanBeCleanedUp() async throws {
        let world = try makeIntegrationWorld("Transcript Cleanup Unavailable")
        let transcribed = try transcribedBook(in: world)
        let untranscribed = try world.makeSilentAudioBook(title: "Tide Clock", trackDurations: [1])
        let busy = TranscriptCleanupSheetModel(
            book: transcribed,
            library: world.library,
            services: makeCleanupServices(transcribing: FailureSwitch(isOn: true))
        )
        let missing = TranscriptCleanupSheetModel(book: untranscribed, library: world.library, services: makeCleanupServices())
        var closed = false
        missing.onClose = { closed = true }

        await busy.load()
        await missing.load()

        XCTAssertEqual(busy.phase, .unavailable("Breakwater Notes is being transcribed. Clean up its transcript once that finishes."))
        XCTAssertEqual(missing.phase, .unavailable("Tide Clock has no transcript to clean up. Transcribe its audio first."))
        XCTAssertEqual(missing.focusTarget, .ok)
        XCTAssertEqual(missing.announcement, "Tide Clock has no transcript to clean up. Transcribe its audio first.")
        missing.escape()
        XCTAssertTrue(closed)
    }

    /// The lines about the user's copy of the rules: waiting in the cloud,
    /// which asks the sync service for it; unusable; older than TextMouth's
    /// own; and why Edit Rules… could not open it.
    func testTheSheetSaysHowTheUsersCopyOfTheRulesStands() async throws {
        let world = try makeIntegrationWorld("Transcript Cleanup Rules Notices")
        let book = try transcribedBook(in: world)
        let downloads = CallLog<Void>()
        let announcements = SheetAnnouncements()
        let own = TranscriptCleanupRuleSet(version: 2, date: "2026-10-05", rules: [rule("pier", "jetty")])

        let inCloud = TranscriptCleanupSheetModel(book: book, library: world.library, services: makeCleanupServices(
            rules: TranscriptCleanupRuleFile.Lookup(rules: Self.rules, source: .builtIn, userCopy: .inCloud, builtInVersion: 4),
            downloads: downloads
        ))
        let unusable = TranscriptCleanupSheetModel(book: book, library: world.library, services: makeCleanupServices(
            rules: TranscriptCleanupRuleFile.Lookup(rules: Self.rules, source: .builtIn, userCopy: .unusable("rules[0].pattern is empty"),
                                                    builtInVersion: 4)
        ))
        let older = TranscriptCleanupSheetModel(book: book, library: world.library, services: makeCleanupServices(
            rules: TranscriptCleanupRuleFile.Lookup(rules: own, source: .user, userCopy: .used, builtInVersion: 4),
            editRulesFailure: "The volume is read-only.",
            announcements: announcements
        ))
        await inCloud.load()
        await unusable.load()
        await older.load()
        await older.editRules()

        XCTAssertEqual(inCloud.rulesNoticeLines, [TranscriptCleanupWording.userCopyInCloud])
        XCTAssertEqual(downloads.calls.count, 1)
        XCTAssertEqual(unusable.rulesNoticeLines, [
            "Your copy of the rules couldn't be used: rules[0].pattern is empty. It was kept beside itself, and TextMouth's "
                + "own rules are used until you correct it.",
        ])
        XCTAssertEqual(older.rulesLine, "Rules: your copy, version 2 of \(TranscriptCleanupRuleSet.dayName("2026-10-05")), 1 rule.")
        XCTAssertEqual(older.rulesNoticeLines, [
            "TextMouth's own rules are newer, version 4. To use them, delete your copy, or copy their new rules into it.",
            "Couldn't open the rules: The volume is read-only.",
        ])
        XCTAssertEqual(announcements.messages, ["Couldn't open the rules: The volume is read-only."])
    }

    // MARK: - Applying and Undoing

    /// Apply cleans up the transcript, ends its Edit Text session first,
    /// shows the cleaned text in an open reader, tells VoiceOver how many
    /// corrections were made, and closes the sheet.
    func testApplyCleansUpTheTranscriptAndTellsTheReader() async throws {
        let world = try makeIntegrationWorld("Transcript Cleanup Applied")
        let book = try transcribedBook(in: world)
        let reader = world.openReader(for: book)
        let loaded = await eventuallyHolds { !reader.isLoading }
        XCTAssertTrue(loaded, "the reader never loaded")
        let announcements = SheetAnnouncements()
        let ended = CallLog<UUID>()
        let model = TranscriptCleanupSheetModel(book: book, library: world.library, services: makeCleanupServices(
            endedEdits: ended,
            announcements: announcements
        ))
        var closed = false
        model.onClose = { closed = true }
        await model.load()

        await model.apply()

        XCTAssertTrue(closed, "the sheet stayed open")
        XCTAssertEqual(ended.calls, [book.id])
        XCTAssertEqual(announcements.messages, ["Cleaned up the transcript of Breakwater Notes: 2 corrections."])
        guard case .found(let saved) = TranscriptStore.read(from: book.tmbDirectory) else {
            return XCTFail("the cleaned transcript could not be read")
        }
        XCTAssertEqual(saved.cleanedUp?.corrections, 2)
        XCTAssertEqual(saved.cleanedUp?.rules, "built-in")
        XCTAssertEqual(reader.content?.transcript?.chapterText(0)?.contains("jetty"), true, "the reader shows the text from before")
    }

    /// A cleaned transcript's sheet says when it was cleaned up, offers Undo
    /// Cleanup, and warns when the user edited the transcript since; Undo
    /// Cleanup puts it back, tells VoiceOver, and closes the sheet.
    func testUndoCleanupPutsTheTranscriptBack() async throws {
        let world = try makeIntegrationWorld("Transcript Cleanup Undo Sheet")
        let book = try transcribedBook(in: world)
        guard case .found(let original) = TranscriptStore.read(from: book.tmbDirectory) else {
            return XCTFail("the transcript could not be read")
        }
        try TranscriptStore.cleanUp(book, expecting: original, with: Self.rules, from: .builtIn, now: TranscriptFixtures.date)
        // An edit in the user's editor a day after the cleanup.
        guard case .found(var cleaned) = TranscriptStore.read(from: book.tmbDirectory) else {
            return XCTFail("the cleaned transcript could not be read")
        }
        let edited = TranscriptFixtures.date.addingTimeInterval(86_400)
        cleaned.editedAt = edited
        try TranscriptStore.write(cleaned, into: book.tmbDirectory)
        let announcements = SheetAnnouncements()
        let model = TranscriptCleanupSheetModel(book: book, library: world.library, services: makeCleanupServices(announcements: announcements))
        var closed = false
        model.onClose = { closed = true }
        await model.load()

        XCTAssertTrue(model.canUndo)
        XCTAssertEqual(model.summaryLine, TranscriptCleanupWording.nothingToChange)
        XCTAssertEqual(model.historyLines, [
            "Cleaned up on \(TranscriptionWording.day(TranscriptFixtures.date)), with rules version 4: 2 corrections. "
                + "Undo Cleanup puts back the transcript from before.",
            "You edited the transcript on \(TranscriptionWording.day(edited)), after the cleanup. Undo Cleanup undoes those edits too.",
        ])
        XCTAssertEqual(model.focusTarget, .cancel, "Undo Cleanup is never pressed for the user")

        await model.undo()

        XCTAssertTrue(closed)
        XCTAssertEqual(announcements.messages, ["Undid the cleanup of the transcript of Breakwater Notes."])
        XCTAssertEqual(TranscriptStore.read(from: book.tmbDirectory), .found(original))
    }

    /// A transcription of the book begun after the sheet opened, as from
    /// another window, keeps Apply from acting, and the sheet says why.
    func testApplyWaitsForATranscriptionBegunMeanwhile() async throws {
        let world = try makeIntegrationWorld("Transcript Cleanup Busy")
        let book = try transcribedBook(in: world)
        let transcribing = FailureSwitch(isOn: false)
        let model = TranscriptCleanupSheetModel(book: book, library: world.library, services: makeCleanupServices(transcribing: transcribing))
        await model.load()
        transcribing.isOn = true

        await model.apply()

        XCTAssertEqual(model.phase, .failed(
            "Couldn't clean up the transcript of Breakwater Notes: The book is being transcribed again. "
                + "Clean up its transcript once that finishes."
        ))
        guard case .found(let untouched) = TranscriptStore.read(from: book.tmbDirectory) else {
            return XCTFail("the transcript could not be read")
        }
        XCTAssertNil(untouched.cleanedUp)
    }

    /// A cleanup that fails says why, with Close, which takes VoiceOver's
    /// focus, and the transcript stays as it was.
    func testAFailedCleanupSaysWhy() async throws {
        let world = try makeIntegrationWorld("Transcript Cleanup Failure")
        let book = try transcribedBook(in: world)
        let model = TranscriptCleanupSheetModel(book: book, library: world.library, services: makeCleanupServices())
        await model.load()
        // Another Mac transcribed the book again meanwhile.
        guard case .found(var changed) = TranscriptStore.read(from: book.tmbDirectory) else {
            return XCTFail("the transcript could not be read")
        }
        changed.files[0].sentences[0].rewrite(as: "Gannet wings fold.")
        try TranscriptStore.write(changed, into: book.tmbDirectory)

        await model.apply()

        XCTAssertEqual(model.phase, .failed(
            "Couldn't clean up the transcript of Breakwater Notes: The transcript changed since this was shown. "
                + "Open Clean Up Transcript again to see what would change now."
        ))
        XCTAssertEqual(model.focusTarget, .close)
        XCTAssertEqual(TranscriptStore.read(from: book.tmbDirectory), .found(changed))
    }

    // MARK: - As Drawn

    /// The ready sheet asks VoiceOver's focus once, for Apply, and announces
    /// its lines once VoiceOver has had time to reach it.
    func testTheReadySheetMovesVoiceOverToApplyThenAnnouncesItsLines() throws {
        let world = try makeIntegrationWorld("Transcript Cleanup Sheet Drawn")
        let book = try transcribedBook(in: world)
        let announcements = SheetAnnouncements()
        let model = TranscriptCleanupSheetModel(book: book, library: world.library, services: makeCleanupServices(announcements: announcements))

        withHostedView(TranscriptCleanupSheet(model: model), size: NSSize(width: 600, height: 700), until: { hostingView in
            model.phase == .ready && !self.descendants(of: hostingView, as: VoiceOverFocusTriggerView.self).isEmpty
        }) { hostingView in
            XCTAssertEqual(model.phase, .ready, "the sheet never read the transcript")
            XCTAssertEqual(model.focusTarget, .apply)
            XCTAssertEqual(descendants(of: hostingView, as: VoiceOverFocusTriggerView.self).count, 1,
                           "VoiceOver's focus is asked for once, for the first control")
            XCTAssertTrue(waitUntil(timeout: 10) { !announcements.messages.isEmpty }, "the sheet's lines were never announced")
            XCTAssertEqual(announcements.messages, [model.announcement].compactMap { $0 })
        }
    }

    /// The ready sheet's buttons are Edit Rules…, Cancel, and Apply, each
    /// labelled and hinted, in that order.
    func testTheReadySheetLabelsItsButtons() async throws {
        let world = try makeIntegrationWorld("Transcript Cleanup Buttons")
        let book = try transcribedBook(in: world)
        let model = TranscriptCleanupSheetModel(book: book, library: world.library, services: makeCleanupServices())
        await model.load()

        try withHostedView(TranscriptCleanupSheet(model: model), size: NSSize(width: 600, height: 700), until: {
            !self.buttons(in: $0).isEmpty
        }) { hostingView in
            let found = buttons(in: hostingView)
            guard !found.isEmpty else {
                throw XCTSkip("SwiftUI exposed no button to accessibility without an assistive app")
            }
            XCTAssertEqual(found.map(\.label), ["Edit Rules…", "Cancel", "Apply"])
            XCTAssertEqual(found.map(\.hint), [
                TranscriptCleanupWording.editRulesHint, TranscriptCleanupWording.cancelHint, TranscriptCleanupWording.applyHint,
            ])
        }
    }

    /// Return presses Apply, which cleans up the transcript and closes the
    /// sheet; Escape presses Cancel, which closes a sheet without changing
    /// anything.
    func testReturnAppliesAndEscapeCancels() throws {
        let world = try makeIntegrationWorld("Transcript Cleanup Keys")
        let applied = try transcribedBook(in: world)
        let cancelled = try transcribedBook(in: world, title: "Tide Clock")
        let applying = TranscriptCleanupSheetModel(book: applied, library: world.library, services: makeCleanupServices())
        let cancelling = TranscriptCleanupSheetModel(book: cancelled, library: world.library, services: makeCleanupServices())
        var appliedClosed = false
        var cancelledClosed = false
        applying.onClose = { appliedClosed = true }
        cancelling.onClose = { cancelledClosed = true }

        try withHostedView(TranscriptCleanupSheet(model: applying), size: NSSize(width: 600, height: 700), until: { _ in
            applying.phase == .ready
        }) { hostingView in
            guard pressKeyEquivalent(.return, in: hostingView) else {
                throw XCTSkip("This macOS hands an offscreen window no key equivalents")
            }
            XCTAssertTrue(waitUntil(timeout: 10) { appliedClosed }, "Return did not apply")
        }
        withHostedView(TranscriptCleanupSheet(model: cancelling), size: NSSize(width: 600, height: 700), until: { _ in
            cancelling.phase == .ready
        }) { hostingView in
            XCTAssertTrue(pressKeyEquivalent(.escape, in: hostingView))
            XCTAssertTrue(waitUntil { cancelledClosed }, "Escape did not cancel")
        }
        guard case .found(let cleaned) = TranscriptStore.read(from: applied.tmbDirectory),
              case .found(let untouched) = TranscriptStore.read(from: cancelled.tmbDirectory) else {
            return XCTFail("a transcript could not be read")
        }
        XCTAssertNotNil(cleaned.cleanedUp)
        XCTAssertNil(untouched.cleanedUp)
    }

    // MARK: - Fixtures

    /// Rules that change two sentences of the scripted narration.
    static let rules = TranscriptCleanupFixtures.narrationRules

    /// TextMouth's own rules, `rules`, as the sheet reads them.
    private func lookup(_ rules: TranscriptCleanupRuleSet = TranscriptCleanupSheetTests.rules) -> TranscriptCleanupRuleFile.Lookup {
        TranscriptCleanupRuleFile.Lookup(rules: rules, source: .builtIn, userCopy: .none, builtInVersion: rules.version)
    }

    /// A whole-word rule writing its replacement for its pattern.
    private let rule = TranscriptCleanupFixtures.rule

    /// The rules a test's sheet reads, which the test can change, as the
    /// user's editing of their copy does.
    @MainActor
    final class RulesSupply {
        /// The rules the sheet reads next.
        var lookup: TranscriptCleanupRuleFile.Lookup

        init(_ lookup: TranscriptCleanupRuleFile.Lookup) {
            self.lookup = lookup
        }
    }

    /// Services for a Clean Up sheet that reach nothing of this Mac: the
    /// rules `rules` gives, or `supply` when given, a transcription under
    /// way while `transcribing` is on, Edit Rules… failing with
    /// `editRulesFailure` or opening nothing, and downloads asked for, Edit
    /// Text sessions ended, and announcements kept in the logs given.
    private func makeCleanupServices(
        rules: TranscriptCleanupRuleFile.Lookup? = nil,
        supply: RulesSupply? = nil,
        transcribing: FailureSwitch = FailureSwitch(isOn: false),
        editRulesFailure: String? = nil,
        downloads: CallLog<Void> = CallLog(),
        endedEdits: CallLog<UUID> = CallLog(),
        announcements: SheetAnnouncements = SheetAnnouncements()
    ) -> TranscriptCleanupServices {
        let supply = supply ?? RulesSupply(rules ?? lookup())
        return TranscriptCleanupServices(
            loadRules: { await supply.lookup },
            requestRulesDownload: { downloads.record(()) },
            editRules: { _ in editRulesFailure },
            isTranscribing: { _ in transcribing.isOn },
            endTextEdit: { endedEdits.record($0) },
            announce: { message, window in announcements.record(message, window) }
        )
    }

    /// A silent audiobook titled `title`, of two tracks in `world`,
    /// transcribed with the scripted narration and installed as its text.
    private func transcribedBook(in world: IntegrationWorld, title: String = "Breakwater Notes") throws -> Book {
        try TranscriptCleanupFixtures.transcribedBook(in: world, title: title).book
    }

    /// The buttons VoiceOver can land on below `root`.
    private func buttons(in root: Any) -> [AccessibleControl] {
        accessibleControls(in: root).filter { $0.role == .button }
    }
}
