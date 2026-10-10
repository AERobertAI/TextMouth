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
