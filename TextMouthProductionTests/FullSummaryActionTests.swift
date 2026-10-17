import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

/// The full summaries as actions of their own (FR12's branch C, section 3
/// of the design): Where Am I? Full Summary, W twice, and Speak Full Info,
/// Shift-Command-I twice (I twice until October 17), named as the user chose
/// on October 7 (question 9), listed under
/// Information after their brief summaries, each posting its own
/// notification, with Where Am I? and Book Info keeping their
/// keys; the rule every press of a summary follows; and their menu items
/// (question 8) and Shortcuts tab rows.
@MainActor
final class FullSummaryActionTests: XCTestCase {

    // MARK: - Keys Used Below

    private let wTwice = KeyBinding(key: "w", isDoublePress: true)
    private let iTwice = KeyBinding(key: "i", command: true, shift: true, isDoublePress: true)

    // MARK: - The Actions

    /// Each action is named as config.json names it, works in the app's
    /// windows, and posts a notification of its own.
    func testTheFullSummariesAreNamedAsTheUserChose() {
        XCTAssertEqual(ShortcutAction.whereAmIFull.rawValue, "Where Am I? Full Summary")
        XCTAssertEqual(ShortcutAction.speakFullInfo.rawValue, "Speak Full Info")
        for action in [ShortcutAction.whereAmIFull, .speakFullInfo] {
            XCTAssertEqual(action.title, action.rawValue)
            XCTAssertEqual(ShortcutAction.named(action.rawValue.lowercased()), action)
            XCTAssertEqual(action.defaultScope, .app)
            XCTAssertEqual(action.category, "Information")
        }
        XCTAssertEqual(ShortcutAction.whereAmIFull.notificationName, .whereAmIFull)
        XCTAssertEqual(ShortcutAction.speakFullInfo.notificationName, .speakFullInfo)
        XCTAssertEqual(Notification.Name.whereAmIFull.rawValue, "whereAmIFull")
        XCTAssertEqual(Notification.Name.speakFullInfo.rawValue, "speakFullInfo")
    }

    /// The Information group lists each full summary right after its brief
    /// one, as the Shortcuts tab shows the group, in Settings order.
    func testEachFullSummaryIsListedAfterItsBriefOne() {
        let information = ShortcutAction.allCases.filter { $0.category == "Information" }

        XCTAssertEqual(information, [.whereAmI, .whereAmIFull, .speakInfo, .speakFullInfo, .speakImportProgress, .speakDownloadProgress])
    }

    /// Their keys are W twice and Shift-Command-I twice, said, shown, and written in
    /// config.json with the word "twice"; Where Am I? keeps W, Speak Info has
    /// Shift-Command-I, and Book Info keeps Command-I.
    func testTheirKeysAreWTwiceAndITwice() {
        let defaults = ShortcutAction.defaultBindings

        XCTAssertEqual(defaults[.whereAmIFull], [wTwice])
        XCTAssertEqual(defaults[.speakFullInfo], [iTwice])
        XCTAssertEqual(wTwice.accessibleDisplayString, "W twice")
        XCTAssertEqual(iTwice.accessibleDisplayString, "Shift + Command + I twice")
        XCTAssertEqual(wTwice.displayString, "W twice")
        XCTAssertEqual(wTwice.configText, "w twice")
        XCTAssertEqual(iTwice.configText, "shift+command+i twice")
        XCTAssertEqual(ShortcutListing.followingDefaults([iTwice]), "default: shift+command+i twice")
        XCTAssertEqual(defaults[.whereAmI], [KeyBinding(key: "w")])
        XCTAssertEqual(defaults[.speakInfo], [KeyBinding(key: "i", command: true, shift: true)])
        XCTAssertEqual(defaults[.showBookInfo], [KeyBinding(key: "i", command: true)])
    }

    /// No other action of either scope has W twice or Shift-Command-I twice by default;
    /// the audio editor's W and I, Where Am I? and Mark In there, keep
    /// their single presses with no double action.
    func testNoOtherActionHasTheirKeys() {
        let defaults = ShortcutAction.defaultBindings
        let owners = ShortcutAction.allCases.filter { action in
            defaults[action]?.contains { $0 == wTwice || $0 == iTwice } == true
        }

        XCTAssertEqual(owners, [.whereAmIFull, .speakFullInfo])
        let editor = ShortcutPressDispatcher.Index(defaults)
        XCTAssertEqual(editor.actions(for: KeyBinding(key: "w"), in: .audioEditor), .init(single: .editorWhereAmI, double: nil, singleWaits: false))
        XCTAssertEqual(editor.actions(for: KeyBinding(key: "i"), in: .audioEditor), .init(single: .editorMarkIn, double: nil, singleWaits: false))
    }

    // MARK: - The Press Rule (Section 3 of the Design)

    /// What a press does, for each summary pressed for and each summary
    /// speaking: with nothing speaking it speaks the one pressed for; a
    /// brief press stops either; a full press switches the brief summary to
    /// the full one and stops the full one; and a press about another
    /// subject speaks its own summary in place of the one speaking.
    func testWhatEachPressDoes() {
        XCTAssertEqual(SummaryPress.outcome(pressing: .brief, while: nil), .speak(.brief))
        XCTAssertEqual(SummaryPress.outcome(pressing: .full, while: nil), .speak(.full))
        XCTAssertEqual(SummaryPress.outcome(pressing: .brief, while: .brief), .stop)
        XCTAssertEqual(SummaryPress.outcome(pressing: .brief, while: .full), .stop)
        XCTAssertEqual(SummaryPress.outcome(pressing: .full, while: .brief), .replace(with: .full))
        XCTAssertEqual(SummaryPress.outcome(pressing: .full, while: .full), .stop)
        for pressed in [SummaryDetail.brief, .full] {
            for speaking in [SummaryDetail.brief, .full] {
                XCTAssertEqual(SummaryPress.outcome(pressing: pressed, while: speaking, sameSubject: false), .replace(with: pressed))
            }
            XCTAssertEqual(SummaryPress.outcome(pressing: pressed, while: nil, sameSubject: false), .speak(pressed))
        }
    }

    // MARK: - The Menus (Question 8)

    /// The Playback menu offers Where Am I? Full Summary right after Where
    /// Am I?, and the Library menu Speak Full Info right after Speak Info,
    /// named as the actions are, with no key equivalent shown, as their
    /// neighbors show none, and enabled as their neighbors are.
    func testTheMenusOfferEachFullSummaryAfterItsBriefOne() throws {
        let mainMenu = try XCTUnwrap(NSApp.mainMenu)
        let pairs: [(menu: String, brief: String, full: String)] = [
            ("Playback", "Where Am I?", ShortcutAction.whereAmIFull.title),
            ("Library", ShortcutAction.speakInfo.title, ShortcutAction.speakFullInfo.title),
        ]
        for (menuTitle, briefTitle, fullTitle) in pairs {
            let menu = try XCTUnwrap(mainMenu.items.first { $0.title == menuTitle }?.submenu, "no \(menuTitle) menu")
            let titles = menu.items.map(\.title).joined(separator: ", ")
            let briefIndex = try XCTUnwrap(menu.items.firstIndex { $0.title == briefTitle }, titles)
            let fullIndex = briefIndex + 1
            guard menu.items.indices.contains(fullIndex) else {
                return XCTFail("nothing follows \(briefTitle) in \(menuTitle): \(titles)")
            }
            let brief = menu.items[briefIndex]
            let full = menu.items[fullIndex]
            XCTAssertEqual(full.title, fullTitle, titles)
            XCTAssertEqual(full.keyEquivalent, "", "\(fullTitle) shows a key equivalent")
            XCTAssertEqual(brief.keyEquivalent, "", "\(briefTitle) shows a key equivalent")
            XCTAssertEqual(full.isEnabled, brief.isEnabled, "\(fullTitle) is not enabled as \(briefTitle) is")
            XCTAssertEqual(full.isHidden, brief.isHidden)
        }
    }

    // MARK: - The Shortcuts Tab

    /// The Shortcuts tab says each one's keys in words, "W twice" and "Shift + Command + I
    /// twice", in its row's VoiceOver label as for every action.
    func testTheShortcutsTabSaysTheirKeysInWords() {
        let manager = KeyboardShortcutManager(userDefaults: makeSandboxedPreferences("full-summary-tab"), installsEventMonitor: false)

        XCTAssertEqual(manager.allDisplayStrings(for: .whereAmIFull), "W twice")
        XCTAssertEqual(manager.allDisplayStrings(for: .speakFullInfo), "Shift + Command + I twice")
        XCTAssertEqual(
            ShortcutsSettingsWording.rowLabel(for: .whereAmIFull, keys: manager.bindingsFor(.whereAmIFull), isEdited: manager.isEdited(.whereAmIFull)),
            "Where Am I? Full Summary: W twice"
        )
        XCTAssertEqual(
            ShortcutsSettingsWording.rowLabel(for: .speakFullInfo, keys: manager.bindingsFor(.speakFullInfo), isEdited: manager.isEdited(.speakFullInfo)),
            "Speak Full Info: Shift + Command + I twice"
        )
    }

    /// The tab's rows for the two say so to VoiceOver. SwiftUI builds these
    /// elements only for an assistive app, so without one the test is
    /// skipped; the wording above holds either way.
    func testTheirRowsSayTheirKeysToVoiceOver() throws {
        let manager = KeyboardShortcutManager(userDefaults: makeSandboxedPreferences("full-summary-tab-rows"), installsEventMonitor: false)
        let labels = ["Where Am I? Full Summary: W twice", "Speak Full Info: Shift + Command + I twice"]
        let view = VStack {
            ShortcutBindingRow(action: .whereAmIFull)
            ShortcutBindingRow(action: .speakFullInfo)
        }
        .environmentObject(manager)

        try withHostedView(view, until: { hosting in labels.allSatisfy { !self.accessibilityElements(labelled: $0, in: hosting).isEmpty } }) { hosting in
            guard labels.contains(where: { !accessibilityElements(labelled: $0, in: hosting).isEmpty }) else {
                throw XCTSkip("SwiftUI exposed no accessibility elements without an assistive app")
            }
            for label in labels {
                XCTAssertFalse(accessibilityElements(labelled: label, in: hosting).isEmpty, "no row says \(label)")
            }
        }
    }
}
