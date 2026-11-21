import AppKit
import Combine
import SwiftUI
import XCTest
@testable import TextMouth

/// Go to View 1 to Go to View 9 (the design of October 30, 2026,
/// LIBRARY-VIEWS-RESEARCH-2026-10-30.md, section 6): nine shortcut actions,
/// Command-1 to Command-9 by default, in Library windows; the Library menu's
/// Go to View submenu; and a Library window's choice of the view, with what
/// it says, a view deleted while the window shows it included. Every store
/// here is on sandboxed preferences of the test's own,
/// every model and shortcut manager the test's own, and no key is really
/// pressed.
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
        XCTAssertEqual(all.filter { $0.category == "Library" }.suffix(3), [.importDAISYFolder, .addFeed, .searchLibrary])
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

    // MARK: - Wording

    /// Every name and sentence of Go to View, exactly.
    func testEveryWording() {
        XCTAssertEqual(LibraryViewPickerWording.goToViewMenuTitle, "Go to View")
        XCTAssertEqual(LibraryViewPickerWording.noLibraryWindow, "No Library Window")
        XCTAssertEqual(
            LibraryViewPickerWording.wentToView(name: "All Items", counts: "743 books, 2 feeds"),
            "All Items, 743 books, 2 feeds"
        )
        XCTAssertEqual(
            LibraryViewPickerWording.wentToView(name: "Reading List", counts: CountWording.listItems(books: 1, episodes: 2)),
            "Reading List, 1 book, 2 episodes"
        )
        // Changed on purpose by the review of October 31, 2026 (finding 10):
        // the keys' own count, and a sentence for a view listing nothing.
        XCTAssertEqual(LibraryViewPickerWording.noView(number: 7, reached: 6), "There is no view 7. Go to View reaches 6 views.")
        XCTAssertEqual(LibraryViewPickerWording.noView(number: 2, reached: 1), "There is no view 2. Go to View reaches 1 view.")
        XCTAssertEqual(LibraryViewPickerWording.wentToEmptyView(name: "New Episodes"), "New Episodes, nothing matches this view now.")
    }

    // MARK: - The View a Window Goes To

    /// Go to View counts the views offered to a window showing none: those
    /// offered always, and those offered when applicable while they list
    /// something, in the list's order. It says the view's name and what it
    /// lists there, Folders at the window's folder; a number past them goes
    /// nowhere and says how many there are, and a number below 1 goes
    /// nowhere either.
    @MainActor
    func testGoToViewCountsTheViewsOfferedAndSaysWhatTheyList() {
        let model = Self.model()
        let views = Self.FormatViews()
        let store = makeStore("library-view-goto-choice", adding: views)
        let center = LibraryFeedFolders.shared.center
        func goTo(_ number: Int) -> LibraryViewModel.GoToViewOutcome {
            model.goToView(numbered: number, in: store.list, folderPath: "Essays", center: center)
        }

        XCTAssertEqual(goTo(1).view?.id, .category(.folders))
        XCTAssertEqual(goTo(1).announcement, "Folders, 0 books", "Folders at the window's folder, Essays, which is empty")
        XCTAssertEqual(goTo(4).view?.id, .category(.recent))
        XCTAssertEqual(goTo(4).announcement, "Recently Opened, nothing matches this view now.")
        XCTAssertEqual(goTo(5).view?.id, .category(.readingList))
        XCTAssertEqual(goTo(5).announcement, "Reading List, 0 books")
        XCTAssertEqual(goTo(6), LibraryViewModel.GoToViewOutcome(view: views.epubs, announcement: "EPUBs, 1 book"))
        // PDFs lists nothing, so it is not offered, and Text Books is 7.
        XCTAssertEqual(goTo(7), LibraryViewModel.GoToViewOutcome(view: views.textBooks, announcement: "Text Books, 1 book"))
        XCTAssertEqual(
            goTo(8),
            LibraryViewModel.GoToViewOutcome(view: nil, announcement: "There is no view 8. Go to View reaches 7 views.")
        )
        XCTAssertNil(goTo(0).view)
        XCTAssertNil(goTo(-1).view)
    }

    /// A view listing feeds alone, offered always, that lists nothing now
    /// is said in the words its window shows, never as "0 books", a kind of
    /// row it never lists (review of October 31, 2026, finding 10).
    @MainActor
    func testGoingToAnEmptyViewOfFeedsSaysNothingMatches() {
        let model = Self.model()
        let store = makeStore("library-view-goto-empty-feeds", adding: Self.FormatViews())
        let quiet = LibraryViewDefinition(
            id: .custom(UUID()),
            name: "Quiet Feeds",
            visibility: .always,
            filter: LibraryViewFilter(
                lists: [.feeds],
                conditions: [LibraryViewCondition(test: .titleOrAuthorContains("a title no feed has, 7f3a"))]
            )
        )
        XCTAssertTrue(store.update { $0.add(quiet, after: nil) })
        // After the seven views offered in `makeStore`'s order.
        XCTAssertEqual(
            model.goToView(numbered: 8, in: store.list, folderPath: "", center: LibraryFeedFolders.shared.center),
            LibraryViewModel.GoToViewOutcome(view: quiet, announcement: "Quiet Feeds, nothing matches this view now.")
        )
    }

    /// A hidden view is never counted, even while a window shows it and
    /// its pop-up keeps it: the numbers follow the views offered to a
    /// window showing none, so a key always goes to the same view.
    @MainActor
    func testAViewKeptOnlyBecauseAWindowShowsItIsNotCounted() {
        let model = Self.model()
        let views = Self.FormatViews()
        let store = makeStore("library-view-goto-hidden", adding: views)
        store.update { $0.setVisibility(.hidden, of: .category(.unopened)) }
        let center = LibraryFeedFolders.shared.center

        let poppedUp = model.offeredViews(in: store.list, current: .category(.unopened), center: center).map(\.id)
        XCTAssertTrue(poppedUp.contains(.category(.unopened)), "the window showing Unopened keeps it in its pop-up")
        XCTAssertEqual(model.goToView(numbered: 3, in: store.list, folderPath: "", center: center).view?.id, .category(.recent))
        XCTAssertEqual(
            model.goToView(numbered: 7, in: store.list, folderPath: "", center: center).announcement,
            "There is no view 7. Go to View reaches 6 views."
        )
    }

    // MARK: - The Window

    /// A Library window takes Go to View posted for it, from its key or the
    /// menu: it shows the view numbered and says its name and what it lists,
    /// or says there is no such view and stays where it is. A key pressed in
    /// another window is that window's alone.
    @MainActor
    func testALibraryWindowGoesToTheViewAskedForAndSaysSo() throws {
        let model = Self.model()
        let views = Self.FormatViews()
        let store = makeStore("library-view-goto-window", adding: views)
        let settings = SettingsViewModel(notificationCenter: NotificationCenter(), initializeServices: false)
        let shown = ShownViewProbe(.category(.folders))
        let hosted = hostOffscreen(
            LibraryView(
                currentFolderPath: .constant(""),
                shownViewID: shown.binding,
                showFileImporter: .constant(false),
                showTextInput: .constant(false),
                onOpenBook: { _ in },
                views: store
            )
            .environmentObject(model)
            .environmentObject(settings)
        )
        defer { takeDown(hosted.window) }
        XCTAssertTrue(
            waitUntil(timeout: 2) {
                hosted.hostingView.layoutSubtreeIfNeeded()
                return !self.descendants(of: hosted.hostingView, as: NSPopUpButton.self).isEmpty
            },
            "the window was not drawn"
        )
        // Lets the list take its window, which it needs to tell a key
        // pressed in another window from one pressed in its own.
        settle(hosted.hostingView, seconds: 0.2)
        // Posts Go to View `number` as a key pressed in `window` posts it.
        func press(_ number: Int, in window: NSWindow) {
            var userInfo = ShortcutAction.goToViewUserInfo(number: number)
            userInfo["sourceWindow"] = window
            NotificationCenter.default.post(name: .goToLibraryView, object: nil, userInfo: userInfo)
        }

        let other = makeShortcutWindow(.library)
        let recorder = recordingAnnouncements {
            press(6, in: hosted.window)
            press(8, in: hosted.window)
            press(2, in: other)
        }

        XCTAssertEqual(shown.id, views.epubs.id)
        XCTAssertEqual(
            recorder.announcements.map(\.message),
            ["EPUBs, 1 book", "There is no view 8. Go to View reaches 7 views."]
        )
    }

    /// A window showing a view that is deleted, in Settings or by a change
    /// of config.json, gives way to Folders, the first view offered, and
    /// says so; a view it does not show changes nothing there when deleted
    /// (`LibraryViewNavigationSupport`; review of October 31, 2026, finding
    /// 15).
    @MainActor
    func testAWindowShowingADeletedViewFallsBackToFolders() throws {
        let model = Self.model()
        let views = Self.FormatViews()
        let store = makeStore("library-view-goto-deleted", adding: views)
        let settings = SettingsViewModel(notificationCenter: NotificationCenter(), initializeServices: false)
        let shown = ShownViewProbe(views.epubs.id)
        let hosted = hostOffscreen(
            LibraryView(
                currentFolderPath: .constant(""),
                shownViewID: shown.binding,
                showFileImporter: .constant(false),
                showTextInput: .constant(false),
                onOpenBook: { _ in },
                views: store
            )
            .environmentObject(model)
            .environmentObject(settings)
        )
        defer { takeDown(hosted.window) }
        XCTAssertTrue(
            waitUntil(timeout: 2) {
                hosted.hostingView.layoutSubtreeIfNeeded()
                return !self.descendants(of: hosted.hostingView, as: NSPopUpButton.self).isEmpty
            },
            "the window was not drawn"
        )

        let recorder = recordingAnnouncements {
            XCTAssertTrue(store.update { $0.delete(views.textBooks.id) })
            settle(hosted.hostingView, seconds: 0.3)
            XCTAssertEqual(shown.id, views.epubs.id, "deleting another view moved the window")

            XCTAssertTrue(store.update { $0.delete(views.epubs.id) })
            XCTAssertTrue(
                waitUntil(timeout: 2) {
                    hosted.hostingView.layoutSubtreeIfNeeded()
                    return shown.id == .category(.folders)
                },
                "the window still shows the deleted view"
            )
        }
        XCTAssertEqual(
            recorder.announcements.map(\.message),
            ["The view this window showed was deleted. It now shows Folders."]
        )
    }

    // MARK: - The Library Menu

    /// The Go to View submenu's first nine items show the keys the shortcut
    /// manager has in force for Go to View 1 to Go to View 9, where those
    /// work in the window in front: Command-1 with a Library window in
    /// front, and none with a reader or no window in front; a key the user
    /// gave instead; none for a double press, which no menu can show; none
    /// in a Library window once the user moves the key to reader windows;
    /// and none for an item past the ninth.
    @MainActor
    func testTheSubmenuShowsTheKeysInForceWhereTheyWork() throws {
        let manager = KeyboardShortcutManager(userDefaults: makeSandboxedPreferences("library-view-goto-menu-keys"), installsEventMonitor: false)
        let shown = try XCTUnwrap(manager.menuShownKey(for: .goToView1, frontKind: .library))
        XCTAssertEqual(shown.key.character, "1")
        XCTAssertEqual(shown.modifiers, .command)
        XCTAssertNil(manager.menuShownKey(for: .goToView1, frontKind: .reader))
        XCTAssertNil(manager.menuShownKey(for: .goToView1, frontKind: nil))
        XCTAssertNil(ShortcutAction.goToView(number: 10).flatMap { manager.menuShownKey(for: $0, frontKind: .library) })

        manager.updateBindings(for: .goToView1, to: [KeyBinding(key: "1", option: true, control: true)])
        let mine = try XCTUnwrap(manager.menuShownKey(for: .goToView1, frontKind: .library))
        XCTAssertEqual(mine.key.character, "1")
        XCTAssertEqual(mine.modifiers, [.control, .option])

        manager.updateBindings(for: .goToView1, to: [Self.command(1).asDoublePress(true)])
        XCTAssertNil(manager.menuShownKey(for: .goToView1, frontKind: .library), "no menu shows a double press")

        manager.resetToDefault(.goToView1)
        manager.setScope(.reader, for: .goToView1)
        XCTAssertEqual(manager.scope(of: .goToView1), .reader)
        XCTAssertNil(manager.menuShownKey(for: .goToView1, frontKind: .library))
    }

    /// The Library menu has a Go to View submenu right after Folder or Feed
    /// Settings: with a Library window in front, an item for each view it
    /// offers, the first nine showing Command-1 to Command-9; with none, one
    /// dimmed item, No Library Window. Skipped when this run's menu bar has
    /// no Library menu.
    @MainActor
    func testTheLibraryMenuHasAGoToViewSubmenu() throws {
        guard let library = NSApp.mainMenu?.items.first(where: { $0.title == "Library" })?.submenu else {
            throw XCTSkip("This run's menu bar has no Library menu")
        }
        library.delegate?.menuNeedsUpdate?(library)
        let titles = library.items.map(\.title)
        let settings = try XCTUnwrap(titles.firstIndex(of: ShortcutAction.folderOrFeedSettings.title), titles.joined(separator: ", "))
        let goTo = try XCTUnwrap(library.items.dropFirst(settings + 1).first, "nothing follows Folder or Feed Settings")
        XCTAssertEqual(goTo.title, LibraryViewPickerWording.goToViewMenuTitle)
        let submenu = try XCTUnwrap(goTo.submenu, "Go to View has no submenu")
        submenu.delegate?.menuNeedsUpdate?(submenu)
        let items = submenu.items

        if items.map(\.title) == [LibraryViewPickerWording.noLibraryWindow] {
            XCTAssertEqual(items.map(\.isEnabled), [false], "No Library Window is dimmed")
            XCTAssertEqual(items.map(\.keyEquivalent), [""])
            return
        }
        XCTAssertFalse(items.isEmpty, "Go to View lists nothing")
        let showsKeys = FrontWindowKind.shared.kind == .library
        for (index, item) in items.enumerated() {
            let key = showsKeys && index < 9 ? "\(index + 1)" : ""
            XCTAssertTrue(item.isEnabled, item.title)
            XCTAssertEqual(item.keyEquivalent, key, item.title)
            if !key.isEmpty {
                XCTAssertEqual(item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control]), .command, item.title)
            }
        }
    }

    // MARK: - Fixtures

    /// Command and the digit `number`: Go to View `number`'s default key.
    private static func command(_ number: Int) -> KeyBinding {
        KeyBinding(key: "\(number)", command: true)
    }

    /// Three views of the listener's own, each listing the books of one
    /// format: EPUBs, offered always; PDFs, offered when applicable, which
    /// lists nothing in `model()`; and Text Books, offered when applicable,
    /// which lists one book there.
    private struct FormatViews {
        let epubs = FormatViews.view("EPUBs", .epub, .always)
        let pdfs = FormatViews.view("PDFs", .pdf, .whenApplicable)
        let textBooks = FormatViews.view("Text Books", .txt, .whenApplicable)

        /// In the order they are added, after the shipped views.
        var all: [LibraryViewDefinition] { [epubs, pdfs, textBooks] }

        /// A view named `name` listing the books of `format`, offered as
        /// `visibility` says.
        private static func view(_ name: String, _ format: BookFormat, _ visibility: LibraryViewVisibility) -> LibraryViewDefinition {
            LibraryViewDefinition(
                id: .custom(UUID()),
                name: name,
                visibility: visibility,
                filter: LibraryViewFilter(lists: [.books], conditions: [LibraryViewCondition(test: .format(format))])
            )
        }
    }

    /// A store of the test's own, on sandboxed preferences labelled
    /// `label`: the shipped views, Feeds hidden, since whether it is offered
    /// follows the app's feed engine, then `views`' three at the end. So the
    /// views offered are Folders, All Items, Unopened, Recently Opened, the
    /// Reading List, EPUBs, and Text Books, numbered 1 to 7.
    @MainActor
    private func makeStore(_ label: String, adding views: FormatViews) -> LibraryViewDefinitionStore {
        let store = LibraryViewDefinitionStore(preferences: makeSandboxedPreferences(label))
        store.update { list in
            list.setVisibility(.hidden, of: .feeds)
            for view in views.all {
                list.add(view, after: nil)
            }
        }
        return store
    }

    /// A model of two books at the top of the library, an EPUB and a text
    /// book, neither opened nor in the reading list, and an empty folder,
    /// Essays.
    @MainActor
    private static func model() -> LibraryViewModel {
        let model = LibraryViewModel(initializeServices: false)
        model.finishedBookIDs = { [] }
        model.library = Library(
            books: [
                Book(title: "Atlas", format: .epub, filePath: "/Atlas.epub", md5Hash: "atlas", tmbDirectoryName: "Atlas.tmb"),
                Book(title: "Bestiary", format: .txt, filePath: "/Bestiary.txt", md5Hash: "bestiary", tmbDirectoryName: "Bestiary.tmb"),
            ],
            folders: [BookFolder(name: "Essays")]
        )
        return model
    }
}

/// The view a hosted Library window shows, held where a test can read it, as
/// the window's `shownViewID` binding sets it.
@MainActor
private final class ShownViewProbe {
    /// The view shown.
    var id: LibraryViewID

    /// A probe of a window showing `id`.
    init(_ id: LibraryViewID) {
        self.id = id
    }

    /// The binding the window's parent would give it.
    var binding: Binding<LibraryViewID> {
        Binding(get: { self.id }, set: { self.id = $0 })
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
