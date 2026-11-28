// Phase 0 stand-in: the Mac's FrontWindowKind follows which kind of window is in front so menu commands show their keys only there; iOS has no menu windows, so the kind is always nil.
import SwiftUI

/// The kind of window in front, which the Mac's menus act on. iOS has the
/// same shape so the shared menu code compiles, but there is never a window
/// kind there: `kind` stays nil and nothing is observed.
@MainActor
final class FrontWindowKind: ObservableObject {
    /// The app's one.
    static let shared = FrontWindowKind()

    /// The kind of window in front: always nil on iOS.
    @Published private(set) var kind: ShortcutWindowKind?

    /// Private, as the Mac's is: the app has the one `shared`.
    private init() {}

    /// The kind of `window`: always nil on iOS, which has no kinds of window.
    static func kind(of window: PlatformWindow?) -> ShortcutWindowKind? {
        nil
    }
}
