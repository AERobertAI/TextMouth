import Foundation

/// The one keeper of the screen's sleep: it counts who wants the screen kept
/// awake, and tells its owner the screen should stay awake while anyone does.
///
/// UIKit's `UIApplication.isIdleTimerDisabled` is one app-wide flag. Two
/// owners that each set it and clear it (the import copier, and Book content
/// while it has focus) switch each other off: whichever lets go first lets the
/// screen lock for the other. Here each owner asks for a hold, and the flag
/// follows "anyone holds".
///
/// A plain type that imports no UIKit, so the Mac's tests decide every case;
/// the iPhone's `PhoneScreenSleep` supplies the one that sets the flag.
@MainActor
final class PhoneScreenHolds {
    /// Called with whether the screen should now stay awake, each time that
    /// changes (and not otherwise).
    private let apply: @MainActor (Bool) -> Void
    /// The holds not yet let go, by number.
    private var holders: Set<Int> = []
    /// The number the next hold gets.
    private var nextHolder = 0
    /// What `apply` was last told, so it's called only on a change.
    private var isAwake = false

    /// A keeper that tells `apply` whether the screen should stay awake.
    init(apply: @escaping @MainActor (Bool) -> Void) {
        self.apply = apply
    }

    /// How many holds are in force.
    var holdCount: Int { holders.count }

    /// Whether the screen should stay awake: anyone holds.
    var keepsScreenAwake: Bool { !holders.isEmpty }

    /// Takes a hold on the screen's sleep. The returned closure lets go, and
    /// letting go twice does nothing, so an owner can call it from every place
    /// it may end.
    func begin() -> @MainActor () -> Void {
        let holder = nextHolder
        nextHolder += 1
        holders.insert(holder)
        update()
        return { [weak self] in
            guard let self, self.holders.remove(holder) != nil else { return }
            self.update()
        }
    }

    /// Tells `apply` when "anyone holds" has changed.
    private func update() {
        let awake = keepsScreenAwake
        guard awake != isAwake else { return }
        isAwake = awake
        apply(awake)
    }
}
