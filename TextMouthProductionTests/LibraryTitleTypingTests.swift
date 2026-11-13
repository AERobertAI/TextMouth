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
        let notTyping: [(String, EventModifiers)] = [
            ("h", .command), ("h", .control), ("h", [.command, .shift]), ("", []),
            ("\r", []), ("\t", []), ("\u{1B}", []), ("\u{7F}", []), ("\u{F700}", .function), ("\u{F728}", .function),
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
        XCTAssertFalse(claim.takesSpace(in: other, at: 10.5))
        XCTAssertFalse(claim.takesSpace(in: nil, at: 10.5))
        claim.release(in: other)
        XCTAssertTrue(claim.takesSpace(in: window, at: 10.5), "another window let the claim go")
        claim.release(in: window)
        XCTAssertFalse(claim.takesSpace(in: window, at: 10.5))
        claim.claim(in: nil, until: 20)
        XCTAssertFalse(claim.takesSpace(in: window, at: 10.5))
    }

    /// The shortcut manager takes a Space as Play or Pause, but leaves one
    /// that a window's list claimed to that list, until the claim's time,
    /// and in that window alone.
    func testASpaceAListClaimedGoesToTheListAndAnyOtherIsPlayOrPause() throws {
        let manager = KeyboardShortcutManager(
            userDefaults: makeSandboxedPreferences("title-typing-space"),
            installsEventMonitor: false,
            notificationCenter: center
        )
        let window = Self.window()
        let other = Self.window()
        let claim = TitleTypingSpaceClaim.shared
        defer {
            claim.release(in: window)
            window.close()
            other.close()
        }
        // Presses far apart on the events' time line, so none chains with
        // another into a double press.
        let start = ProcessInfo.processInfo.systemUptime
        let space = KeyBinding(key: "space")
        func pressSpace(at offset: TimeInterval, in keyWindow: NSWindow) throws -> Bool {
            let event = try ShortcutKeyPresses.keyPress(of: space, at: start + offset)
            return manager.handleKeyEvent(event, keyWindow: keyWindow, firstResponder: nil)
        }

        XCTAssertTrue(try pressSpace(at: 0, in: window), "a Space no list claimed was not Play or Pause")
        claim.claim(in: window, until: start + 21)
        XCTAssertFalse(try pressSpace(at: 20, in: window), "a Space the list claimed was taken from it")
        XCTAssertTrue(try pressSpace(at: 40, in: window), "a Space after the claim's time was not Play or Pause")
        claim.claim(in: window, until: start + 61)
        XCTAssertTrue(try pressSpace(at: 60, in: other), "a Space in another window was the list's")
    }

    // MARK: - Typing in a Hosted Library List

    /// In a hosted Library list of Treasure Island, The Hobbit, Hamlet, and
    /// A Tale of Two Cities, in that manual order, typed letters select the
    /// row each choice names, which Speak Info then speaks (into a recorder,
    /// so nothing is heard): as written, H is Hamlet, by the list's own type
    /// select; passing over articles, H is The Hobbit, T the first title
    /// filed under T wherever the selection is, "the h" The Hobbit again, "a
    /// t" the row after the selection, a letter no title begins with leaves
    /// the selection where it was, letters a pause apart start afresh, and,
    /// with titles inverted, "hobbit, t" is The Hobbit too.
    ///
    /// Only keys that reach a row, or that letter navigation takes, are
    /// typed, since a key nobody takes would make the Mac beep.
    func testTypedLettersSelectTheRowEachChoiceNames() throws {
        let recorder = InfoSynthesizerRecorder()
        let previousSynthesizer = LibraryInfoSpeaker.makeSynthesizer
        LibraryInfoSpeaker.makeSynthesizer = { recorder }
        defer { LibraryInfoSpeaker.makeSynthesizer = previousSynthesizer }
        let store = TextMouthRuntime.current.preferences
        preservePreferences([LeadingArticles.preference.key], in: store)

        let folder = "Shelf"
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(
            books: ["Treasure Island", "The Hobbit", "Hamlet", "A Tale of Two Cities"].enumerated().map { index, title in
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
            /// Types `text` into the window, key by key, as the keyboard does.
            func type(_ text: String) throws {
                for character in text {
                    hosted.window.sendEvent(try Self.keyDown(character, in: hosted.window))
                    flush(hosted.hostingView)
                }
            }
            /// Waits out the time typed letters add up within.
            func pause() {
                settle(hosted.hostingView, seconds: LibraryTitleTyping.interval + 0.3)
            }

            switch choice {
            case .partOfTitle:
                // The list's own type select, as the titles are written.
                try type("h")
                XCTAssertEqual(selectedTitle(), "Hamlet", "\(choice)")
            case .ignoredWhenTyping, .ignoredWhenTypingAndSorting:
                var steps: [String] = []
                func expect(_ typed: String, _ title: String?, pausingFirst: Bool = true) throws {
                    if pausingFirst { pause() }
                    try type(typed)
                    let selected = selectedTitle()
                    if selected != title {
                        steps.append("\"\(typed)\" selected \(selected ?? "nothing"), not \(title ?? "nothing")")
                    }
                }
                try expect("h", "The Hobbit", pausingFirst: false)
                try expect("t", "Treasure Island")
                try expect("the h", "The Hobbit")
                try expect("ha", "Hamlet")
                // After the selection, then before it: the first in the list's order.
                try expect("a t", "A Tale of Two Cities")
                try expect("t", "Treasure Island")
                // No title begins with Z: the selection stays.
                try expect("z", "Treasure Island")
                // Letters a pause apart start afresh: T, then H on its own.
                try expect("t", "Treasure Island")
                try expect("h", "The Hobbit")
                if choice == .ignoredWhenTypingAndSorting {
                    try expect("hobbit, t", "The Hobbit")
                }
                XCTAssertEqual(steps, [], "\(choice)")
            }
        }
    }

    /// A key-down event typing `character`, with the key code the keyboard
    /// gives it, so AppKit and SwiftUI read it as they read a key pressed.
    private static func keyDown(_ character: Character, in window: NSWindow) throws -> NSEvent {
        let keyCodes: [Character: UInt16] = [
            "a": 0, "h": 4, "z": 6, "b": 11, "e": 14, "t": 17, "o": 31, "i": 34, " ": 49, ",": 43,
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
            isARepeat: false,
            keyCode: keyCodes[character] ?? 0
        ), "no key-down event for \(text)")
    }

    // MARK: - Fixtures

    /// A titled window, never shown, which the test closes.
    private static func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 120), styleMask: [.titled], backing: .buffered, defer: true)
        // The test owns the window; AppKit must not release it again on close.
        window.isReleasedWhenClosed = false
        window.title = "Hosted test view"
        return window
    }
}
