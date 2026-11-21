// Phase 0 stand-in: on the Mac, an NSWindow answers `isMainWindow` (whether
// it is the window in front of the app's others, which the reader asks when
// a sleep-timer restart gesture has no timer history to follow). UIKit's
// UIWindow has no main window; iOS answers with whether the window is the
// key window, the one UIKit has, so shared code that asks both still compiles
// and reads the one fact iOS has. Phase 1 reads the scene instead.

import UIKit

extension UIWindow {
    /// Whether this window is in front of the app's others: on iOS, whether
    /// it is the key window (UIKit has no separate main window).
    var isMainWindow: Bool { isKeyWindow }
}
