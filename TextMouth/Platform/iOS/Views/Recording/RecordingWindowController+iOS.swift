// Phase 0 stand-in: on the Mac, RecordingWindowController owns the Record
// window: it opens the window, holds a quit while a take is still being
// saved, and lists takes a crash left behind. The iPhone has no windows to
// manage, so this version has the same name and the members shared code calls
// (MenuCommands, AddToLibraryHost, AppDelegate, KeyboardShortcutManager,
// MenuVisibilityManager) and does nothing with them. Phase 1 opens a
// recording screen from `show`. If a throwing entry is ever needed, the error
// to throw is `IOSUnavailable.feature("Recording")`.
import Foundation

/// The iOS stand-in for the Mac's Record window controller.
@MainActor
final class RecordingWindowController {
    /// The one controller, as on the Mac.
    static let shared = RecordingWindowController()

    /// The identifier shared code compares a window's identifier with, the
    /// Mac's text; no iOS window carries it.
    nonisolated static let windowIdentifier = "new-recording"

    /// Gives the controller the library its recordings go into. The Mac keeps
    /// it to look for recovered takes; here there is nothing to keep.
    func attach(_ library: LibraryViewModel) {}

    /// Shows the Record window on the Mac. On iOS it does nothing yet:
    /// phase 1 opens a recording screen here.
    func show(library: LibraryViewModel? = nil, recovered: [RecoveredTake] = []) {}

    /// Whether a quit must wait for a recording to be saved. There is no
    /// recording on iOS, so nothing is held and the quit goes on.
    func holdQuit(then quit: @escaping @MainActor @Sendable () -> Void) -> Bool {
        false
    }
}
