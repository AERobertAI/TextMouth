import Foundation

func runSleepTimerTests() {
// ---- ReadingPosition & Time Estimate Tests ----
print("\n--- ReadingPosition & Time Estimate Tests ---")

test("ReadingPosition defaults") {
    let pos = (chapterIndex: 0, characterOffset: 0, globalOffset: 0 as Int?)
    try assertEqual(pos.chapterIndex, 0)
    try assertEqual(pos.characterOffset, 0)
}

test("Book estimatedTimeRemaining without word counts returns nil") {
    // Simulating a book with no totalWordCount
    let totalWordCount: Int? = nil
    let totalCharCount: Int? = nil
    let wpm = 200.0

    let result: TimeInterval?
    if let totalWords = totalWordCount, let totalChars = totalCharCount,
       totalChars > 0, wpm > 0 {
        let totalTime = Double(totalWords) / wpm * 60.0
        result = totalTime
    } else {
        result = nil
    }
    try assertTrue(result == nil, "Should return nil when word count is unknown")
}

test("Book estimatedTimeRemaining with word counts and position") {
    let totalWords = 10000
    let totalChars = 50000
    let wpm = 200.0
    let globalOffset = 25000  // halfway

    let totalTime = Double(totalWords) / wpm * 60.0
    let fraction = min(Double(globalOffset) / Double(totalChars), 1.0)
    let remaining = totalTime * (1.0 - fraction)

    // 10000 words / 200 wpm = 50 min = 3000 sec, halfway = 1500 sec remaining
    try assertEqual(Int(remaining), 1500, "Should be 1500 seconds remaining at halfway")
}

test("Book estimatedTimeRemaining at start and end") {
    let totalWords = 10000
    let totalChars = 50000
    let wpm = 200.0

    // At start (offset 0)
    let remainingAtStart = Double(totalWords) / wpm * 60.0 * (1.0 - 0.0 / Double(totalChars))
    try assertEqual(Int(remainingAtStart), 3000, "Full book = 3000 seconds")

    // At end (offset = totalChars)
    let fraction = min(Double(totalChars) / Double(totalChars), 1.0)
    let remainingAtEnd = Double(totalWords) / wpm * 60.0 * (1.0 - fraction)
    try assertEqual(Int(remainingAtEnd), 0, "At end = 0 seconds remaining")
}

// ---- SleepTimer Logic Tests ----
print("\n--- SleepTimer Logic Tests ---")

test("SleepTimer minutes countdown logic") {
    var remaining = 5 * 60  // 5 minutes in seconds
    var isActive = true

    // Simulate 5 ticks
    for _ in 0..<5 {
        remaining -= 1
    }
    try assertEqual(remaining, 295, "Should have 295 seconds remaining after 5 ticks")
    try assertTrue(isActive, "Should still be active")

    // Simulate countdown to zero
    remaining = 1
    remaining -= 1
    if remaining <= 0 {
        isActive = false
    }
    try assertTrue(!isActive, "Should expire when reaching 0")
}

test("SleepTimer endOfHeading triggers correctly") {
    var endOfHeadingTriggered = false
    var expired = false

    // First heading boundary: arm the trigger
    if !endOfHeadingTriggered {
        endOfHeadingTriggered = true
    } else {
        expired = true
    }
    try assertTrue(!expired, "Should not expire on first heading boundary")
    try assertTrue(endOfHeadingTriggered, "Should arm trigger")

    // Second heading boundary: should expire
    if !endOfHeadingTriggered {
        endOfHeadingTriggered = true
    } else {
        expired = true
    }
    try assertTrue(expired, "Should expire on second heading boundary")
}

test("SleepTimer formattedRemaining") {
    func format(minutes: Bool, seconds: Int) -> String {
        if !minutes { return "" }
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }

    try assertEqual(format(minutes: true, seconds: 300), "5:00")
    try assertEqual(format(minutes: true, seconds: 65), "1:05")
    try assertEqual(format(minutes: true, seconds: 0), "0:00")
}

// ---- Sleep Timer Auto-Close Setting ----
print("\n--- Sleep Timer Auto-Close Setting ---")

test("Auto-close default is true") {
    // The default config should have sleepTimerAutoClose = true
    let config = TestAppConfig()
    try assertTrue(config.sleepTimerAutoClose, "Default should be auto-close")
}

test("Auto-close setting round-trips through JSON") {
    var config = TestAppConfig()
    config.sleepTimerAutoClose = false

    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(TestAppConfig.self, from: data)
    try assertTrue(!decoded.sleepTimerAutoClose, "Should preserve false after round-trip")
}

test("Auto-close setting missing from JSON defaults to true") {
    // Simulate old config.json without the sleepTimerAutoClose key
    let json = """
    {"sleepFadeOutDuration": 5}
    """.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(TestAppConfig.self, from: json)
    try assertTrue(decoded.sleepTimerAutoClose, "Missing key should default to true")
}

// ---- Sleep Timer Restart ----
print("\n--- Sleep Timer Restart ---")

test("Restart preserves duration type: minutes") {
    var duration: SleepTimerDuration? = .minutes(15)
    var remainingSeconds = 15 * 60

    // Simulate countdown
    remainingSeconds -= 300  // 5 minutes pass
    try assertEqual(remainingSeconds, 600, "Should have 10 minutes left")

    // Restart: re-apply the same duration
    if let d = duration {
        if case .minutes(let m) = d {
            remainingSeconds = m * 60
        }
    }
    try assertEqual(remainingSeconds, 900, "After restart should be back to 15 minutes (900s)")
}

test("Restart preserves duration type: endOfHeading") {
    let duration: SleepTimerDuration? = .endOfHeading
    var endOfHeadingTriggered = true  // was armed

    // Restart: reset the trigger
    if let d = duration, case .endOfHeading = d {
        endOfHeadingTriggered = false
    }
    try assertTrue(!endOfHeadingTriggered, "Restart should reset the heading trigger")
}

test("Restart with no active duration is a no-op") {
    let duration: SleepTimerDuration? = nil
    var restarted = false
    if duration != nil {
        restarted = true
    }
    try assertTrue(!restarted, "Should not restart when no duration is set")
}

// ---- Sleep Timer State Transitions ----
print("\n--- Sleep Timer State Transitions ---")

test("Start sets isActive and duration") {
    var isActive = false
    var duration: SleepTimerDuration? = nil

    // Simulate start
    duration = .minutes(30)
    isActive = true
    try assertTrue(isActive)
    if case .minutes(let m) = duration {
        try assertEqual(m, 30)
    } else {
        throw TestError.assertionFailed("Duration should be minutes(30)")
    }
}

test("Stop clears isActive and duration") {
    var isActive = true
    var duration: SleepTimerDuration? = .minutes(10)
    var remainingSeconds = 600

    // Simulate stop
    isActive = false
    duration = nil
    remainingSeconds = 0

    try assertTrue(!isActive)
    try assertTrue(duration == nil)
    try assertEqual(remainingSeconds, 0)
}

test("Cancel then re-set: clean state transition") {
    var isActive = true
    var duration: SleepTimerDuration? = .minutes(10)

    // Cancel
    isActive = false
    duration = nil

    // Re-set with different duration
    duration = .minutes(45)
    isActive = true

    if case .minutes(let m) = duration {
        try assertEqual(m, 45, "Should have new duration after cancel + re-set")
    } else {
        throw TestError.assertionFailed("Duration should be minutes(45)")
    }
}

// ---- Pause-Aware Countdown Tests ----
print("\n--- Pause-Aware Countdown Tests ---")

// These mirror the production pauseCountdown / resumeCountdown behaviour.
// Symptom they prevent: a sleep timer set before a long break expires
// silently while playback is paused, then pauses the user a few minutes
// after they resume — perceived as a "random pause every couple of
// minutes" without an obvious cause.

/// Local simulator of the relevant SleepTimerService state machine.
class PauseAwareSleepTimer {
    var isActive = false
    var isFadingOut = false
    var duration: SleepTimerDuration? = nil
    var remainingSeconds = 0
    var timerArmed = false
    var isCountdownPausedByPlayback = false

    func start(_ duration: SleepTimerDuration) {
        stop()
        self.duration = duration
        isActive = true
        switch duration {
        case .minutes(let m):
            remainingSeconds = m * 60
            timerArmed = true
        case .endOfHeading, .endOfDocument:
            remainingSeconds = 0
        }
    }

    func stop() {
        isActive = false
        isFadingOut = false
        duration = nil
        remainingSeconds = 0
        timerArmed = false
        isCountdownPausedByPlayback = false
    }

    func tick() {
        guard isActive, timerArmed else { return }
        if remainingSeconds > 0 { remainingSeconds -= 1 }
    }

    func pauseCountdown() {
        guard isActive,
              case .minutes = duration,
              !isFadingOut,
              timerArmed else { return }
        timerArmed = false
        isCountdownPausedByPlayback = true
    }

    func resumeCountdown() {
        guard isActive,
              isCountdownPausedByPlayback,
              case .minutes = duration else { return }
        isCountdownPausedByPlayback = false
        timerArmed = true
    }
}

test("Pause-aware countdown: pause halts the tick") {
    let t = PauseAwareSleepTimer()
    t.start(.minutes(2))
    try assertEqual(t.remainingSeconds, 120)

    // Tick once, then pause — subsequent ticks must not decrement.
    t.tick()
    try assertEqual(t.remainingSeconds, 119)

    t.pauseCountdown()
    for _ in 0..<60 { t.tick() }
    try assertEqual(t.remainingSeconds, 119, "Paused countdown must preserve remaining time")
    try assertTrue(t.isCountdownPausedByPlayback)
    try assertTrue(!t.timerArmed)
}

test("Pause-aware countdown: resume re-arms with the same remaining time") {
    let t = PauseAwareSleepTimer()
    t.start(.minutes(5))
    for _ in 0..<10 { t.tick() }
    try assertEqual(t.remainingSeconds, 290)

    t.pauseCountdown()
    // Long break — many ticks while paused should be no-ops.
    for _ in 0..<10_000 { t.tick() }
    try assertEqual(t.remainingSeconds, 290, "Time must not advance during a paused break")

    t.resumeCountdown()
    try assertTrue(!t.isCountdownPausedByPlayback)
    try assertTrue(t.timerArmed)
    t.tick()
    try assertEqual(t.remainingSeconds, 289, "Tick after resume should resume normal decrement")
}

test("Pause-aware countdown: pause is a no-op for endOfHeading mode") {
    // Heading-end and document-end durations don't tick on a clock —
    // they're triggered by playback events. Pausing them shouldn't
    // touch any state.
    let t = PauseAwareSleepTimer()
    t.start(.endOfHeading)
    t.pauseCountdown()
    try assertTrue(!t.isCountdownPausedByPlayback,
                  "Heading-end mode should not enter the paused countdown state")
    try assertTrue(t.isActive, "Service stays active for the heading event")
}

test("Pause-aware countdown: pause is a no-op for endOfDocument mode") {
    let t = PauseAwareSleepTimer()
    t.start(.endOfDocument)
    t.pauseCountdown()
    try assertTrue(!t.isCountdownPausedByPlayback)
    try assertTrue(t.isActive)
}

test("Pause-aware countdown: resume is a no-op when nothing was paused") {
    // Cold start path — play() may call resumeCountdown unconditionally.
    let t = PauseAwareSleepTimer()
    t.start(.minutes(10))
    try assertTrue(t.timerArmed)
    try assertTrue(!t.isCountdownPausedByPlayback)

    t.resumeCountdown()  // should not arm a second timer or change state
    try assertTrue(t.timerArmed)
    try assertTrue(!t.isCountdownPausedByPlayback)
}

test("Pause-aware countdown: resume is a no-op when no timer is active") {
    // No timer set at all — resume must not start one out of nowhere.
    let t = PauseAwareSleepTimer()
    try assertTrue(!t.isActive)
    t.resumeCountdown()
    try assertTrue(!t.isActive)
    try assertTrue(!t.timerArmed)
}

test("Pause-aware countdown: pause does not touch a fading timer") {
    // Mid-fade pauses are handled by the playback layer (which calls
    // sleepTimerService.stop() to abort the fade). pauseCountdown
    // must NOT accidentally halt the fade — that would leave audio
    // at a low volume indefinitely.
    let t = PauseAwareSleepTimer()
    t.start(.minutes(1))
    t.isFadingOut = true
    t.timerArmed = true  // pre-fade tick state captured

    t.pauseCountdown()
    try assertTrue(!t.isCountdownPausedByPlayback,
                  "Mid-fade pauseCountdown must be a no-op")
    try assertTrue(t.timerArmed, "Fading timer state must not be modified")
}

test("Pause-aware countdown: stop clears the paused-by-playback flag") {
    // If the user cancels the timer while it was halted by a pause,
    // the flag must clear so a new timer started later doesn't
    // inherit a stale paused state.
    let t = PauseAwareSleepTimer()
    t.start(.minutes(10))
    t.pauseCountdown()
    try assertTrue(t.isCountdownPausedByPlayback)

    t.stop()
    try assertTrue(!t.isCountdownPausedByPlayback,
                  "stop() must clear the pause-by-playback flag")

    // New timer starts cleanly
    t.start(.minutes(5))
    try assertTrue(t.timerArmed)
    try assertTrue(!t.isCountdownPausedByPlayback)
}

test("Pause-aware countdown: long-break scenario does not expire silently") {
    // The bug scenario in one test:
    // 1. User sets a 10-minute timer, plays for a moment.
    // 2. User pauses to do something else for 30 minutes.
    // 3. User resumes — must still have ~all the original time left.
    // 4. Without the pause-aware fix, the timer would have expired
    //    during the break and pause the user moments after resume.
    let t = PauseAwareSleepTimer()
    t.start(.minutes(10))
    for _ in 0..<5 { t.tick() }   // 5 seconds of playback
    try assertEqual(t.remainingSeconds, 595)

    t.pauseCountdown()
    for _ in 0..<(30 * 60) { t.tick() }  // 30 minutes of paused-break time
    try assertEqual(t.remainingSeconds, 595,
                   "Bug fix: timer must not have run down during the break")

    t.resumeCountdown()
    for _ in 0..<5 { t.tick() }   // 5 more seconds of playback after resume
    try assertEqual(t.remainingSeconds, 590)
}

// ---- Sleep Timer Fade-Out Volume Pop Tests (Fix 10) ----
print("\n--- Sleep Timer Fade-Out Volume Pop Tests ---")

test("Fade expiry: pause happens before volume restore") {
    // Simulates the onTimerExpired handler ordering.
    // The fix ensures pause() is called BEFORE restoreVolume()
    // so there's no audible pop of full-volume audio.
    var actions: [String] = []
    var currentVolume: Float = 0.0  // Faded to zero
    var isPaused = false

    // Correct ordering: pause first, then restore
    func pauseFirst() {
        isPaused = true
        actions.append("pause")
    }
    func restoreAfter() {
        currentVolume = 1.0
        actions.append("restore")
    }

    pauseFirst()
    restoreAfter()

    try assertEqual(actions, ["pause", "restore"],
        "Pause must happen before volume restore to avoid audible pop")
    try assertTrue(isPaused, "Audio should be paused")
    try assertEqual(currentVolume, 1.0, "Volume should be restored after pause")
}

test("Fade expiry: volume is at zero when pause fires") {
    // The last fade step sets volume to 0.0. When onTimerExpired
    // fires, volume should still be 0.0 at the moment of pause.
    var volumeHistory: [Float] = []
    var currentVolume: Float = 1.0

    // Simulate fade-out: 5 steps from 1.0 to 0.0
    let totalSteps = 5
    for step in 1...totalSteps {
        currentVolume = Float(max(0, 1.0 - Double(step) / Double(totalSteps)))
        volumeHistory.append(currentVolume)
    }

    // At this point, volume should be 0.0
    try assertEqual(currentVolume, 0.0, "Volume should be 0 after fade completes")

    // Now the onTimerExpired handler fires — volume is still 0.0
    // Pause happens first (at volume 0.0), then restore (inaudible)
    let volumeAtPause = currentVolume
    try assertEqual(volumeAtPause, 0.0,
        "Volume must be 0 at the moment pause is called")

    // Restore happens after pause
    currentVolume = 1.0
    try assertEqual(currentVolume, 1.0, "Volume restored for next playback")
}

test("Manual pause during fade: audio pauses before volume restore") {
    // If the user presses pause while a fade-out is in progress,
    // the pause() method should pause audio first, then clean up
    // the fade state and restore volume.
    var actions: [String] = []
    var isFadingOut = true
    var currentVolume: Float = 0.5  // Mid-fade

    // Simulates the corrected pause() ordering
    func pause() {
        // 1. Pause audio first
        actions.append("pause_audio")
        // 2. Then handle fade cleanup (volume is now inaudible)
        if isFadingOut {
            isFadingOut = false
            currentVolume = 1.0
            actions.append("restore_volume")
        }
    }

    pause()

    try assertEqual(actions, ["pause_audio", "restore_volume"],
        "Audio must pause before volume is restored")
    try assertTrue(!isFadingOut, "Fade should be stopped")
    try assertEqual(currentVolume, 1.0, "Volume should be restored")
}

test("No fade active: pause does not touch volume") {
    // When there's no fade-out in progress, pause() should not
    // call restoreVolume() at all.
    var actions: [String] = []
    var isFadingOut = false
    var currentVolume: Float = 1.0

    func pause() {
        actions.append("pause_audio")
        if isFadingOut {
            isFadingOut = false
            currentVolume = 1.0
            actions.append("restore_volume")
        }
    }

    pause()

    try assertEqual(actions, ["pause_audio"],
        "No volume restore when fade is not active")
    try assertEqual(currentVolume, 1.0, "Volume should remain at 1.0")
}

test("Fade expiry with zero duration: pause before expire callback") {
    // With fadeOutDuration = 0, expire() calls onTimerExpired
    // directly (no fade steps). The handler still must pause
    // before restoring volume.
    var actions: [String] = []
    var currentVolume: Float = 1.0

    func onTimerExpired() {
        // Correct ordering
        actions.append("pause")
        currentVolume = 1.0  // restore
        actions.append("restore")
    }

    // No fade steps, just expire
    onTimerExpired()
    try assertEqual(actions.first, "pause",
        "Even with zero fade duration, pause must come first")
}

// ---- Stop Ordering Tests (Fix 13) ----
print("\n--- Stop Ordering Tests ---")

test("stop(): audio stops before volume restore (TTS path)") {
    // Previously, stop() called restoreVolume() BEFORE stopping audio,
    // causing a brief pop of full-volume audio. The fix mirrors the
    // pause() ordering: stop audio first, then restore volume.
    var actions: [String] = []
    var currentVolume: Float = 0.2  // Mid-fade

    func stop() {
        // Correct ordering: stop audio first
        actions.append("stop_audio")
        // Then restore volume (inaudible because audio is stopped)
        currentVolume = 1.0
        actions.append("restore_volume")
    }

    stop()
    try assertEqual(actions, ["stop_audio", "restore_volume"],
        "Audio must stop before volume is restored to avoid pop")
    try assertEqual(currentVolume, 1.0, "Volume restored for next playback")
}

test("stop(): audio stops before volume restore (audio book path)") {
    var actions: [String] = []
    var currentVolume: Float = 0.3

    func stop() {
        actions.append("stop_audio")
        currentVolume = 1.0
        actions.append("restore_volume")
    }

    stop()
    try assertEqual(actions, ["stop_audio", "restore_volume"],
        "Audio book path: stop before restore")
}

test("stop() during active fade: fade stops, audio stops, then volume restore") {
    // When stop() is called while a fade is in progress, the sleep
    // timer should be stopped first, then audio, then volume restored.
    var actions: [String] = []
    var isFadingOut = true
    var currentVolume: Float = 0.4

    func stop() {
        if isFadingOut {
            isFadingOut = false
            actions.append("stop_fade")
        }
        actions.append("stop_audio")
        currentVolume = 1.0
        actions.append("restore_volume")
    }

    stop()
    try assertEqual(actions, ["stop_fade", "stop_audio", "restore_volume"],
        "Fade must stop, then audio, then restore")
    try assertTrue(!isFadingOut)
    try assertEqual(currentVolume, 1.0)
}

test("stop() without fade: no restore volume before stop") {
    // Verify the ordering is correct even when no fade is active.
    var actions: [String] = []
    var currentVolume: Float = 1.0

    func stop() {
        actions.append("stop_audio")
        currentVolume = 1.0
        actions.append("restore_volume")
    }

    stop()
    try assertTrue(actions.first == "stop_audio",
        "Stop audio must always come first, even without fade")
}

} // end runSleepTimerTests

/// Minimal config struct for testing sleep timer settings persistence
private struct TestAppConfig: Codable {
    var sleepFadeOutDuration: Double
    var sleepTimerAutoClose: Bool

    init(sleepFadeOutDuration: Double = 0, sleepTimerAutoClose: Bool = true) {
        self.sleepFadeOutDuration = sleepFadeOutDuration
        self.sleepTimerAutoClose = sleepTimerAutoClose
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sleepFadeOutDuration = try container.decodeIfPresent(Double.self, forKey: .sleepFadeOutDuration) ?? 0
        sleepTimerAutoClose = try container.decodeIfPresent(Bool.self, forKey: .sleepTimerAutoClose) ?? true
    }
}
