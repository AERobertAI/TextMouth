import AppKit
import XCTest
@testable import TextMouth

/// The full summaries as actions of their own (FR12's branch C, section 3
/// of the design): Where Am I? Full Summary, W twice, and Speak Full Info,
/// I twice, named as the user chose on October 7 (question 9), listed under
/// Information after their brief summaries, each posting its own
/// notification, with Where Am I?, Speak Info, and Book Info keeping their
/// keys.
@MainActor
final class FullSummaryActionTests: XCTestCase {

    // MARK: - Keys Used Below

    private let wTwice = KeyBinding(key: "w", isDoublePress: true)
    private let iTwice = KeyBinding(key: "i", isDoublePress: true)

    // MARK: - The Actions

    /// Each action is named as config.json names it, works in the app's
    /// windows, and posts a notification of its own.
    func testTheFullSummariesAreNamedAsTheUserChose() {
        XCTAssertEqual(ShortcutAction.whereAmIFull.rawValue, "Where Am I? Full Summary")
        XCTAssertEqual(ShortcutAction.speakFullInfo.rawValue, "Speak Full Info")
        for action in [ShortcutAction.whereAmIFull, .speakFullInfo] {
            XCTAssertEqual(action.title, action.rawValue)
            XCTAssertEqual(ShortcutAction.named(action.rawValue.lowercased()), action)
            XCTAssertEqual(action.scope, .app)
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

        XCTAssertEqual(information, [.whereAmI, .whereAmIFull, .speakInfo, .speakFullInfo, .speakImportProgress])
    }

    /// Their keys are W twice and I twice, said, shown, and written in
    /// config.json with the word "twice"; Where Am I? keeps W, Speak Info
    /// keeps I, and Book Info keeps Command-I.
    func testTheirKeysAreWTwiceAndITwice() {
        let defaults = ShortcutAction.defaultBindings

        XCTAssertEqual(defaults[.whereAmIFull], [wTwice])
        XCTAssertEqual(defaults[.speakFullInfo], [iTwice])
        XCTAssertEqual(wTwice.accessibleDisplayString, "W twice")
        XCTAssertEqual(iTwice.accessibleDisplayString, "I twice")
        XCTAssertEqual(wTwice.displayString, "W twice")
        XCTAssertEqual(wTwice.configText, "w twice")
        XCTAssertEqual(iTwice.configText, "i twice")
        XCTAssertEqual(ShortcutListing.followingDefaults([iTwice]), "default: i twice")
        XCTAssertEqual(defaults[.whereAmI], [KeyBinding(key: "w")])
        XCTAssertEqual(defaults[.speakInfo], [KeyBinding(key: "i")])
        XCTAssertEqual(defaults[.showBookInfo], [KeyBinding(key: "i", command: true)])
    }

    /// No other action of either scope has W twice or I twice by default;
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
}
