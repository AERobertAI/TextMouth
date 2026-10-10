import AppKit
import Combine
import XCTest
@testable import TextMouth

/// Key presses made up for the shortcut tests, as the shortcut manager's
/// event monitor is handed them, and the actions the manager posts. No key
/// is really pressed, and no event is sent to any window.
enum ShortcutKeyPresses {
    /// The key code and characters the keyboard gives each key a binding
    /// names rather than spells; a binding matches these keys by code.
    static let namedKeyPresses: [String: (keyCode: UInt16, characters: String)] = [
        "space": (49, " "),
        "tab": (48, "\t"),
        "return": (36, "\r"),
        "delete": (51, "\u{7F}"),
        "escape": (53, "\u{1B}"),
        "leftArrow": (123, "\u{F702}"),
        "rightArrow": (124, "\u{F703}"),
        "downArrow": (125, "\u{F701}"),
        "upArrow": (126, "\u{F700}"),
    ]

    /// A key-down event for `binding`'s key with exactly its modifiers, at
    /// `time` on the events' time line: the Mac's uptime unless given, so a
    /// second press follows the first well within the double-press time.
    static func keyPress(of binding: KeyBinding, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) throws -> NSEvent {
        var flags: NSEvent.ModifierFlags = []
        if binding.command { flags.insert(.command) }
        if binding.option { flags.insert(.option) }
        if binding.shift { flags.insert(.shift) }
        if binding.control { flags.insert(.control) }
        let named = namedKeyPresses[binding.key]
        // A key a binding spells is matched by its character, which Shift
        // capitalizes as the keyboard does; its code goes unread.
        let characters = named?.characters ?? (binding.shift ? binding.key.uppercased() : binding.key)
        return try keyDown(keyCode: named?.keyCode ?? 0, characters: characters, modifiers: flags, at: time)
    }

    /// A key-down event giving `characters` for the key with code
    /// `keyCode`, `modifiers` held, at `time`.
    static func keyDown(
        keyCode: UInt16,
        characters: String,
        modifiers: NSEvent.ModifierFlags,
        at time: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) throws -> NSEvent {
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: time,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )
        return try XCTUnwrap(event, "no key press for the key with code \(keyCode)")
    }
}

extension XCTestCase {
    /// A window, never shown, that the shortcut manager takes for a window
    /// of `kind` (`KeyboardShortcutManager.windowKind(of:)`, FR12's branch
    /// E): a reader's, an audio editor's, or the Record window by their
    /// identifiers, a Library window as any other titled window is taken,
    /// and a panel for any other kind. It is closed when the test ends.
    @MainActor
    func makeShortcutWindow(_ kind: ShortcutWindowKind) -> NSWindow {
        let frame = NSRect(x: 0, y: 0, width: 320, height: 120)
        let window = kind == .other
            ? NSPanel(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: true)
            : NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: true)
        // The test owns the window; AppKit must not release it again on close.
        window.isReleasedWhenClosed = false
        // A titled window that is not key stays off screen, as a hosted test
        // view's does (`withHostedView`).
        window.title = "Hosted test view"
        switch kind {
        case .reader: window.identifier = NSUserInterfaceItemIdentifier("book-reader-AppWindow-1")
        case .audioEditor: window.identifier = NSUserInterfaceItemIdentifier(AudioEditorWindowController.windowIdentifier)
        case .recording: window.identifier = NSUserInterfaceItemIdentifier(RecordingWindowController.windowIdentifier)
        case .library, .other: break
        }
        addTeardownBlock { @MainActor in window.close() }
        return window
    }

    /// A window, never shown, that says it is a sheet presented on `window`
    /// (`ShortcutTestSheet`), as the shortcut manager and the menus read a
    /// sheet, and a sheet over a sheet when `window` is one. It is closed
    /// when the test ends.
    @MainActor
    func makeShortcutSheet(on window: NSWindow) -> NSWindow {
        let sheet = ShortcutTestSheet(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        // The test owns the window; AppKit must not release it again on close.
        sheet.isReleasedWhenClosed = false
        sheet.title = "Hosted test sheet"
        sheet.presentedOn = window
        addTeardownBlock { @MainActor in sheet.close() }
        return sheet
    }
}

/// A window, never shown, that says it is a sheet presented on
/// `presentedOn`, as an attached sheet says (`sheetParent`), without a sheet
/// being presented, which would show it.
final class ShortcutTestSheet: NSWindow {
    /// The window it says it is presented on.
    weak var presentedOn: NSWindow?

    override var sheetParent: NSWindow? {
        presentedOn
    }
}

/// Who holds each key where it works, for the tests that every key has one
/// owner in each kind of window (FR12's branches D and E).
enum ShortcutKeyOwners {
    /// Each key `bindings` gives two actions in one kind of window, each
    /// action working where `scopes` says, its default scope unless given,
    /// and its keys acting where they do there (`ShortcutScope.windowKinds(of:)`,
    /// a menu command's wherever its menu item acts): the same key, or a key
    /// equivalent's key and the same key pressed twice
    /// (`KeyClaims.forms(of:for:)`). Each is described once, as "⇧⌘T in
    /// library: Show Sleep Timer and New from Text…", in the order Settings
    /// lists the actions; none when every key has one owner wherever it
    /// works.
    static func keysOnTwoActions(
        in bindings: [ShortcutAction: [KeyBinding]],
        scopes: (ShortcutAction) -> ShortcutScope = { $0.defaultScope }
    ) -> [String] {
        var owners: [ShortcutWindowKind: [KeyBinding: ShortcutAction]] = [:]
        var clashes: [String] = []
        for action in ShortcutAction.allCases {
            let actsIn = scopes(action).windowKinds(of: action)
            for binding in bindings[action] ?? [] {
                let forms = KeyClaims.forms(of: binding, for: action)
                for kind in ShortcutWindowKind.allCases where actsIn.contains(kind) {
                    if let owner = forms.lazy.compactMap({ owners[kind]?[$0] }).first(where: { $0 != action }) {
                        let clash = "\(binding.displayString) in \(kind): \(owner.rawValue) and \(action.rawValue)"
                        if !clashes.contains(clash) {
                            clashes.append(clash)
                        }
                        continue
                    }
                    for form in forms {
                        owners[kind, default: [:]][form] = action
                    }
                }
            }
        }
        return clashes
    }

    /// The actions among whose keys `bindings` puts `binding` that act in a
    /// kind of window `action` acts in, each working where `scopes` says,
    /// its default scope unless given, by the clash rule's overlap
    /// (`ShortcutAction.sharesAWindow(in:with:in:)`, a menu command's key
    /// counting wherever its menu item acts), in the order Settings lists
    /// them: who answers the key where `action` would, `action` itself
    /// included. An action working only in other windows, as the audio
    /// editor's keep their own keys, is left out.
    static func actions(
        holding binding: KeyBinding,
        in bindings: [ShortcutAction: [KeyBinding]],
        sharingAWindowWith action: ShortcutAction,
        scopes: (ShortcutAction) -> ShortcutScope = { $0.defaultScope }
    ) -> [ShortcutAction] {
        ShortcutAction.allCases.filter { holder in
            bindings[holder]?.contains(binding) == true
                && holder.sharesAWindow(in: scopes(holder), with: action, in: scopes(action))
        }
    }
}

/// Every shortcut action posted on a notification center, in the order
/// posted: each action's name, or the notification's own name for one that
/// carries no action. It listens until it is released.
@MainActor
final class PostedShortcutActions {
    /// What was posted, oldest first.
    private(set) var names: [String] = []
    /// The subscription to every action's notification.
    private var subscription: AnyCancellable?

    /// Starts listening on `center` for every action's notification; the
    /// audio editor's actions share one.
    init(on center: NotificationCenter) {
        let notificationNames = Set(ShortcutAction.allCases.map(\.notificationName))
        subscription = Publishers.MergeMany(notificationNames.map { center.publisher(for: $0) })
            .sink { [weak self] notification in
                // The manager posts on the main thread, within the press.
                MainActor.assumeIsolated {
                    self?.names.append(notification.userInfo?["action"] as? String ?? notification.name.rawValue)
                }
            }
    }
}
