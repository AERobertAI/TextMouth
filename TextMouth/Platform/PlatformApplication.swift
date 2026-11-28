#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The application-wide facts shared code asks for most, under one name for
/// both apps (phase 0 of the iOS port). On the Mac each member is exactly the
/// AppKit expression the code used before (`PlatformApplication.keyWindow` is
/// `NSApp.keyWindow`), so the Mac does what it did, and
/// Scripts/ios/mac-projection.py reads each use as that expression. On iOS
/// each answers as well as phase 0 can: there is no key or main window to
/// name yet (phase 1 finds the scene's), and "active" means in the foreground.
///
/// Members are added here only for an AppKit expression several shared files
/// use; a call only the Mac makes stays behind `#if os(macOS)`.
enum PlatformApplication {
    /// The window that takes the keyboard: `NSApp.keyWindow` on the Mac; on
    /// iOS, none yet.
    @MainActor static var keyWindow: PlatformWindow? {
        #if os(macOS)
        NSApp.keyWindow
        #else
        nil
        #endif
    }

    /// The window in front: `NSApp.mainWindow` on the Mac; on iOS, none yet.
    @MainActor static var mainWindow: PlatformWindow? {
        #if os(macOS)
        NSApp.mainWindow
        #else
        nil
        #endif
    }

    /// Whether TextMouth is the active app: `NSApp.isActive` on the Mac; on
    /// iOS, whether it is in the foreground and active.
    @MainActor static var isActive: Bool {
        #if os(macOS)
        NSApp.isActive
        #else
        UIApplication.shared.applicationState == .active
        #endif
    }

    /// Posted when TextMouth becomes the active app: AppKit's notification on
    /// the Mac, UIKit's on iOS.
    static var didBecomeActiveNotification: Notification.Name {
        #if os(macOS)
        NSApplication.didBecomeActiveNotification
        #else
        UIApplication.didBecomeActiveNotification
        #endif
    }

    /// Posted when TextMouth stops being the active app: AppKit's notification
    /// on the Mac, UIKit's on iOS.
    static var didResignActiveNotification: Notification.Name {
        #if os(macOS)
        NSApplication.didResignActiveNotification
        #else
        UIApplication.willResignActiveNotification
        #endif
    }
}
