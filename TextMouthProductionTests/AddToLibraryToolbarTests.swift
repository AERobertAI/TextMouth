import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

/// The Library window's Add to Library button and what runs behind it
/// (FR20, part two). No test posts a real `.openBookFile`,
/// `.importDAISYFolder`, `.newFromText`, or `.addFeed`, or shows the Record
/// window: the test host is the app itself, and a real post could open a
/// file panel on a live window. The runner is always a recording one.
@MainActor
final class AddToLibraryToolbarTests: XCTestCase {

    // MARK: - Fixtures

    /// One thing the runner was asked to do.
    private enum Call: Equatable {
        /// A notification posted, with whether it carried a source window.
        case post(Notification.Name, sourceWindow: NSWindow?)
        /// The Record window shown.
        case recording
    }

    /// Everything a recording runner was asked to do, and whether the sheet
    /// had gone each time.
    private final class Recording {
        var calls: [Call] = []
        /// `isPresented` of the model at each call.
        var sheetShowing: [Bool] = []
    }

    /// A host that runs choices through a recording runner and follows a
    /// store of its own, with the recording it fills.
    private func makeHost(_ label: String) -> (host: AddToLibraryHost, recording: Recording) {
        let recording = Recording()
        let shortcuts = KeyboardShortcutManager(userDefaults: makeSandboxedPreferences(label), installsEventMonitor: false)
        // The host is needed to read `isPresented` in the runner's closures,
        // so they reach it through a box filled once it exists.
        final class HostBox { weak var host: AddToLibraryHost? }
        let box = HostBox()
        let runner = AddToLibraryRunner(
            post: { name, userInfo in
                recording.calls.append(.post(name, sourceWindow: userInfo?["sourceWindow"] as? NSWindow))
                recording.sheetShowing.append(box.host?.model.isPresented ?? true)
            },
            showRecordingWindow: {
                recording.calls.append(.recording)
                recording.sheetShowing.append(box.host?.model.isPresented ?? true)
            }
        )
        let host = AddToLibraryHost(shortcuts: shortcuts, runner: runner)
        box.host = host
        return (host, recording)
    }

    /// Opens the sheet, makes `choice`, and lets the sheet finish closing,
    /// as SwiftUI does by calling `onDismiss`.
    private func choose(_ choice: AddToLibraryChoice, in host: AddToLibraryHost) {
        host.present()
        host.model.choose(choice)
        host.model.sheetDidDismiss()
    }

    // MARK: - The Runner

    /// Each choice, chosen and the sheet gone, makes exactly one call of the
    /// runner: the notification its menu posts, or the Record window. The
    /// sheet has gone by then.
    func testEachChoiceRunsOnceWithWhatItsMenuRuns() {
        let expected: [(AddToLibraryChoice, Call)] = [
            (.openBook, .post(.openBookFile, sourceWindow: nil)),
            (.importFolder, .post(.importDAISYFolder, sourceWindow: nil)),
            (.newFromText, .post(.newFromText, sourceWindow: nil)),
            (.newRecording, .recording),
            (.addFeed, .post(.addFeed, sourceWindow: nil)),
        ]
        XCTAssertEqual(expected.map(\.0), AddToLibraryChoice.allCases, "a choice was left untested")
        for (choice, call) in expected {
            let (host, recording) = makeHost("runner-\(choice.title)")
            choose(choice, in: host)
            XCTAssertEqual(recording.calls, [call], choice.title)
            XCTAssertEqual(recording.sheetShowing, [false], "\(choice.title) ran while the sheet was showing")
        }
    }

    /// A choice made while the sheet is still showing runs nothing until the
    /// sheet has gone.
    func testAChoiceWaitsForTheSheetToGo() {
        let (host, recording) = makeHost("runner-waits")
        host.present()
        host.model.choose(.newFromText)
        XCTAssertEqual(recording.calls, [], "the choice ran before the sheet had gone")
        host.model.sheetDidDismiss()
        XCTAssertEqual(recording.calls, [.post(.newFromText, sourceWindow: nil)])
        host.model.sheetDidDismiss()
        XCTAssertEqual(recording.calls.count, 1, "the choice ran twice")
    }

    /// Add Feed names the window the sheet was in, as the old toolbar button
    /// did, so the Add Feed sheet is that window's; no other choice does.
    func testAddFeedNamesTheWindowAndNoOtherChoiceDoes() {
        let (host, recording) = makeHost("runner-source-window")
        let window = NSWindow()
        host.attach(window: window, library: LibraryViewModel(initializeServices: false))
        for choice in AddToLibraryChoice.allCases {
            choose(choice, in: host)
        }
        XCTAssertEqual(recording.calls, [
            .post(.openBookFile, sourceWindow: nil),
            .post(.importDAISYFolder, sourceWindow: nil),
            .post(.newFromText, sourceWindow: nil),
            .recording,
            .post(.addFeed, sourceWindow: window),
        ])
    }

    /// Cancel, and Escape, which presses it, close the sheet and run
    /// nothing, even after a choice was made.
    func testCancelRunsNothing() {
        let (host, recording) = makeHost("runner-cancel")
        host.present()
        host.model.cancel()
        host.model.sheetDidDismiss()
        XCTAssertFalse(host.model.isPresented)

        host.present()
        host.model.choose(.addFeed)
        host.model.cancel()
        host.model.sheetDidDismiss()
        XCTAssertEqual(recording.calls, [])
    }

    /// A choice whose menu command does not work in a Library window is
    /// dimmed and runs nothing.
    func testADimmedChoiceRunsNothing() {
        let (host, recording) = makeHost("runner-dimmed")
        // New from Text works in Reader windows alone, so it is dimmed here.
        host.shortcuts.setScope(.reader, for: .newFromText)
        XCTAssertFalse(host.model.isEnabled(.newFromText))
        XCTAssertTrue(host.model.isEnabled(.openBook))
        choose(.newFromText, in: host)
        XCTAssertEqual(recording.calls, [])
    }

    // MARK: - The Router Picks This Window

    /// With two Library windows registered, the key one, which is the window
    /// the sheet was in, takes the commands the sheet's choices post.
    func testTheKeyLibraryWindowTakesTheCommands() {
        let first = NSWindow()
        let second = NSWindow()
        let reader = NSWindow()
        for action in [GlobalAction.openBookFile, .newFromText, .importDAISYFolder] {
            XCTAssertEqual(
                LibraryWindowRouter.handler(
                    for: action,
                    keyWindow: second,
                    registeredLibraryWindows: [first, second],
                    readerWindows: [reader]
                ),
                .libraryWindow(second),
                "\(action)"
            )
        }
    }

    // MARK: - The Toolbar

    /// The labels of the toolbar's items of a hosted Library window with an
    /// empty library, as AppKit draws them, or nil when this macOS draws no
    /// toolbar for a hosted view.
    private func libraryToolbarLabels() -> [String]? {
        let library = LibraryViewModel(initializeServices: false)
        let settings = SettingsViewModel(notificationCenter: NotificationCenter(), initializeServices: false)
        let hostingView = NSHostingView(
            rootView: LibraryView(
                currentFolderPath: .constant(""),
                category: .constant(.folders),
                showFileImporter: .constant(false),
                showTextInput: .constant(false),
                onOpenBook: { _ in }
            )
            .environmentObject(library)
            .environmentObject(settings)
        )
        // Bridged, so SwiftUI draws the window's toolbar in AppKit's.
        hostingView.sceneBridgingOptions = [.toolbars]
        let window = OffscreenTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "Hosted Library window test"
        window.contentView = hostingView
        defer { takeDown(window) }
        guard waitUntil(timeout: 5, {
            window.contentView?.layoutSubtreeIfNeeded()
            return window.toolbar != nil
        }) else { return nil }
        settle(hostingView, seconds: 0.5)
        return window.toolbar?.items.map(\.label)
    }

    /// The toolbar shows Add to Library once, and none of the three buttons
    /// it replaced.
    func testTheToolbarShowsAddToLibraryAndNotTheThreeItReplaced() throws {
        guard let labels = libraryToolbarLabels() else {
            throw XCTSkip("This macOS draws no toolbar for a hosted SwiftUI view")
        }
        XCTAssertEqual(labels.filter { $0 == "Add to Library" }.count, 1, "\(labels)")
        for gone in ["Import Book", "New from Text", "Add Feed"] {
            XCTAssertFalse(labels.contains(gone), "the toolbar still has \(gone): \(labels)")
        }
    }

    /// The button's words, pinned exactly since the listener hears them
    /// through VoiceOver.
    func testTheButtonsWords() {
        XCTAssertEqual(AddToLibraryWording.buttonTitle, "Add to Library")
        XCTAssertEqual(AddToLibraryWording.buttonLabel, "Add to Library")
        XCTAssertEqual(
            AddToLibraryWording.buttonHint,
            "Opens a sheet with the ways to add to the library: open a book, import a folder, make a book from text, record audio, or add a feed"
        )
    }

    /// The window's source draws the one button from those words with the
    /// plus image, takes over the Import button's place as VoiceOver's
    /// initial target, and has none of the three it replaced. SwiftUI keeps
    /// a button's label and hint where a test cannot read them, so this
    /// reads the source, as the folder settings tests do for the menu.
    func testTheWindowDrawsOneButtonThatTakesTheImportButtonsPlace() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TextMouth/Views/Library/LibraryView.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        XCTAssertTrue(text.contains("Label(AddToLibraryWording.buttonTitle, systemImage: \"plus\")"))
        XCTAssertTrue(text.contains(".accessibilityLabel(AddToLibraryWording.buttonLabel)"))
        XCTAssertTrue(text.contains(".accessibilityHint(AddToLibraryWording.buttonHint)"))
        XCTAssertTrue(text.contains("isEnabled: focusTarget == .importButton"))
        XCTAssertTrue(text.contains("addToLibraryButton(focusTarget: focusTarget)"))
        for gone in ["importBookButton", "Label(\"New from Text\"", "FeedWording.addFeedToolbarTitle", "FeedWording.addFeedButtonLabel"] {
            XCTAssertFalse(text.contains(gone), "\(gone) is still in the Library window")
        }
        // The Open Book choice's hint keeps its text.
        XCTAssertEqual(LibraryView.importBookHint, "Opens a file picker to import books in any format TextMouth reads.")
    }
}
