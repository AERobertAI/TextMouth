// Phase 0 stand-in: the Mac's SwitchedWindowFocus puts VoiceOver and keyboard focus in a reader window switched to another book, after a delay; iOS does nothing yet.
import Foundation

/// Seeing to focus in a window that was switched to another book. The Mac
/// checks, a moment after the book loads, whether the window's focus trigger
/// ran and places focus itself if not. iOS has no such windows yet, so the
/// shared reader code compiles against this and nothing happens.
@MainActor
enum SwitchedWindowFocus {
    /// How long the Mac waits after the load before looking (the same value,
    /// so the shared name means the same thing).
    static let checkDelay: TimeInterval = 1.6

    /// Whether the check puts focus in the window: only in the key window,
    /// and only if no trigger posted since the book loaded. Identical to the
    /// Mac's, a pure function of its arguments.
    nonisolated static func shouldPlace(postsAtTheLoad: Int, postsNow: Int, windowIsKey: Bool) -> Bool {
        windowIsKey && postsNow == postsAtTheLoad
    }

    /// Does nothing on iOS for now; the Mac schedules its focus check here.
    static func place(in window: PlatformWindow) {
        // Intentionally empty: iOS has no switched reader windows in phase 0.
    }
}
