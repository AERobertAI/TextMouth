import UIKit

/// The app's one keeper of the screen's sleep. Everything on the iPhone that
/// needs the screen to stay awake (the import copier while it copies, Book
/// content while it has focus) takes a hold here, never setting
/// `UIApplication.isIdleTimerDisabled` itself; the flag is on while any hold is
/// in force (`PhoneScreenHolds`). Apple's documentation of the property says
/// it's an app-wide setting that disables the idle timer, so it needs one
/// owner.
@MainActor
enum PhoneScreenSleep {
    /// The keeper, which sets the app-wide idle timer flag.
    static let holds = PhoneScreenHolds { awake in
        UIApplication.shared.isIdleTimerDisabled = awake
    }

    /// Takes a hold on the screen's sleep; the closure returned lets go.
    static func hold() -> @MainActor () -> Void {
        holds.begin()
    }
}
