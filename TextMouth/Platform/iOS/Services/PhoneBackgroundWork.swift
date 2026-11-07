import Combine
import UIKit

/// The life cycle's iOS wiring (Slice 6): what keeps the book's place and the
/// app running when the screen is locked, joined to the parts that tell of it.
///
/// - **Silent gaps:** every reader's `silentGapBegan`, `audioMayStart`, and
///   `audioEnded` hooks reach one `PhoneBackgroundHold`, which holds a
///   background task through a gap and flushes the place when the book stops in
///   the background.
/// - **The sleep timer:** a timer that runs out is held awake through its fade
///   and its owner's pause; in the background the place is then flushed and the
///   audio session let go, the spec's "fade, pause, save, flush, deactivate".
/// - **Coming back:** the timer's deadline is checked first, and Book content
///   is told to refresh (`Notification.Name.phoneBookContentShouldRefresh`).
/// - **Memory warnings:** the look-ahead's audio is dropped and every place
///   saved (`PhoneLifeCycle.memoryWarningReceived(isInBackground:)`).
///
/// Every observer is on the main queue, with `MainActor.assumeIsolated`, and
/// every hold is the life cycle's, a background task whose expiry ends it.
/// Nothing here has run on an iPhone.
@MainActor
enum PhoneBackgroundWork {
    /// Whether `install(on:)` has run: once for the process, however many times
    /// a scene connects.
    private static var isInstalled = false
    /// The hold through silent gaps, for every reader.
    private static var hold: PhoneBackgroundHold?
    /// The readers given the hooks, by their IDs: a reader that comes back on
    /// screen from behind another is told of again, and is not wrapped twice.
    private static var attachedReaderIDs = Set<UUID>()
    /// The session's readers, as each is set.
    private static var readerSubscription: AnyCancellable?
    /// The observer of the system's memory warnings.
    private static var memoryWarningObserver: NSObjectProtocol?

    /// Lets the audio session go when no book plays: `iosui-audio`'s
    /// `PhoneAudioSession.shared.deactivateIfIdle()`, which readies every paused
    /// reader's engine first and leaves the Now Playing item in place. Set
    /// where both slices meet; until then it does nothing, and the session
    /// stays active, as it does on the Mac.
    static var deactivateAudioIfIdle: @MainActor () -> Void = {}

    /// Whether the app is in the background now: the screen locked, or another
    /// app in front. `.inactive`, for Control Center or a call's banner, is not:
    /// the app is still on screen.
    static var isInBackground: Bool {
        UIApplication.shared.applicationState == .background
    }

    /// Joins the life cycle's iOS work to `model`, once.
    static func install(on model: PhoneAppModel) {
        guard !isInstalled else { return }
        isInstalled = true
        let lifeCycle = model.lifeCycle
        let hold = PhoneBackgroundHold(
            beginHold: { [weak lifeCycle] name in
                lifeCycle?.beginHold(name) ?? {}
            },
            isInBackground: { PhoneBackgroundWork.isInBackground },
            flush: { PhoneLifeCycle.flushPendingWrites(because: "book-stopped-in-background") }
        )
        self.hold = hold
        // `$reader` tells of each reader as it is about to be set, on the main
        // actor that sets it, before anything can play it: the hooks are in
        // place before the first Play.
        readerSubscription = model.session.$reader.sink { reader in
            guard let reader else { return }
            attach(hold, to: reader)
        }
        installSleepTimerHold(lifeCycle)
        lifeCycle.onDidEnterBackground {
            // Paused as the app leaves, the book needs the audio session no
            // more (spec: "Deactivate ... entering the background while paused").
            // The flush itself is the model's own handler's.
            PhoneBackgroundWork.deactivateAudioIfIdle()
        }
        lifeCycle.onWillEnterForeground {
            PhoneBackgroundWork.cameBack()
        }
        lifeCycle.onDidBecomeActive {
            // Again at activation, which a launch reaches without a return
            // from the background: a check of a deadline not passed changes
            // nothing.
            SleepTimerService.shared.checkPhoneDeadline()
        }
        // UIKit posts the warning on the main thread; the observer runs on the
        // main queue either way, and is never removed: it lasts the process.
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak lifeCycle] _ in
            MainActor.assumeIsolated {
                lifeCycle?.memoryWarningReceived(in: model.session, isInBackground: PhoneBackgroundWork.isInBackground)
            }
        }
        DiagnosticLog.event(.app, "PHONE_LIFE_CYCLE_INSTALLED: silent gaps, sleep timer, return, memory warnings")
    }

    /// Gives `reader` the hooks that reach the hold, composed with whatever
    /// another slice set, so neither replaces the other: the audio session's
    /// `audioMayStart` asks first or after, and either order answers alike.
    private static func attach(_ hold: PhoneBackgroundHold, to reader: ReaderViewModel) {
        guard attachedReaderIDs.insert(reader.readerID).inserted else { return }
        reader.phoneHooks.silentGapBegan = { [weak hold] in
            hold?.silentGapBegan()
        }
        let askedBefore = reader.phoneHooks.audioMayStart
        reader.phoneHooks.audioMayStart = { [weak hold] in
            let mayStart = askedBefore()
            hold?.audioMayStartAnswered(mayStart)
            return mayStart
        }
        let endedBefore = reader.phoneHooks.audioEnded
        reader.phoneHooks.audioEnded = { [weak hold] in
            endedBefore?()
            hold?.audioEnded()
        }
    }

    /// Holds the app awake while a sleep timer that ran out puts the book to
    /// sleep: begun as it runs out (`SleepTimerService.phoneExpiryHold`), and
    /// ended once its owner has paused the book and saved its place, after the
    /// flush and the audio session's release in the background.
    private static func installSleepTimerHold(_ lifeCycle: PhoneLifeCycle) {
        SleepTimerService.shared.phoneExpiryHold = { [weak lifeCycle] in
            let endHold = lifeCycle?.beginHold("Sleep timer putting the book to sleep") ?? {}
            return {
                if PhoneBackgroundWork.isInBackground {
                    PhoneLifeCycle.flushPendingWrites(because: "sleep-timer-expired-in-background")
                    PhoneBackgroundWork.deactivateAudioIfIdle()
                }
                endHold()
            }
        }
    }

    /// The app is coming back toward the screen: the sleep timer's deadline is
    /// checked before anything else, so a timer whose time passed expires at
    /// once, and Book content is told to show the place as it is now.
    private static func cameBack() {
        SleepTimerService.shared.checkPhoneDeadline()
        NotificationCenter.default.post(name: .phoneBookContentShouldRefresh, object: nil)
    }
}
