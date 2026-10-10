import AppKit
import Combine
import XCTest
@testable import TextMouth

/// The press dispatcher (FR12, section 2.3 of the design): the four kinds of
/// key, a single action only, a double action only, a single action with a
/// double that escalates it, and a single action with an unrelated double;
/// and the rules for every key: the boundary of the double-press time,
/// another key while a single press waits, a second window, a text field,
/// a held key's repeats, the presses after a double, and the window a
/// waiting press keeps. The test passes the clock and fires the timers
/// itself, so nothing here waits.
@MainActor
final class ShortcutPressDispatcherTests: XCTestCase {

    // MARK: - Keys Used Below

    private let plainJ = KeyBinding(key: "j")
    private let jTwice = KeyBinding(key: "j", isDoublePress: true)
    private let plainW = KeyBinding(key: "w")
    private let wTwice = KeyBinding(key: "w", isDoublePress: true)
    private let plainK = KeyBinding(key: "k")
    private let commandI = KeyBinding(key: "i", command: true)
    private let commandITwice = KeyBinding(key: "i", command: true, isDoublePress: true)

    /// The double-press time every test uses, in seconds.
    private let time: TimeInterval = 0.5

    // MARK: - A Single Action Only

    /// A key with a single action only acts at once on every press, however
    /// quick: no default key waits.
    func testASingleActionActsAtOnceOnEveryPress() {
        let harness = Harness([.whereAmI: [plainW]])

        XCTAssertTrue(harness.press(plainW, at: 10))
        XCTAssertTrue(harness.press(plainW, at: 10.1))

        XCTAssertEqual(harness.performed, [.whereAmI, .whereAmI])
        XCTAssertEqual(harness.timers.count, 0, "a key with no double action never starts a timer")
    }

    // MARK: - A Double Action Only

    /// A key with a double action only takes its first press and does
    /// nothing with it; a second press within the time runs the double
    /// action, and with no second press nothing happens.
    func testADoubleActionOnlyActsOnTheSecondPressAlone() {
        let harness = Harness([.goToLibrary: [jTwice]])

        XCTAssertTrue(harness.press(plainJ, at: 10), "the first press is taken")
        XCTAssertEqual(harness.performed, [])
        XCTAssertTrue(harness.press(plainJ, at: 10.3))
        XCTAssertEqual(harness.performed, [.goToLibrary])

        XCTAssertTrue(harness.press(plainJ, at: 20))
        harness.fireTimers()
        XCTAssertFalse(harness.press(KeyBinding(key: "q"), at: 21), "another key goes on")
        XCTAssertEqual(harness.performed, [.goToLibrary], "a lone first press did nothing")
        XCTAssertEqual(harness.timers.count, 0, "nothing waits on a timer")
    }

    // MARK: - A Double Action That Escalates the Single One

    /// With a double action that escalates the single one, the first press
    /// acts at once and a second within the time runs the double action;
    /// a third quick press is ignored rather than starting over.
    func testAnEscalatingDoubleLetsTheFirstPressActAtOnce() {
        let harness = Harness([.speakInfo: [plainW], .showBookInfo: [wTwice]], escalations: [.showBookInfo: .speakInfo])

        harness.press(plainW, at: 10)
        XCTAssertEqual(harness.performed, [.speakInfo], "the first press acts at once")
        harness.press(plainW, at: 10.3)
        XCTAssertEqual(harness.performed, [.speakInfo, .showBookInfo])
        XCTAssertTrue(harness.press(plainW, at: 10.6))
        XCTAssertEqual(harness.performed, [.speakInfo, .showBookInfo], "the third quick press is ignored")
        XCTAssertEqual(harness.timers.count, 0, "nothing waits")
    }

    /// An action on both presses of one key is its own escalation: the
    /// first press acts at once, and the second runs it again.
    func testAnActionOnBothPressesOfOneKeyIsItsOwnEscalation() {
        let harness = Harness([.whereAmI: [plainW, wTwice]])

        harness.press(plainW, at: 10)
        harness.press(plainW, at: 10.2)

        XCTAssertEqual(harness.performed, [.whereAmI, .whereAmI])
        XCTAssertEqual(harness.index.waitingKeys, [])
    }

    /// No action escalates another until FR12's branch C gives the full
    /// summaries actions of their own.
    func testNoActionEscalatesAnotherYet() {
        XCTAssertEqual(ShortcutAction.escalations, [:])
        XCTAssertTrue(ShortcutAction.allCases.allSatisfy { $0.escalates == nil })
    }

    // MARK: - An Unrelated Double Action

    /// With an unrelated double action, the first press waits: a second
    /// within the time runs the double action alone, and the single action
    /// never runs.
    func testAnUnrelatedDoubleMakesTheFirstPressWait() throws {
        let harness = Harness([.skipBackward: [plainJ], .goToLibrary: [jTwice]])

        harness.press(plainJ, at: 10)
        XCTAssertEqual(harness.performed, [], "the single press waits")
        let timer = try XCTUnwrap(harness.timers.last)
        XCTAssertEqual(timer.delay, time, accuracy: 1e-9)
        harness.press(plainJ, at: 10.4)

        XCTAssertEqual(harness.performed, [.goToLibrary])
        XCTAssertTrue(timer.isCancelled)
        harness.fireTimers()
        XCTAssertEqual(harness.performed, [.goToLibrary], "the single action never ran")
    }

    /// With no second press, the waiting single action runs once the time
    /// is up, and only once.
    func testAWaitingSinglePressActsWhenTheTimeIsUp() throws {
        let harness = Harness([.skipBackward: [plainJ], .goToLibrary: [jTwice]])
        // The press is handed over a tenth of a second after the key went down.
        harness.now = 10.1

        harness.dispatcher.handle(harness.makePress(plainJ, at: 10))

        XCTAssertEqual(try XCTUnwrap(harness.timers.last).delay, 0.4, accuracy: 1e-9, "the wait counts from the key press")
        harness.fireTimers()
        harness.fireTimers()
        XCTAssertEqual(harness.performed, [.skipBackward])
    }

    /// Another key pressed while a single press waits runs it at once, then
    /// acts itself: the order the keys were pressed in.
    func testAnotherKeyRunsTheWaitingSinglePressAtOnce() {
        let harness = Harness([.skipBackward: [plainJ], .goToLibrary: [jTwice], .togglePlayback: [plainK]])

        harness.press(plainJ, at: 10)
        harness.press(plainK, at: 10.1)

        XCTAssertEqual(harness.performed, [.skipBackward, .togglePlayback])
        XCTAssertTrue(harness.timers.allSatisfy(\.isCancelled))
    }

    /// A key no shortcut has, pressed while a single press waits, runs it at
    /// once too, and goes on to the window.
    func testAKeyThatIsNoShortcutRunsTheWaitingSinglePressToo() {
        let harness = Harness([.skipBackward: [plainJ], .goToLibrary: [jTwice]])

        harness.press(plainJ, at: 10)
        XCTAssertFalse(harness.press(KeyBinding(key: "q"), at: 10.1))
        XCTAssertEqual(harness.performed, [.skipBackward])

        harness.press(plainJ, at: 20)
        XCTAssertFalse(harness.press(nil, at: 20.1), "a key no binding names")
        XCTAssertEqual(harness.performed, [.skipBackward, .skipBackward])
    }

    // MARK: - The Boundary

    /// A second press at exactly the double-press time is a single press:
    /// the first one's single action runs, and the second press waits in its
    /// turn; just inside the time, it is the double press.
    func testAPressAtExactlyTheTimeIsASinglePress() {
        let harness = Harness([.skipBackward: [plainJ], .goToLibrary: [jTwice]])

        harness.press(plainJ, at: 10)
        harness.press(plainJ, at: 10 + time)
        XCTAssertEqual(harness.performed, [.skipBackward])
        harness.fireTimers()
        XCTAssertEqual(harness.performed, [.skipBackward, .skipBackward])

        harness.press(plainJ, at: 20)
        harness.press(plainJ, at: 20 + time - 0.001)
        XCTAssertEqual(harness.performed, [.skipBackward, .skipBackward, .goToLibrary])
    }

    /// The double-press time is read at each press, so a change of it
    /// counts from the next press.
    func testTheTimeIsReadAtEachPress() {
        let harness = Harness([.skipBackward: [plainJ], .goToLibrary: [jTwice]])
        harness.doublePressTime = 1.5

        harness.press(plainJ, at: 10)
        harness.press(plainJ, at: 11.2)

        XCTAssertEqual(harness.performed, [.goToLibrary])
    }

    // MARK: - A Second Window

    /// The same key pressed in another window within the time is no double
    /// press: the first press's single action runs in its own window, and
    /// the second press waits in the other.
    func testTheSameKeyInAnotherWindowIsNoDoublePress() {
        let harness = Harness([.skipBackward: [plainJ], .goToLibrary: [jTwice]])
        let first = makeWindow()
        let second = makeWindow()

        harness.press(plainJ, at: 10, in: first)
        harness.press(plainJ, at: 10.2, in: second)
        XCTAssertEqual(harness.triggers.map(\.action), [.skipBackward])
        XCTAssertTrue(harness.triggers.first?.window === first)

        harness.fireTimers()
        XCTAssertEqual(harness.triggers.map(\.action), [.skipBackward, .skipBackward])
        XCTAssertTrue(harness.triggers.last?.window === second)
    }

    /// A waiting single press acts in the window it was pressed in, even
    /// when the time is up after another window has become key; a double
    /// press acts in its window.
    func testAWaitingPressKeepsItsWindow() {
        let harness = Harness([.skipBackward: [plainJ], .goToLibrary: [jTwice]])
        let window = makeWindow()

        harness.press(plainJ, at: 10, in: window)
        harness.fireTimers()
        harness.press(plainJ, at: 20, in: window)
        harness.press(plainJ, at: 20.2, in: window)

        XCTAssertEqual(harness.triggers.map(\.action), [.skipBackward, .goToLibrary])
        XCTAssertTrue(harness.triggers.allSatisfy { $0.window === window })
    }

    /// A waiting single press whose window has closed and gone meanwhile
    /// acts nowhere, rather than in whichever window is key.
    func testAWaitingPressWhoseWindowHasGoneActsNowhere() throws {
        let harness = Harness([.skipBackward: [plainJ], .goToLibrary: [jTwice]])
        weak var pressedIn: NSWindow?
        autoreleasepool {
            let window = makeWindow(releasedByTheTest: true)
            pressedIn = window
            harness.press(plainJ, at: 10, in: window)
        }
        guard pressedIn == nil else {
            throw XCTSkip("AppKit kept the window alive after the test let it go")
        }

        harness.fireTimers()

        XCTAssertEqual(harness.performed, [])
    }

    // MARK: - Text Fields

    /// A plain key typed in a focused text field never counts as a press:
    /// it goes on to the field, and runs a waiting single press at once, as
    /// any other key does; it never makes the second press of a double.
    func testAKeyTypedInAFieldNeverCountsAsAPress() {
        let harness = Harness([.skipBackward: [plainJ], .goToLibrary: [jTwice]])

        harness.press(plainJ, at: 10)
        XCTAssertFalse(harness.press(plainJ, at: 10.1, inTextField: true), "the field keeps its J")
        XCTAssertEqual(harness.performed, [.skipBackward])

        XCTAssertFalse(harness.press(plainJ, at: 20, inTextField: true))
        XCTAssertFalse(harness.press(plainJ, at: 20.1, inTextField: true))
        XCTAssertEqual(harness.performed, [.skipBackward], "two J's typed are no double press")
        XCTAssertEqual(harness.timers.count, 1)
    }

    /// A double binding with Command acts from a text field, as single ones
    /// do; a key the field edits with, such as Command-A, never counts.
    func testACommandDoublePressActsFromAField() {
        let harness = Harness([
            .showBookInfo: [commandI], .goToLibrary: [commandITwice],
            .selectAll: [KeyBinding(key: "a", command: true, isDoublePress: true)],
        ])

        harness.press(commandI, at: 10, inTextField: true)
        harness.press(commandI, at: 10.2, inTextField: true)
        XCTAssertEqual(harness.performed, [.goToLibrary])

        let commandA = KeyBinding(key: "a", command: true)
        XCTAssertFalse(harness.press(commandA, at: 20, inTextField: true))
        XCTAssertFalse(harness.press(commandA, at: 20.1, inTextField: true))
        XCTAssertEqual(harness.performed, [.goToLibrary], "Command-A stays the field's")
    }

    // MARK: - Repeats

    /// A held key's repeats are taken and ignored for a key with a double
    /// action: they never make a double press, and the waiting single
    /// press still acts when the time is up.
    func testRepeatsOfAKeyWithADoubleActionAreIgnored() {
        let harness = Harness([.skipBackward: [plainJ], .goToLibrary: [jTwice]])

        harness.press(plainJ, at: 10)
        XCTAssertTrue(harness.press(plainJ, at: 10.3, isRepeat: true))
        XCTAssertTrue(harness.press(plainJ, at: 10.4, isRepeat: true))
        harness.fireTimers()
        XCTAssertTrue(harness.press(plainJ, at: 10.6, isRepeat: true))

        XCTAssertEqual(harness.performed, [.skipBackward])
    }

    /// Any other key repeats its action as it always has.
    func testRepeatsOfAKeyWithoutADoubleActionAct() {
        let harness = Harness([.skipBackward: [plainJ]])

        harness.press(plainJ, at: 10)
        harness.press(plainJ, at: 10.4, isRepeat: true)
        harness.press(plainJ, at: 10.45, isRepeat: true)

        XCTAssertEqual(harness.performed, [.skipBackward, .skipBackward, .skipBackward])
    }

    // MARK: - After a Double Press

    /// After a double press acts, each further press of its key within the
    /// time of the one before is ignored, held or pressed; a press after
    /// that starts over.
    func testFurtherPressesAfterADoubleAreIgnored() {
        let harness = Harness([.skipBackward: [plainJ], .goToLibrary: [jTwice]])

        harness.press(plainJ, at: 10)
        harness.press(plainJ, at: 10.3)
        XCTAssertTrue(harness.press(plainJ, at: 10.6))
        XCTAssertTrue(harness.press(plainJ, at: 11.0))
        XCTAssertTrue(harness.press(plainJ, at: 11.2, isRepeat: true))
        XCTAssertEqual(harness.performed, [.goToLibrary])

        harness.press(plainJ, at: 12)
        harness.fireTimers()
        XCTAssertEqual(harness.performed, [.goToLibrary, .skipBackward])
    }

    /// Another key ends the run of ignored presses at once.
    func testAnotherKeyEndsTheIgnoredPresses() {
        let harness = Harness([.skipBackward: [plainJ], .goToLibrary: [jTwice], .togglePlayback: [plainK]])

        harness.press(plainJ, at: 10)
        harness.press(plainJ, at: 10.2)
        harness.press(plainK, at: 10.3)
        harness.press(plainJ, at: 10.4)
        harness.fireTimers()

        XCTAssertEqual(harness.performed, [.goToLibrary, .togglePlayback, .skipBackward])
    }

    // MARK: - Scopes

    /// A key is one key in one scope: the same key in an audio editor
    /// window is the editor's, and no press in a sheet over an editor is a
    /// shortcut, though it runs a waiting single press at once.
    func testScopesKeepTheirKeysApart() {
        let harness = Harness([.skipBackward: [plainJ], .goToLibrary: [jTwice], .editorSkipBack: [plainJ]])

        harness.press(plainJ, at: 10, scope: .audioEditor)
        XCTAssertEqual(harness.performed, [.editorSkipBack], "the editor's J has no double action")

        harness.press(plainJ, at: 20)
        XCTAssertFalse(harness.press(plainJ, at: 20.1, scope: nil))
        XCTAssertEqual(harness.performed, [.editorSkipBack, .skipBackward])
    }

    // MARK: - The Index

    /// The index is built in the order Settings lists the actions, so the
    /// same bindings always make the same index: were one key on two
    /// actions, the one Settings lists first would have it, at every
    /// launch, where the walk through a dictionary took whichever came
    /// first in an order that can change.
    func testTheIndexNeverDependsOnADictionarysOrder() {
        let shiftCommandB = KeyBinding(key: "b", command: true, shift: true)
        for _ in 0..<20 {
            var bindings: [ShortcutAction: [KeyBinding]] = [:]
            for action in ShortcutAction.allCases.shuffled() {
                bindings[action] = ShortcutAction.defaultBindings[action] ?? []
            }
            bindings[.nextBookmark] = [shiftCommandB]

            let index = ShortcutPressDispatcher.Index(bindings)

            XCTAssertEqual(index.actions(for: shiftCommandB, in: .app)?.single, .nextBookmark)
        }
    }

    /// Each key's single and double actions, by scope; a single and a double
    /// press of one key are its two actions, never a clash.
    func testTheIndexHoldsEachKeysTwoActionsByScope() {
        let index = ShortcutPressDispatcher.Index([
            .skipBackward: [plainJ, KeyBinding(key: "leftArrow", command: true)],
            .goToLibrary: [jTwice],
            .editorSkipBack: [plainJ],
        ])

        XCTAssertEqual(index.actions(for: plainJ, in: .app), .init(single: .skipBackward, double: .goToLibrary, singleWaits: true))
        XCTAssertEqual(index.actions(for: jTwice, in: .app), index.actions(for: plainJ, in: .app), "looked up by its stroke")
        XCTAssertEqual(index.actions(for: plainJ, in: .audioEditor), .init(single: .editorSkipBack, double: nil, singleWaits: false))
        XCTAssertNil(index.actions(for: plainK, in: .app))
        XCTAssertEqual(index.waitingKeys, [.init(scope: .app, stroke: plainJ, single: .skipBackward, double: .goToLibrary)])
    }

    // MARK: - Through the Manager

    /// The manager hands each key press to the dispatcher with its
    /// timestamp, window, and whether it repeats, and posts what it decides,
    /// with the window; a waiting single press posts when the timer fires.
    /// The manager's index follows its bindings as they change.
    func testTheManagerPostsWhatTheDispatcherDecides() throws {
        let center = NotificationCenter()
        var timers: [HandFiredTimer] = []
        let manager = KeyboardShortcutManager(
            userDefaults: makeSandboxedPreferences("press-dispatcher-manager"),
            installsEventMonitor: false,
            notificationCenter: center,
            clock: { 10 },
            startTimer: { delay, fire in
                let timer = HandFiredTimer(delay: delay, fire: fire)
                timers.append(timer)
                return timer
            }
        )
        manager.addBinding(jTwice, to: .goToLibrary)
        var posted: [(action: String, window: NSWindow?)] = []
        let names = Set(ShortcutAction.allCases.map(\.notificationName))
        let subscription = Publishers.MergeMany(names.map { center.publisher(for: $0) }).sink { notification in
            posted.append((notification.userInfo?["action"] as? String ?? "", notification.userInfo?["sourceWindow"] as? NSWindow))
        }
        defer { subscription.cancel() }
        let window = makeWindow()

        XCTAssertTrue(manager.handleKeyEvent(try keyDown("j", keyCode: 38, at: 10), keyWindow: window, firstResponder: nil))
        XCTAssertTrue(posted.isEmpty, "J waits: Skip Backward's single press and Go to Library's double")
        XCTAssertTrue(manager.handleKeyEvent(try keyDown("j", keyCode: 38, at: 10.2), keyWindow: window, firstResponder: nil))
        XCTAssertEqual(posted.map(\.action), [ShortcutAction.goToLibrary.rawValue])
        XCTAssertTrue(posted.first?.window === window)

        XCTAssertTrue(manager.handleKeyEvent(try keyDown("j", keyCode: 38, at: 20), keyWindow: window, firstResponder: nil))
        XCTAssertTrue(manager.handleKeyEvent(try keyDown("j", keyCode: 38, at: 20.3, isRepeat: true), keyWindow: window, firstResponder: nil))
        timers.forEach { $0.fire() }
        XCTAssertEqual(posted.map(\.action), [ShortcutAction.goToLibrary.rawValue, ShortcutAction.skipBackward.rawValue])

        manager.resetToDefault(.goToLibrary)
        XCTAssertTrue(manager.handleKeyEvent(try keyDown("j", keyCode: 38, at: 30), keyWindow: window, firstResponder: nil))
        XCTAssertEqual(posted.last?.action, ShortcutAction.skipBackward.rawValue, "J acts at once again")
        XCTAssertEqual(posted.count, 3)
    }

    /// A change of the bindings runs a waiting single press at once, since
    /// its key may mean something else from then on.
    func testAChangeOfTheBindingsRunsAWaitingPress() {
        let harness = Harness([.skipBackward: [plainJ], .goToLibrary: [jTwice]])

        harness.press(plainJ, at: 10)
        harness.dispatcher.rebuild(from: [.skipBackward: [plainJ]])
        harness.press(plainJ, at: 10.2)

        XCTAssertEqual(harness.performed, [.skipBackward, .skipBackward])
    }

    // MARK: - Helpers

    /// A window the test owns, never shown.
    private func makeWindow(releasedByTheTest: Bool = false) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        // The test owns the window; AppKit must not release it again on close.
        window.isReleasedWhenClosed = false
        if !releasedByTheTest {
            addTeardownBlock { @MainActor in window.close() }
        }
        return window
    }

    /// A key-down event for `characters`, made up for the test, at `time`.
    private func keyDown(_ characters: String, keyCode: UInt16, at time: TimeInterval, isRepeat: Bool = false) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: time, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: isRepeat, keyCode: keyCode
        ))
    }
}

// MARK: - The Test's Dispatcher

/// A dispatcher for given bindings, with a clock the test sets and timers it
/// fires by hand, recording every action triggered. The dispatcher's
/// closures capture a record of their own rather than the harness, so none
/// can outlive what it reads.
@MainActor
final class Harness {
    /// What the dispatcher's closures read and write.
    private final class Record {
        /// The time the clock reads.
        var now: TimeInterval = 0
        /// The double-press time, read at each press.
        var doublePressTime: TimeInterval = 0.5
        /// Every timer started, oldest first.
        var timers: [HandFiredTimer] = []
        /// Every action triggered, oldest first.
        var triggers: [ShortcutPressDispatcher.Trigger] = []
    }

    /// The dispatcher under test.
    let dispatcher: ShortcutPressDispatcher
    /// What its closures read and write.
    private let record: Record

    /// The time the clock reads.
    var now: TimeInterval {
        get { record.now }
        set { record.now = newValue }
    }

    /// The double-press time, read at each press.
    var doublePressTime: TimeInterval {
        get { record.doublePressTime }
        set { record.doublePressTime = newValue }
    }

    /// Every timer started, oldest first.
    var timers: [HandFiredTimer] {
        record.timers
    }

    /// Every action triggered, with its window and Shift, oldest first.
    var triggers: [ShortcutPressDispatcher.Trigger] {
        record.triggers
    }

    /// The actions triggered, oldest first.
    var performed: [ShortcutAction] {
        triggers.map(\.action)
    }

    /// The dispatcher's index.
    var index: ShortcutPressDispatcher.Index {
        dispatcher.index
    }

    /// A dispatcher for `bindings`, where each double action of
    /// `escalations` escalates its single action.
    init(_ bindings: [ShortcutAction: [KeyBinding]], escalations: [ShortcutAction: ShortcutAction] = [:]) {
        let record = Record()
        self.record = record
        dispatcher = ShortcutPressDispatcher(
            bindings: bindings,
            doublePressTime: { record.doublePressTime },
            clock: { record.now },
            startTimer: { delay, fire in
                let timer = HandFiredTimer(delay: delay, fire: fire)
                record.timers.append(timer)
                return timer
            },
            escalation: { escalations[$0] },
            perform: { record.triggers.append($0) }
        )
    }

    /// A press of `binding`'s key, as the manager would hand it over; nil
    /// for a key no binding names.
    func makePress(
        _ binding: KeyBinding?,
        at time: TimeInterval,
        in window: NSWindow? = nil,
        scope: ShortcutScope? = .app,
        inTextField: Bool = false,
        isRepeat: Bool = false
    ) -> ShortcutPressDispatcher.Press {
        ShortcutPressDispatcher.Press(
            stroke: binding?.stroke,
            time: time,
            window: window,
            scope: scope,
            textInputIsFocused: inTextField,
            isRepeat: isRepeat
        )
    }

    /// Presses `binding`'s key at `time`, the clock reading that time, and
    /// returns whether the dispatcher took the press.
    @discardableResult
    func press(
        _ binding: KeyBinding?,
        at time: TimeInterval,
        in window: NSWindow? = nil,
        scope: ShortcutScope? = .app,
        inTextField: Bool = false,
        isRepeat: Bool = false
    ) -> Bool {
        now = time
        return dispatcher.handle(makePress(binding, at: time, in: window, scope: scope, inTextField: inTextField, isRepeat: isRepeat))
    }

    /// Fires every timer started and not cancelled, as the time running out
    /// would.
    func fireTimers() {
        timers.forEach { $0.fire() }
    }
}

/// A press timer the test fires by hand: firing a cancelled one, or one
/// already fired, does nothing.
@MainActor
final class HandFiredTimer: PressTimer {
    /// The delay it was started with, in seconds.
    let delay: TimeInterval
    /// What it calls when fired.
    private let action: @MainActor @Sendable () -> Void
    /// Whether it was cancelled.
    private(set) var isCancelled = false
    /// Whether it has fired.
    private(set) var hasFired = false

    /// A timer started with `delay`, calling `fire` when fired.
    init(delay: TimeInterval, fire: @escaping @MainActor @Sendable () -> Void) {
        self.delay = delay
        action = fire
    }

    func cancel() {
        isCancelled = true
    }

    /// Calls the timer's action, as its time running out would, unless it
    /// was cancelled or has fired already.
    func fire() {
        guard !isCancelled, !hasFired else { return }
        hasFired = true
        action()
    }
}
