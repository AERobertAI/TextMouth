import AppKit
import Combine
import SwiftUI
import XCTest
@testable import TextMouth

/// The audio editor window's controls as VoiceOver, a braille display, and
/// the keyboard meet them (FR04): every command has one button, in a group
/// under its heading, titled as Settings lists it, with a hint saying what
/// it does and the shortcuts in force, which follows a change in Settings;
/// each pop-up lists its choices by name; the window and each sheet start
/// VoiceOver on one control; and, wherever this session exposes the AppKit
/// controls SwiftUI draws, VoiceOver reads each by its label, hint, and
/// value; and one press of Return runs a sheet's command once. SwiftUI
/// builds its own buttons and text for VoiceOver only while an assistive
/// app is connected, so their words are checked through the model
/// functions that give them. No test shows a window, plays a sound, or
/// records.
@MainActor
final class AudioEditorWindowTests: XCTestCase {

    /// A size the whole editor window fits in.
    private static let windowSize = NSSize(width: 820, height: 1_000)

    /// The editor's commands, in the order Settings lists them.
    private var editorActions: [ShortcutAction] {
        ShortcutAction.allCases.filter { $0.defaultScope == .audioEditor }
    }

    // MARK: - The Buttons

    /// Every editor command has exactly one button, in one of the window's
    /// four groups, each under a heading of its own.
    func testEveryCommandHasOneButtonInAGroup() {
        let listed = AudioEditorView.groups.flatMap(\.actions)
        XCTAssertEqual(Set(listed), Set(editorActions), "a command has no button, or a button no command")
        XCTAssertEqual(listed.count, editorActions.count, "a command has two buttons")
        XCTAssertEqual(AudioEditorView.groups.map(\.heading), ["Listen and Move", "Select and Mark", "Edit", "Save and Export"])
    }

    /// Every button is titled as Settings lists its command, and its hint
    /// says what it does, then its shortcuts in words, then, for an Undo
    /// that can't, why.
    func testEveryButtonSaysWhatItDoesAndItsShortcuts() async throws {
        let model = try await openRamp(seconds: 4, loadsPreview: false).model

        for action in editorActions {
            XCTAssertEqual(model.title(for: action), action.title)
            let shortcuts = AudioEditorWording.shortcutSentence(ShortcutAction.defaultBindings[action] ?? [])
            let hint = "\(AudioEditorWording.explanation(of: action)) \(shortcuts)"
            XCTAssertEqual(model.hint(for: action), action == .editorUndo ? "\(hint) There's nothing to undo." : hint)
        }
        XCTAssertEqual(model.hint(for: .editorSkipBack), "Moves the cursor back one second. Shortcuts: J or Comma.")
    }

    /// A shortcut changed in Settings reaches its button's hint, and the
    /// window hears of it, so the button is drawn again with the new one.
    func testAChangedShortcutReachesItsButtonsHint() async throws {
        let harness = try await openRamp(seconds: 4, loadsPreview: false)
        let model = harness.model
        let changes = Tally()
        let watching = model.objectWillChange.sink { _ in changes.count += 1 }
        defer { watching.cancel() }

        var edits = KeyboardShortcutManager.editsPreference.read(from: harness.store)
        edits.setKeys([KeyBinding(key: "h", shift: true)], for: .editorSkipBack)
        KeyboardShortcutManager.editsPreference.write(edits, to: harness.store)

        XCTAssertEqual(model.hint(for: .editorSkipBack), "Moves the cursor back one second. Shortcut: Shift + H.")
        let heard = await eventually { changes.count > 0 }
        XCTAssertTrue(heard, "the window never heard the shortcut change")
    }

    // MARK: - The Pop-Ups

    /// The window's microphone pop-up lists the microphones by name; with
    /// none connected it says so, and can't be changed.
    func testTheMicrophonePopUpListsTheMicrophonesByName() async throws {
        let harness = try await openRamp(seconds: 4, loadsPreview: false)
        let window = AudioEditorView(model: harness.model)

        checkPopUp(in: window, size: Self.windowSize, lists: ["MacBook Air Microphone", "AirPods Pro"], isEnabled: true)
        harness.catalog.change(to: [])
        checkPopUp(in: window, size: Self.windowSize, lists: [AudioEditorWording.noMicrophoneItem], isEnabled: false)
    }

    /// Apply Filter lists the presets by name, as Settings keeps them;
    /// Export lists the formats TextMouth can write; and Audio Info lists
    /// what may happen to the book's original audio, the global setting
    /// first, named.
    func testTheSheetsPopUpsListTheirChoicesByName() async throws {
        let model = try await openRamp(seconds: 4, loadsPreview: false).model

        let presets = AudioFilterPresetLibrary().presets.map(\.name)
        XCTAssertFalse(presets.isEmpty)
        checkPopUp(in: AudioEditorFilterSheet(model: model), lists: presets)
        let formats = model.session.exportFormats.map(\.title)
        XCTAssertEqual(Array(formats.prefix(6)), ["M4A (AAC)", "M4B Audiobook (AAC)", "Apple Lossless (M4A)", "WAV", "AIFF", "CAF"])
        checkPopUp(in: AudioEditorExportSheet(model: model), lists: formats)
        checkPopUp(in: AudioEditorInfoSheet(model: model), lists: [
            AudioEditorWording.useGlobal(model.globalPolicy), "Keep", "Don't keep", "Keep for a number of days",
        ])
    }

    // MARK: - Where VoiceOver Starts

    /// Each sheet starts VoiceOver on one control: a question's on its
    /// field; Apply Filter's on the Filter pop-up, or on Cancel with every
    /// preset deleted in Settings; Export's on the Format pop-up; Audio
    /// Info's on its policy pop-up; a save's on its progress bar; and the
    /// list's on its first marker, or on Close while it lists nothing at
    /// all.
    func testEachSheetStartsVoiceOverOnOneControl() async throws {
        let model = try await openRamp(seconds: 4, loadsPreview: false).model

        for prompt in [AudioEditorPrompt.goToTime, .insertSilence, .insertChapter] {
            checkVoiceOverStarts(on: prompt.fieldLabel, in: promptSheet(prompt, of: model))
        }
        checkVoiceOverStarts(on: AudioEditorWording.presetLabel, in: AudioEditorFilterSheet(model: model))
        let noPresets = try emptyPresetLibrary()
        XCTAssertTrue(noPresets.presets.isEmpty)
        checkVoiceOverStarts(on: AudioEditorWording.cancelButton, in: AudioEditorFilterSheet(model: model, presets: noPresets))
        checkVoiceOverStarts(on: AudioEditorWording.formatLabel, in: AudioEditorExportSheet(model: model))
        checkVoiceOverStarts(on: AudioEditorWording.policyLabel, in: AudioEditorInfoSheet(model: model))
        model.progress = AudioEditorProgress(title: AudioEditorWording.savingTitle, detail: "", fraction: 0.5)
        checkVoiceOverStarts(on: AudioEditorWording.progressLabel, in: AudioEditorProgressSheet(model: model))

        // Its preview never loaded, the audio has no pauses found yet.
        XCTAssertTrue(model.markers.isEmpty && model.chapters.isEmpty && model.pauses.isEmpty)
        checkVoiceOverStarts(on: AudioEditorWording.closeButton, in: AudioEditorMarkersSheet(model: model))
        model.addMarker()
        let marker = try XCTUnwrap(model.orderedMarkers.first)
        checkVoiceOverStarts(
            on: AudioEditorWording.marker(1, named: marker.name, at: marker.time),
            in: AudioEditorMarkersSheet(model: model)
        )
    }

    // MARK: - As VoiceOver Reads Them

    /// VoiceOver reads each AppKit control by its label, hint, and value:
    /// the window's microphone pop-up, with the microphone in use; a
    /// question's field, with what to type; the sheets' pop-ups, with the
    /// choice made; and Audio Info's stepper, once the book keeps its
    /// original for some days, with the days in words.
    func testVoiceOverReadsEachControlByItsLabel() async throws {
        try skipUnlessHostedWindowsExposeAccessibility()
        let harness = try await openRamp(seconds: 4, loadsPreview: false)
        let model = harness.model

        try readControls(of: AudioEditorView(model: model), size: Self.windowSize, drawn: NSPopUpButton.self) { controls in
            let microphone = try control(labelled: AudioEditorWording.microphoneLabel, in: controls)
            XCTAssertEqual(microphone.hint, AudioEditorWording.microphoneHint)
            XCTAssertEqual(microphone.element.accessibilityValue() as? String, "MacBook Air Microphone")
        }
        for prompt in [AudioEditorPrompt.goToTime, .insertSilence, .insertChapter] {
            try readControls(of: promptSheet(prompt, of: model), drawn: NSTextField.self) { controls in
                let field = try control(labelled: prompt.fieldLabel, in: controls)
                XCTAssertEqual(field.hint, prompt.explanation)
            }
        }
        try readControls(of: AudioEditorFilterSheet(model: model), drawn: NSPopUpButton.self) { controls in
            let preset = try control(labelled: AudioEditorWording.presetLabel, in: controls)
            XCTAssertEqual(preset.element.accessibilityValue() as? String, AudioFilterPresetLibrary().presets.first?.name)
        }
        try readControls(of: AudioEditorExportSheet(model: model), drawn: NSPopUpButton.self) { controls in
            let format = try control(labelled: AudioEditorWording.formatLabel, in: controls)
            XCTAssertEqual(format.element.accessibilityValue() as? String, model.session.exportFormats.first?.title)
        }

        await model.setPolicy(.deleteAfterDays, days: 3)
        XCTAssertEqual(model.policyChoice, .deleteAfterDays, "\(harness.announcements.sentences)")
        try readControls(of: AudioEditorInfoSheet(model: model), drawn: NSStepper.self) { controls in
            let policy = try control(labelled: AudioEditorWording.policyLabel, in: controls)
            XCTAssertEqual(policy.hint, AudioEditingSettingsWording.policyHint)
            XCTAssertEqual(policy.element.accessibilityValue() as? String, "Keep for a number of days")
            let days = try control(labelled: AudioEditingSettingsWording.daysLabel, in: controls)
            XCTAssertEqual(days.valueDescription, "3 days")
        }
    }

    /// A save's sheet draws a native progress bar, which VoiceOver reads as
    /// the progress indicator it is, at how far the save is. AppKit exposes
    /// no progress bar among a hosted window's elements, so its words, the
    /// label and the percent, are pinned where they are made
    /// (`AudioEditorWording`).
    func testASavesSheetDrawsItsProgressBarAtHowFarItIs() async throws {
        let model = try await openRamp(seconds: 4, loadsPreview: false).model
        model.progress = AudioEditorProgress(title: AudioEditorWording.savingTitle, detail: "Saving.", fraction: 0.5)

        withHostedView(AudioEditorProgressSheet(model: model), until: { !self.descendants(of: $0, as: NSProgressIndicator.self).isEmpty }) { hosting in
            guard let bar = descendants(of: hosting, as: NSProgressIndicator.self).first else {
                return XCTFail("no progress bar was drawn")
            }
            XCTAssertEqual(bar.accessibilityRole(), .progressIndicator)
            XCTAssertFalse(bar.isIndeterminate)
            XCTAssertEqual(bar.doubleValue / bar.maxValue, 0.5, accuracy: 0.000_1)
        }
        XCTAssertEqual(AudioEditorWording.progressLabel, "Progress")
    }

    // MARK: - The List's Rows

    /// Each row of Markers and Pauses is one element labelled with its
    /// words, "Marker 1, Intro, at 3 seconds.", which VoiceOver reads once:
    /// the words drawn are hidden from it, and the row's buttons name the
    /// row, "Delete Marker 1", so a braille display tells one row's from
    /// the next. Wherever this session exposes SwiftUI's elements, a hosted
    /// list holds no text repeating a row's words under the row, and the
    /// row's buttons and actions are those.
    func testARowsWordsAreReadOnce() async throws {
        let pause = AudioEditorPause(start: 1, end: 1.8)
        XCTAssertEqual(AudioEditorWording.marker(1, named: "Intro", at: 3), "Marker 1, Intro, at 3 seconds.")
        XCTAssertEqual(AudioEditorWording.marker(2, named: "", at: 64), "Marker 2, at 1 minute, 4 seconds.")
        XCTAssertEqual(AudioEditorWording.chapterRow(1, title: "Locks", at: 10), "Chapter 1: Locks, at 10 seconds")
        XCTAssertEqual(AudioEditorWording.pauseRow(1, pause), "Pause 1, 0.8 seconds, at 1 second")
        XCTAssertEqual(AudioEditorWording.markerSubject(1), "Marker 1")
        XCTAssertEqual(AudioEditorWording.rowButton(AudioEditorWording.deleteButton, AudioEditorWording.markerSubject(1)), "Delete Marker 1")
        XCTAssertEqual(AudioEditorWording.rowButton(AudioEditorWording.removeButton, AudioEditorWording.chapterSubject(1)), "Remove Chapter 1")
        XCTAssertEqual(AudioEditorWording.rowButton(AudioEditorWording.selectButton, AudioEditorWording.pauseSubject(1)), "Select Pause 1")

        let model = try await openRamp(seconds: 12, loadsPreview: false).model
        model.move(to: 3)
        model.addMarker()
        let marker = try XCTUnwrap(model.markers.first)
        model.renameMarker(marker.id, to: "Intro")
        try await model.session.perform(.setChapter(at: 10, title: "Locks"))
        model.pauses = [pause]
        model.pauseSearch = .found
        // Each row's words, the subject its buttons name it with, and its
        // commands, which name its actions.
        let markerLabel = "Marker 1, Intro, at 3 seconds."
        let rows: [(label: String, subject: String, commands: [String])] = [
            (markerLabel, "Marker 1", [AudioEditorWording.goToButton, AudioEditorWording.renameButton, AudioEditorWording.deleteButton]),
            ("Chapter 1: Locks, at 10 seconds", "Chapter 1", [AudioEditorWording.goToButton, AudioEditorWording.renameButton, AudioEditorWording.removeButton]),
            ("Pause 1, 0.8 seconds, at 1 second", "Pause 1", [AudioEditorWording.goToButton, AudioEditorWording.selectButton]),
        ]

        try withHostedView(AudioEditorMarkersSheet(model: model), until: {
            !self.accessibilityElements(labelled: markerLabel, in: $0).isEmpty
        }) { hosting in
            guard !accessibilityElements(labelled: markerLabel, in: hosting).isEmpty else {
                throw XCTSkip("SwiftUI exposed no accessibility elements without an assistive app")
            }
            for row in rows {
                let found = accessibilityElements(labelled: row.label, in: hosting)
                XCTAssertEqual(found.count, 1, "\(row.label) is one element")
                guard let element = found.first else { continue }
                let repeated = (element.accessibilityChildren() ?? []).flatMap { elements(saying: row.label, under: $0) }
                XCTAssertTrue(repeated.isEmpty, "\(row.label) is drawn again under its row for VoiceOver")
                let buttons = accessibleControls(in: element).filter { $0.role == .button }.map(\.label)
                if !buttons.isEmpty {
                    XCTAssertEqual(buttons, row.commands.map { AudioEditorWording.rowButton($0, row.subject) })
                }
                let actions = (element.accessibilityCustomActions() ?? []).map(\.name)
                if !actions.isEmpty {
                    XCTAssertEqual(actions, row.commands)
                }
            }
        }
    }

    /// While a marker or a chapter marker is renamed, its row holds the
    /// field, labelled for VoiceOver with the row's subject, "Name Marker
    /// 1" or "Title Chapter 2", holding the name as it stands, then Save
    /// Name and Cancel; VoiceOver reads the field by that label, with the
    /// name as its value.
    func testARenameRowsFieldNamesItsRow() throws {
        XCTAssertEqual(AudioEditorWording.rowButton(AudioEditorWording.nameFieldLabel, AudioEditorWording.markerSubject(1)), "Name Marker 1")
        XCTAssertEqual(AudioEditorWording.rowButton(AudioEditorWording.titleFieldLabel, AudioEditorWording.chapterSubject(2)), "Title Chapter 2")
        XCTAssertEqual(AudioEditorWording.saveNameButton, "Save Name")

        let row = AudioEditorRenameRow(
            label: AudioEditorWording.titleFieldLabel,
            subject: AudioEditorWording.chapterSubject(2),
            name: .constant("Locks"),
            save: {},
            cancel: {}
        )
        try withHostedControls(row) { controls in
            let field = try control(labelled: "Title Chapter 2", in: controls)
            XCTAssertEqual(field.role, .textField)
            XCTAssertEqual(field.element.accessibilityValue() as? String, "Locks")
        }
    }

    // MARK: - Return

    /// One press of Return runs a sheet's command once, with the keyboard
    /// in the field, as it is when the sheet opens, and out of it: Go to
    /// Time, Insert Silence, and Insert Chapter Marker, whose field's
    /// submit and default button take the same answer, and the list's
    /// rename rows, whose field's submit and Save Name save the same name.
    /// The key goes through the window as AppKit sends a key pressed in
    /// it. Insert Silence begins its edit as soon as it is answered, so a
    /// second run would insert the silence twice.
    func testOneReturnRunsACommandOnce() throws {
        for prompt in [AudioEditorPrompt.goToTime, .insertSilence, .insertChapter] {
            let answers = Tally()
            let sheet = AudioEditorPromptSheet(prompt: prompt, initialText: "1", submit: { _ in
                answers.count += 1
                return nil
            }, cancel: {})
            try checkReturnRunsOnce(in: sheet, counting: answers, prompt.title)
        }
        let saves = Tally()
        let row = AudioEditorRenameRow(
            label: AudioEditorWording.nameFieldLabel,
            subject: AudioEditorWording.markerSubject(1),
            name: .constant("Intro"),
            save: { saves.count += 1 },
            cancel: {}
        )
        try checkReturnRunsOnce(in: row, counting: saves, "the rename row")
    }

    /// Escape cancels a renaming under way, the list staying open, as it
    /// cancels a renaming in the Finder: once the keyboard has left the
    /// field, which keeps Escape itself, the rename row's Cancel takes the
    /// key and saves nothing; Close takes it only while no name is typed,
    /// closing the list.
    func testEscapeCancelsARenamingBeforeClosingTheList() async throws {
        XCTAssertNil(AudioEditorMarkersSheet.closeShortcut(whileRenaming: true))
        XCTAssertEqual(AudioEditorMarkersSheet.closeShortcut(whileRenaming: false), .cancelAction)

        let saves = Tally()
        let cancels = Tally()
        let row = AudioEditorRenameRow(
            label: AudioEditorWording.nameFieldLabel,
            subject: AudioEditorWording.markerSubject(1),
            name: .constant("Intro"),
            save: { saves.count += 1 },
            cancel: { cancels.count += 1 }
        )
        try withHostedView(row, until: { !self.editableTextFields(in: $0).isEmpty }) { hosting in
            let window = try XCTUnwrap(hosting.window, "the rename row has no window")
            // The keyboard out of the field, as after a Tab to the buttons.
            window.makeFirstResponder(nil)
            try press(.escape, in: window)
            guard ran(cancels) else {
                throw XCTSkip("This macOS hands an offscreen window no key presses")
            }
            XCTAssertEqual(cancels.count, 1, "Escape cancelled the renaming \(cancels.count) times")
            XCTAssertEqual(saves.count, 0, "Escape saved the name")
        }

        let model = try await openRamp(seconds: 4, loadsPreview: false).model
        model.sheet = .markers
        try withHostedView(AudioEditorMarkersSheet(model: model), until: { $0.fittingSize.height > 0 }) { hosting in
            guard pressKeyEquivalent(.escape, in: hosting) else {
                throw XCTSkip("This macOS hands an offscreen window no key equivalents")
            }
            XCTAssertTrue(waitUntil { model.sheet == nil }, "Escape did not close the list")
        }
    }

    /// Hosts `view`, puts the keyboard in its field, as the view does as it
    /// opens, presses Return once, and checks that `runs` counted one run;
    /// then takes the keyboard out of the field and presses Return again,
    /// for one more. Skips where this macOS hands an offscreen window no
    /// key at all.
    private func checkReturnRunsOnce<Content: View>(in view: Content, counting runs: Tally, _ name: String) throws {
        try withHostedView(view, until: { !self.editableTextFields(in: $0).isEmpty }) { hosting in
            let window = try windowWithKeyboardInField(of: hosting, name)
            try press(.return, in: window)
            guard ran(runs) else {
                throw XCTSkip("This macOS hands an offscreen window no key presses")
            }
            XCTAssertEqual(runs.count, 1, "one Return ran \(name)'s command \(runs.count) times with the keyboard in its field")

            window.makeFirstResponder(nil)
            runs.count = 0
            try press(.return, in: window)
            _ = ran(runs)
            XCTAssertEqual(runs.count, 1, "one Return ran \(name)'s command \(runs.count) times with the keyboard out of its field")
        }
    }

    /// The window hosting `hosting`, with the keyboard put in the first
    /// field drawn, as a sheet puts it as it opens; fails the test, naming
    /// `name`, when there is no field or it took no keyboard focus.
    private func windowWithKeyboardInField(of hosting: NSView, _ name: String) throws -> NSWindow {
        let window = try XCTUnwrap(hosting.window, "\(name) has no window")
        let field = try XCTUnwrap(editableTextFields(in: hosting).first, "\(name) drew no field")
        XCTAssertTrue(window.makeFirstResponder(field), "\(name)'s field took no keyboard focus")
        XCTAssertTrue(isEditing(field, in: window), "\(name)'s field isn't being edited")
        return window
    }

    /// Presses `key` in `window`, as AppKit sends a key pressed in it: to
    /// the control with keyboard focus, or to the button with that shortcut.
    /// Unlike the shared `pressKey(_:in:)`, which offers the key to the
    /// window's buttons as a key equivalent first, this sends it to the
    /// window, so the field with the keyboard meets it first: what one
    /// Return must not do is run a command both in its field and through
    /// the default button.
    private func press(_ key: KeyEquivalent, in window: NSWindow) throws {
        window.sendEvent(try XCTUnwrap(keyDown(key, in: window), "no key-down event for \(key.character)"))
    }

    /// Whether `runs` counted a run within a second of a key press, waiting
    /// a moment more for any second run, which would come at once or on
    /// the next turn of the run loop.
    private func ran(_ runs: Tally) -> Bool {
        guard waitUntil(timeout: 1, { runs.count > 0 }) else { return false }
        _ = waitUntil(timeout: 0.3) { runs.count > 1 }
        return true
    }

    // MARK: - The Main Edit Menu

    /// The main Edit menu sends the actions an editor window answers: Undo
    /// and Redo, which its window takes, and Cut, Copy, Paste, and Select
    /// All, which stand for the editor's own commands.
    func testTheEditMenuSendsWhatAnEditorWindowAnswers() throws {
        let menu = try XCTUnwrap(NSApp.mainMenu)
        let edit = try XCTUnwrap(menu.items.first { $0.title == "Edit" }?.submenu, "the menu bar has no Edit menu")
        let sent = Set(edit.items.compactMap(\.action).map(NSStringFromSelector))
        for action in ["undo:", "redo:", "cut:", "copy:", "paste:", "selectAll:"] {
            XCTAssertTrue(sent.contains(action), "the Edit menu sends no \(action): \(sent.sorted())")
        }
        let standsFor = ["cut:", "copy:", "paste:", "selectAll:"].map { AudioEditorEditMenu.command(for: NSSelectorFromString($0)) }
        XCTAssertEqual(standsFor, [.editorCut, .editorCopy, .editorPaste, .editorSelectAll])
        XCTAssertNil(AudioEditorEditMenu.command(for: #selector(NSText.delete(_:))))
    }

    /// While the editor's window is the key window, the Edit menu's Cut,
    /// Copy, Paste, and Select All are the editor's, available as its
    /// buttons are; while another window is in front, as a sheet over the
    /// editor is, they are not, and do nothing to it.
    func testTheEditMenusCommandsActOnTheEditorInFront() async throws {
        let model = try await openRamp(seconds: 4).model
        let (controller, _, front) = editMenu(over: model)
        let cut = menuItem(#selector(NSText.cut(_:)))
        let paste = menuItem(#selector(NSText.paste(_:)))
        let selectAll = menuItem(#selector(NSText.selectAll(_:)))
        XCTAssertFalse(controller.validateMenuItem(cut), "nothing is selected")
        XCTAssertFalse(controller.validateMenuItem(paste), "nothing was copied")
        XCTAssertTrue(controller.validateMenuItem(selectAll))

        controller.selectAll(nil)
        let selectedAll = await eventually { model.selection == AudioTimeRange(start: 0, end: 4) }
        XCTAssertTrue(selectedAll, "Select All didn't select the audio")
        XCTAssertTrue(controller.validateMenuItem(cut))
        model.select(AudioTimeRange(start: 1, end: 2))
        controller.cut(nil)
        let didCut = await eventually { abs(model.duration - 3) < 0.000_1 && !model.isWorking }
        XCTAssertTrue(didCut, "Cut didn't cut the selection")
        XCTAssertTrue(controller.validateMenuItem(paste), "the cut audio waits to be pasted")

        front.window = NSWindow()
        XCTAssertFalse(controller.validateMenuItem(selectAll))
        XCTAssertFalse(controller.validateMenuItem(paste))
        controller.selectAll(nil)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(model.selection, "another window's Select All reached the editor")
    }

    /// The editor window's undo manager stands for the editor's Undo and
    /// Redo: the window gives it to the Edit menu, which then titles its
    /// items as the editor's buttons are titled and undoes and redoes
    /// through them.
    func testTheEditMenusUndoAndRedoAreTheEditors() async throws {
        let model = try await openRamp(seconds: 4).model
        let (controller, window, _) = editMenu(over: model)
        let undoManager = try XCTUnwrap(controller.editor(in: window)?.undoManager)
        XCTAssertTrue(window.undoManager === undoManager, "the window doesn't give the menu the editor's undo manager")
        XCTAssertEqual(undoManager.undoMenuItemTitle, "Undo")

        model.select(AudioTimeRange(start: 1, end: 2))
        await model.cut()
        let undoItem = NSMenuItem(title: "Undo", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
        XCTAssertTrue(window.validateMenuItem(undoItem))
        XCTAssertEqual(undoItem.title, "Undo Cut 1 Second")

        window.perform(NSSelectorFromString("undo:"), with: nil)
        let undone = await eventually { abs(model.duration - 4) < 0.000_1 && !model.isWorking }
        XCTAssertTrue(undone, "Undo didn't undo the cut")
        XCTAssertTrue(undoManager.canRedo)
        XCTAssertEqual(undoManager.redoMenuItemTitle, "Redo Cut 1 Second")
        undoManager.redo()
        let redone = await eventually { abs(model.duration - 3) < 0.000_1 && !model.isWorking }
        XCTAssertTrue(redone, "Redo didn't redo the cut")

        model.isWorking = true
        XCTAssertFalse(undoManager.canUndo, "Undo waits for work under way, as its button does")
        model.isWorking = false
    }

    // MARK: - Helpers

    /// A controller of its own over `model`'s editor, in a window never
    /// shown, which it takes as the key window until `front.window` names
    /// another.
    private func editMenu(over model: AudioEditorModel) -> (AudioEditorWindowController, NSWindow, KeyWindowStandIn) {
        let controller = AudioEditorWindowController()
        let window = NSWindow()
        controller.attach(model, to: window)
        let front = KeyWindowStandIn(window)
        controller.keyWindow = { front.window }
        return (controller, window, front)
    }

    /// An Edit menu item sending `action`.
    private func menuItem(_ action: Selector) -> NSMenuItem {
        NSMenuItem(title: "", action: action, keyEquivalent: "")
    }

    /// A preset library with every preset deleted, as Settings leaves it,
    /// kept in a file of the test's own.
    private func emptyPresetLibrary() throws -> AudioFilterPresetLibrary {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("audio-filters-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let library = AudioFilterPresetLibrary(url: url, reader: SavedFile.readWithoutDownloading)
        for preset in library.presets {
            try library.remove(preset.id)
        }
        return library
    }

    /// `prompt`'s sheet for `model`, as the window builds it.
    private func promptSheet(_ prompt: AudioEditorPrompt, of model: AudioEditorModel) -> AudioEditorPromptSheet {
        AudioEditorPromptSheet(
            prompt: prompt,
            initialText: model.initialText(for: prompt),
            submit: { model.answer(prompt, with: $0) },
            cancel: { model.sheet = nil }
        )
    }

    /// Hosts `view`, and checks that it draws a pop-up listing `titles`, in
    /// order, enabled as `isEnabled` says when it is given.
    private func checkPopUp<Content: View>(
        in view: Content,
        size: NSSize = NSSize(width: 600, height: 520),
        lists titles: [String],
        isEnabled: Bool? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        withHostedView(view, size: size, until: { !self.descendants(of: $0, as: NSPopUpButton.self).isEmpty }) { hosting in
            let popUps = descendants(of: hosting, as: NSPopUpButton.self)
            guard let popUp = popUps.first(where: { $0.itemTitles == titles }) else {
                return XCTFail("no pop-up lists \(titles): \(popUps.map(\.itemTitles))", file: file, line: line)
            }
            if let isEnabled {
                XCTAssertEqual(popUp.isEnabled, isEnabled, "\(titles)", file: file, line: line)
            }
        }
    }

    /// Hosts `view` until it has drawn a control of `type`, and passes the
    /// controls VoiceOver can land on to `body` while the window lives.
    private func readControls<Content: View, Control: NSView>(
        of view: Content,
        size: NSSize = NSSize(width: 600, height: 520),
        drawn type: Control.Type,
        _ body: ([AccessibleControl]) throws -> Void
    ) throws {
        try withHostedView(view, size: size, until: {
            !self.descendants(of: $0, as: type).isEmpty && !self.accessibleControls(in: $0).isEmpty
        }) { hosting in
            try body(accessibleControls(in: hosting))
        }
    }

    /// Every accessibility element at or below `root` whose label or value
    /// is `text`: where a row's words would be read again.
    private func elements(saying text: String, under root: Any) -> [NSAccessibilityProtocol] {
        guard let node = root as? NSAccessibilityProtocol else { return [] }
        let says = node.accessibilityLabel() == text || node.accessibilityValue() as? String == text
        return (says ? [node] : []) + (node.accessibilityChildren() ?? []).flatMap { elements(saying: text, under: $0) }
    }

    /// The control labelled `label` among `controls`; fails the test,
    /// listing the labels there are, when there is none.
    private func control(labelled label: String, in controls: [AccessibleControl]) throws -> AccessibleControl {
        try XCTUnwrap(controls.first { $0.label == label }, "no control is labelled \(label): \(controls.map(\.label))")
    }
}

/// Counts what a publisher sends.
@MainActor
private final class Tally {
    var count = 0
}

/// The window a test says is in front, for a controller's Edit menu.
@MainActor
private final class KeyWindowStandIn {
    var window: NSWindow?

    init(_ window: NSWindow?) {
        self.window = window
    }
}
