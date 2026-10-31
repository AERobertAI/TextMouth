import AppKit
import Combine
import SwiftUI
import XCTest
@testable import TextMouth

/// Go to View 1 to Go to View 9 (the design of October 30, 2026,
/// LIBRARY-VIEWS-RESEARCH-2026-10-30.md, section 6): nine shortcut actions,
/// Command-1 to Command-9 by default, in Library windows. Every store here
/// is on sandboxed preferences of the test's own, every shortcut manager the
/// test's own, and no key is really pressed.
///
/// Each test runs on the main actor, not the class as a whole, as
/// `UnopenedCategoryTests` explains.
final class LibraryViewGoToTests: XCTestCase {
    /// The isolated data root's index, put back after a test that saves.
    private var sandbox: LibraryIndexSandbox?

    override func setUpWithError() throws {
        sandbox = try LibraryIndexSandbox.capture()
    }

    override func tearDownWithError() throws {
        // Tear-down also runs when capturing failed in set-up.
        sandbox?.restore()
    }

    // MARK: - The Nine Actions

    /// Go to View 1 to Go to View 9 are named as the design names them,
    /// numbered 1 to 9, and listed under Library right after Folder or Feed
    /// Settings, where the Shortcuts tab lists them; no other action has a
    /// number, and no other number has an action.
    func testTheNineActionsAreNamedNumberedAndListedUnderLibrary() throws {
        let actions = ShortcutAction.goToViewActions
        XCTAssertEqual(actions.map(\.rawValue), (1...9).map { "Go to View \($0)" })
        for (index, action) in actions.enumerated() {
            XCTAssertEqual(action.title, action.rawValue)
            XCTAssertEqual(action.category, "Library", action.rawValue)
            XCTAssertEqual(action.goToViewNumber, index + 1)
            XCTAssertEqual(ShortcutAction.goToView(number: index + 1), action)
            XCTAssertEqual(ShortcutAction.named(action.rawValue), action, "config.json reads the name")
        }
        XCTAssertEqual(ShortcutAction.allCases.filter { $0.goToViewNumber != nil }, actions)
        for number in [-1, 0, 10, 100] {
            XCTAssertNil(ShortcutAction.goToView(number: number), "\(number)")
        }

        let all = ShortcutAction.allCases
        let settings = try XCTUnwrap(all.firstIndex(of: .folderOrFeedSettings))
        XCTAssertEqual(Array(all.dropFirst(settings + 1).prefix(actions.count)), actions)
        XCTAssertEqual(all.filter { $0.category == "Library" }.suffix(2), [.importDAISYFolder, .addFeed])
    }

    /// Each has Command and its digit by default, a key no other default
    /// has, working in Library windows: config.json writes it "command+1"
    /// and reads it back, VoiceOver and a braille display say "Command + 1",
    /// and a menu item can show it, as the Go to View submenu's does.
    @MainActor
    func testTheirDefaultsAreCommandAndTheirDigitInLibraryWindows() throws {
        for (index, action) in ShortcutAction.goToViewActions.enumerated() {
            let number = index + 1
            let key = Self.command(number)
            XCTAssertEqual(ShortcutAction.defaultBindings[action], [key], action.rawValue)
            XCTAssertEqual(action.defaultScope, .library, action.rawValue)
            XCTAssertEqual(key.configText, "command+\(number)")
            XCTAssertEqual(KeyBinding(configText: "command+\(number)"), key)
            XCTAssertEqual(KeyBinding(configText: "Cmd + \(number)"), key, "text written by hand is read generously")
            XCTAssertEqual(key.accessibleDisplayString, "Command + \(number)")
            XCTAssertEqual(key.displayString, "\u{2318}\(number)")
            XCTAssertTrue(key.canBeKeyEquivalent, action.rawValue)
            let shown = try XCTUnwrap(key.keyboardShortcut, action.rawValue)
            XCTAssertEqual(shown.key.character, Character("\(number)"))
            XCTAssertEqual(shown.modifiers, .command)
        }

        let digits = Set((1...9).map(Self.command))
        for action in ShortcutAction.allCases where action.goToViewNumber == nil {
            let taken = (ShortcutAction.defaultBindings[action] ?? []).filter { digits.contains($0.stroke) }
            XCTAssertEqual(taken, [], "\(action.rawValue) has one of Go to View's default keys")
        }
    }

    /// The Shortcuts tab's row and config.json's entry say each key and that
    /// it works in Library windows, and its Works in pop-up offers what the
    /// other actions the shortcut manager takes offer: every window, Library
    /// windows, or reader windows. None is a menu item's key equivalent,
    /// since a key past the views offered must reach the window to say so.
    func testTheShortcutsTabAndConfigJSONSayWhereTheKeysWork() {
        XCTAssertEqual(
            ShortcutsSettingsWording.rowLabel(for: .goToView1, keys: [Self.command(1)], isEdited: false, worksIn: .library),
            "Go to View 1: Command + 1. Works in Library windows."
        )
        for action in ShortcutAction.goToViewActions {
            XCTAssertEqual(action.availableScopes, [.app, .library, .reader], action.rawValue)
            XCTAssertFalse(action.isKeyEquivalent, action.rawValue)
        }
        let listings = ShortcutEdits().listings(defaults: ShortcutAction.defaultBindings)
        XCTAssertEqual(listings[.goToView1], "default in Library windows: command+1")
        XCTAssertEqual(listings[.goToView9], "default in Library windows: command+9")
    }

    // MARK: - What They Post

    /// All nine post one notification, whose user info numbers the view:
    /// the action's raw value from a key or one of the submenu's first nine
    /// items, the number from an item past them. Anything else numbers none.
    func testTheyPostOneNotificationNumberingTheView() {
        XCTAssertEqual(Notification.Name.goToLibraryView.rawValue, "goToLibraryView")
        for action in ShortcutAction.goToViewActions {
            XCTAssertEqual(action.notificationName, .goToLibraryView, action.rawValue)
        }

        let third = ShortcutAction.goToViewUserInfo(number: 3)
        XCTAssertEqual(third.count, 1)
        XCTAssertEqual(third["action"] as? String, "Go to View 3")
        let twelfth = ShortcutAction.goToViewUserInfo(number: 12)
        XCTAssertEqual(twelfth.count, 1)
        XCTAssertEqual(twelfth[ShortcutAction.goToViewNumberKey] as? Int, 12)
        XCTAssertEqual(ShortcutAction.goToViewNumberKey, "viewNumber")
        for number in [1, 5, 9, 10, 12, 200] {
            XCTAssertEqual(ShortcutAction.goToViewNumber(in: ShortcutAction.goToViewUserInfo(number: number)), number)
        }

        XCTAssertEqual(ShortcutAction.goToViewNumber(in: ["action": "Go to View 4", "sourceWindow": NSObject()]), 4, "as the manager posts a key")
        XCTAssertNil(ShortcutAction.goToViewNumber(in: ["action": ShortcutAction.togglePlayback.rawValue]))
        XCTAssertNil(ShortcutAction.goToViewNumber(in: ["action": "Go to View 10"]))
        XCTAssertNil(ShortcutAction.goToViewNumber(in: [:]))
        XCTAssertNil(ShortcutAction.goToViewNumber(in: nil))
    }

    /// The shortcut manager takes Command-1 to Command-9 in a Library
    /// window, from a text field too, posting the action with the window
    /// pressed in, so that window alone goes to the view; in any other kind
    /// of window it leaves them alone.
    @MainActor
    func testTheManagerTakesTheKeysInLibraryWindowsAlone() throws {
        let center = NotificationCenter()
        let manager = KeyboardShortcutManager(
            userDefaults: makeSandboxedPreferences("library-view-goto-manager"),
            installsEventMonitor: false,
            notificationCenter: center
        )
        let posted = PostedGoToViews(on: center)
        let library = makeShortcutWindow(.library)

        XCTAssertTrue(manager.handleKeyEvent(try ShortcutKeyPresses.keyPress(of: Self.command(3)), keyWindow: library, firstResponder: nil))
        XCTAssertTrue(manager.handleKeyEvent(try ShortcutKeyPresses.keyPress(of: Self.command(9)), keyWindow: library, firstResponder: NSTextView()))
        XCTAssertEqual(posted.numbers, [3, 9])
        XCTAssertEqual(posted.windows, [ObjectIdentifier(library), ObjectIdentifier(library)])

        for kind in [ShortcutWindowKind.reader, .audioEditor, .recording, .other] {
            let press = try ShortcutKeyPresses.keyPress(of: Self.command(1))
            XCTAssertFalse(manager.handleKeyEvent(press, keyWindow: makeShortcutWindow(kind), firstResponder: nil), "\(kind)")
        }
        XCTAssertEqual(posted.numbers, [3, 9], "Command-1 acted outside a Library window")
    }

    // MARK: - A Key the User Gave Another Action

    /// A user who gave Command-1 to another action working in Library
    /// windows keeps it, and Go to View 1 then has no key, which the
    /// Shortcuts tab names; Command-2 given to an action working only in
    /// readers leaves Go to View 2 its key, as the two never meet.
    @MainActor
    func testAKeyTheUserGaveAnotherActionStaysTheirs() {
        let inForce = ShortcutEdits([.speakInfo: [Self.command(1)], .showSleepTimer: [Self.command(2)]])
            .effectiveBindings(defaults: ShortcutAction.defaultBindings)
        XCTAssertEqual(inForce[.speakInfo], [Self.command(1)])
        XCTAssertEqual(inForce[.goToView1], [])
        XCTAssertEqual(inForce[.showSleepTimer], [Self.command(2)])
        XCTAssertEqual(inForce[.goToView2], [Self.command(2)])
        XCTAssertEqual(inForce[.goToView3], [Self.command(3)])

        let manager = KeyboardShortcutManager(userDefaults: makeSandboxedPreferences("library-view-goto-taken"), installsEventMonitor: false)
        manager.addBinding(Self.command(1), to: .speakInfo)
        XCTAssertEqual(manager.bindingsFor(.goToView1), [])
        XCTAssertEqual(manager.defaultKeysHeldElsewhere(for: .goToView1), [DefaultKeyHeldElsewhere(key: Self.command(1), holder: .speakInfo)])
        XCTAssertEqual(manager.bindingsFor(.goToView2), [Self.command(2)])
    }

    // MARK: - Fixtures

    /// Command and the digit `number`: Go to View `number`'s default key.
    private static func command(_ number: Int) -> KeyBinding {
        KeyBinding(key: "\(number)", command: true)
    }
}

/// Every Go to View posted on a notification center, as a test reads it:
/// the number each asks for, and the window each names as pressed in. It
/// listens until it is released.
@MainActor
private final class PostedGoToViews {
    /// The numbers asked for, oldest first; nil for a post numbering none.
    private(set) var numbers: [Int?] = []
    /// The windows named as pressed in, oldest first, by identity.
    private(set) var windows: [ObjectIdentifier?] = []
    /// The subscription to `.goToLibraryView`.
    private var subscription: AnyCancellable?

    /// Starts listening on `center`.
    init(on center: NotificationCenter) {
        subscription = center.publisher(for: .goToLibraryView).sink { [weak self] notification in
            let number = ShortcutAction.goToViewNumber(in: notification.userInfo)
            let window = (notification.userInfo?["sourceWindow"] as? NSWindow).map(ObjectIdentifier.init)
            // The manager posts on the main thread, within the press.
            MainActor.assumeIsolated {
                self?.numbers.append(number)
                self?.windows.append(window)
            }
        }
    }
}
