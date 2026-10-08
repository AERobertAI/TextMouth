import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

/// The Shortcuts tab with the record of the user's edits (FR12): every key
/// said in words, never in symbols, which a braille display shows as signs;
/// an edited row says "Edited" and offers Reset to Default, as a button and
/// a VoiceOver action; a recorded key is announced, with the action it was
/// taken from. The wording is pinned without a window, since SwiftUI
/// exposes its buttons and rows only to a connected assistive app.
@MainActor
final class ShortcutsSettingsTabTests: XCTestCase {

    // MARK: - Keys in Words

    /// A shortcut is said in words: its modifiers, then its key, a special
    /// key by its name; the screen keeps its symbols.
    func testEveryKeyIsSaidInWords() {
        let said: [(KeyBinding, String)] = [
            (KeyBinding(key: "rightArrow", command: true), "Command + Right Arrow"),
            (KeyBinding(key: "leftArrow", command: true), "Command + Left Arrow"),
            (KeyBinding(key: "upArrow", command: true, option: true), "Option + Command + Up Arrow"),
            (KeyBinding(key: "downArrow", command: true, shift: true), "Shift + Command + Down Arrow"),
            (KeyBinding(key: "delete", command: true), "Command + Delete"),
            (KeyBinding(key: "escape", shift: true), "Shift + Escape"),
            (KeyBinding(key: "tab", control: true), "Control + Tab"),
            (KeyBinding(key: "return"), "Return"),
            (KeyBinding(key: "space"), "Space"),
            (KeyBinding(key: "b", command: true, option: true, shift: true), "Option + Shift + Command + B"),
            (KeyBinding(key: "[", command: true), "Command + ["),
        ]
        for (binding, words) in said {
            XCTAssertEqual(binding.accessibleDisplayString, words)
        }
        XCTAssertEqual(KeyBinding(key: "rightArrow", command: true).displayString, "\u{2318}\u{2192}")
        XCTAssertEqual(KeyBinding.accessibleDisplayString(for: [KeyBinding(key: "space"), KeyBinding(key: "k")]), "Space or K")
        XCTAssertEqual(KeyBinding.accessibleDisplayString(for: []), "No shortcut")
    }

    /// The manager says an action's keys in force in words.
    func testTheManagerSaysAnActionsKeysInWords() {
        let manager = KeyboardShortcutManager(userDefaults: makeSandboxedPreferences("shortcut-tab-words"), installsEventMonitor: false)

        XCTAssertEqual(manager.allDisplayStrings(for: .skipForward), "Command + Right Arrow or L")
        XCTAssertEqual(manager.allDisplayStrings(for: .releaseMediaControls), "No shortcut")
    }

    // MARK: - A Row

    /// A row's VoiceOver label names the action, its keys in words, and,
    /// for an edited action, "Edited."; an audio editor action keeps its
    /// group's name.
    func testARowSaysItsKeysInWordsAndWhetherItIsEdited() {
        let shiftR = KeyBinding(key: "r", shift: true)

        XCTAssertEqual(
            ShortcutsSettingsWording.rowLabel(for: .releaseMediaControls, keys: [shiftR], isEdited: true),
            "Release Media Controls: Shift + R. Edited."
        )
        XCTAssertEqual(ShortcutsSettingsWording.rowLabel(for: .whereAmI, keys: [KeyBinding(key: "w")], isEdited: false), "Where Am I?: W")
        XCTAssertEqual(ShortcutsSettingsWording.rowLabel(for: .goToLibrary, keys: [], isEdited: true), "Go to Library: No shortcut. Edited.")
        XCTAssertEqual(
            ShortcutsSettingsWording.rowLabel(for: .editorPlayPause, keys: [KeyBinding(key: "space"), KeyBinding(key: "k")], isEdited: false),
            "Audio Editor: Play / Pause: Space or K"
        )
        XCTAssertEqual(ShortcutsSettingsWording.edited, "Edited")
    }

    /// Reset to Default names its action to VoiceOver, and once done says
    /// the keys the action has again.
    func testResetToDefaultNamesItsActionAndSaysTheKeys() {
        XCTAssertEqual(ShortcutsSettingsWording.resetToDefaultTitle, "Reset to Default")
        XCTAssertEqual(ShortcutsSettingsWording.resetToDefaultLabel(for: .releaseMediaControls), "Reset Release Media Controls to Default")
        XCTAssertEqual(
            ShortcutsSettingsWording.resetAnnouncement(for: .nextBookmark, keys: [KeyBinding(key: "b", command: true, option: true, shift: true)]),
            "Next Bookmark reset to default: Option + Shift + Command + B."
        )
        XCTAssertEqual(
            ShortcutsSettingsWording.resetAnnouncement(for: .releaseMediaControls, keys: []),
            "Release Media Controls reset to default: No shortcut."
        )
        XCTAssertFalse(ShortcutsSettingsWording.resetToDefaultHint.isEmpty)
    }

    // MARK: - Recording a Key

    /// A recorded key is announced with the action it was recorded for and,
    /// when another action had it, the one it was taken from; a name ending
    /// in a question mark ends the sentence itself.
    func testARecordedKeyIsAnnouncedWithTheActionItWasTakenFrom() {
        XCTAssertEqual(
            ShortcutsSettingsWording.recorded(KeyBinding(key: "r", shift: true), for: .releaseMediaControls, takenFrom: nil),
            "Shift + R, recorded for Release Media Controls."
        )
        XCTAssertEqual(
            ShortcutsSettingsWording.recorded(KeyBinding(key: "k"), for: .whereAmI, takenFrom: .togglePlayback),
            "K, recorded for Where Am I? Taken from Play / Pause."
        )
        XCTAssertEqual(
            ShortcutsSettingsWording.recorded(KeyBinding(key: "w"), for: .goToLibrary, takenFrom: .whereAmI),
            "W, recorded for Go to Library. Taken from Where Am I?"
        )
    }

    /// The action a recorded key is taken from is the one of the same scope
    /// whose keys in force hold it, never one of the other scope.
    func testTheActionAKeyIsTakenFromIsTheOneHoldingItInTheScope() {
        let manager = KeyboardShortcutManager(userDefaults: makeSandboxedPreferences("shortcut-tab-owner"), installsEventMonitor: false)

        XCTAssertEqual(manager.action(holding: KeyBinding(key: "k"), in: .app), .togglePlayback)
        XCTAssertEqual(manager.action(holding: KeyBinding(key: "k"), in: .audioEditor), .editorPlayPause)
        XCTAssertNil(manager.action(holding: KeyBinding(key: "r", shift: true), in: .app))

        manager.addBinding(KeyBinding(key: "k"), to: .whereAmI)
        XCTAssertEqual(manager.action(holding: KeyBinding(key: "k"), in: .app), .whereAmI)
    }

    // MARK: - The Row on Screen

    /// An edited row is one element whose label ends "Edited." and whose
    /// VoiceOver action is Reset to Default; an unedited row offers none.
    /// SwiftUI builds these elements only for an assistive app, so without
    /// one the test is skipped; the wording above holds either way.
    func testAnEditedRowOffersResetToDefaultToVoiceOver() throws {
        let manager = KeyboardShortcutManager(userDefaults: makeSandboxedPreferences("shortcut-tab-row"), installsEventMonitor: false)
        manager.updateBindings(for: .releaseMediaControls, to: [KeyBinding(key: "r", shift: true)])
        let editedLabel = "Release Media Controls: Shift + R. Edited."
        let view = VStack {
            ShortcutBindingRow(action: .releaseMediaControls)
            ShortcutBindingRow(action: .whereAmI)
        }
        .environmentObject(manager)

        try withHostedView(view, until: { !self.accessibilityElements(labelled: editedLabel, in: $0).isEmpty }) { hosting in
            guard let edited = accessibilityElements(labelled: editedLabel, in: hosting).first else {
                throw XCTSkip("SwiftUI exposed no accessibility elements without an assistive app")
            }
            XCTAssertEqual((edited.accessibilityCustomActions() ?? []).map(\.name), [ShortcutsSettingsWording.resetToDefaultTitle])
            let unedited = accessibilityElements(labelled: "Where Am I?: W", in: hosting).first
            XCTAssertEqual((unedited?.accessibilityCustomActions() ?? []).map(\.name), [])
        }
    }
}
