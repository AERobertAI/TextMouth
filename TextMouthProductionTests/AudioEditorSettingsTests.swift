import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

/// The audio editor's settings (FR04): Storage settings' Audio Editing
/// group gains "Preview filters before applying" and "Play half a second
/// after each move", both on until turned off, kept in the preferences
/// store and mirrored in config.json, and followed by the editor at once,
/// Apply's hint saying what a press does now; the filter presets are
/// edited like the substitution rules, a premade
/// one reset alone, a new chain checked as it is typed and refused when it
/// isn't one; and the editor's keys are a group of the Shortcuts tab.
@MainActor
final class AudioEditorSettingsTests: XCTestCase {

    // MARK: - The Two Switches

    /// Both switches are on until turned off, and the group's model reads
    /// and writes them in the store, where config.json mirrors them.
    func testTheSwitchesAreOnUntilTurnedOffAndMirrored() throws {
        let store = makeSandboxedPreferences("editor-settings")
        let settings = AudioEditingSettingsModel(store: store, locate: { nil })
        XCTAssertTrue(settings.previewsFiltersFirst)
        XCTAssertTrue(settings.playsAfterMoves)

        settings.previewsFiltersFirst = false
        settings.playsAfterMoves = false
        XCTAssertFalse(AudioEditorPreferences.previewFiltersFirst.read(from: store))
        XCTAssertFalse(AudioEditorPreferences.playAfterMoves.read(from: store))
        XCTAssertTrue(AudioEditingPreferences.keys.contains("audioEditorPreviewsFilters"))
        XCTAssertTrue(ConfigService.AppConfig.Portability.mirrored.contains { $0.storeKey == "audioEditorPlaysAfterMoves" })
        let config = try JSONDecoder().decode(
            ConfigService.AppConfig.self,
            from: Data(#"{"audioEditorPreviewsFilters": false, "audioEditorPlaysAfterMoves": true}"#.utf8)
        )
        XCTAssertEqual(config.audioEditorPreviewsFilters, false)
        XCTAssertEqual(config.audioEditorPlaysAfterMoves, true)
    }

    /// The Audio Editing group shows both switches as the checkboxes they
    /// are, in order, each in the state the store holds. SwiftUI draws a
    /// checkbox untitled, its label beside it, so the checkboxes are read
    /// in reading order (`feedCheckboxes(in:)`, the feed settings' helper
    /// for SwiftUI's checkboxes); without ffmpeg found, there are only
    /// these two.
    func testTheGroupShowsBothSwitchesInTheStoresState() throws {
        let store = makeSandboxedPreferences("editor-settings-view")
        AudioEditorPreferences.playAfterMoves.write(false, to: store)

        withHostedView(Form { AudioEditingSettingsSection(store: store, locate: { nil }) }, size: NSSize(width: 600, height: 700), until: {
            self.feedCheckboxes(in: $0).count >= 2
        }) { hosting in
            // The Filter Presets… button below them, should SwiftUI draw it
            // untitled too, comes after.
            XCTAssertEqual(feedCheckboxes(in: hosting).prefix(2).map { $0.state == .on }, [true, false])
        }
    }

    /// With the preview first, Apply previews a preset on a target once,
    /// saying to choose Apply again, and applies it the second time; with
    /// it off, Apply applies at once.
    func testApplyPreviewsFirstAsTheSettingSays() async throws {
        let fixture = try AudioEditorTestBook.ramp(seconds: 6, for: self)
        fixture.library.audioFilterEngine = { .builtIn }
        let harness = try await EditorHarness.open(fixture, for: self)
        let model = harness.model
        addTeardownBlock { @MainActor in model.windowClosed() }
        await model.loadPreview()
        let louder = AudioFilterPreset(id: UUID(), name: "Louder", chain: "volume=6dB")
        model.select(AudioTimeRange(start: 1, end: 2))
        model.perform(.editorApplyFilter)
        XCTAssertEqual(model.sheet, .filter)

        await model.chooseApply(louder, to: .selection)
        XCTAssertEqual(harness.announcements.sentences.last, "Previewing Louder first. Choose Apply again to apply it.")
        XCTAssertFalse(model.session.canUndo, "the first Apply applied the filter")
        await model.chooseApply(louder, to: .wholeFile)
        XCTAssertFalse(model.session.canUndo, "a new target wasn't previewed first")

        await model.chooseApply(louder, to: .wholeFile)
        XCTAssertEqual(model.undoName, "Apply Filter")
        XCTAssertNil(model.sheet)

        AudioEditorPreferences.previewFiltersFirst.write(false, to: harness.store)
        model.perform(.editorApplyFilter)
        await model.chooseApply(louder, to: .wholeFile)
        XCTAssertEqual(harness.announcements.sentences.last, "Applied Louder to all of the audio. Now 6 seconds long.")
    }

    /// Apply's hint says what a press does: with the preview first, that it
    /// plays the filtered audio first, until that preset has been previewed
    /// on that target, through Apply or through Preview, a preview that has
    /// ended counting; from then on, for another preset or target still,
    /// that it applies the filter. Opening Apply Filter again starts over,
    /// and with the setting off a press applies at once.
    func testApplysHintSaysWhatAPressDoes() async throws {
        let fixture = try AudioEditorTestBook.ramp(seconds: 6, for: self)
        fixture.library.audioFilterEngine = { .builtIn }
        let harness = try await EditorHarness.open(fixture, for: self)
        let model = harness.model
        addTeardownBlock { @MainActor in model.windowClosed() }
        AudioEditorPreferences.playAfterMoves.write(false, to: harness.store)
        await model.loadPreview()
        let louder = AudioFilterPreset(id: UUID(), name: "Louder", chain: "volume=6dB")
        let quieter = AudioFilterPreset(id: UUID(), name: "Quieter", chain: "volume=-6dB")
        model.select(AudioTimeRange(start: 1, end: 2))
        model.perform(.editorApplyFilter)

        XCTAssertEqual(AudioEditorWording.applyPreviewsFirstHint, "Plays the filtered audio first; choose Apply again to apply the filter.")
        XCTAssertEqual(AudioEditorWording.applyHint, "Applies the filter.")
        XCTAssertTrue(model.applyWouldPreview(louder, on: .selection))
        XCTAssertEqual(model.applyHint(for: louder, on: .selection), AudioEditorWording.applyPreviewsFirstHint)
        XCTAssertEqual(model.applyHint(for: nil, on: .selection), AudioEditorWording.applyHint, "with no preset chosen, nothing previews")

        // Apply previewed first: the next press of it applies, but only that
        // preset on that target.
        await model.chooseApply(louder, to: .selection)
        XCTAssertEqual(model.filterPreview?.presetID, louder.id)
        XCTAssertFalse(model.applyWouldPreview(louder, on: .selection))
        XCTAssertEqual(model.applyHint(for: louder, on: .selection), AudioEditorWording.applyHint)
        XCTAssertTrue(model.applyWouldPreview(louder, on: .wholeFile), "another target previews first")
        XCTAssertTrue(model.applyWouldPreview(quieter, on: .selection), "another preset previews first")

        // The preview ends; it still counts.
        let loads = harness.player.loadedFrames.count
        harness.player.finishPlaying(at: 2)
        XCTAssertNil(model.filterPreview)
        XCTAssertEqual(model.applyHint(for: louder, on: .selection), AudioEditorWording.applyHint)
        let restored = await eventually { harness.player.loadedFrames.count > loads }
        XCTAssertTrue(restored, "the edited audio never came back after the preview")

        // The Preview button counts too.
        await model.previewFilter(quieter, on: .selection)
        XCTAssertEqual(model.applyHint(for: quieter, on: .selection), AudioEditorWording.applyHint)

        // Opening Apply Filter again starts over.
        model.sheet = nil
        model.perform(.editorApplyFilter)
        XCTAssertEqual(model.sheet, .filter)
        XCTAssertEqual(model.applyHint(for: louder, on: .selection), AudioEditorWording.applyPreviewsFirstHint)
        XCTAssertEqual(model.applyHint(for: quieter, on: .selection), AudioEditorWording.applyPreviewsFirstHint)

        // With the setting off, a press applies at once.
        AudioEditorPreferences.previewFiltersFirst.write(false, to: harness.store)
        XCTAssertFalse(model.applyWouldPreview(louder, on: .selection))
        XCTAssertEqual(model.applyHint(for: louder, on: .selection), AudioEditorWording.applyHint)
    }

    // MARK: - The Filter Presets

    /// Reset acts only on a premade preset changed from how it came, and
    /// the moves only away from the ends; a user's preset can't be reset.
    func testAPresetsCommandsActWhereTheyCan() throws {
        let standard = AudioFilterPresetLibrary.standard
        let first = try XCTUnwrap(standard.first)
        var changed = first
        changed.chain = "highpass=f=100"
        let mine = AudioFilterPreset(id: UUID(), name: "Telephone", chain: "highpass=f=300,lowpass=f=3400")

        XCTAssertEqual(AudioFilterPresetCommand.available(for: first, at: 0, of: 3), [.edit, .moveDown, .delete])
        XCTAssertEqual(AudioFilterPresetCommand.available(for: changed, at: 1, of: 3), [.edit, .reset, .moveUp, .moveDown, .delete])
        XCTAssertEqual(AudioFilterPresetCommand.available(for: mine, at: 2, of: 3), [.edit, .moveUp, .delete])
        XCTAssertEqual(AudioFilterPresetCommand.premade(changed), first)
        XCTAssertNil(AudioFilterPresetCommand.premade(mine))
        XCTAssertEqual(
            AudioFilterPresetsWording.row(changed, isChangedPremade: true),
            "\(first.name): highpass=f=100, changed from its default"
        )
    }

    /// A chain is checked as it is typed: TextMouth's own filters run it,
    /// or only ffmpeg does, or it isn't a chain at all.
    func testAChainIsCheckedAsItIsTyped() {
        XCTAssertEqual(AudioFilterPresetsWording.chainCheck("highpass=f=80,volume=3dB"), "TextMouth's own filters run this chain.")
        XCTAssertTrue(AudioFilterPresetsWording.chainCheck("aecho=0.8:0.9:500:0.3").hasSuffix("It runs only through ffmpeg."))
        XCTAssertEqual(AudioFilterPresetsWording.chainCheck("highpass=f='80"), "A quote isn't closed in “highpass=f='80”.")
        XCTAssertEqual(AudioFilterPresetsWording.chainCheck("   "), "Type a chain of filters.")
    }

    /// A new preset is saved with its chain checked first: one that isn't
    /// a chain, or has no name, is refused with why; an edit keeps the
    /// preset's place and identity.
    func testAPresetIsSavedOnlyWithANameAndAChain() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("audio-filters-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let library = AudioFilterPresetLibrary(url: url, reader: SavedFile.readWithoutDownloading)

        XCTAssertEqual(
            try AudioFilterPresetsView.save(AudioFilterPresetDraft(id: UUID(), name: " Telephone ", chain: "highpass=f=300", isNew: true), in: library),
            "Added Telephone"
        )
        XCTAssertEqual(library.presets.last?.name, "Telephone")
        XCTAssertThrowsError(try AudioFilterPresetsView.save(AudioFilterPresetDraft(id: UUID(), name: "Broken", chain: "volume='3", isNew: true), in: library)) {
            XCTAssertEqual($0.localizedDescription, "A quote isn't closed in “volume='3”.")
        }
        XCTAssertThrowsError(try AudioFilterPresetsView.save(AudioFilterPresetDraft(id: UUID(), name: "  ", chain: "volume=3dB", isNew: true), in: library)) {
            XCTAssertEqual($0 as? AudioFilterPresetError, .blankName)
        }

        let telephone = try XCTUnwrap(library.presets.last)
        let place = try XCTUnwrap(library.presets.firstIndex { $0.id == telephone.id })
        XCTAssertEqual(
            try AudioFilterPresetsView.save(AudioFilterPresetDraft(id: telephone.id, name: "Old Phone", chain: "highpass=f=400", isNew: false), in: library),
            "Saved Old Phone"
        )
        XCTAssertEqual(library.presets[checked: place], AudioFilterPreset(id: telephone.id, name: "Old Phone", chain: "highpass=f=400"))
    }

    // MARK: - The Shortcuts Tab

    /// The editor's keys are the last group of the Shortcuts tab, under
    /// its own heading, each action listed by its title.
    func testTheEditorsKeysAreAGroupOfTheShortcutsTab() {
        var categories: [String] = []
        for action in ShortcutAction.allCases where !categories.contains(action.category) {
            categories.append(action.category)
        }
        XCTAssertEqual(categories.last, ShortcutAction.audioEditorCategory)
        let titles = ShortcutAction.allCases.filter { $0.scope == .audioEditor }.map(\.title)
        XCTAssertEqual(titles.first, "Play / Pause")
        XCTAssertTrue(titles.contains("Punch In"))
        XCTAssertFalse(titles.contains { $0.hasPrefix("Audio Editor") })
    }
}
