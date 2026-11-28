import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

/// The transcription dialogs as drawn (FR05): the Transcribe Audio sheet,
/// ready, explaining why it cannot transcribe, and showing a transcription
/// under way; the offer after an import; and the Transcription group of
/// Playback settings. Each is hosted in an offscreen window, as SwiftUI
/// draws it: VoiceOver's focus is asked for once, for the sheet's first
/// control; Return presses the default button and Escape Cancel, OK, or
/// Close; and the sheet announces its lines once VoiceOver has reached that
/// control.
///
/// SwiftUI builds the spoken labels of its own buttons only for a connected
/// assistive app, so their words are pinned through `TranscriptionWording`
/// and the sheet's model, where they come from, and a test that reads the
/// drawn buttons' labels skips, rather than fails, when none are exposed.
/// Every sheet here reaches scripted services: nothing asks the system's
/// recognizer, and nothing downloads.
///
/// A test that waits, while a sheet is hosted, for the sheet's own tasks or
/// the transcription's progress is synchronous: an asynchronous test runs
/// as a job of the main queue, which the run loop it spins while waiting
/// never drains, so those would never run.
@MainActor
final class TranscriptionSheetViewTests: XCTestCase {

    // MARK: - The Sheet, Ready

    /// The ready sheet, which checks the book as it appears, asks
    /// VoiceOver's focus once, for Transcribe, and announces its lines once
    /// VoiceOver has had time to reach it.
    func testTheReadySheetMovesVoiceOverToTranscribeThenAnnouncesItsLines() {
        let announcements = SheetAnnouncements()
        let model = TranscriptionSheetModel(
            request: .book(TranscriptionSheetTests.audiobook("Harbour Bells", seconds: 3_060)),
            library: nil,
            services: makeSheetServices(announcements: announcements)
        )

        withHostedView(TranscriptionSheet(model: model), until: { hostingView in
            model.phase == .ready && !self.descendants(of: hostingView, as: VoiceOverFocusTriggerView.self).isEmpty
        }) { hostingView in
            XCTAssertEqual(model.phase, .ready, "the sheet never checked the book")
            XCTAssertEqual(model.focusTarget, .transcribe)
            XCTAssertEqual(
                descendants(of: hostingView, as: VoiceOverFocusTriggerView.self).count,
                1,
                "VoiceOver's focus is asked for once, for the first control"
            )
            XCTAssertTrue(
                waitUntil(timeout: 10) { !announcements.messages.isEmpty },
                "the sheet's lines were never announced"
            )
            XCTAssertEqual(announcements.messages, [model.announcement].compactMap { $0 })
        }
    }

    /// The ready sheet's buttons are Cancel and Transcribe, each labelled
    /// and hinted, in that order.
    func testTheReadySheetLabelsItsButtons() async throws {
        try skipUnlessSwiftUIExposesItsOwnElements()
        let model = TranscriptionSheetModel(
            request: .book(TranscriptionSheetTests.audiobook("Harbour Bells", seconds: 3_060)),
            library: nil,
            services: makeSheetServices()
        )
        await model.load()

        try withHostedView(TranscriptionSheet(model: model), until: { !self.buttons(in: $0).isEmpty }) { hostingView in
            let found = buttons(in: hostingView)
            guard !found.isEmpty else {
                throw XCTSkip("SwiftUI exposed no button to accessibility without an assistive app")
            }
            XCTAssertEqual(found.map(\.label), ["Cancel", "Transcribe"])
            XCTAssertEqual(found.map(\.hint), [TranscriptionWording.cancelHint, TranscriptionWording.transcribeHint])
        }
    }

    /// Return presses Transcribe, which starts the transcription the sheet
    /// then shows; Escape presses Cancel, which closes a sheet that has not
    /// started one.
    func testReturnTranscribesAndEscapeCancels() async throws {
        let world = try makeIntegrationWorld("Transcription Sheet Keys")
        let book = try world.makeSilentAudioBook(title: "Long Pier Recordings", trackDurations: [20])
        let center = makeScriptedCenter(script: TranscriptionUIScripts.longTrack, pause: .milliseconds(100))
        let transcribing = TranscriptionSheetModel(request: .book(book), library: world.library, services: makeSheetServices(center: center))
        await transcribing.load()
        let closing = TranscriptionSheetModel(request: .book(book), library: world.library, services: makeSheetServices())
        await closing.load()
        var closed = false
        closing.onClose = { closed = true }

        try withHostedView(TranscriptionSheet(model: transcribing), until: { $0.fittingSize.height > 0 }) { hostingView in
            guard pressKeyEquivalent(.return, in: hostingView) else {
                throw XCTSkip("This macOS hands an offscreen window no key equivalents")
            }
            XCTAssertTrue(waitUntil { transcribing.phase == .transcribing }, "Return did not transcribe")
        }
        withHostedView(TranscriptionSheet(model: closing), until: { $0.fittingSize.height > 0 }) { hostingView in
            XCTAssertTrue(pressKeyEquivalent(.escape, in: hostingView))
            XCTAssertTrue(waitUntil { closed }, "Escape did not cancel")
        }
        center.cancel()
        let ended = await eventuallyHolds { center.current == nil }
        XCTAssertTrue(ended, "the transcription never stopped")
    }

    // MARK: - The Sheet, Saying Why

    /// On a system older than macOS 26 the sheet holds only OK, which takes
    /// VoiceOver's focus and which Return presses, closing the sheet.
    func testTheVersionMessageSheetClosesWithReturn() async throws {
        let model = TranscriptionSheetModel(
            request: .book(TranscriptionSheetTests.audiobook("Harbour Bells")),
            library: nil,
            services: makeSheetServices(support: .needsNewerSystem)
        )
        await model.load()
        var closed = false
        model.onClose = { closed = true }

        try withHostedView(TranscriptionSheet(model: model), until: { $0.fittingSize.height > 0 }) { hostingView in
            XCTAssertEqual(descendants(of: hostingView, as: VoiceOverFocusTriggerView.self).count, 1)
            guard pressKeyEquivalent(.return, in: hostingView) else {
                throw XCTSkip("This macOS hands an offscreen window no key equivalents")
            }
            XCTAssertTrue(waitUntil { closed }, "Return did not press OK")
        }
        XCTAssertEqual(model.phase, .unavailable("Transcription needs macOS 26 or later."))
    }

    // MARK: - The Sheet, Transcribing

    /// A transcription under way draws its progress bar, which VoiceOver's
    /// focus is asked for, and Escape presses Cancel, stopping it.
    func testTheProgressSheetDrawsItsBarAndEscapeStops() throws {
        let world = try makeIntegrationWorld("Transcription Progress Sheet Drawn")
        let book = try world.makeSilentAudioBook(title: "Long Pier Recordings", trackDurations: [20])
        let center = makeScriptedCenter(script: TranscriptionUIScripts.longTrack, pause: .milliseconds(100))
        let model = TranscriptionSheetModel(request: .book(book), library: world.library, services: makeSheetServices(center: center))
        defer {
            // No transcription outlives the test, however it ends.
            center.cancel()
            _ = waitUntil(timeout: 5) { center.current == nil }
        }

        try withHostedView(TranscriptionSheet(model: model), until: { _ in model.phase == .ready }) { hostingView in
            model.transcribe()
            let drawn = waitUntil(timeout: 5) {
                hostingView.layoutSubtreeIfNeeded()
                return model.progress != nil && !self.descendants(of: hostingView, as: NSProgressIndicator.self).isEmpty
            }
            XCTAssertTrue(drawn, "the transcription never drew its progress")
            XCTAssertEqual(model.focusTarget, .progress)
            XCTAssertEqual(descendants(of: hostingView, as: VoiceOverFocusTriggerView.self).count, 1)
            guard pressKeyEquivalent(.escape, in: hostingView) else {
                throw XCTSkip("This macOS hands an offscreen window no key equivalents")
            }
            XCTAssertTrue(waitUntil(timeout: 5) { center.current == nil }, "Escape did not stop the transcription")
        }
    }

    // MARK: - The Offer After an Import

    /// The offer's sheet offers Transcribe first, which Return presses, and
    /// Not Now, which Escape presses.
    func testTheOfferAnswersTranscribeWithReturnAndNotNowWithEscape() throws {
        let decision = ImportDecision(
            kind: .transcriptionOffer(.init(bookID: UUID(), bookTitle: "Harbour Bells", audioSeconds: 3_060)),
            request: ImportRequest()
        )
        let answers = CallLog<ImportDecisionAnswer>()
        let sheet = ImportDecisionSheet(
            decision: decision,
            wording: ImportDecisionWording(for: decision, position: 1, total: 1, movesToTrash: true),
            voiceOverDelay: 0,
            onAnswer: { answer in
                answers.record(answer)
                return .success(nil)
            },
            announce: { _ in }
        )

        try withHostedView(sheet, until: { $0.fittingSize.height > 0 }) { hostingView in
            guard pressKeyEquivalent(.return, in: hostingView) else {
                throw XCTSkip("This macOS hands an offscreen window no key equivalents")
            }
            XCTAssertTrue(waitUntil { answers.calls == [.transcribe] }, "Return answered \(answers.calls)")
            // The choices are dimmed while an answer is carried out, a moment
            // after it is recorded, so Escape is tried until it is taken.
            XCTAssertTrue(waitUntil { pressKeyEquivalent(.escape, in: hostingView) }, "Escape was never taken")
            XCTAssertTrue(waitUntil { answers.calls == [.transcribe, .cancel] }, "Escape answered \(answers.calls)")
        }
    }

    // MARK: - Settings

    /// The Transcription group draws the language pop-up, holding each
    /// language with its status, and the offer's checkbox.
    func testTheSettingsGroupDrawsThePopUpAndTheCheckbox() async throws {
        let world = try makeIntegrationWorld("Transcription Settings Drawn")
        let languages = TranscriptionLanguageChoices(
            systemSupport: { .available },
            supportedLocales: { [Locale(identifier: "en-US"), Locale(identifier: "en-GB")] },
            installedLocales: { [Locale(identifier: "en-US")] }
        )
        await languages.load()
        world.settings.transcriptionLanguage = "en-US"
        let form = Form {
            TranscriptionSettingsSection(languages: languages)
        }
        .environmentObject(world.settings)

        withHostedView(form, until: { !self.descendants(of: $0, as: NSPopUpButton.self).isEmpty }) { hostingView in
            let popUps = descendants(of: hostingView, as: NSPopUpButton.self)
            XCTAssertEqual(popUps.count, 1, "one language pop-up")
            XCTAssertEqual(popUps.first?.itemTitles, languages.choices(including: "en-US").map(\.label))
            XCTAssertEqual(popUps.first?.titleOfSelectedItem, "\(TranscriptionLanguage.name(of: "en-US")), installed")
            let checkboxes = descendants(of: hostingView, as: NSButton.self).filter { !($0 is NSPopUpButton) }
            XCTAssertFalse(checkboxes.isEmpty, "no checkbox was drawn")
        }
    }

    // MARK: - Fixtures

    /// The buttons VoiceOver can land on below `root`.
    private func buttons(in root: Any) -> [AccessibleControl] {
        accessibleControls(in: root).filter { $0.role == .button }
    }
}
