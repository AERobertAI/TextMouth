// One AppKit case of Scripts/test/quit-while-held.py, run in a process of its
// own with a watchdog: a quit held while work must finish, as TextMouth's
// application delegate holds one, built from the app's real QuitRequest,
// QuitHold, and QuitFinisher sources.
//
// Usage: probe CASE. The case's verdict is its last line, "RESULT ...", and
// its exit code: 0 the case behaved as the fix says, 1 it did not, 2 the
// quit never ended (the watchdog), 3 the work was cut off. The "old-" cases
// are controls: they hold a quit the way TextMouth did before the fix, and
// are expected to show the fault (exit 2 or 3).
//
// Nothing is shown, played, recorded, or written. The probe is a plain AppKit
// program with no windows, and the watchdog ends it after 8 seconds at most.
import AppKit
import CoreServices

setvbuf(stdout, nil, _IONBF, 0)

/// The case this process runs.
let caseName = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "ask-queue"
/// When the process began, for the log's times.
let startedAt = Date()

/// Prints one line of the log with the time since the start.
func log(_ line: String) {
    print(String(format: "%5.0f ms  ", Date().timeIntervalSince(startedAt) * 1_000) + line)
}

/// The SDK's keyword of a quit's reason, `kAEQuitReason`, and the SDK's
/// reason of a log out: what loginwindow sends, taken from the headers.
let sdkQuitReasonKeyword = AEKeyword(kAEQuitReason)
let sdkLogOutReason = OSType(kAEReallyLogOut)

/// How the delegate holds a quit while the work runs.
enum Design {
    /// The fix: cancel, finish, ask again (`QuitFinisher`).
    case finisher
    /// Before the fix: answer `.terminateLater` and reply when the work ends
    /// (`QuitHold.hold`).
    case pending
}

/// The cases: how the design holds the quit, and what asks to quit.
struct Case {
    let design: Design
    /// Whether the case is a control that undoes the fix and must show the fault.
    let isControl: Bool
    /// What starts the quit, scheduled once the app is running.
    let start: @MainActor (Probe) -> Void
}

/// The delegate: the application delegate's decisions, over one piece of
/// work that takes 600 ms, and a log of what happened.
@MainActor
final class Probe: NSObject, NSApplicationDelegate {
    /// The case's design.
    var design: Design = .finisher
    /// How many times AppKit asked the delegate.
    var asked = 0
    /// What was said to the listener, in order.
    var told: [String] = []
    /// Whether the notice was taken down.
    var noticeTakenDown = false
    /// Whether the work ran to its end.
    var workEnded = false
    /// Whether the work has been started by a quit.
    var workStarted = false

    /// The finisher, saying into `told`, and asking again through the real helper.
    lazy var finisher = QuitFinisher(
        tell: { [unowned self] in
            told.append($0)
            log("told: \($0)")
        },
        finished: { [unowned self] in
            noticeTakenDown = true
            log("notice taken down")
        }
    )

    /// The work: 600 ms from its start, a quarter of the way to the watchdog.
    var work: QuitHold.Work {
        QuitHold.Work(
            isRunning: { [unowned self] in !workEnded },
            end: { [unowned self] in
                workStarted = true
                log("work started")
                try? await Task.sleep(for: .milliseconds(600))
                workEnded = true
                log("work ended")
            },
            longestWait: .seconds(3),
            kind: "probe work",
            finishing: { "keeping the probe's downloads" }
        )
    }

    /// The delegate's question, as `AppDelegate.applicationShouldTerminate`
    /// answers it for the work: the repeated request first, then the work.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        asked += 1
        let session = QuitReason.currentRequestEndsTheSession
        log("applicationShouldTerminate #\(asked) (ends the session: \(session))")
        switch design {
        case .finisher:
            // The order of AppDelegate.applicationShouldTerminate: a session
            // end during a held quit first, then a repeated request.
            if session, finisher.answerSessionEnd(replyLater: { sender.reply(toApplicationShouldTerminate: $0) }) {
                log("session end answered later, while the person's quit is finished")
                return .terminateLater
            }
            if finisher.answerRepeatedRequest() { return .terminateCancel }
            let waited = finisher.takeFinished()
            let answer = finisher.reply(
                forQuitWith: [work],
                waitedFor: waited,
                endsTheSession: session,
                replyLater: { sender.reply(toApplicationShouldTerminate: $0) }
            )
            log("answered \(answer.rawValue) (0 cancel, 1 now, 2 later)")
            return answer
        case .pending:
            let held = QuitHold.hold([work]) {
                log("hold replying \($0)")
                sender.reply(toApplicationShouldTerminate: $0)
            }
            return held ? .terminateLater : .terminateNow
        }
    }

    /// The end: prints the verdict and exits with its code.
    func applicationWillTerminate(_ notification: Notification) {
        log("applicationWillTerminate: asked \(asked) time(s), work ended: \(workEnded)")
        // Work that began and did not end is work the quit cut off.
        if workStarted, !workEnded {
            print("RESULT \(caseName): the work was cut off (started, not ended) at quit")
            exit(3)
        }
        var problems: [String] = []
        if caseName != "no-work", !workEnded { problems.append("the work never ran") }
        if caseName == "no-work", workStarted { problems.append("work ran with nothing to do") }
        if let expectation = Self.expectations[caseName] {
            problems += expectation(self)
        }
        if problems.isEmpty {
            print("RESULT \(caseName): the quit ended, the work first")
            exit(0)
        }
        print("RESULT \(caseName): " + problems.joined(separator: "; "))
        exit(1)
    }

    /// Extra things a case must show once the app ends: problems found.
    static let expectations: [String: @MainActor (Probe) -> [String]] = [
        "second-timer": secondRequest, "second-key": secondRequest, "second-dock": secondRequest,
        "logout": sessionEnd, "logout-param": sessionEnd,
        "logout-during-quit": { probe in
            var problems: [String] = []
            if probe.asked != 2 { problems.append("asked \(probe.asked) times, not twice (a cancelled log out asks again)") }
            if probe.told.count < 2 { problems.append("said \(probe.told.count) time(s), fewer than 2") }
            if !probe.noticeTakenDown { problems.append("the notice was not taken down") }
            return problems
        },
    ]

    /// A log out with work to finish: answered later, never cancelled, so it
    /// is asked once; the work's words are said once, as for any held quit.
    static let sessionEnd: @MainActor (Probe) -> [String] = { probe in
        var problems: [String] = []
        if probe.told.count != 1 { problems.append("said \(probe.told.count) time(s), not once") }
        if probe.asked != 1 { problems.append("asked \(probe.asked) times, not once (a cancelled log out asks again)") }
        return problems
    }

    /// A second request while the work is finished: the delegate was asked
    /// for the first, the second, and the request that follows the work; the
    /// words were said at least twice; and the notice came down.
    static let secondRequest: @MainActor (Probe) -> [String] = { probe in
        var problems: [String] = []
        if probe.asked < 3 { problems.append("asked \(probe.asked) time(s), fewer than 3") }
        if probe.told.count < 2 { problems.append("said \(probe.told.count) time(s), fewer than 2") }
        if !probe.noticeTakenDown { problems.append("the notice was not taken down") }
        return problems
    }

    /// A main menu with a Quit item on Command-Q, as every Mac app has, so a
    /// posted Command-Q reaches the menu as a real one does.
    func installMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        let quitItem = NSMenuItem(title: "Quit Probe", action: #selector(quitFromMenu), keyEquivalent: "q")
        quitItem.target = self
        appMenu.addItem(quitItem)
        appItem.submenu = appMenu
        NSApp.mainMenu = main
    }

    /// The Quit menu item's action, as an app's calls terminate.
    @objc func quitFromMenu() {
        log("Quit menu item chosen (Command-Q)")
        NSApp.terminate(nil)
    }

    /// Posts a Command-Q key-down to the app's own event queue.
    @objc func postCommandQ() {
        log("posting Command-Q")
        if let key = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: 0, context: nil, characters: "q", charactersIgnoringModifiers: "q",
            isARepeat: false, keyCode: 12
        ) {
            NSApp.postEvent(key, atStart: false)
        }
    }

    /// A quit from a run-loop timer, as the Quit menu item's action runs.
    @objc func quitFromTimer() {
        log("terminate from a run-loop timer")
        NSApp.terminate(nil)
    }

    /// The Dock's Quit, or with a reason the system's: a quit Apple event to
    /// this process, as the Dock and loginwindow send one.
    func sendQuitEvent(reason: OSType?, asParameter: Bool = false) {
        log("sending a quit Apple event (reason: \(reason.map { String($0, radix: 16) } ?? "none"), as \(asParameter ? "a parameter" : "an attribute"))")
        let target = NSAppleEventDescriptor(processIdentifier: getpid())
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEQuitApplication),
            targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        // The SDK's own keyword, never QuitReason's: a wrong keyword there
        // must fail these cases, not be echoed back by them.
        if let reason {
            let described = NSAppleEventDescriptor(enumCode: reason)
            if asParameter {
                event.setParam(described, forKeyword: sdkQuitReasonKeyword)
            } else {
                event.setAttribute(described, forKeyword: sdkQuitReasonKeyword)
            }
        }
        guard let description = event.aeDesc else { return }
        let status = AESendMessage(description, nil, AESendMode(kAENoReply), kAEDefaultTimeout)
        log("AESendMessage returned \(status)")
    }

    /// Runs `body` after `seconds`, in every common run-loop mode.
    func after(_ seconds: TimeInterval, _ body: @escaping @MainActor () -> Void) {
        let timer = Timer(timeInterval: seconds, repeats: false) { _ in
            MainActor.assumeIsolated { body() }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// The cases by name.
    static let cases: [String: Case] = [
        // The fault, as the old code had it: a hold answered later, then asked
        // again from a main-queue block. Expected to hang.
        "old-queue": Case(design: .pending, isControl: true) { _ in
            DispatchQueue.main.async { log("terminate(nil) from a main-queue block"); NSApp.terminate(nil) }
        },
        // The helper, from the same main-queue block, against the same hold.
        "ask-queue": Case(design: .pending, isControl: false) { _ in
            DispatchQueue.main.async { log("QuitRequest.ask() from a main-queue block"); QuitRequest.ask() }
        },
        // The helper, from a main-actor Task.
        "ask-task": Case(design: .pending, isControl: false) { _ in
            Task { @MainActor in log("QuitRequest.ask() from a main-actor Task"); QuitRequest.ask() }
        },
        // The second request, against a pending reply: AppKit quits at once.
        // Expected to cut the work off.
        "old-second": Case(design: .pending, isControl: true) { probe in
            probe.after(0.05) { probe.quitFromTimer() }
            probe.after(0.20) { probe.quitFromTimer() }
        },
        // The fix: a second terminate from a timer while the work is finished.
        "second-timer": Case(design: .finisher, isControl: false) { probe in
            probe.after(0.05) { probe.quitFromTimer() }
            probe.after(0.20) { probe.quitFromTimer() }
        },
        // The fix: a second Command-Q, as a key event through the menu.
        "second-key": Case(design: .finisher, isControl: false) { probe in
            probe.installMenu()
            probe.after(0.05) { probe.quitFromTimer() }
            probe.after(0.20) { probe.postCommandQ() }
        },
        // The fix: a second request from the Dock, as a quit Apple event.
        "second-dock": Case(design: .finisher, isControl: false) { probe in
            probe.after(0.05) { probe.quitFromTimer() }
            probe.after(0.20) { probe.sendQuitEvent(reason: nil) }
        },
        // The log out is not cancelled: answered later, work ended, once. The
        // reason is the SDK's, sent as an attribute and as a parameter.
        "logout": Case(design: .finisher, isControl: false) { probe in
            probe.after(0.05) { probe.sendQuitEvent(reason: sdkLogOutReason) }
        },
        "logout-param": Case(design: .finisher, isControl: false) { probe in
            probe.after(0.05) { probe.sendQuitEvent(reason: sdkLogOutReason, asParameter: true) }
        },
        // A log out while the person's quit is being finished: answered
        // later, not cancelled, the work ended, then TextMouth ends.
        "logout-during-quit": Case(design: .finisher, isControl: false) { probe in
            probe.after(0.05) { probe.quitFromTimer() }
            probe.after(0.20) { probe.sendQuitEvent(reason: sdkLogOutReason) }
        },
        // Nothing to finish: the quit goes ahead at once.
        "no-work": Case(design: .finisher, isControl: false) { probe in
            probe.workEnded = true
            probe.after(0.05) { probe.quitFromTimer() }
        },
    ]

    /// Starts the case once the app runs.
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let chosen = Self.cases[caseName] else {
            print("RESULT \(caseName): no such case")
            exit(1)
        }
        design = chosen.design
        log("case \(caseName)")
        chosen.start(self)
    }
}

// The watchdog: whatever happens, the probe ends.
Thread.detachNewThread {
    Thread.sleep(forTimeInterval: 8)
    print("RESULT \(caseName): HUNG, no end within 8 seconds")
    exit(2)
}

// Top-level code runs on the main thread; say so to the compiler.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = Probe()
    app.delegate = delegate
    app.run()
}
