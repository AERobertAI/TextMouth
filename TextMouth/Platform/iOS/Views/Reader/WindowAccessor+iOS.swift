// Phase 0 stand-in: the Mac's WindowAccessor hands the SwiftUI view its NSWindow and reports key, close, and on-screen changes; iOS reports nothing yet.
import SwiftUI

/// An invisible view that, on the Mac, captures its hosting window and
/// reports when the window becomes key, closes, or comes on screen. On iOS
/// it has the same shape, so the shared views that name it compile, but it
/// finds no window and calls none of its callbacks.
struct WindowAccessor: View {
    /// Called with the hosting window once found (never, on iOS for now).
    let onWindowFound: (PlatformWindow) -> Void
    /// Called each time the window becomes key (never, on iOS for now).
    let onWindowBecameKey: () -> Void
    /// Called as the window closes (never, on iOS for now).
    let onWindowWillClose: () -> Void
    /// Called each time the window comes on screen (never, on iOS for now).
    let onWindowBecameVisible: () -> Void

    /// Keeps the callbacks, with the same labels and defaults as the Mac's.
    init(
        onWindowFound: @escaping (PlatformWindow) -> Void,
        onWindowBecameKey: @escaping () -> Void = {},
        onWindowWillClose: @escaping () -> Void = {},
        onWindowBecameVisible: @escaping () -> Void = {}
    ) {
        self.onWindowFound = onWindowFound
        self.onWindowBecameKey = onWindowBecameKey
        self.onWindowWillClose = onWindowWillClose
        self.onWindowBecameVisible = onWindowBecameVisible
    }

    /// Nothing to see or hear: a zero-size clear view, hidden from
    /// accessibility.
    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }
}
