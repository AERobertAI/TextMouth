import AppKit
import AVFoundation
import SwiftUI
import XCTest
@testable import TextMouth

/// The Library list's letter navigation that passes over leading articles
/// (`LibraryTitleTyping`, TITLE-ARTICLES-RESEARCH-2026-11-13.md): which keys
/// are typing, and the Space a list typing a title claims from the
/// shortcuts, which is Play or Pause at every other time.
@MainActor
final class LibraryTitleTypingTests: XCTestCase {
    /// Where the shortcut manager under test posts its actions.
    private let center = NotificationCenter()

    // MARK: - Which Keys Are Typing

    /// Letters, numbers, punctuation, and a space are typing, with Shift or
    /// Option too; nothing with Command or Control is, and neither is a
    /// control character or a function key.
    func testWhichKeysAreTyping() {
        let typing: [(String, EventModifiers)] = [
            ("h", []), ("H", .shift), ("é", .option), ("3", []), ("'", []), ("’", .option), (" ", []), ("&", .shift),
        ]
        for (characters, modifiers) in typing {
            XCTAssertTrue(LibraryTitleTyping.isTyping(characters, modifiers: modifiers), "\(characters.debugDescription) is typing")
        }
        // An arrow and Forward Delete, as AppKit writes them in the
        // private-use area.
        let notTyping: [(String, EventModifiers)] = [
            ("h", .command), ("h", .control), ("h", [.command, .shift]), ("", []),
            ("\r", []), ("\t", []), ("\u{1B}", []), ("\u{7F}", []), ("\u{F700}", []), ("\u{F728}", []),
        ]
        for (characters, modifiers) in notTyping {
            XCTAssertFalse(LibraryTitleTyping.isTyping(characters, modifiers: modifiers), "\(characters.debugDescription) is not typing")
        }
    }

    // MARK: - The Space a List Claims

    /// A claim holds for its window alone, until its time, and only the
    /// window that made it lets it go; no window claims nothing.
    func testASpaceIsClaimedForOneWindowUntilItsTime() {
        let claim = TitleTypingSpaceClaim()
        let window = Self.window()
        let other = Self.window()
        defer {
            window.close()
            other.close()
        }
        XCTAssertFalse(claim.takesSpace(in: window, at: 10))
        claim.claim(in: window, until: 11)
        XCTAssertTrue(claim.takesSpace(in: window, at: 10.5))
        XCTAssertTrue(claim.takesSpace(in: window, at: 11))
        XCTAssertFalse(claim.takesSpace(in: window, at: 11.25))
        // The list accepts a Space a little later than the shortcuts leave
        // one to it, so a Space between their two looks at the clock, at the
        // claim's edge, is never left with neither: whatever the shortcuts
        // left to the list, the list accepts.
        XCTAssertTrue(claim.acceptsSpace(in: window, at: 11.25))
        XCTAssertTrue(claim.acceptsSpace(in: window, at: 11 + TitleTypingSpaceClaim.acceptanceSlack))
        XCTAssertFalse(claim.acceptsSpace(in: window, at: 11 + TitleTypingSpaceClaim.acceptanceSlack + 0.25))
        for time in stride(from: 9.0, through: 12.0, by: 0.125) where claim.takesSpace(in: window, at: time) {
            XCTAssertTrue(claim.acceptsSpace(in: window, at: time), "a Space the shortcuts left at \(time) was not accepted")
        }
        XCTAssertFalse(claim.acceptsSpace(in: other, at: 10.5))
        XCTAssertFalse(claim.acceptsSpace(in: nil, at: 10.5))
        XCTAssertFalse(claim.takesSpace(in: other, at: 10.5))
        XCTAssertFalse(claim.takesSpace(in: nil, at: 10.5))
        claim.release(in: other)
        XCTAssertTrue(claim.takesSpace(in: window, at: 10.5), "another window let the claim go")
        claim.release(in: window)
        XCTAssertFalse(claim.takesSpace(in: window, at: 10.5))
        XCTAssertFalse(claim.acceptsSpace(in: window, at: 10.5), "a claim let go accepts nothing")
        claim.claim(in: nil, until: 20)
        XCTAssertFalse(claim.takesSpace(in: window, at: 10.5))
    }

    /// The shortcut manager takes a Space as Play or Pause, but leaves one
    /// that a window's list claimed to that list, until the claim's time,
    /// in that window alone, and only while a list has the keyboard there:
    /// a Space on another control, such as a button tabbed to, plays or
    /// pauses as always.
    func testASpaceAListClaimedGoesToTheListAndAnyOtherIsPlayOrPause() throws {
        let manager = KeyboardShortcutManager(
            userDefaults: makeSandboxedPreferences("title-typing-space"),
            installsEventMonitor: false,
            notificationCenter: center
        )
        let window = Self.window()
        let other = Self.window()
        let claim = TitleTypingSpaceClaim.shared
        // The claim's clock, set by the test, which the manager reads too.
        let start = ProcessInfo.processInfo.systemUptime
        var now = start
        let previousClock = TitleTypingSpaceClaim.clock
        TitleTypingSpaceClaim.clock = { now }
        defer {
            TitleTypingSpaceClaim.clock = previousClock
            claim.release(in: window)
            window.close()
            other.close()
        }
        let space = KeyBinding(key: "space")
        // The list has the keyboard unless a press names another responder.
        let list = NSTableView()
        // Presses far apart on the events' time line, so none chains with
        // another into a double press.
        func pressSpace(at offset: TimeInterval, in keyWindow: NSWindow, on responder: NSResponder? = nil) throws -> Bool {
            now = start + offset
            let event = try ShortcutKeyPresses.keyPress(of: space, at: start + offset)
            return manager.handleKeyEvent(event, keyWindow: keyWindow, firstResponder: responder ?? list)
        }

        XCTAssertTrue(try pressSpace(at: 0, in: window), "a Space no list claimed was not Play or Pause")
        claim.claim(in: window, until: start + 21)
        XCTAssertFalse(try pressSpace(at: 20, in: window), "a Space the list claimed was taken from it")
        XCTAssertTrue(try pressSpace(at: 40, in: window), "a Space after the claim's time was not Play or Pause")
        claim.claim(in: window, until: start + 61)
        XCTAssertTrue(try pressSpace(at: 60, in: other), "a Space in another window was the list's")
        XCTAssertTrue(try pressSpace(at: 60.25, in: window, on: NSButton()), "a Space on a button was the list's")
    }

    // MARK: - Typing in a Hosted Library List

    /// In a hosted Library list of Treasure Island, The Hobbit, Hamlet, and
    /// A Tale of Two Cities, in that manual order, typed letters select the
    /// row each choice names, which Speak Info then speaks (into a recorder,
    /// so nothing is heard): as written, H is Hamlet, by the list's own type
    /// select; passing over articles, H is The Hobbit, H again a pause later
    /// Hamlet and then The Hobbit once more (a new search starts after the
    /// selection and wraps), T the next title filed under T after the
    /// selection, "the h" The Hobbit, "ha" Hamlet (an added letter starts at
    /// the selected row), "a t" A Tale of Two Cities, a letter no title
    /// begins with leaves the selection where it was, letters a pause apart
    /// start afresh, and, with titles inverted, "hobbit, t" is The Hobbit
    /// too.
    ///
    /// Only keys that reach a row, or that letter navigation takes, are
    /// typed, since a key nobody takes would make the Mac beep: the first H
    /// of each choice that passes over articles reaches a row by AppKit's
    /// type select too, and if that is what took it (Hamlet, not The
    /// Hobbit, selected) the test stops there. Time is the test's own
    /// clock, stepped past the interval for a pause, so nothing waits.
    func testTypedLettersSelectTheRowEachChoiceNames() throws {
        let recorder = InfoSynthesizerRecorder()
        let previousSynthesizer = LibraryInfoSpeaker.makeSynthesizer
        LibraryInfoSpeaker.makeSynthesizer = { recorder }
        var now = ProcessInfo.processInfo.systemUptime
        let previousClock = TitleTypingSpaceClaim.clock
        TitleTypingSpaceClaim.clock = { now }
        defer {
            LibraryInfoSpeaker.makeSynthesizer = previousSynthesizer
            TitleTypingSpaceClaim.clock = previousClock
        }
        let store = TextMouthRuntime.current.preferences
        preservePreferences([LeadingArticles.preference.key], in: store)

        let folder = "Shelf"
        let (model, settings) = Self.shelf(
            of: ["Treasure Island", "The Hobbit", "Hamlet", "A Tale of Two Cities"], in: folder
        )

        for choice in LeadingArticles.allCases {
            LeadingArticles.preference.write(choice, to: store)
            let hosted = hostOffscreen(
                LibraryView(
                    currentFolderPath: .constant(folder),
                    category: .constant(.folders),
                    showFileImporter: .constant(false),
                    showTextInput: .constant(false),
                    onOpenBook: { _ in }
                )
                .environmentObject(model)
                .environmentObject(settings)
            )
            defer { takeDown(hosted.window) }
            settle(hosted.hostingView, seconds: 0.5)
            let table = try XCTUnwrap(descendants(of: hosted.hostingView, as: NSTableView.self).first, "the window shows no list")
            guard hosted.window.makeFirstResponder(table), hosted.window.firstResponder === table else {
                throw XCTSkip("This macOS gives an offscreen window's list no keyboard focus, so nothing is typed")
            }

            /// The title of the row selected, as Speak Info speaks it.
            func selectedTitle() -> String? {
                let before = recorder.utterances.count
                NotificationCenter.default.post(name: .speakInfo, object: nil, userInfo: ["sourceWindow": hosted.window])
                flush(hosted.hostingView)
                guard recorder.utterances.count > before, let utterance = recorder.utterances.last else { return nil }
                // Ended at once, so the next press speaks rather than stops.
                recorder.delegate?.speechSynthesizer?(AVSpeechSynthesizer(), didFinish: utterance)
                flush(hosted.hostingView)
                let spoken = utterance.speechString
                return spoken == LibraryInfoWording.nothingSelected ? nil : spoken.components(separatedBy: ". ").first
            }
            /// Types `text` into the window, key by key, as the keyboard
            /// does, each key a tenth of a second after the one before.
            func type(_ text: String) throws {
                for character in text {
                    now += 0.1
                    hosted.window.sendEvent(try Self.keyDown(character, in: hosted.window))
                    flush(hosted.hostingView)
                }
            }
            /// Lets the time typed letters add up within pass.
            func pause() {
                now += LibraryTitleTyping.interval + 0.5
            }

            switch choice {
            case .partOfTitle:
                // The list's own type select, as the titles are written.
                try type("h")
                XCTAssertEqual(selectedTitle(), "Hamlet", "\(choice)")
            case .ignoredWhenTyping, .ignoredWhenTypingAndSorting:
                // H reaches a row whoever takes it; only letter navigation
                // that passes over articles reaches The Hobbit. Without it,
                // no further key is typed, as one might reach nothing.
                try type("h")
                let first = selectedTitle()
                guard first == "The Hobbit" else {
                    return XCTFail("\(choice): H selected \(first ?? "nothing"), not The Hobbit; letter navigation did not take the key")
                }
                var steps: [String] = []
                func expect(_ typed: String, _ title: String?, pausingFirst: Bool = true) throws {
                    if pausingFirst { pause() }
                    try type(typed)
                    let selected = selectedTitle()
                    if selected != title {
                        steps.append("\"\(typed)\" selected \(selected ?? "nothing"), not \(title ?? "nothing")")
                    }
                }
                // H again, a pause later, moves on to the next H after the
                // selection, and wraps past the last, as AppKit's does.
                try expect("h", "Hamlet")
                try expect("h", "The Hobbit")
                // T searches after the selection: A Tale of Two Cities is
                // filed under T and follows The Hobbit; the next T wraps to
                // Treasure Island.
                try expect("t", "A Tale of Two Cities")
                try expect("t", "Treasure Island")
                try expect("the h", "The Hobbit")
                // Letters that add up stay on the row they reached: "h"
                // moves to Hamlet, and "a" added to it keeps it.
                try expect("ha", "Hamlet")
                // The article typed as a word: "a" reaches nothing, the
                // space joins it, and "t" reaches the title written with it.
                try expect("a t", "A Tale of Two Cities")
                try expect("t", "Treasure Island")
                // No title begins with Z: the selection stays.
                try expect("z", "Treasure Island")
                // Letters a pause apart start afresh: T, then H on its own.
                try expect("t", "A Tale of Two Cities")
                try expect("h", "The Hobbit")
                // A held key types once: an A that only repeats adds nothing,
                // so the search stays "h" rather than reaching Hamlet.
                hosted.window.sendEvent(try Self.keyDown("a", in: hosted.window, isARepeat: true))
                flush(hosted.hostingView)
                if let held = selectedTitle(), held != "The Hobbit" {
                    steps.append("a held A's repeat selected \(held)")
                }
                if choice == .ignoredWhenTypingAndSorting {
                    try expect("hobbit, t", "The Hobbit")
                }
                XCTAssertEqual(steps, [], "\(choice)")
            }
        }
    }

    /// The list takes a key only while a table has the keyboard: not while
    /// the search field does (its field editor is the first responder), nor
    /// when no window or no responder is known.
    func testTheListTakesKeysOnlyWhileATableHasTheKeyboard() throws {
        let window = Self.window()
        defer { window.close() }
        let content = try XCTUnwrap(window.contentView)
        let table = NSTableView()
        let field = NSSearchField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        content.addSubview(table)
        content.addSubview(field)
        guard window.makeFirstResponder(table), window.firstResponder === table else {
            throw XCTSkip("This macOS gives a window that was never shown no keyboard focus")
        }
        XCTAssertTrue(LibraryTitleTyping.tableHasKeyboard(in: window), "a table has the keyboard")
        XCTAssertTrue(window.makeFirstResponder(field), "the search field took the keyboard")
        XCTAssertFalse(LibraryTitleTyping.tableHasKeyboard(in: window), "the search field has the keyboard, not a table")
        XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertFalse(LibraryTitleTyping.tableHasKeyboard(in: window), "nothing has the keyboard")
        XCTAssertFalse(LibraryTitleTyping.tableHasKeyboard(in: nil), "no window")
    }

    /// Letters typed into the Library's search field reach the field in the
    /// choices that pass over articles, and select no row: the list's key
    /// handler lets them go on. The field is in the window's toolbar, which
    /// a window hosting the view alone may not draw, so the test is skipped
    /// where it finds no search field (the runner's first trains did not
    /// find one in an offscreen window), and the guard
    /// (`LibraryTitleTyping.tableHasKeyboard(in:)`) is tested on its own.
    func testLettersTypedInTheSearchFieldReachTheField() throws {
        let store = TextMouthRuntime.current.preferences
        preservePreferences([LeadingArticles.preference.key], in: store)
        let folder = "Shelf"
        let (model, settings) = Self.shelf(of: ["Treasure Island", "The Hobbit", "Hamlet"], in: folder)
        var sawAField = false
        for choice in [LeadingArticles.ignoredWhenTyping, .ignoredWhenTypingAndSorting] {
            LeadingArticles.preference.write(choice, to: store)
            let controller = NSHostingController(
                rootView: LibraryView(
                    currentFolderPath: .constant(folder),
                    category: .constant(.folders),
                    showFileImporter: .constant(false),
                    showTextInput: .constant(false),
                    onOpenBook: { _ in }
                )
                .environmentObject(model)
                .environmentObject(settings)
            )
            let window = NSWindow(contentViewController: controller)
            window.isReleasedWhenClosed = false
            window.title = "Hosted search field test"
            window.setContentSize(NSSize(width: 900, height: 700))
            defer {
                window.contentViewController = nil
                window.close()
            }
            window.orderFrontRegardless()
            settle(window.contentView, seconds: 0.5)
            // The toolbar's items live in the window's frame view, above the content.
            let frameView = try XCTUnwrap(window.contentView?.superview)
            guard let field = descendants(of: frameView, as: NSSearchField.self).first,
                  window.makeFirstResponder(field), let editor = field.currentEditor() else {
                continue
            }
            sawAField = true
            for character in "ha" {
                window.sendEvent(try Self.keyDown(character, in: window))
                settle(window.contentView, seconds: 0.1)
            }
            XCTAssertEqual(editor.string, "ha", "\(choice): the letters typed in the search field did not reach it")
            let table = descendants(of: frameView, as: NSTableView.self).first
            XCTAssertEqual(table?.selectedRow, -1, "\(choice): letters typed in the search field selected a row")
        }
        try XCTSkipUnless(sawAField, "This window shows no search field, so nothing could be typed into one")
    }

    /// Typing a title far down a long list selects it and scrolls it into
    /// view, whole, as the list's own type select does, and typing one at
    /// the top scrolls back up to it. The list ends with The Zebra and then
    /// Theodora, so T reaches Theodora, the last row, only by letter
    /// navigation that passes over articles, and The Zebra by AppKit's own
    /// type select; either way T reaches a row, so nothing beeps. V, for
    /// Volume 01, the first, is typed only once letter navigation has taken
    /// T. Time is the test's own clock, stepped past the interval between
    /// the two, so nothing waits for it.
    func testTheRowTypedToIsScrolledIntoView() throws {
        var now = ProcessInfo.processInfo.systemUptime
        let previousClock = TitleTypingSpaceClaim.clock
        TitleTypingSpaceClaim.clock = { now }
        defer { TitleTypingSpaceClaim.clock = previousClock }
        let store = TextMouthRuntime.current.preferences
        preservePreferences([LeadingArticles.preference.key], in: store)
        LeadingArticles.preference.write(.ignoredWhenTyping, to: store)
        let folder = "Long Shelf"
        let titles = (1...60).map { String(format: "Volume %02d", $0) } + ["The Zebra", "Theodora"]
        let (model, settings) = Self.shelf(of: titles, in: folder)
        let hosted = hostOffscreen(
            LibraryView(
                currentFolderPath: .constant(folder),
                category: .constant(.folders),
                showFileImporter: .constant(false),
                showTextInput: .constant(false),
                onOpenBook: { _ in }
            )
            .environmentObject(model)
            .environmentObject(settings),
            size: NSSize(width: 700, height: 420)
        )
        defer { takeDown(hosted.window) }
        settle(hosted.hostingView, seconds: 0.5)
        let table = try XCTUnwrap(descendants(of: hosted.hostingView, as: NSTableView.self).first, "the window shows no list")
        guard hosted.window.makeFirstResponder(table), hosted.window.firstResponder === table else {
            throw XCTSkip("This macOS gives an offscreen window's list no keyboard focus, so nothing is typed")
        }
        let visibleBefore = table.rows(in: table.visibleRect)
        XCTAssertLessThan(visibleBefore.location + visibleBefore.length, table.numberOfRows, "the whole list fit the window, so nothing could scroll")

        /// Checks that the selected row shows, among the rows AppKit names
        /// as showing, and shows whole, naming the rows that show when it
        /// does not.
        func selectedRowShows(after typed: String) {
            let selected = table.selectedRow
            let visible = table.rows(in: table.visibleRect)
            XCTAssertTrue(
                selected >= 0 && NSLocationInRange(selected, visible) && LibraryTitleTyping.rowShowsWhole(selected, in: table),
                "after \(typed), row \(selected) was selected but rows \(visible.location)..<\(visible.location + visible.length) show"
            )
        }

        hosted.window.sendEvent(try Self.keyDown("t", in: hosted.window))
        settle(hosted.hostingView, seconds: 0.5)
        // Without letter navigation, AppKit would take V too, after T, and
        // "tv" reaches nothing, so no further key is typed.
        guard table.selectedRow == table.numberOfRows - 1 else {
            return XCTFail(
                "after T the table's selected row is \(table.selectedRow), not Theodora, the last row: The Zebra, the row "
                    + "before, is AppKit's own type select, and none means the list's selection never reached the table"
            )
        }
        selectedRowShows(after: "T")

        now += LibraryTitleTyping.interval + 0.5
        hosted.window.sendEvent(try Self.keyDown("v", in: hosted.window))
        settle(hosted.hostingView, seconds: 0.5)
        XCTAssertEqual(table.selectedRow, table.numberOfRows - titles.count, "V did not select Volume 01, the first book")
        selectedRowShows(after: "V")
    }

    /// A key-down event typing `character`, with the key code the keyboard
    /// gives it, so AppKit and SwiftUI read it as they read a key pressed;
    /// `isARepeat` for a held key's repeat.
    private static func keyDown(_ character: Character, in window: NSWindow, isARepeat: Bool = false) throws -> NSEvent {
        let keyCodes: [Character: UInt16] = [
            "a": 0, "h": 4, "z": 6, "v": 9, "b": 11, "e": 14, "t": 17, "o": 31, "i": 34, " ": 49, ",": 43,
        ]
        let text = String(character)
        return try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: text,
            charactersIgnoringModifiers: text,
            isARepeat: isARepeat,
            keyCode: keyCodes[character] ?? 0
        ), "no key-down event for \(text)")
    }

    // MARK: - Fixtures

    /// A library with one folder, `folder`, holding books titled `titles`
    /// in that manual order, and a settings model that starts no services.
    private static func shelf(of titles: [String], in folder: String) -> (LibraryViewModel, SettingsViewModel) {
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(
            books: titles.enumerated().map { index, title in
                Book(
                    title: title,
                    author: "Author",
                    format: .epub,
                    filePath: "/nonexistent/title-typing/\(index).epub",
                    md5Hash: "title-typing-\(index)",
                    folderPath: folder,
                    manualSortOrder: index
                )
            },
            folders: [BookFolder(name: folder)]
        )
        let location = LibraryLocation(category: .folders, folderPath: folder)
        model.library.folderSortSettings[location.sortSettingsKey] = FolderSortSetting(sortField: .manual, sortAscending: true)
        let settings = SettingsViewModel(notificationCenter: NotificationCenter(), initializeServices: false)
        return (model, settings)
    }

    /// A titled window, never shown, which the test closes.
    private static func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 120), styleMask: [.titled], backing: .buffered, defer: true)
        // The test owns the window; AppKit must not release it again on close.
        window.isReleasedWhenClosed = false
        window.title = "Hosted test view"
        return window
    }
}
