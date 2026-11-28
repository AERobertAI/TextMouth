#if os(macOS)
import AppKit
import CoreServices

/// Why a request to quit came, as far as the delegate needs to tell: the
/// system ending the session (log out, restart, shut down), which waits for
/// a reply and must not be cancelled, or the person asking to quit.
///
/// The system says why in the quit Apple event it sends, under the SDK's
/// `kAEQuitReason` (`'why?'`, AERegistry.h): a log out, restart, or shut down
/// by one of the reasons below. Whether loginwindow puts it among the event's
/// attributes or its parameters is not settled by the header, so both are
/// read. A shut down or restart also posts
/// `NSWorkspace.willPowerOffNotification` first, and a quit that follows it
/// soon after counts as the system's too, in case the event names no reason.
@MainActor
enum QuitReason {
    /// The Apple event keyword of a quit's reason: the SDK's own constant,
    /// never spelled out here (it was once written `'why '`, which no event
    /// carries, so no log out was ever recognised).
    static let reasonKeyword = AEKeyword(kAEQuitReason)

    /// The reasons that end the session: `kAELogOut`, `kAEReallyLogOut`,
    /// `kAERestart`, and `kAEShutDown`.
    static let sessionEndingReasons: Set<OSType> = [
        OSType(kAELogOut), OSType(kAEReallyLogOut), OSType(kAERestart), OSType(kAEShutDown),
    ]

    /// How long after `willPowerOffNotification` a quit still counts as the
    /// system's: the log out or shut down may be cancelled by the person, and
    /// a quit minutes later is theirs again.
    static let powerOffWindow: TimeInterval = 120

    /// When the system last said it is powering off, if it did.
    private static var powerOffAnnouncedAt: Date?
    /// The observer of that notice, once watching.
    private static var powerOffObserver: NSObjectProtocol?

    /// Starts noting `willPowerOffNotification`, once, at launch.
    static func startWatchingForPowerOff(center: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        guard powerOffObserver == nil else { return }
        powerOffObserver = center.addObserver(
            forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { noteWillPowerOff() }
        }
    }

    /// Notes that the system is powering off, at `date`.
    static func noteWillPowerOff(at date: Date = Date()) {
        powerOffAnnouncedAt = date
    }

    /// Forgets the notice: for tests, which must leave nothing behind.
    static func forgetPowerOff() {
        powerOffAnnouncedAt = nil
    }

    /// Whether a quit at `now` follows the system's notice that it is
    /// powering off closely enough to be its own.
    static func quitFollowsPowerOff(now: Date = Date()) -> Bool {
        guard let announced = powerOffAnnouncedAt else { return false }
        return now.timeIntervalSince(announced) >= 0 && now.timeIntervalSince(announced) <= powerOffWindow
    }

    /// The quit reason `event` names, as an attribute or a parameter, if any.
    static func reason(in event: NSAppleEventDescriptor?) -> OSType? {
        guard let event else { return nil }
        let described = event.attributeDescriptor(forKeyword: reasonKeyword)
            ?? event.paramDescriptor(forKeyword: reasonKeyword)
        guard let code = described?.enumCodeValue, code != 0 else { return nil }
        return code
    }

    /// Whether `reason`, the quit reason of an Apple event if it had one,
    /// ends the session. Pure, so the choice is tested without an event.
    static func endsTheSession(_ reason: OSType?) -> Bool {
        reason.map(sessionEndingReasons.contains) ?? false
    }

    /// Whether `event` names a session-ending reason.
    static func endsTheSession(event: NSAppleEventDescriptor?) -> Bool {
        endsTheSession(reason(in: event))
    }

    /// Whether the quit being answered now was asked by the system ending the
    /// session. Command-Q, the Quit menu item, and a call to `terminate` have
    /// no Apple event; the Dock's Quit has one without a session-ending
    /// reason.
    static var currentRequestEndsTheSession: Bool {
        endsTheSession(event: NSAppleEventManager.shared().currentAppleEvent) || quitFollowsPowerOff()
    }
}
#endif
