import XCTest
@testable import TextMouth

// The plain types Slice 1 lands for the other slices, each in a class named for
// it: the phone's defaults, its life cycle, its focus rules, its announcer, the
// reader's sheets, and the reader's hooks.

/// `PhoneDefaults`: what the phone fixes, and its two navigation units.
@MainActor
final class PhoneDefaultsTests: XCTestCase {
    /// The settings are set, and applying them again changes nothing.
    func testApplyingSetsWhatThePhoneFixes() throws {
        let world = try makeIntegrationWorld("PhoneDefaultsApply")
        let file = try makeSandboxDirectory("PhoneDefaultsApply").appendingPathComponent("config.json")
        let config = ConfigService(fileURL: file)
        world.settings.playbackNavigationUnitControlMode = .none

        PhoneDefaults.apply(to: world.settings, config: config)

        XCTAssertEqual(world.settings.playbackNavigationUnitControlMode, .shared)
        XCTAssertFalse(config.config.moveToTrashInsteadOfDeleting)
        XCTAssertEqual(config.config.importDeleteBehavior, .keepOriginal)
        let applied = config.config
        PhoneDefaults.apply(to: world.settings, config: config)
        XCTAssertEqual(config.config, applied, "Applying again changed the configuration")
    }

    /// Sentence for text books and 15 seconds for audiobooks, until chosen.
    func testTheTwoUnitsDefaultByKindAndKeepAChoice() {
        let preferences = makeSandboxedPreferences("PhoneDefaultsUnits")
        XCTAssertEqual(PhoneDefaults.textNavigationUnit(in: preferences), .sentence)
        XCTAssertEqual(PhoneDefaults.audioNavigationUnit(in: preferences), .seconds15)

        PhoneDefaults.setTextNavigationUnit(.paragraph, in: preferences)
        PhoneDefaults.setAudioNavigationUnit(.seconds30, in: preferences)
        XCTAssertEqual(PhoneDefaults.textNavigationUnit(in: preferences), .paragraph)
        XCTAssertEqual(PhoneDefaults.audioNavigationUnit(in: preferences), .seconds30)

        preferences.set("no such unit", forKey: PhoneDefaults.textNavigationUnitKey)
        XCTAssertEqual(PhoneDefaults.textNavigationUnit(in: preferences), .sentence, "A damaged value is kept")
    }

    /// A book's own unit wins while offered; one not offered falls to its kind's,
    /// then to the kind's built-in default.
    func testABooksUnitFallsToItsKindsWhenNotOffered() {
        let preferences = makeSandboxedPreferences("PhoneDefaultsBookUnit")
        let all = SkipUnit.allCases
        let audio = all.filter { $0 != .sentence && $0 != .paragraph && $0 != .page }

        XCTAssertEqual(PhoneDefaults.navigationUnit(ownRawValue: "Heading", isAudio: false, offered: all, in: preferences), .heading)
        XCTAssertEqual(PhoneDefaults.navigationUnit(ownRawValue: nil, isAudio: false, offered: all, in: preferences), .sentence)
        XCTAssertEqual(PhoneDefaults.navigationUnit(ownRawValue: nil, isAudio: true, offered: audio, in: preferences), .seconds15)
        XCTAssertEqual(
            PhoneDefaults.navigationUnit(ownRawValue: "Sentence", isAudio: true, offered: audio, in: preferences),
            .seconds15,
            "An audiobook started on a unit it does not offer"
        )
        PhoneDefaults.setTextNavigationUnit(.page, in: preferences)
        let noPages = all.filter { $0 != .page }
        XCTAssertEqual(
            PhoneDefaults.navigationUnit(ownRawValue: nil, isAudio: false, offered: noPages, in: preferences),
            .sentence,
            "A book without pages took Page"
        )
    }
}

/// `PhoneLifeCycle`: handlers in order, and a file opened at launch.
@MainActor
final class PhoneLifeCycleTests: XCTestCase {
    /// Each moment's handlers run in the order they were registered.
    func testHandlersRunInOrder() {
        let lifeCycle = PhoneLifeCycle()
        var heard: [String] = []
        lifeCycle.onDidEnterBackground { heard.append("background 1") }
        lifeCycle.onDidEnterBackground { heard.append("background 2") }
        lifeCycle.onWillEnterForeground { heard.append("foreground") }
        lifeCycle.onDidBecomeActive { heard.append("active") }

        lifeCycle.sceneDidEnterBackground()
        lifeCycle.sceneWillEnterForeground()
        lifeCycle.sceneDidBecomeActive()

        XCTAssertEqual(heard, ["background 1", "background 2", "foreground", "active"])
    }

    /// A file before the app is first active is one opened at launch; later
    /// ones are not, and an empty list opens nothing.
    func testAFileOpenedAtLaunchIsKnown() {
        let lifeCycle = PhoneLifeCycle()
        var opened: [[URL]] = []
        lifeCycle.openedFiles = { opened.append($0) }
        let file = URL(fileURLWithPath: "/nonexistent/book.epub")

        lifeCycle.sceneOpened([])
        XCTAssertFalse(lifeCycle.filesOpenedAtLaunch)
        lifeCycle.sceneOpened([file])
        XCTAssertTrue(lifeCycle.filesOpenedAtLaunch)
        XCTAssertEqual(opened, [[file]])

        let later = PhoneLifeCycle()
        later.sceneDidBecomeActive()
        later.sceneOpened([file])
        XCTAssertFalse(later.filesOpenedAtLaunch)
    }
}

/// `PhoneFocusPolicy`: Play at arrival, never pulled from under the listener.
final class PhoneFocusPolicyTests: XCTestCase {
    /// With focus landing nowhere useful, it posts `.screenChanged` at 0.35
    /// seconds, `.layoutChanged` once at 1.2, and stops at 3.
    func testWithNoLandingItPostsTwiceThenStops() {
        // Arrival at 0, so each time is the exact time since arrival.
        var policy = PhoneFocusPolicy(arrivedAt: 0)
        XCTAssertNil(policy.action(at: 0.2))
        XCTAssertEqual(policy.nextCheck, 0.35)
        XCTAssertEqual(policy.action(at: 0.35), .postScreenChanged)
        XCTAssertNil(policy.action(at: 0.5), "Posted twice")
        policy.focusLanded(on: nil)
        XCTAssertEqual(policy.action(at: 1.2), .postLayoutChanged, "A landing on Back or the title stopped it")
        XCTAssertNil(policy.action(at: 2))
        XCTAssertNil(policy.action(at: 3))
        XCTAssertTrue(policy.isFinished)
        XCTAssertNil(policy.nextCheck)
    }

    /// Once focus has been on Play, it stops for good.
    func testFocusOnPlayStopsItForGood() {
        var policy = PhoneFocusPolicy(arrivedAt: 0)
        XCTAssertEqual(policy.action(at: 0.4), .postScreenChanged)
        policy.focusLanded(on: .play)
        XCTAssertNil(policy.action(at: 1.3))
        policy.focusLanded(on: nil)
        XCTAssertNil(policy.action(at: 1.5))
        XCTAssertTrue(policy.isFinished)
    }

    /// A landing on another reader control is the listener's, even before the
    /// first post: nothing is posted at all.
    func testALandingOnAnotherControlIsTheListeners() {
        var policy = PhoneFocusPolicy(arrivedAt: 0)
        policy.focusLanded(on: .navigationUnit)
        XCTAssertNil(policy.action(at: 0.4))
        XCTAssertNil(policy.action(at: 1.3))
        XCTAssertTrue(policy.isFinished)
    }

    /// A late check posts one thing at a time: `.screenChanged` first.
    func testALateCheckPostsOneThingAtATime() {
        var policy = PhoneFocusPolicy(arrivedAt: 0)
        XCTAssertEqual(policy.action(at: 1.5), .postScreenChanged)
        XCTAssertEqual(policy.action(at: 1.5), .postLayoutChanged)
        XCTAssertNil(policy.action(at: 1.5))
    }
}

/// `PhoneListFocus`: which row focus goes to.
final class PhoneListFocusTests: XCTestCase {
    /// The row wanted, while the list holds it, else the fallback, else none.
    func testTheRowOrItsFallback() {
        XCTAssertEqual(PhoneListFocus.row("b", in: ["a", "b"], fallback: "a"), "b")
        XCTAssertEqual(PhoneListFocus.row("c", in: ["a", "b"], fallback: "a"), "a")
        XCTAssertNil(PhoneListFocus.row("c", in: ["a", "b"], fallback: "d"))
    }

    /// A row that has gone falls to the next remaining row, else the one before,
    /// else the caller's.
    func testAGoneRowFallsToItsNeighbour() {
        let old = ["a", "b", "c", "d"]
        XCTAssertEqual(PhoneListFocus.fallback(forGone: "b", oldRows: old, newRows: ["a", "c", "d"], otherwise: nil), "c")
        XCTAssertEqual(PhoneListFocus.fallback(forGone: "d", oldRows: old, newRows: ["a", "b", "c"], otherwise: nil), "c")
        XCTAssertEqual(PhoneListFocus.fallback(forGone: "a", oldRows: ["a"], newRows: [], otherwise: "continue"), "continue")
        XCTAssertEqual(PhoneListFocus.fallback(forGone: "z", oldRows: old, newRows: old, otherwise: "continue"), "continue")
    }
}

/// `VoiceOverAnnouncer.collectingAnnouncements(during:)`.
@MainActor
final class VoiceOverAnnouncerCollectingTests: XCTestCase {
    /// What the call announces is collected, in order, and nothing is posted;
    /// the poster is back afterwards, after a throw too.
    func testItCollectsAndPutsThePosterBack() throws {
        // The closure holds a `try` (inside XCTAssertThrowsError), so Swift
        // reads it as throwing, and the recorder, which rethrows, needs one.
        let recorder = try recordingAnnouncements {
            let collected = VoiceOverAnnouncer.collectingAnnouncements {
                VoiceOverAnnouncer.announce("Next heading", priority: .high)
                VoiceOverAnnouncer.announce("Chapter 2", priority: .low)
            }
            XCTAssertEqual(collected.map(\.message), ["Next heading", "Chapter 2"])
            XCTAssertEqual(collected.map(\.priority), [.high, .low])

            struct Stop: Error {}
            XCTAssertThrowsError(try VoiceOverAnnouncer.collectingAnnouncements {
                VoiceOverAnnouncer.announce("Inside")
                throw Stop()
            })
            VoiceOverAnnouncer.announce("After")
        }
        XCTAssertEqual(recorder.announcements.map(\.message), ["After"], "The poster was not put back")
    }
}

/// `PhoneAnnouncer`: two strengths, each after a moment, and a run of words
/// joined into one announcement.
@MainActor
final class PhoneAnnouncerTests: XCTestCase {
    /// Each waits 0.15 seconds, then says its words at its priority: `say`
    /// queues behind VoiceOver's speech (iOS's low priority, by Apple's
    /// header), and on the Mac's test host, important is an ordinary
    /// high-priority announcement.
    func testEachStrengthWaitsAndSaysItsWords() {
        let previous = PhoneAnnouncer.schedule
        var delays: [TimeInterval] = []
        PhoneAnnouncer.schedule = { delay, work in
            delays.append(delay)
            work()
        }
        defer { PhoneAnnouncer.schedule = previous }

        let recorder = recordingAnnouncements {
            PhoneAnnouncer.say("Opened Tide Tables")
            PhoneAnnouncer.important("Sleep timer ends in 1 minute")
        }

        XCTAssertEqual(delays, [0.15, 0.15])
        XCTAssertEqual(recorder.announcements.map(\.message), [
            "Opened Tide Tables", "Sleep timer ends in 1 minute",
        ])
        XCTAssertEqual(recorder.announcements.map(\.priority), [.low, .high])
    }

    /// A run of words is one announcement, each sentence ended, empties left
    /// out; nothing is said when nothing is left.
    func testARunOfWordsIsOneAnnouncement() {
        XCTAssertEqual(
            PhoneAnnouncer.joined(["Sleep timer stopped", "", "Heading: The Crossing.", "  Chapter 2?  "]),
            "Sleep timer stopped. Heading: The Crossing. Chapter 2?"
        )
        XCTAssertEqual(PhoneAnnouncer.joined(["", "Heading: The Crossing"]), "Heading: The Crossing", "A lone message gets no stop")
        XCTAssertNil(PhoneAnnouncer.joined([]))
        XCTAssertNil(PhoneAnnouncer.joined(["", "   "]))

        let previous = PhoneAnnouncer.schedule
        PhoneAnnouncer.schedule = { _, work in work() }
        defer { PhoneAnnouncer.schedule = previous }
        let recorder = recordingAnnouncements {
            PhoneAnnouncer.say(inOrder: ["Closed", "Saved"])
            PhoneAnnouncer.say(inOrder: [])
        }
        XCTAssertEqual(recorder.announcements.map(\.message), ["Closed. Saved."])
        XCTAssertEqual(recorder.announcements.map(\.priority), [.low])
    }

    /// Announcements posted together combine at the strongest priority among
    /// them, so the most urgent is not made to wait.
    func testCombinedAnnouncementsTakeTheStrongestPriority() {
        let combined = PhoneAnnouncer.combined([
            VoiceOverAnnouncement(message: "Chapter 2", priority: .low),
            VoiceOverAnnouncement(message: "Sleep timer stopped", priority: .high),
        ])
        XCTAssertEqual(combined, VoiceOverAnnouncement(message: "Chapter 2. Sleep timer stopped.", priority: .high))
        XCTAssertNil(PhoneAnnouncer.combined([]))
    }
}

/// `PhoneReaderSheet`: the eight sheets, each its own.
final class PhoneReaderSheetTests: XCTestCase {
    /// Eight sheets, each with an identity of its own.
    func testEachSheetIsItsOwn() {
        XCTAssertEqual(PhoneReaderSheet.allCases.count, 8)
        XCTAssertEqual(Set(PhoneReaderSheet.allCases.map(\.id)).count, 8)
    }
}

/// `ReaderPhoneHooks`: every default leaves the reader as on the Mac.
@MainActor
final class ReaderPhoneHooksTests: XCTestCase {
    /// Audio may start, and no move or end is taken over.
    func testTheDefaultsChangeNothing() {
        let hooks = ReaderPhoneHooks()
        XCTAssertTrue(hooks.audioMayStart())
        XCTAssertNil(hooks.moveForward)
        XCTAssertNil(hooks.moveBackward)
        XCTAssertNil(hooks.audioEnded)
        XCTAssertNil(hooks.silentGapBegan)
    }
}
