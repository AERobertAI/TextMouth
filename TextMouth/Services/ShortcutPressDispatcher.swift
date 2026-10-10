import AppKit

// MARK: - The Dispatcher

/// Decides what each key press does, single and double presses alike (FR12,
/// section 2 of the design): the one place a key press becomes an action.
///
/// A press is looked up in an index of the bindings in force (`Index`),
/// built for each scope from the shortcut manager's bindings and rebuilt
/// whenever they change, so which action a key triggers never depends on the
/// order of a dictionary, as it did while presses were matched by walking
/// one. For one key, meaning one key with the same modifiers in one scope:
/// - With a single action only, each press acts at once, as before.
/// - With a double action only, the first press is taken and does nothing,
///   and a second press within the double-press time runs the double action.
/// - With a single action and a double action that escalates it
///   (`ShortcutAction.escalates`), or the same action on both, the first
///   press acts at once, and a second within the time runs the double
///   action, which takes over.
/// - With a single action and an unrelated double action, the first press
///   waits: a second within the time runs the double action alone, and
///   otherwise the single action runs once the time is up, or at once when
///   another key is pressed first.
///
/// For every key:
/// - A double press is the same key with the same modifiers, pressed twice
///   in the same window, the second press less than the double-press time
///   after the first by the events' own timestamps; a press at exactly the
///   time is a single press.
/// - A held key's automatic repeats are taken and ignored for a key with a
///   double action, and act as its presses do for any other key.
/// - A key a focused text field keeps (`KeyboardShortcutManager.shouldHandle`)
///   never counts as a press: it goes on to the field, and, like any other
///   key, runs a waiting single press at once. A double binding with Command
///   or Control acts from a field, as single ones do.
/// - Once a double press has acted, each further press of its key that comes
///   within the time of the one before is taken and ignored, so a third
///   quick press never starts the key over.
/// - A waiting single press acts in the window it was pressed in, with
///   whether Shift was held then, even after the time; when that window has
///   gone meanwhile, it acts nowhere.
/// - In the app's windows, a press with Shift that matches no binding of
///   its own matches its binding without Shift, and says Shift was held, so
///   Shift-J and Shift-L skip by the Playback tab's Shift units; never in a
///   text field (`match(_:)`).
///
/// The clock and the timer a waiting single press waits on are passed in,
/// so tests decide when time passes and never wait themselves.
@MainActor
final class ShortcutPressDispatcher {

    // MARK: Types

    /// Reads the time on the events' time line: seconds since the Mac
    /// started, which `NSEvent.timestamp` counts too.
    typealias Clock = @MainActor () -> TimeInterval

    /// Starts a one-shot timer that calls `fire` after `delay` seconds,
    /// unless it is cancelled first.
    typealias StartTimer = @MainActor (_ delay: TimeInterval, _ fire: @escaping @MainActor @Sendable () -> Void) -> any PressTimer

    /// The single action a double action escalates, if any
    /// (`ShortcutAction.escalates`).
    typealias Escalation = @Sendable (ShortcutAction) -> ShortcutAction?

    /// One key press, as the shortcut manager hands it over.
    struct Press {
        /// The key and the modifiers held, as one press of a binding
        /// (`KeyBinding.from(event:)`); nil for a key no binding can name,
        /// which still counts as another key.
        var stroke: KeyBinding?
        /// When the key went down: the event's own timestamp, in seconds
        /// since the Mac started.
        var time: TimeInterval
        /// The window that was key, or nil when none was.
        var window: NSWindow?
        /// The scope whose shortcuts the press matches, or nil where none
        /// do, as in a sheet over an audio editor.
        var scope: ShortcutScope?
        /// Whether a text field or text view had the keyboard.
        var textInputIsFocused: Bool
        /// Whether the press is a held key's automatic repeat.
        var isRepeat: Bool
    }

    /// An action a press triggered, for the manager to post.
    struct Trigger {
        /// The action.
        let action: ShortcutAction
        /// The binding pressed, a double press's included, as the sleep
        /// timer's log names it.
        let binding: KeyBinding
        /// Whether Shift was held beyond the binding's own modifiers.
        let shiftHeld: Bool
        /// The window the key was pressed in, where the action acts; nil
        /// when none was key.
        let window: NSWindow?
    }

    // MARK: State

    /// The bindings in force, by scope and key.
    private(set) var index: Index
    /// How soon a second press must follow the first to make a double
    /// press, in seconds, read at each press.
    private let doublePressTime: @MainActor () -> TimeInterval
    /// The time now, on the events' time line.
    private let clock: Clock
    /// Starts the timer a waiting single press waits on.
    private let startTimer: StartTimer
    /// The action a double action escalates, if any: `escalates`, unless a
    /// test passes a table of its own.
    private let escalation: Escalation
    /// Posts a triggered action.
    private let perform: @MainActor (Trigger) -> Void

    /// What the last presses left: nothing, a first press waiting for its
    /// second, or a double press whose further presses are ignored.
    private var state = State.idle
    /// The timer a waiting single press waits on, while one waits.
    private var timer: (any PressTimer)?
    /// Counts the waits begun, so that a timer of an earlier one does
    /// nothing if it fires after all.
    private var waitNumber = 0

    /// A dispatcher for `bindings`, posting each triggered action through
    /// `perform`.
    /// - Parameters:
    ///   - bindings: Every action's keys in force.
    ///   - doublePressTime: Reads the double-press time, in seconds.
    ///   - clock: Reads the time on the events' time line; the Mac's uptime
    ///     unless a test passes its own.
    ///   - startTimer: Starts the timer a waiting single press waits on; a
    ///     work item on the main queue unless a test passes its own.
    ///   - escalation: The action a double action escalates; `escalates`
    ///     unless a test passes a table of its own.
    ///   - perform: Posts a triggered action.
    init(
        bindings: [ShortcutAction: [KeyBinding]],
        doublePressTime: @escaping @MainActor () -> TimeInterval,
        clock: @escaping Clock = { ProcessInfo.processInfo.systemUptime },
        startTimer: @escaping StartTimer = { delay, fire in MainQueuePressTimer(delay: delay, fire: fire) },
        escalation: @escaping Escalation = { $0.escalates },
        perform: @escaping @MainActor (Trigger) -> Void
    ) {
        self.doublePressTime = doublePressTime
        self.clock = clock
        self.startTimer = startTimer
        self.escalation = escalation
        self.perform = perform
        index = Index(bindings, escalation: escalation)
    }

    /// Takes `bindings` as the bindings in force. A single press still
    /// waiting acts at once, and a double press's further presses count
    /// again, since the keys they were pressed for may have changed.
    func rebuild(from bindings: [ShortcutAction: [KeyBinding]]) {
        index = Index(bindings, escalation: escalation)
        runWaitingSingle()
        state = .idle
    }

    // MARK: A Press

    /// Decides what `press` does, posting what it triggers, and returns
    /// whether the press was a shortcut's, which goes no further; false
    /// leaves it to the window, its menus, and its first responder.
    @discardableResult
    func handle(_ press: Press) -> Bool {
        let match = match(press)
        switch state {
        case .waiting(let first):
            // The same key again, as a shortcut: held, its repeats are
            // ignored; pressed again in time, it is the double press.
            if match != nil, first.isPressOfSameKey(press) {
                if press.isRepeat {
                    return true
                }
                if press.time - first.time < doublePressTime() {
                    endWait()
                    state = .afterDouble(Pressed(of: first, lastPressedAt: press.time))
                    trigger(first.double, binding: first.doubleBinding, shiftHeld: first.shiftHeld, window: press.window)
                    return true
                }
            }
            // Any other key, or this one too late: the single press waiting
            // acts first.
            runWaitingSingle()
        case .afterDouble(let pressed):
            // The same key again within the time of its last press, held or
            // pressed: ignored.
            if match != nil, pressed.isPressOfSameKey(press), press.time - pressed.lastPressedAt < doublePressTime() {
                state = .afterDouble(Pressed(of: pressed, lastPressedAt: press.time))
                return true
            }
            state = .idle
        case .idle:
            break
        }
        return act(on: press, match: match)
    }

    /// Acts on `press`, the first press of its key, or a repeat, now that
    /// no earlier press is waiting on it.
    private func act(on press: Press, match: Match?) -> Bool {
        guard let match, let stroke = press.stroke, let scope = press.scope else { return false }
        if press.isRepeat {
            // A held key repeats its single action, unless the key has a
            // double action, whose presses its repeats would fake.
            if match.actions.double == nil, let single = match.actions.single {
                trigger(single, binding: match.stroke, shiftHeld: match.shiftHeld, window: press.window)
            }
            return true
        }
        guard let double = match.actions.double else {
            if let single = match.actions.single {
                trigger(single, binding: match.stroke, shiftHeld: match.shiftHeld, window: press.window)
            }
            return true
        }
        let first = FirstPress(
            stroke: stroke,
            scope: scope,
            window: PressWindow(press.window),
            time: press.time,
            matchedStroke: match.stroke,
            shiftHeld: match.shiftHeld,
            single: match.actions.single,
            singleWaits: match.actions.singleWaits,
            double: double
        )
        state = .waiting(first)
        if first.singleWaits {
            startWaiting(for: first)
        } else if let single = first.single {
            // The double action escalates the single one, which acts at once.
            trigger(single, binding: match.stroke, shiftHeld: match.shiftHeld, window: press.window)
        }
        return true
    }

    // MARK: A Single Press Waiting

    /// Starts the timer `first`'s single press waits on, to run it when the
    /// double-press time after the press is up.
    private func startWaiting(for first: FirstPress) {
        timer?.cancel()
        waitNumber += 1
        let wait = waitNumber
        let delay = max(0, first.time + doublePressTime() - clock())
        timer = startTimer(delay) { [weak self] in
            self?.timeIsUp(forWait: wait)
        }
    }

    /// Runs the single press waiting on the timer of wait number `wait`,
    /// unless that wait is over.
    private func timeIsUp(forWait wait: Int) {
        guard wait == waitNumber else { return }
        runWaitingSingle()
    }

    /// Runs the single action of the first press waiting, if it waits, in
    /// the window it was pressed in, and ends the wait.
    private func runWaitingSingle() {
        guard case .waiting(let first) = state else { return }
        endWait()
        guard first.singleWaits, let single = first.single, !first.window.isGone else { return }
        trigger(single, binding: first.matchedStroke, shiftHeld: first.shiftHeld, window: first.window.window)
    }

    /// Ends the wait of a first press, cancelling its timer.
    private func endWait() {
        timer?.cancel()
        timer = nil
        waitNumber += 1
        state = .idle
    }

    // MARK: Matching

    /// What a press matched.
    private struct Match {
        /// The binding it matched, as a single press.
        let stroke: KeyBinding
        /// That key's actions in the press's scope.
        let actions: Index.Actions
        /// Whether Shift was held beyond the binding's own modifiers.
        let shiftHeld: Bool
    }

    /// The shortcut `press` matches, or nil: none for a key no binding
    /// names, where no shortcuts match, or for a key a focused text field
    /// keeps, which never counts as a press.
    ///
    /// A press with Shift that matches no binding of its own, single or
    /// double, matches its binding without Shift, saying that Shift was
    /// held (finding 4 of the design): Shift-J skips back by the Shift unit.
    /// Never in a focused text field, where Shift with an arrow selects text
    /// and Shift with a letter types a capital, and only in a scope that
    /// allows it (`ShortcutScope.matchesShiftBeyondItsBindings`).
    private func match(_ press: Press) -> Match? {
        guard let stroke = press.stroke, let scope = press.scope,
              KeyboardShortcutManager.shouldHandle(binding: stroke, whenTextInputIsFocused: press.textInputIsFocused) else {
            return nil
        }
        if let actions = index.actions(for: stroke, in: scope) {
            return Match(stroke: stroke, actions: actions, shiftHeld: false)
        }
        guard stroke.shift, !press.textInputIsFocused, scope.matchesShiftBeyondItsBindings else { return nil }
        var unshifted = stroke
        unshifted.shift = false
        guard let actions = index.actions(for: unshifted, in: scope) else { return nil }
        return Match(
            stroke: unshifted,
            actions: actions,
            shiftHeld: KeyboardShortcutManager.hasExtraShift(eventHasShift: stroke.shift, bindingRequiresShift: unshifted.shift)
        )
    }

    /// Posts `action`, triggered by `binding` in `window`.
    private func trigger(_ action: ShortcutAction, binding: KeyBinding, shiftHeld: Bool, window: NSWindow?) {
        perform(Trigger(action: action, binding: binding, shiftHeld: shiftHeld, window: window))
    }
}

// MARK: - The Index

extension ShortcutPressDispatcher {
    /// Each key's single and double action in force, for each scope, built
    /// in the order Settings lists the actions, so the same bindings always
    /// make the same index. The bindings in force give each key one owner
    /// in each scope (`ShortcutEdits.effectiveBindings(defaults:)`), its
    /// single and double presses counting as two keys; should two actions
    /// hold one anyway, the one Settings lists first has it here.
    struct Index {
        /// One key's actions in one scope.
        struct Actions: Equatable {
            /// The action a single press runs, if any.
            var single: ShortcutAction?
            /// The action a double press runs, if any.
            var double: ShortcutAction?
            /// Whether the single press waits out the double-press time
            /// before it acts: the key has a single action and a double
            /// action that does not escalate it.
            var singleWaits = false
        }

        /// A key whose single press waits, and the two actions that make it.
        struct WaitingKey: Equatable {
            /// The scope it waits in.
            let scope: ShortcutScope
            /// The key, as a single press.
            let stroke: KeyBinding
            /// The action its single press runs, after the wait.
            let single: ShortcutAction
            /// The action its double press runs.
            let double: ShortcutAction
        }

        /// Each scope's keys, with their actions.
        private var actionsByScope: [ShortcutScope: [KeyBinding: Actions]] = [:]
        /// Every key whose single press waits, in the order Settings lists
        /// their actions.
        private(set) var waitingKeys: [WaitingKey] = []

        /// The index of `bindings`, telling which double actions escalate
        /// which single ones by `escalation`.
        init(_ bindings: [ShortcutAction: [KeyBinding]], escalation: Escalation = { $0.escalates }) {
            var keyOrder: [(scope: ShortcutScope, stroke: KeyBinding)] = []
            for action in ShortcutAction.allCases {
                for binding in bindings[action] ?? [] {
                    let stroke = binding.stroke
                    var actions = actionsByScope[action.scope]?[stroke] ?? Actions()
                    if actions == Actions() {
                        keyOrder.append((action.scope, stroke))
                    }
                    if binding.isDoublePress {
                        actions.double = actions.double ?? action
                    } else {
                        actions.single = actions.single ?? action
                    }
                    actionsByScope[action.scope, default: [:]][stroke] = actions
                }
            }
            // Which single presses wait, now that every key's actions are known.
            for (scope, stroke) in keyOrder {
                guard var actions = actionsByScope[scope]?[stroke], let single = actions.single, let double = actions.double else {
                    continue
                }
                actions.singleWaits = double != single && escalation(double) != single
                actionsByScope[scope]?[stroke] = actions
                if actions.singleWaits {
                    waitingKeys.append(WaitingKey(scope: scope, stroke: stroke, single: single, double: double))
                }
            }
        }

        /// The actions of the key `stroke`, pressed in `scope`, or nil when
        /// it has none there.
        func actions(for stroke: KeyBinding, in scope: ShortcutScope) -> Actions? {
            actionsByScope[scope]?[stroke.stroke]
        }
    }
}

// MARK: - The Presses Remembered

extension ShortcutPressDispatcher {
    /// What the last presses left.
    private enum State {
        /// Nothing waits.
        case idle
        /// The first press of a key with a double action, waiting to see
        /// whether its second follows within the time.
        case waiting(FirstPress)
        /// A double press acted; its key's further quick presses are ignored.
        case afterDouble(Pressed)
    }

    /// The first press of a key with a double action.
    private struct FirstPress {
        /// The key pressed, as a single press.
        let stroke: KeyBinding
        /// The scope it was pressed in.
        let scope: ShortcutScope
        /// The window it was pressed in.
        let window: PressWindow
        /// When it was pressed.
        let time: TimeInterval
        /// The binding it matched, as a single press.
        let matchedStroke: KeyBinding
        /// Whether Shift was held beyond the binding's own modifiers.
        let shiftHeld: Bool
        /// The key's single action, if any.
        let single: ShortcutAction?
        /// Whether that single action waits for the time to pass, rather
        /// than having acted at once.
        let singleWaits: Bool
        /// The key's double action.
        let double: ShortcutAction

        /// The double press's binding, as the sleep timer's log names it.
        var doubleBinding: KeyBinding {
            matchedStroke.asDoublePress(true)
        }

        /// Whether `press` is of the same key, with the same modifiers, in
        /// the same scope and window.
        func isPressOfSameKey(_ press: Press) -> Bool {
            press.stroke == stroke && press.scope == scope && window.isSame(as: press.window)
        }
    }

    /// A key whose double press acted, and when it was last pressed.
    private struct Pressed {
        /// The key, as a single press.
        let stroke: KeyBinding
        /// The scope it was pressed in.
        let scope: ShortcutScope
        /// The window it was pressed in.
        let window: PressWindow
        /// When it was last pressed: the second press, or a further one
        /// ignored since.
        let lastPressedAt: TimeInterval

        /// The key of `first`, last pressed at `time`.
        init(of first: FirstPress, lastPressedAt time: TimeInterval) {
            stroke = first.stroke
            scope = first.scope
            window = first.window
            lastPressedAt = time
        }

        /// The same key as `pressed`, last pressed at `time`.
        init(of pressed: Pressed, lastPressedAt time: TimeInterval) {
            stroke = pressed.stroke
            scope = pressed.scope
            window = pressed.window
            lastPressedAt = time
        }

        /// Whether `press` is of the same key, with the same modifiers, in
        /// the same scope and window.
        func isPressOfSameKey(_ press: Press) -> Bool {
            press.stroke == stroke && press.scope == scope && window.isSame(as: press.window)
        }
    }

    /// The window a press was made in, held weakly, so a waiting press never
    /// keeps a closed window alive, and known by its identity.
    private struct PressWindow {
        /// The window, while it lives.
        weak var window: NSWindow?
        /// Which window it was, or nil when none was key.
        let identity: ObjectIdentifier?

        /// The window `window`, or none.
        init(_ window: NSWindow?) {
            self.window = window
            identity = window.map(ObjectIdentifier.init)
        }

        /// Whether `other` is this window, or both are none. A window that
        /// has gone is no window pressed in since.
        func isSame(as other: NSWindow?) -> Bool {
            identity == other.map(ObjectIdentifier.init) && !isGone
        }

        /// Whether the press had a window, which has gone since.
        var isGone: Bool {
            identity != nil && window == nil
        }
    }
}

// MARK: - Trying a Double Press

/// Try a Double Press (FR12, section 6.2 of the design): for five seconds,
/// the next two presses of any key are no shortcuts, and how far apart they
/// came is measured against the double-press time, so the user can set the
/// time by ear. The timer is passed in, so tests never wait.
@MainActor
final class DoublePressTrial {
    /// What the two presses made.
    enum Outcome: Equatable {
        /// One key pressed twice within the double-press time.
        case doublePress
        /// One key pressed twice, this many seconds apart: too far apart.
        case tooFarApart(TimeInterval)
        /// Two different keys.
        case differentKeys
        /// Fewer than two presses before the trial's time ran out.
        case noSecondPress
    }

    /// How long a trial waits for its two presses: five seconds.
    static let length: TimeInterval = 5

    /// How soon a second press must follow the first to make a double press.
    private let doublePressTime: TimeInterval
    /// Starts the trial's timer.
    private let startTimer: ShortcutPressDispatcher.StartTimer
    /// Called once, when the trial ends.
    private let finish: @MainActor (Outcome) -> Void
    /// The first press, with its key, or nil for a key no binding names.
    private var first: (stroke: KeyBinding?, time: TimeInterval)?
    /// The timer ending the trial when its time is up.
    private var timer: (any PressTimer)?
    /// Whether the trial has ended.
    private(set) var hasEnded = false

    /// A trial measuring against `doublePressTime`, ending through `finish`.
    init(
        doublePressTime: TimeInterval,
        startTimer: @escaping ShortcutPressDispatcher.StartTimer = { delay, fire in MainQueuePressTimer(delay: delay, fire: fire) },
        finish: @escaping @MainActor (Outcome) -> Void
    ) {
        self.doublePressTime = doublePressTime
        self.startTimer = startTimer
        self.finish = finish
    }

    /// Starts the trial's five seconds.
    func start() {
        timer = startTimer(Self.length) { [weak self] in
            self?.timeIsUp()
        }
    }

    /// Takes one key press made during the trial, as no shortcut: the key
    /// with its modifiers (`stroke`, nil for a key no binding names), when
    /// it went down, and whether it is a held key's repeat, which is
    /// ignored. Returns whether the trial took it: every press until the
    /// trial ends.
    @discardableResult
    func take(_ stroke: KeyBinding?, at time: TimeInterval, isRepeat: Bool) -> Bool {
        guard !hasEnded else { return false }
        if isRepeat {
            return true
        }
        guard let first else {
            self.first = (stroke, time)
            return true
        }
        let apart = time - first.time
        if stroke == nil || stroke != first.stroke {
            end(.differentKeys)
        } else if apart < doublePressTime {
            end(.doublePress)
        } else {
            end(.tooFarApart(apart))
        }
        return true
    }

    /// Ends the trial without an outcome.
    func cancel() {
        timer?.cancel()
        timer = nil
        hasEnded = true
    }

    /// Ends the trial once its time is up without two presses.
    private func timeIsUp() {
        guard !hasEnded else { return }
        end(.noSecondPress)
    }

    /// Ends the trial with `outcome`.
    private func end(_ outcome: Outcome) {
        cancel()
        finish(outcome)
    }
}

// MARK: - The Timer

/// A one-shot timer a waiting single press waits on, cancelled when a
/// second press, or another key, comes first.
@MainActor
protocol PressTimer: AnyObject {
    /// Keeps the timer from firing.
    func cancel()
}

/// The app's press timer: a work item on the main queue, which runs while a
/// menu is open or a key is held too.
@MainActor
final class MainQueuePressTimer: PressTimer {
    /// The work item that fires.
    private let workItem: DispatchWorkItem

    /// Starts a timer that calls `fire` on the main actor after `delay`
    /// seconds.
    init(delay: TimeInterval, fire: @escaping @MainActor @Sendable () -> Void) {
        workItem = DispatchWorkItem {
            MainActor.assumeIsolated { fire() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    func cancel() {
        workItem.cancel()
    }
}

// MARK: - Escalation

extension ShortcutAction {
    /// The single actions double actions escalate (FR12, section 2.3 of the
    /// design): a key with such a pair acts on its first press at once, and
    /// its double press takes over, where any other pair makes the single
    /// press wait. The two full summaries are the only ones (FR12's branch
    /// C): Where Am I? Full Summary escalates Where Am I?, and Speak Full
    /// Info escalates Speak Info, so the first W or I starts the brief
    /// summary at once and a second within the double-press time switches
    /// to the full one. The rule follows the actions, whatever keys the user
    /// gives them, and there is no setting for it; a later escalation would
    /// join the table here.
    static let escalations: [ShortcutAction: ShortcutAction] = [
        .whereAmIFull: .whereAmI,
        .speakFullInfo: .speakInfo,
    ]

    /// The single action this double action escalates, if any. An action
    /// on both presses of one key counts as its own escalation, which the
    /// dispatcher's index sees for itself.
    var escalates: ShortcutAction? {
        Self.escalations[self]
    }
}
