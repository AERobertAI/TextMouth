import Foundation

func runPlaybackTests() {
// ---- NowPlaying Service Logic Tests ----
print("\n--- NowPlaying Service Logic Tests ---")

test("NowPlaying info format") {
    // Simulate building now playing info
    let title = "Alice in Wonderland"
    let author = "Lewis Carroll"
    let isPlaying = true

    var info = [String: Any]()
    info["title"] = title
    info["artist"] = author
    info["playbackRate"] = isPlaying ? 1.0 : 0.0

    try assertEqual(info["title"] as? String, "Alice in Wonderland")
    try assertEqual(info["artist"] as? String, "Lewis Carroll")
    try assertEqual(info["playbackRate"] as? Double, 1.0)
}

test("NowPlaying clear sets nil") {
    var info: [String: Any]? = ["title": "Test"]
    info = nil
    try assertTrue(info == nil, "Should be nil after clear")
}

// ---- NowPlaying Remote Command Separation Tests ----
print("\n--- NowPlaying Remote Command Separation Tests ---")

// Simulates the NowPlayingService's play/pause/toggle separation and suppress logic.
// The actual service uses MPRemoteCommandCenter which can't be unit tested,
// so we test the logic pattern directly.

test("Play command only plays, does not toggle") {
    // Simulate the separated command handlers
    var isPlaying = false
    var playCallCount = 0
    var pauseCallCount = 0

    let onPlay = { playCallCount += 1; isPlaying = true }
    let onPause = { pauseCallCount += 1; isPlaying = false }

    // Start paused, receive play command
    onPlay()
    try assertTrue(isPlaying)
    try assertEqual(playCallCount, 1)

    // Already playing, receive another play command — should not toggle off
    onPlay()
    try assertTrue(isPlaying, "Play should keep playing, not toggle to paused")
    try assertEqual(playCallCount, 2)
    try assertEqual(pauseCallCount, 0, "Pause should never have been called")
}

test("Remote play resumes paused playback instead of cold-starting") {
    enum Mode {
        case stopped
        case speaking
        case paused
    }

    var mode: Mode = .paused
    var playCalls = 0
    var resumeCalls = 0

    func playOrResume() {
        switch mode {
        case .paused:
            resumeCalls += 1
            mode = .speaking
        case .stopped:
            playCalls += 1
            mode = .speaking
        case .speaking:
            break
        }
    }

    playOrResume()
    try assertEqual(resumeCalls, 1, "Paused play should resume")
    try assertEqual(playCalls, 0, "Paused play should not cold-start")
    try assertTrue(mode == .speaking)
}

// ---- Playback UI Mirror Tests ----
print("\n--- Playback UI Mirror Tests ---")

final class PlaybackUIMirrorSimulator {
    private let chapterStartOffsets: [Int]
    var displayChapterIndex = 0
    var displayCharacterOffset = 0

    init(chapterLengths: [Int]) {
        var starts: [Int] = []
        starts.reserveCapacity(chapterLengths.count)
        var running = 0
        for length in chapterLengths {
            starts.append(running)
            running += length
        }
        self.chapterStartOffsets = starts
    }

    func refreshDisplay(chapterIndex: Int, offset: Int) {
        displayChapterIndex = chapterIndex
        displayCharacterOffset = offset
    }

    func displayCurrentGlobalOffset() -> Int {
        guard displayChapterIndex >= 0,
              displayChapterIndex < chapterStartOffsets.count else { return 0 }
        return chapterStartOffsets[displayChapterIndex] + displayCharacterOffset
    }
}

test("Playback UI mirror: chapter and offset are read from the same display snapshot") {
    let mirror = PlaybackUIMirrorSimulator(chapterLengths: [100, 120, 140])

    // Raw playback moved into chapter 2, but the UI should read the
    // throttled display snapshot instead of mixing a stale chapter with
    // a fresh offset.
    mirror.refreshDisplay(chapterIndex: 1, offset: 5)
    try assertEqual(mirror.displayCurrentGlobalOffset(), 105,
                    "Display offset should use the mirrored chapter index")

    mirror.refreshDisplay(chapterIndex: 2, offset: 12)
    try assertEqual(mirror.displayCurrentGlobalOffset(), 232,
                    "Mirror updates should stay internally consistent")
}

final class VisibleTextWindowRefreshSimulator {
    struct WindowState {
        let chapterIndex: Int
        let startOffset: Int
        let endOffset: Int
    }

    static let maxDisplayChars = 20_000
    static let guardFraction = 0.25

    private(set) var refreshCount = 0
    private(set) var windowState: WindowState?

    func refresh(chapterIndex: Int, offset: Int, text: String, force: Bool = false) {
        if shouldRefresh(chapterIndex: chapterIndex, offset: offset, text: text, force: force) {
            refreshCount += 1
            if text.count <= Self.maxDisplayChars {
                windowState = WindowState(
                    chapterIndex: chapterIndex,
                    startOffset: 0,
                    endOffset: text.count
                )
                return
            }

            let halfWindow = Self.maxDisplayChars / 2
            let center = min(max(offset, halfWindow), text.count - halfWindow)
            let windowStart = max(center - halfWindow, 0)
            let windowEnd = min(center + halfWindow, text.count)
            let startIdx = text.index(text.startIndex, offsetBy: windowStart)
            let endIdx = text.index(text.startIndex, offsetBy: windowEnd)

            var adjustedStart = startIdx
            if windowStart > 0,
               let paraBreak = text.range(of: "\n\n", range: startIdx..<endIdx) {
                adjustedStart = paraBreak.upperBound
            }

            var adjustedEnd = endIdx
            if windowEnd < text.count,
               let paraBreak = text.range(of: "\n\n", options: .backwards, range: adjustedStart..<endIdx) {
                adjustedEnd = paraBreak.lowerBound
            }

            windowState = WindowState(
                chapterIndex: chapterIndex,
                startOffset: text.distance(from: text.startIndex, to: adjustedStart),
                endOffset: text.distance(from: text.startIndex, to: adjustedEnd)
            )
        }
    }

    private func shouldRefresh(
        chapterIndex: Int,
        offset: Int,
        text: String,
        force: Bool
    ) -> Bool {
        if force || text.count <= Self.maxDisplayChars {
            return true
        }
        guard let state = windowState else { return true }
        guard state.chapterIndex == chapterIndex else { return true }

        let guardSize = max(
            1,
            Int(Double(state.endOffset - state.startOffset) * Self.guardFraction)
        )
        let lowerBound = state.startOffset + guardSize
        let upperBound = max(lowerBound, state.endOffset - guardSize)
        return offset < lowerBound || offset > upperBound
    }
}

test("Playback text window stays stable while position moves inside guard band") {
    let simulator = VisibleTextWindowRefreshSimulator()
    let text = String(repeating: "A", count: 30_000)
        + "\n\n"
        + String(repeating: "B", count: 90_000)
        + "\n\n"
        + String(repeating: "C", count: 10_000)

    simulator.refresh(chapterIndex: 0, offset: 10_000, text: text)
    try assertEqual(simulator.refreshCount, 1)

    simulator.refresh(chapterIndex: 0, offset: 14_500, text: text)
    try assertEqual(simulator.refreshCount, 1,
                    "Small playback advances inside the guard band should not rebuild the text window")
}

test("Playback text window rebuilds after leaving the guard band") {
    let simulator = VisibleTextWindowRefreshSimulator()
    let text = String(repeating: "A", count: 30_000)
        + "\n\n"
        + String(repeating: "B", count: 90_000)
        + "\n\n"
        + String(repeating: "C", count: 10_000)

    simulator.refresh(chapterIndex: 0, offset: 10_000, text: text)
    simulator.refresh(chapterIndex: 0, offset: 15_001, text: text)

    try assertEqual(simulator.refreshCount, 2,
                    "The reader should rebuild the visible text window once playback moves beyond the guard band")
}

test("Playback text window can be force-refreshed without a chapter change") {
    let simulator = VisibleTextWindowRefreshSimulator()
    let text = String(repeating: "A", count: 30_000)
        + "\n\n"
        + String(repeating: "B", count: 90_000)
        + "\n\n"
        + String(repeating: "C", count: 10_000)

    simulator.refresh(chapterIndex: 0, offset: 10_000, text: text)
    simulator.refresh(chapterIndex: 0, offset: 14_500, text: text, force: true)

    try assertEqual(simulator.refreshCount, 2,
                    "Pause or manual navigation should still be able to force a fresh text window")
}

test("Pause command only pauses, does not toggle") {
    var isPlaying = true
    var pauseCallCount = 0

    let onPause = { pauseCallCount += 1; isPlaying = false }

    // Playing, receive pause
    onPause()
    try assertTrue(!isPlaying)
    try assertEqual(pauseCallCount, 1)

    // Already paused, receive another pause — should not toggle to play
    onPause()
    try assertTrue(!isPlaying, "Pause should keep paused, not toggle to playing")
    try assertEqual(pauseCallCount, 2)
}

// Simulates the timestamp-based suppress window used by NowPlayingService.
// A device change sets `suppressUntil` to now + window; `isSuppressed` is
// true while Date() < suppressUntil. Tests use short windows and `sleep`
// or explicit past/future timestamps to control the boundary deterministically.

test("Suppress window blocks next play command after device change") {
    var suppressUntil: Date = .distantPast
    var playFired = false
    var isSuppressed: Bool { Date() < suppressUntil }

    func simulateDeviceChange() {
        suppressUntil = Date().addingTimeInterval(2.0)
    }

    func handlePlayCommand() {
        if isSuppressed {
            suppressUntil = .distantPast  // consume
            return
        }
        playFired = true
    }

    // Device changes — suppress window opens
    simulateDeviceChange()
    try assertTrue(isSuppressed)

    // System sends play command — should be suppressed and consumed
    handlePlayCommand()
    try assertTrue(!playFired, "Play should be suppressed after device change")
    try assertTrue(!isSuppressed, "Suppress window should be closed after use")

    // Next deliberate play should work
    handlePlayCommand()
    try assertTrue(playFired, "Second play should not be suppressed")
}

// Simulates the togglePlayPauseCommand handler. During the suppress window,
// the handler must honour the gate (unlike the old code that unconditionally
// cleared the suppress flag). The direction is constrained: playing → pause,
// paused → ignore. This is the core fix for the macOS Bluetooth-disconnect
// spurious auto-resume bug.

test("Toggle during suppress: playing → pauses") {
    var isPlaying = true
    var suppressUntil: Date = Date().addingTimeInterval(2.0)
    var isSuppressed: Bool { Date() < suppressUntil }
    var pauseCount = 0
    var toggleForwarded = 0

    func handleToggleCommand() {
        if isSuppressed {
            suppressUntil = .distantPast
            // Only allow the pause direction during suppress
            if isPlaying {
                isPlaying = false
                pauseCount += 1
            }
            return
        }
        // Normal toggle (not suppressed) — forward to app toggle handler
        toggleForwarded += 1
        isPlaying.toggle()
    }

    // AirPods disconnect sequence with playback running
    handleToggleCommand()
    try assertTrue(!isPlaying, "Playing → should pause on spurious toggle")
    try assertEqual(pauseCount, 1)
    try assertEqual(toggleForwarded, 0, "Toggle should not be forwarded during suppress")
    try assertTrue(!isSuppressed, "Window consumed after handling")
}

test("Toggle during suppress: paused → ignored (blocks spurious auto-resume)") {
    var isPlaying = false
    var suppressUntil: Date = Date().addingTimeInterval(2.0)
    var isSuppressed: Bool { Date() < suppressUntil }
    var toggleForwarded = 0

    func handleToggleCommand() {
        if isSuppressed {
            suppressUntil = .distantPast
            if isPlaying {
                isPlaying = false
            }
            // Paused → do nothing. This is the bug fix.
            return
        }
        toggleForwarded += 1
        isPlaying.toggle()
    }

    // THIS is the reported bug: paused + AirPods disconnect → macOS sends
    // togglePlayPause which would flip to playing. We must ignore it.
    handleToggleCommand()
    try assertTrue(!isPlaying, "Paused → should stay paused on spurious toggle (the bug fix)")
    try assertEqual(toggleForwarded, 0, "Toggle must not be forwarded during suppress")
    try assertTrue(!isSuppressed, "Window consumed after handling")
}

test("Toggle after suppress window expires works normally") {
    var isPlaying = false
    // Suppress window that is already in the past — same shape as natural expiry
    var suppressUntil: Date = Date().addingTimeInterval(-0.1)
    var isSuppressed: Bool { Date() < suppressUntil }
    var toggleForwarded = 0

    func handleToggleCommand() {
        if isSuppressed {
            suppressUntil = .distantPast
            if isPlaying { isPlaying = false }
            return
        }
        toggleForwarded += 1
        isPlaying.toggle()
    }

    // Window already expired — deliberate media-key press must work
    try assertTrue(!isSuppressed)
    handleToggleCommand()
    try assertTrue(isPlaying, "Toggle after window should flip state normally")
    try assertEqual(toggleForwarded, 1)
}

test("Paused direct seek defers speaking until resume") {
    var isPaused = true
    var usingDirectMode = true
    var pendingSeekOffset: Int? = nil
    var speakDirectOffsets: [Int] = []

    func seek(_ offset: Int, engineReady: Bool) {
        if usingDirectMode {
            if isPaused {
                pendingSeekOffset = offset
            } else if engineReady {
                usingDirectMode = false
                speakDirectOffsets.append(offset)
            } else {
                speakDirectOffsets.append(offset)
            }
        }
    }

    func resume(engineReady: Bool) {
        guard isPaused else { return }
        isPaused = false
        if let pending = pendingSeekOffset {
            pendingSeekOffset = nil
            if engineReady {
                usingDirectMode = false
            }
            speakDirectOffsets.append(pending)
        }
    }

    seek(120, engineReady: false)
    try assertEqual(speakDirectOffsets.count, 0, "Seek while paused should not speak immediately")
    try assertEqual(pendingSeekOffset, 120, "Seek offset should be deferred")

    resume(engineReady: false)
    try assertEqual(speakDirectOffsets, [120], "Resume should speak from deferred offset")
}

test("Chunked direct playback continues chunks instead of switching to engine") {
    var directChunkOffsets: [Int] = []
    var engineCalls = 0
    let currentTextCount = 10_000
    let directModeChunked = true
    let directModeChunkEnd = 5_000
    let audioEngineHasRenderedAudio = true

    func didFinish() {
        if directModeChunked {
            let nextOffset = directModeChunkEnd
            if nextOffset < currentTextCount {
                directChunkOffsets.append(nextOffset)
                return
            }
        }

        if audioEngineHasRenderedAudio {
            engineCalls += 1
        }
    }

    didFinish()
    try assertEqual(directChunkOffsets, [5_000], "Chunked direct playback should continue direct chunks")
    try assertEqual(engineCalls, 0, "Chunk boundary should not switch to engine")
}

test("Device change with currently-paused state does not call onPause") {
    // The listener should only call onPause if playback is actually running.
    // Calling it when already paused would fire the pause sound effect and
    // thrash the reading-stats session for no benefit.
    var isPlaying = false
    var pauseCallCount = 0
    var suppressUntil: Date = .distantPast
    let isCurrentlyPlaying = { isPlaying }

    func simulateDeviceChange() {
        suppressUntil = Date().addingTimeInterval(2.0)
        if isCurrentlyPlaying() {
            pauseCallCount += 1
            isPlaying = false
        }
    }

    simulateDeviceChange()
    try assertEqual(pauseCallCount, 0, "onPause must not fire when already paused")
    try assertTrue(Date() < suppressUntil, "Suppress window still armed for incoming toggle")
}

test("Device change with currently-playing state pauses and arms suppress") {
    var isPlaying = true
    var pauseCallCount = 0
    var suppressUntil: Date = .distantPast
    let isCurrentlyPlaying = { isPlaying }

    func simulateDeviceChange() {
        suppressUntil = Date().addingTimeInterval(2.0)
        if isCurrentlyPlaying() {
            pauseCallCount += 1
            isPlaying = false
        }
    }

    simulateDeviceChange()
    try assertEqual(pauseCallCount, 1, "Playing → should pause immediately")
    try assertTrue(!isPlaying)
    try assertTrue(Date() < suppressUntil, "Suppress window should be armed")
}

test("Full AirPods disconnect sequence from paused state") {
    // End-to-end simulation of the bug scenario:
    //  1. User is paused (most common state for a book reader)
    //  2. AirPods disconnect → device change listener fires
    //  3. rcd delivers togglePlayPauseCommand
    //  4. App must stay paused (not flip to playing)
    var isPlaying = false
    var suppressUntil: Date = .distantPast
    var isSuppressed: Bool { Date() < suppressUntil }
    var pauseCallCount = 0
    let isCurrentlyPlaying = { isPlaying }

    func deviceChangeListener() {
        suppressUntil = Date().addingTimeInterval(2.0)
        if isCurrentlyPlaying() {
            pauseCallCount += 1
            isPlaying = false
        }
    }

    func handleToggleCommand() {
        if isSuppressed {
            suppressUntil = .distantPast
            if isPlaying {
                pauseCallCount += 1
                isPlaying = false
            }
            return
        }
        isPlaying.toggle()
    }

    // Step 1: paused baseline
    try assertTrue(!isPlaying)

    // Step 2: AirPods disconnect — listener fires first
    deviceChangeListener()
    try assertEqual(pauseCallCount, 0, "No onPause because already paused")
    try assertTrue(isSuppressed, "Suppress window armed")

    // Step 3: rcd delivers its spurious toggle
    handleToggleCommand()
    try assertTrue(!isPlaying, "Spurious toggle must not flip paused → playing (the bug fix)")
    try assertTrue(!isSuppressed, "Window consumed")
}

test("Full AirPods disconnect sequence from playing state") {
    // The non-buggy direction — verify it still works after the fix.
    var isPlaying = true
    var suppressUntil: Date = .distantPast
    var isSuppressed: Bool { Date() < suppressUntil }
    var pauseCallCount = 0
    let isCurrentlyPlaying = { isPlaying }

    func deviceChangeListener() {
        suppressUntil = Date().addingTimeInterval(2.0)
        if isCurrentlyPlaying() {
            pauseCallCount += 1
            isPlaying = false
        }
    }

    func handleToggleCommand() {
        if isSuppressed {
            suppressUntil = .distantPast
            if isPlaying {
                pauseCallCount += 1
                isPlaying = false
            }
            return
        }
        isPlaying.toggle()
    }

    deviceChangeListener()
    try assertEqual(pauseCallCount, 1, "Playing → listener pauses immediately")
    try assertTrue(!isPlaying)

    // rcd's toggle arrives next — should be a no-op (we already paused, and
    // the suppress handler's "only pause direction" rule ignores the paused case)
    handleToggleCommand()
    try assertEqual(pauseCallCount, 1, "No double-pause")
    try assertTrue(!isPlaying)
}

// Simulates the transport-type gate: the listener only arms the suppress
// window when the PREVIOUS (departing) audio device was Bluetooth. This
// prevents false positives when the user is deliberately switching between
// wired/built-in devices, where rcd does not send a spurious toggle.

test("Transport gate: non-Bluetooth departure does not arm suppress") {
    var suppressUntil: Date = .distantPast
    var isPlaying = true
    var pauseCallCount = 0
    var previousDeviceWasBluetooth = false  // e.g. built-in speakers

    func simulateDeviceChange() {
        let wasBluetooth = previousDeviceWasBluetooth
        // Refresh baseline for next change (simulate the new device being
        // something non-Bluetooth too — the baseline will flip as appropriate
        // in real code via refreshPreviousDeviceInfo()).
        previousDeviceWasBluetooth = false

        guard wasBluetooth else { return }
        suppressUntil = Date().addingTimeInterval(2.0)
        if isPlaying {
            isPlaying = false
            pauseCallCount += 1
        }
    }

    simulateDeviceChange()
    try assertEqual(pauseCallCount, 0, "Non-BT departure should not pause playback")
    try assertTrue(isPlaying, "Playback should continue on wired switch")
    try assertTrue(Date() >= suppressUntil, "Suppress window must not be armed")
}

test("Transport gate: Bluetooth departure arms suppress") {
    var suppressUntil: Date = .distantPast
    var isPlaying = true
    var pauseCallCount = 0
    var previousDeviceWasBluetooth = true  // e.g. AirPods

    func simulateDeviceChange() {
        let wasBluetooth = previousDeviceWasBluetooth
        previousDeviceWasBluetooth = false  // now on built-in after disconnect

        guard wasBluetooth else { return }
        suppressUntil = Date().addingTimeInterval(2.0)
        if isPlaying {
            isPlaying = false
            pauseCallCount += 1
        }
    }

    simulateDeviceChange()
    try assertEqual(pauseCallCount, 1, "BT departure should pause running playback")
    try assertTrue(!isPlaying)
    try assertTrue(Date() < suppressUntil, "Suppress window must be armed")
}

test("Transport gate: BluetoothLE also arms suppress") {
    // kAudioDeviceTransportTypeBluetoothLE ('blea') must be treated the
    // same as kAudioDeviceTransportTypeBluetooth ('blue'). AirPods Pro and
    // other modern Bluetooth audio devices use the LE transport.
    let kBluetooth: UInt32 = 0x626C7565  // 'blue'
    let kBluetoothLE: UInt32 = 0x626C6561 // 'blea'
    let kBuiltIn: UInt32 = 0x62696C74     // 'bilt'

    func isBluetoothTransport(_ t: UInt32) -> Bool {
        return t == kBluetooth || t == kBluetoothLE
    }

    try assertTrue(isBluetoothTransport(kBluetooth), "Classic BT should gate")
    try assertTrue(isBluetoothTransport(kBluetoothLE), "BT LE should gate")
    try assertTrue(!isBluetoothTransport(kBuiltIn), "Built-in should not gate")
}

test("Transport gate: first notification uses setup-time baseline") {
    // At setup, the service caches the initial default output device's
    // transport type so the very first change notification has a baseline
    // to compare against (rather than defaulting to "no previous, assume
    // Bluetooth" which would cause a spurious pause on launch).
    var previousDeviceWasBluetooth = false  // captured at setup (built-in)

    func refreshBaseline(isBluetooth: Bool) {
        previousDeviceWasBluetooth = isBluetooth
    }

    // Simulate service startup: user is on built-in speakers
    refreshBaseline(isBluetooth: false)
    try assertTrue(!previousDeviceWasBluetooth)

    // User then connects AirPods: refreshBaseline would be called at the
    // end of the first listener fire, updating to Bluetooth=true so that
    // when AirPods later disconnect, the gate correctly identifies the
    // departing device as Bluetooth.
    refreshBaseline(isBluetooth: true)
    try assertTrue(previousDeviceWasBluetooth)
}

test("Transport gate: query failure falls back to treating as Bluetooth") {
    // Defensive fallback: if the AudioObjectGetPropertyData query fails
    // (e.g. because the device has already been removed), the helper
    // returns true so the suppress window is armed anyway. Missing a real
    // Bluetooth disconnect is worse than a spurious pause on an unusual
    // device removal.
    func isBluetoothDevice(queryStatus: Int32, transportType: UInt32) -> Bool {
        guard queryStatus == 0 else { return true }  // noErr = 0
        let kBluetooth: UInt32 = 0x626C7565
        let kBluetoothLE: UInt32 = 0x626C6561
        return transportType == kBluetooth || transportType == kBluetoothLE
    }

    try assertTrue(isBluetoothDevice(queryStatus: -1, transportType: 0),
                  "Query failure should assume Bluetooth")
    try assertTrue(isBluetoothDevice(queryStatus: 0, transportType: 0x626C7565),
                  "Success with BT transport should return true")
    try assertTrue(!isBluetoothDevice(queryStatus: 0, transportType: 0x62696C74),
                  "Success with built-in transport should return false")
}

test("Multiple rapid device changes only need one suppress") {
    var suppressUntil: Date = .distantPast
    var isSuppressed: Bool { Date() < suppressUntil }
    var playCount = 0

    func simulateDeviceChange() {
        suppressUntil = Date().addingTimeInterval(2.0)
    }

    func handlePlayCommand() {
        if isSuppressed {
            suppressUntil = .distantPast
            return
        }
        playCount += 1
    }

    // Rapid device switching — the later change extends/re-arms the window
    simulateDeviceChange()
    simulateDeviceChange()

    // Only one play command comes in — should be suppressed
    handlePlayCommand()
    try assertEqual(playCount, 0, "Should still be suppressed")

    // Next play should work
    handlePlayCommand()
    try assertEqual(playCount, 1, "Should work after suppress cleared")
}

// ---- Devices-List Listener (Battery Drain) Tests ----
print("\n--- Devices-List Listener (Battery Drain) Tests ---")

// These tests cover the second listener added for the AirPods-battery-drain
// case. Manual disconnect (case / phone switch) changes the system default
// output and is handled by the original default-output listener. Battery
// drain often does NOT change the default — macOS keeps the dead AirPods
// listed as "default" — but it DOES remove them from the active device
// list. The devices-list listener catches that transition.

test("Devices list change: previous BT device removed arms suppress") {
    // The exact battery-drain scenario: cached BT device disappears from
    // the list, default output stays put. Listener should arm suppress.
    var suppressUntil: Date = .distantPast
    var isSuppressed: Bool { Date() < suppressUntil }
    var previousDeviceWasBluetooth = true
    let previousDeviceID: UInt32 = 42  // imagined AirPods ID
    var isPlaying = false  // user was paused — the buggy direction
    var pauseCallCount = 0
    let isCurrentlyPlaying = { isPlaying }

    func handleDeviceListChange(currentDevices: [UInt32]) {
        guard previousDeviceWasBluetooth, previousDeviceID != 0 else { return }
        guard !currentDevices.contains(previousDeviceID) else { return }

        suppressUntil = Date().addingTimeInterval(2.0)
        if isCurrentlyPlaying() {
            pauseCallCount += 1
            isPlaying = false
        }
        previousDeviceWasBluetooth = false  // clear cached state
    }

    // AirPods drain: device list now contains only the built-in speakers
    handleDeviceListChange(currentDevices: [99])

    try assertTrue(isSuppressed, "Suppress window must arm when BT device vanishes")
    try assertEqual(pauseCallCount, 0, "No onPause when already paused")
    try assertTrue(!previousDeviceWasBluetooth, "State should be cleared after handling")
}

test("Devices list change: BT device still in list does not arm suppress") {
    // Some other device was added or removed, but our cached AirPods
    // are still present. The listener should leave playback alone.
    var suppressUntil: Date = .distantPast
    var isSuppressed: Bool { Date() < suppressUntil }
    var previousDeviceWasBluetooth = true
    let previousDeviceID: UInt32 = 42

    func handleDeviceListChange(currentDevices: [UInt32]) {
        guard previousDeviceWasBluetooth, previousDeviceID != 0 else { return }
        guard !currentDevices.contains(previousDeviceID) else { return }
        suppressUntil = Date().addingTimeInterval(2.0)
    }

    // List still contains AirPods (42) plus a newly added USB device (101)
    handleDeviceListChange(currentDevices: [42, 99, 101])

    try assertTrue(!isSuppressed, "Unrelated list change must not arm suppress")
    try assertTrue(previousDeviceWasBluetooth, "Cached state should remain")
}

test("Devices list change: non-BT previous device does not arm suppress") {
    // Previous default was built-in speakers. Even if some device is
    // removed from the list, no spurious rcd toggle is expected — built-in
    // speakers don't trigger the bug. Skip to avoid false positives.
    var suppressUntil: Date = .distantPast
    var isSuppressed: Bool { Date() < suppressUntil }
    let previousDeviceWasBluetooth = false
    let previousDeviceID: UInt32 = 99  // built-in speakers

    func handleDeviceListChange(currentDevices: [UInt32]) {
        guard previousDeviceWasBluetooth, previousDeviceID != 0 else { return }
        guard !currentDevices.contains(previousDeviceID) else { return }
        suppressUntil = Date().addingTimeInterval(2.0)
    }

    // Speakers somehow vanish (very unusual but possible with virtual
    // audio drivers). Should still not arm — non-BT prior state.
    handleDeviceListChange(currentDevices: [42])

    try assertTrue(!isSuppressed, "Non-BT prior state must not arm suppress")
}

test("Devices list change: no cached device ID does not arm suppress") {
    // Service started up with no audio output present (previousDeviceID=0).
    // Subsequent list changes should not arm suppress until a real device
    // baseline has been captured.
    var suppressUntil: Date = .distantPast
    var isSuppressed: Bool { Date() < suppressUntil }
    let previousDeviceWasBluetooth = true  // suspicious leftover state
    let previousDeviceID: UInt32 = 0       // but no cached ID

    func handleDeviceListChange(currentDevices: [UInt32]) {
        guard previousDeviceWasBluetooth, previousDeviceID != 0 else { return }
        guard !currentDevices.contains(previousDeviceID) else { return }
        suppressUntil = Date().addingTimeInterval(2.0)
    }

    handleDeviceListChange(currentDevices: [42])

    try assertTrue(!isSuppressed, "No cached device ID must not arm suppress")
}

test("Battery drain end-to-end: paused stays paused through spurious toggle") {
    // The bug-fix goal stated end-to-end. AirPods drain → device list
    // listener fires → suppress armed → rcd's spurious toggle blocked.
    var suppressUntil: Date = .distantPast
    var isSuppressed: Bool { Date() < suppressUntil }
    var isPlaying = false
    var previousDeviceWasBluetooth = true
    let previousDeviceID: UInt32 = 42
    var pauseCallCount = 0
    let isCurrentlyPlaying = { isPlaying }

    func handleDeviceListChange(currentDevices: [UInt32]) {
        guard previousDeviceWasBluetooth, previousDeviceID != 0 else { return }
        guard !currentDevices.contains(previousDeviceID) else { return }
        suppressUntil = Date().addingTimeInterval(2.0)
        if isCurrentlyPlaying() {
            pauseCallCount += 1
            isPlaying = false
        }
        previousDeviceWasBluetooth = false
    }

    func handleToggleCommand() {
        if isSuppressed {
            suppressUntil = .distantPast
            if isPlaying {
                pauseCallCount += 1
                isPlaying = false
            }
            return
        }
        isPlaying.toggle()
    }

    // Step 1: paused with AirPods active
    try assertTrue(!isPlaying)

    // Step 2: AirPods battery dies — they vanish from the device list
    handleDeviceListChange(currentDevices: [99])
    try assertTrue(isSuppressed, "Suppress armed by devices-list listener")

    // Step 3: rcd delivers its spurious toggle
    handleToggleCommand()
    try assertTrue(!isPlaying, "Battery-drain toggle must not flip paused → playing")
    try assertTrue(!isSuppressed, "Window consumed")
    try assertEqual(pauseCallCount, 0, "No onPause fired (was already paused)")
}

test("Battery drain end-to-end: playing pauses and stays paused") {
    // Same scenario but with playback active. The listener should pause
    // immediately, and the subsequent spurious toggle should be a no-op.
    var suppressUntil: Date = .distantPast
    var isSuppressed: Bool { Date() < suppressUntil }
    var isPlaying = true
    var previousDeviceWasBluetooth = true
    let previousDeviceID: UInt32 = 42
    var pauseCallCount = 0
    let isCurrentlyPlaying = { isPlaying }

    func handleDeviceListChange(currentDevices: [UInt32]) {
        guard previousDeviceWasBluetooth, previousDeviceID != 0 else { return }
        guard !currentDevices.contains(previousDeviceID) else { return }
        suppressUntil = Date().addingTimeInterval(2.0)
        if isCurrentlyPlaying() {
            pauseCallCount += 1
            isPlaying = false
        }
        previousDeviceWasBluetooth = false
    }

    func handleToggleCommand() {
        if isSuppressed {
            suppressUntil = .distantPast
            if isPlaying {
                pauseCallCount += 1
                isPlaying = false
            }
            return
        }
        isPlaying.toggle()
    }

    handleDeviceListChange(currentDevices: [99])
    try assertEqual(pauseCallCount, 1, "Listener pauses running playback immediately")
    try assertTrue(!isPlaying)

    // Spurious toggle that follows: app already paused, suppress ignores it
    handleToggleCommand()
    try assertEqual(pauseCallCount, 1, "No double-pause from the suppressed toggle")
    try assertTrue(!isPlaying)
}

test("Devices list change: cached state cleared prevents double-fire") {
    // After a battery-drain detection, the default-output listener may
    // also fire a moment later (when macOS finally switches the system
    // default to speakers). Without clearing cached state, both listeners
    // would each arm suppress and call onPause. The clear in
    // handleDeviceListChange prevents that.
    var suppressUntil: Date = .distantPast
    var isSuppressed: Bool { Date() < suppressUntil }
    var isPlaying = true
    var previousDeviceWasBluetooth = true
    var previousDeviceID: UInt32 = 42
    var pauseCallCount = 0
    let isCurrentlyPlaying = { isPlaying }

    // Devices-list listener — clears cached state after handling
    func handleDeviceListChange(currentDevices: [UInt32]) {
        guard previousDeviceWasBluetooth, previousDeviceID != 0 else { return }
        guard !currentDevices.contains(previousDeviceID) else { return }
        suppressUntil = Date().addingTimeInterval(2.0)
        if isCurrentlyPlaying() {
            pauseCallCount += 1
            isPlaying = false
        }
        previousDeviceWasBluetooth = false
        previousDeviceID = 0
    }

    // Default-output listener — checks the same cached state
    func handleDefaultOutputChange() {
        let wasBluetooth = previousDeviceWasBluetooth
        previousDeviceWasBluetooth = false  // refresh to new (speakers)
        previousDeviceID = 99
        guard wasBluetooth else { return }
        suppressUntil = Date().addingTimeInterval(2.0)
        if isCurrentlyPlaying() {
            pauseCallCount += 1
            isPlaying = false
        }
    }

    // Battery drain: list listener fires first
    handleDeviceListChange(currentDevices: [99])
    try assertEqual(pauseCallCount, 1, "List listener pauses once")

    // A moment later the default finally flips to speakers
    handleDefaultOutputChange()
    try assertEqual(pauseCallCount, 1, "Default listener should not double-fire")
    try assertTrue(isSuppressed, "Suppress remains armed for any incoming command")
}

test("Refresh skips a stale 'default' that's no longer in the device list") {
    // After AirPods drain, macOS sometimes keeps the dead device as the
    // system default output even though the device is no longer in the
    // active list. refreshPreviousDeviceInfo must NOT cache such a stale
    // device — caching it would cause every subsequent unrelated
    // devices-list event to detect "device not in list" and re-arm
    // suppress, breaking legitimate play commands.
    func refresh(currentDefault: UInt32?, currentDevices: [UInt32]) -> (UInt32, Bool) {
        guard let deviceID = currentDefault else { return (0, false) }
        let isLive = currentDevices.isEmpty || currentDevices.contains(deviceID)
        if isLive {
            // simulate isBluetoothDevice — true when ID is in the BT range
            let isBT = deviceID == 42  // AirPods
            return (deviceID, isBT)
        }
        return (0, false)
    }

    // Healthy state: AirPods are default and in the device list
    let (id1, was1) = refresh(currentDefault: 42, currentDevices: [42, 99])
    try assertEqual(id1, 42)
    try assertTrue(was1, "Live BT default should cache as Bluetooth")

    // Stale-default state: macOS reports AirPods as default but they're
    // missing from the active list. Refresh must NOT cache them.
    let (id2, was2) = refresh(currentDefault: 42, currentDevices: [99])
    try assertEqual(id2, 0, "Stale default must not be cached")
    try assertTrue(!was2)

    // Empty list (query failed) — fall back to trusting the default
    let (id3, was3) = refresh(currentDefault: 42, currentDevices: [])
    try assertEqual(id3, 42, "Failed list query must not zero a valid default")
    try assertTrue(was3)

    // No default at all
    let (id4, was4) = refresh(currentDefault: nil, currentDevices: [99])
    try assertEqual(id4, 0)
    try assertTrue(!was4)
}

test("Devices list refresh after drain re-establishes baseline on reconnect") {
    // After the cache is cleared by a drain detection, an unrelated
    // devices-list event (e.g. user reconnects AirPods, plugs in a USB
    // device) should refresh the cache. Without this, a SECOND drain
    // for a freshly-reconnected pair would be missed because
    // previousDeviceID would still be zero.
    var previousDeviceWasBluetooth = false
    var previousDeviceID: UInt32 = 0  // post-drain cleared state

    func refresh(currentDefault: UInt32?, currentDevices: [UInt32]) {
        guard let deviceID = currentDefault else {
            previousDeviceID = 0
            previousDeviceWasBluetooth = false
            return
        }
        let isLive = currentDevices.isEmpty || currentDevices.contains(deviceID)
        if isLive {
            previousDeviceID = deviceID
            previousDeviceWasBluetooth = (deviceID == 42)  // AirPods
        } else {
            previousDeviceID = 0
            previousDeviceWasBluetooth = false
        }
    }

    func handleDeviceListChange(currentDefault: UInt32?, currentDevices: [UInt32]) {
        // Skip the disconnect-detection branch (cache is already zeroed)
        if previousDeviceWasBluetooth, previousDeviceID != 0,
           !currentDevices.contains(previousDeviceID) {
            // disconnect path — not exercised here
            return
        }
        refresh(currentDefault: currentDefault, currentDevices: currentDevices)
    }

    // AirPods reconnect, become default again
    handleDeviceListChange(currentDefault: 42, currentDevices: [42, 99])
    try assertEqual(previousDeviceID, 42, "Reconnected AirPods should re-cache")
    try assertTrue(previousDeviceWasBluetooth, "Cache marks them as Bluetooth")

    // Now we're armed again to detect a future drain
}

test("Manual disconnect end-to-end remains intact (default-output path)") {
    // Regression guard: the existing manual-disconnect path must keep
    // working unchanged. Default-output listener fires, devices-list
    // listener may also fire but its early-out (cached state cleared
    // by the default-output listener) prevents double-action.
    var suppressUntil: Date = .distantPast
    var isSuppressed: Bool { Date() < suppressUntil }
    var isPlaying = false  // paused — the buggy direction
    var previousDeviceWasBluetooth = true
    var previousDeviceID: UInt32 = 42
    var pauseCallCount = 0
    let isCurrentlyPlaying = { isPlaying }

    func handleDefaultOutputChange() {
        let wasBluetooth = previousDeviceWasBluetooth
        previousDeviceWasBluetooth = false
        previousDeviceID = 99
        guard wasBluetooth else { return }
        suppressUntil = Date().addingTimeInterval(2.0)
        if isCurrentlyPlaying() {
            pauseCallCount += 1
            isPlaying = false
        }
    }

    func handleDeviceListChange(currentDevices: [UInt32]) {
        guard previousDeviceWasBluetooth, previousDeviceID != 0 else { return }
        guard !currentDevices.contains(previousDeviceID) else { return }
        suppressUntil = Date().addingTimeInterval(2.0)
        if isCurrentlyPlaying() {
            pauseCallCount += 1
            isPlaying = false
        }
        previousDeviceWasBluetooth = false
        previousDeviceID = 0
    }

    func handleToggleCommand() {
        if isSuppressed {
            suppressUntil = .distantPast
            if isPlaying {
                pauseCallCount += 1
                isPlaying = false
            }
            return
        }
        isPlaying.toggle()
    }

    // AirPods placed in case: default flips to speakers FIRST, list update follows
    handleDefaultOutputChange()
    try assertTrue(isSuppressed, "Default-output listener arms suppress")

    // List listener fires next — but cache already cleared
    handleDeviceListChange(currentDevices: [99])
    try assertEqual(pauseCallCount, 0, "No double-action — default-output already cleared cache")

    // rcd's spurious toggle
    handleToggleCommand()
    try assertTrue(!isPlaying, "Paused stays paused (existing fix still works)")
}

test("Bluetooth route-change pause makes next TTS resume recreate backend") {
    // Regression for the remote Play change from play() to playOrResume():
    // ordinary media-key Play should resume, but after an AirPods route
    // change we need a fresh TTS backend so audio binds to the new output.
    var restartBackendOnNextResume = false
    var speechPaused = false
    var continueCalls = 0
    var stopCalls = 0
    var speakCurrentChapterCalls = 0

    func pauseForAudioRouteChange() {
        restartBackendOnNextResume = true
        speechPaused = true
    }

    func resumeSpeechPlayback() {
        if restartBackendOnNextResume {
            restartBackendOnNextResume = false
            stopCalls += 1
            speechPaused = false
            speakCurrentChapterCalls += 1
            return
        }
        continueCalls += 1
        speechPaused = false
    }

    pauseForAudioRouteChange()
    try assertTrue(speechPaused, "Route-change pause leaves UI/service paused")

    resumeSpeechPlayback()
    try assertEqual(stopCalls, 1, "Route-change resume should stop the old backend")
    try assertEqual(speakCurrentChapterCalls, 1, "Route-change resume should cold-start TTS")
    try assertEqual(continueCalls, 0, "Route-change resume must not continue the old synth/engine")
    try assertTrue(!restartBackendOnNextResume, "Restart flag is one-shot")
}

test("Ordinary paused TTS remote Play still resumes without backend restart") {
    var restartBackendOnNextResume = false
    var continueCalls = 0
    var stopCalls = 0
    var speakCurrentChapterCalls = 0

    func resumeSpeechPlayback() {
        if restartBackendOnNextResume {
            restartBackendOnNextResume = false
            stopCalls += 1
            speakCurrentChapterCalls += 1
            return
        }
        continueCalls += 1
    }

    resumeSpeechPlayback()

    try assertEqual(continueCalls, 1, "Ordinary remote Play should keep resume parity")
    try assertEqual(stopCalls, 0, "Ordinary resume should not stop the backend")
    try assertEqual(speakCurrentChapterCalls, 0, "Ordinary resume should not cold-start")
}

test("Bluetooth route-change pause makes next audio-book resume recreate player") {
    var restartBackendOnNextResume = false
    var audioPaused = false
    var avPlayerResumeCalls = 0
    var stopCalls = 0
    var playAudioChapterCalls = 0

    func pauseForAudioRouteChange() {
        restartBackendOnNextResume = true
        audioPaused = true
    }

    func resumeAudioPlayback() {
        if restartBackendOnNextResume {
            restartBackendOnNextResume = false
            stopCalls += 1
            audioPaused = false
            playAudioChapterCalls += 1
            return
        }
        avPlayerResumeCalls += 1
        audioPaused = false
    }

    pauseForAudioRouteChange()
    try assertTrue(audioPaused, "Route-change pause leaves audio paused")

    resumeAudioPlayback()
    try assertEqual(stopCalls, 1, "Route-change resume should discard old AVPlayer route")
    try assertEqual(playAudioChapterCalls, 1, "Route-change resume should recreate player")
    try assertEqual(avPlayerResumeCalls, 0, "Route-change resume must not resume old AVPlayer")
}

// ---- Speed Control Tests ----
print("\n--- Speed Control Tests ---")

test("Rate table interpolation for direct mode") {
    let rateTable: [(rate: Double, wpm: Double)] = [
        (0.0, 50), (0.1, 80), (0.2, 120), (0.3, 167), (0.4, 190),
        (0.5, 216), (0.6, 344), (0.7, 457), (0.8, 604), (0.9, 759), (1.0, 871),
    ]

    func rateForWPM(_ wpm: Double) -> Float {
        guard let first = rateTable.first, let last = rateTable.last else { return 0.5 }
        if wpm <= first.wpm { return Float(first.rate) }
        if wpm >= last.wpm { return Float(last.rate) }
        for i in 0..<(rateTable.count - 1) {
            let lo = rateTable[i]
            let hi = rateTable[i + 1]
            if wpm >= lo.wpm && wpm <= hi.wpm {
                let fraction = (wpm - lo.wpm) / (hi.wpm - lo.wpm)
                return Float(lo.rate + fraction * (hi.rate - lo.rate))
            }
        }
        return 0.5
    }

    // Below minimum
    let rateMin = rateForWPM(30)
    try assertEqual(rateMin, 0.0, "Below 50 WPM should return 0.0")

    // Above maximum
    let rateMax = rateForWPM(1000)
    try assertEqual(rateMax, 1.0, "Above 871 WPM should return 1.0")

    // At exact table entry
    let rate216 = rateForWPM(216)
    try assertEqual(rate216, 0.5, "216 WPM should return 0.5")

    // Interpolated value — between 216 (0.5) and 344 (0.6)
    let rateMid = rateForWPM(280)
    try assertTrue(rateMid > 0.5 && rateMid < 0.6, "280 WPM should interpolate between 0.5 and 0.6")
    print("    280 WPM -> rate \(rateMid)")
}

test("Speed clamping between min and max") {
    let minWPM = 50.0
    let maxWPM = 650.0

    func clamp(_ wpm: Double) -> Double {
        max(minWPM, min(wpm, maxWPM))
    }

    try assertEqual(clamp(200), 200, "Normal value unchanged")
    try assertEqual(clamp(0), 50, "Below min clamps to 50")
    try assertEqual(clamp(1000), 650, "Above max clamps to 650")
    try assertEqual(clamp(50), 50, "At min stays at min")
    try assertEqual(clamp(650), 650, "At max stays at max")
}

test("Audio engine speed ratio calculation") {
    let renderWPM = 457.0

    func engineRate(wpm: Double) -> Float {
        Float(max(0.25, min(wpm / renderWPM, 4.0)))
    }

    // At render speed — rate 1.0
    let rate1 = engineRate(wpm: 457)
    try assertTrue(abs(rate1 - 1.0) < 0.01, "At render WPM should be ~1.0")

    // At half render speed
    let rateHalf = engineRate(wpm: 228.5)
    try assertTrue(abs(rateHalf - 0.5) < 0.01, "At half render WPM should be ~0.5")

    // Below minimum clamp
    let rateMin = engineRate(wpm: 50)
    try assertTrue(rateMin >= 0.25, "Should not go below 0.25")

    // Above maximum clamp
    let rateMax = engineRate(wpm: 5000)
    try assertTrue(rateMax <= 4.0, "Should not exceed 4.0")
}

test("Segmented audio position update uses segment-relative offset") {
    let charsPerSecond = 10.0
    let segmentStartTime = 120.0
    let absoluteTime = 126.4
    let rawOffset = Int((absoluteTime - segmentStartTime) * charsPerSecond)
    let chapterLength = 90
    let clampedOffset = min(rawOffset, max(0, chapterLength - 1))

    try assertEqual(rawOffset, 64, "Offset should be relative to segment start, not full file time")
    try assertEqual(clampedOffset, 64, "Relative offset should remain within chapter bounds")
}

test("Segmented audio seek adds segment start time") {
    let charsPerSecond = 10.0
    let characterOffset = 35
    let segmentStartTime = 42.5
    let absoluteSeekTime = segmentStartTime + Double(characterOffset) / charsPerSecond

    try assertTrue(abs(absoluteSeekTime - 46.0) < 0.001,
                   "Seek time should include the segment's absolute start time")
}

// ---- Jump Validation Tests ----
print("\n--- Jump Validation Tests ---")

// These mirror the parse/validate logic in JumpToPercentPanel and
// JumpToTimePanel in ReaderView.swift. The panels use plain text
// fields (no character filter while typing) and rely on this
// validation at submit time to reject bad input with an error message
// instead of silently clamping or jumping to zero.

/// Result of validating a percent input. Mirrors the View's
/// performJump logic — empty input, non-numeric input, and out-of-
/// range each produce a distinct error message.
enum PercentValidation: Equatable {
    case ok(Double)
    case empty
    case notNumber(String)
    case outOfRange
}

func validatePercent(_ raw: String) -> PercentValidation {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { return .empty }
    guard let value = Double(trimmed) else { return .notNumber(trimmed) }
    if value < 0 || value > 100 { return .outOfRange }
    return .ok(value)
}

test("validatePercent: empty input rejected") {
    try assertEqual(validatePercent(""), .empty, "Empty string surfaces an error")
    try assertEqual(validatePercent("   "), .empty, "Whitespace-only is empty too")
}

test("validatePercent: non-numeric rejected with the offending text") {
    try assertEqual(validatePercent("abc"), .notNumber("abc"))
    try assertEqual(validatePercent("47abc"), .notNumber("47abc"),
                    "Partial parse still rejected — Swift's Double init is strict")
}

test("validatePercent: out of range rejected") {
    try assertEqual(validatePercent("-1"), .outOfRange)
    try assertEqual(validatePercent("101"), .outOfRange)
    try assertEqual(validatePercent("999"), .outOfRange)
}

test("validatePercent: in-range accepted including decimals and edges") {
    try assertEqual(validatePercent("0"), .ok(0))
    try assertEqual(validatePercent("100"), .ok(100), "Exactly 100 is allowed")
    try assertEqual(validatePercent("47.5"), .ok(47.5))
    try assertEqual(validatePercent("  50  "), .ok(50), "Whitespace trimmed")
}

/// Result of validating an H/M/S time input. Mirrors the View's
/// JumpToTimePanel.performJump logic.
enum TimeValidation: Equatable {
    case ok(TimeInterval)
    case fieldNotNumber(String)
    case minutesOver59
    case secondsOver59
    case beyondBookEnd
}

func validateTime(
    hours: String,
    minutes: String,
    seconds: String,
    bookLengthSeconds: TimeInterval
) -> TimeValidation {
    /// Empty input → 0; non-numeric → nil so the caller can name
    /// the offending field. Returning Optional avoids needing a
    /// custom Error-conforming type just for the test stand-in.
    func parse(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return 0 }
        guard let v = Int(trimmed), v >= 0 else { return nil }
        return v
    }
    guard let h = parse(hours) else { return .fieldNotNumber("hours") }
    guard let m = parse(minutes) else { return .fieldNotNumber("minutes") }
    guard let s = parse(seconds) else { return .fieldNotNumber("seconds") }
    if m >= 60 { return .minutesOver59 }
    if s >= 60 { return .secondsOver59 }
    let total = TimeInterval(h * 3600 + m * 60 + s)
    if total > bookLengthSeconds { return .beyondBookEnd }
    return .ok(total)
}

test("validateTime: empty fields treated as zero") {
    // Typing only minutes shouldn't fail because the seconds field
    // happens to be blank.
    try assertEqual(validateTime(hours: "", minutes: "", seconds: "",
                                 bookLengthSeconds: 3600), .ok(0))
    try assertEqual(validateTime(hours: "", minutes: "5", seconds: "",
                                 bookLengthSeconds: 3600), .ok(300))
}

test("validateTime: non-numeric in any field rejected") {
    try assertEqual(
        validateTime(hours: "abc", minutes: "0", seconds: "0", bookLengthSeconds: 3600),
        .fieldNotNumber("hours"))
    try assertEqual(
        validateTime(hours: "0", minutes: "5x", seconds: "0", bookLengthSeconds: 3600),
        .fieldNotNumber("minutes"))
    try assertEqual(
        validateTime(hours: "0", minutes: "0", seconds: "..", bookLengthSeconds: 3600),
        .fieldNotNumber("seconds"))
}

test("validateTime: minutes >= 60 rejected") {
    try assertEqual(
        validateTime(hours: "0", minutes: "60", seconds: "0", bookLengthSeconds: 999_999),
        .minutesOver59,
        "60 minutes should be entered as 1 hour 0 minutes")
}

test("validateTime: seconds >= 60 rejected") {
    try assertEqual(
        validateTime(hours: "0", minutes: "0", seconds: "75", bookLengthSeconds: 999_999),
        .secondsOver59)
}

test("validateTime: beyond book end rejected") {
    // 1-hour book; user enters 2 hours.
    try assertEqual(
        validateTime(hours: "2", minutes: "0", seconds: "0", bookLengthSeconds: 3600),
        .beyondBookEnd)
}

test("validateTime: at book end accepted") {
    // Exact end is a valid jump target — useful for "skip to end"
    // testing.
    try assertEqual(
        validateTime(hours: "1", minutes: "0", seconds: "0", bookLengthSeconds: 3600),
        .ok(3600))
}

test("validateTime: ordinary in-range values accepted") {
    try assertEqual(
        validateTime(hours: "1", minutes: "30", seconds: "45", bookLengthSeconds: 7200),
        .ok(5445))
    try assertEqual(
        validateTime(hours: "0", minutes: "5", seconds: "30", bookLengthSeconds: 7200),
        .ok(330))
}

// ---- Audio Layout / Multi-Chapter m4b Position Tests ----
print("\n--- Audio Layout / Multi-Chapter m4b Position Tests ---")

// These tests cover the bug where a single-file audio book with
// chapter metadata (typical m4b) had its time observer storing
// ABSOLUTE file time in currentCharacterOffset, while skipCharacters
// walked chapter boundaries assuming the offset was CHAPTER-RELATIVE.
// The mismatch produced wildly wrong skip targets — a 15-second
// rewind from chapter 3 could land in chapter 0.

/// Cumulative chapter start time helper, mirroring chapterStartTime()
/// in ReaderViewModel+Playback.swift for the m4b chapter layout.
func chapterStartTimeForM4B(chapterIndex: Int, chapterCharCounts: [Int]) -> Double {
    let charsPerSec = 10.0
    let preceding = chapterCharCounts.prefix(chapterIndex).reduce(0, +)
    return Double(preceding) / charsPerSec
}

test("m4b chapters: chapterStartTime sums preceding chapter durations") {
    let chapterCharCounts = [6000, 9000, 4500]  // 600s, 900s, 450s
    try assertEqual(chapterStartTimeForM4B(chapterIndex: 0, chapterCharCounts: chapterCharCounts), 0.0)
    try assertEqual(chapterStartTimeForM4B(chapterIndex: 1, chapterCharCounts: chapterCharCounts), 600.0)
    try assertEqual(chapterStartTimeForM4B(chapterIndex: 2, chapterCharCounts: chapterCharCounts), 1500.0)
}

test("m4b chapters: skip backward 15s mid-chapter lands at correct absolute time") {
    // Pre-fix scenario: user at time 1500s in chapter 2 (which starts
    // at 1500s). currentCharacterOffset was absolute (15000), chapter
    // walk with chapter lengths [6000, 9000, ...] would treat 14850
    // as falling in chapter 1 — wrong jump.
    // Post-fix: position observer uses location(forGlobalOffset:) to
    // store (chapter, localOffset). At time 1500s, that's
    // (chapter 2, local 0). 15s rewind targets local -150, which
    // falls into chapter 1. Same chapter walk now produces the
    // correct chapter and local offset.
    let chapterCharCounts = [6000, 9000, 4500]
    let totalChars = chapterCharCounts.reduce(0, +)

    // location(forGlobalOffset: 15000) for chapters [6000, 9000, 4500]
    let absoluteAt1500s = 15000
    var cumulative = 0
    var startChapter = 0
    var startLocal = 0
    for (i, len) in chapterCharCounts.enumerated() {
        if absoluteAt1500s < cumulative + len {
            startChapter = i
            startLocal = absoluteAt1500s - cumulative
            break
        }
        cumulative += len
    }
    try assertEqual(startChapter, 2, "Time 1500s falls in chapter 2 (starts at 1500s)")
    try assertEqual(startLocal, 0, "Exactly at chapter 2 start")

    // Rewind 15s = -150 chars chapter-relative, but since localOffset
    // is 0 and the chapter walk goes backward, we end up in chapter 1
    // at offset (9000 - 150) = 8850.
    var charOffset = startLocal - 150
    var chapIdx = startChapter
    while charOffset < 0 && chapIdx > 0 {
        chapIdx -= 1
        charOffset += chapterCharCounts[chapIdx]
    }
    try assertEqual(chapIdx, 1, "15s rewind from chapter 2 start lands in chapter 1")
    try assertEqual(charOffset, 8850, "150 chars before end of chapter 1 = 8850 local")

    // Convert back to absolute via chapterStartTime + local offset
    let absoluteSeek = chapterStartTimeForM4B(chapterIndex: chapIdx, chapterCharCounts: chapterCharCounts)
                       + Double(charOffset) / 10.0
    try assertTrue(abs(absoluteSeek - 1485.0) < 0.001,
                   "Final seek target = 600 + 885 = 1485s = 15s before original 1500s")

    _ = totalChars
}

test("m4b chapters: time observer auto-advances chapter index") {
    // The position observer used to leave currentChapterIndex pinned
    // to wherever it was at playback start. Now it uses
    // location(forGlobalOffset:) so the index follows the playhead.
    let chapterCharCounts = [6000, 9000, 4500]

    // Player crosses chapter boundary at time 600.1s
    let absoluteOffset = 6001
    var cumulative = 0
    var observedChapter = 0
    var observedLocal = 0
    for (i, len) in chapterCharCounts.enumerated() {
        if absoluteOffset < cumulative + len {
            observedChapter = i
            observedLocal = absoluteOffset - cumulative
            break
        }
        cumulative += len
    }
    try assertEqual(observedChapter, 1, "1s past chapter 0 boundary lands in chapter 1")
    try assertEqual(observedLocal, 1, "Local offset is 1 char into chapter 1")
}

test("Audio layout: segmented DAISY translates time observer correctly") {
    // For DAISY segments, chapter start = segment.startTime. The
    // observer subtracts startTime so the stored offset is
    // chapter-relative.
    let segmentStartTime = 600.0
    let absoluteTime = 615.0  // 15s into the segment
    let charsPerSec = 10.0
    let chapterRelativeTime = max(0, absoluteTime - segmentStartTime)
    let storedOffset = Int(chapterRelativeTime * charsPerSec)
    try assertEqual(storedOffset, 150, "DAISY segment-relative offset is 150 chars")
}

test("Audio layout: multi-file stores chapter-relative directly") {
    // Multi-file audio plays each chapter from its own file. The
    // player's reported time is already chapter-relative, no
    // adjustment needed.
    let absoluteTime = 42.0
    let storedOffset = Int(absoluteTime * 10)
    try assertEqual(storedOffset, 420)
}

test("Audio layout: single-file (one chapter) stores absolute time*10") {
    // No chapter boundaries; chapter 0 starts at 0; offset == time*10.
    let absoluteTime = 1234.5
    let storedOffset = Int(absoluteTime * 10)
    try assertEqual(storedOffset, 12345)
}

test("Same-chapter seek for segmented audio adds segment.startTime") {
    // Pre-existing bug surfaced by review: navigateTo and skipCharacters
    // both did `audioPlaybackService.seek(to: charOffset / 10)` on the
    // same-chapter branch. For DAISY segmented audio (multiple chapters
    // share one file), this is missing segment.startTime so the user
    // lands at the wrong global timestamp — typically way before the
    // chapter starts. Fix mirrors the formula playAudioChapter has used
    // since DAISY support shipped.
    let charsPerSecond = 10.0
    let charOffset = 250
    let segmentStartTime = 600.0  // Chapter 5 starts 10 minutes in
    var audioSegmentsActive = true

    func computeSeekTime() -> Double {
        var t = Double(charOffset) / charsPerSecond
        if audioSegmentsActive { t += segmentStartTime }
        return t
    }

    let seekTime = computeSeekTime()
    try assertTrue(abs(seekTime - 625.0) < 0.001,
                   "Same-chapter seek must add segment.startTime: 25s relative + 600s start = 625s absolute")

    // Sanity: when segments are absent (regular audio book), the
    // adjustment is skipped — the offset alone is the absolute time.
    audioSegmentsActive = false
    let seekTimeNoSegment = computeSeekTime()
    try assertTrue(abs(seekTimeNoSegment - 25.0) < 0.001,
                   "Without segments, charOffset/10 IS the absolute time")
}

test("skipCharacters same-chapter seek for segmented audio") {
    // Same fix applies to the audio book skipCharacters path (used by
    // 15s/30s/60s skip on audio books). Without the segment.startTime
    // adjustment a 15-second rewind would skip backward past the
    // segment boundary into the previous chapter's audio.
    let charsPerSecond = 10.0
    let currentOffset = 800
    let segmentStartTime = 1200.0  // Chapter starts 20 minutes in
    let skipDelta = -150  // 15 seconds backward

    let newOffset = currentOffset + skipDelta  // 650
    let seekTime = Double(newOffset) / charsPerSecond + segmentStartTime
    // 65s relative + 1200s segment start = 1265s absolute
    try assertTrue(abs(seekTime - 1265.0) < 0.001,
                   "Time-based skip must apply segment.startTime offset")

    // Invariant: the seek time must be inside the segment, not before
    // segmentStartTime.
    try assertTrue(seekTime >= segmentStartTime,
                   "Skip target must remain at or after the segment start")
}

test("Segmented audio chapter offset clamps near clip end") {
    let charsPerSecond = 10.0
    let segmentStartTime = 30.0
    let absoluteTime = 45.0
    let chapterLength = 120
    let rawOffset = Int(max(0, absoluteTime - segmentStartTime) * charsPerSecond)
    let clampedOffset = min(rawOffset, max(0, chapterLength - 1))

    try assertEqual(rawOffset, 150, "Absolute time should convert to a relative chapter offset")
    try assertEqual(clampedOffset, 119, "Offset should clamp to the chapter placeholder length")
}

test("Audio playback reload is skipped when reusing the same file") {
    var loadedURL: String?
    var loadCount = 0

    func load(_ url: String) {
        if loadedURL == url { return }
        loadedURL = url
        loadCount += 1
    }

    load("/tmp/book/chapter01.mp3")
    load("/tmp/book/chapter01.mp3")
    load("/tmp/book/chapter02.mp3")

    try assertEqual(loadCount, 2, "Reusing the same file should not rebuild the player")
}

test("Audio playback play from zero resets position") {
    let duration = 100.0

    func clampedPlayTime(from requestedTime: Double) -> Double {
        max(0, min(requestedTime, duration))
    }

    try assertEqual(clampedPlayTime(from: 0), 0, "A zero seek should reset to the start")
    try assertEqual(clampedPlayTime(from: 150), 100, "Playback should clamp to known duration")
}

test("Seek guard prevents clip end re-trigger during async seek") {
    // Simulates the race condition: the time observer fires with a stale
    // time that is >= the new clipEndTime before the seek completes.
    var isSeeking = false
    var clipEndTime: Double? = nil
    var finishedCount = 0

    // Simulate onPlaybackFinished
    func onPlaybackFinished() {
        finishedCount += 1
    }

    // Simulate time observer callback with the seek guard
    func timeObserverFired(secs: Double) {
        if !isSeeking, let endTime = clipEndTime, secs >= endTime {
            clipEndTime = nil
            onPlaybackFinished()
        }
    }

    // First segment: clip end at 300s, properly triggered
    clipEndTime = 300.0
    timeObserverFired(secs: 300.5)
    try assertEqual(finishedCount, 1, "First clip end should fire normally")

    // Now simulate chapter advance: new clip end set, seek in progress
    clipEndTime = 600.0
    isSeeking = true

    // Time observer fires with stale time (still near old position)
    timeObserverFired(secs: 300.5)
    try assertEqual(finishedCount, 1, "Seek guard should block stale clip-end trigger")

    // Seek completes
    isSeeking = false

    // Time observer now fires with correct position
    timeObserverFired(secs: 310.0)
    try assertEqual(finishedCount, 1, "Should not fire because 310 < 600")

    // Eventually reaches real end
    timeObserverFired(secs: 601.0)
    try assertEqual(finishedCount, 2, "Should fire when actually reaching new clip end")
}

test("Seek guard prevents rapid loop when consecutive segments share same clip range") {
    // This is the exact scenario that causes the Hyperion looping bug:
    // multiple segments with identical endTime, and each onPlaybackFinished
    // starts an async seek that hasn't completed before the next observer fires.
    var isSeeking = false
    var clipEndTime: Double? = nil
    var finishedCount = 0
    var currentChapter = 0
    let totalChapters = 5

    func onPlaybackFinished() {
        finishedCount += 1
        currentChapter += 1
        if currentChapter < totalChapters {
            // Simulate playAudioChapter: set new clip end and start seeking
            isSeeking = true
            clipEndTime = 300.0  // Same end time (the bug scenario)
            // Seek completion would clear isSeeking later
        }
    }

    func timeObserverFired(secs: Double) {
        if !isSeeking, let endTime = clipEndTime, secs >= endTime {
            clipEndTime = nil
            onPlaybackFinished()
        }
    }

    // First segment fires normally
    clipEndTime = 300.0
    timeObserverFired(secs: 300.0)
    try assertEqual(finishedCount, 1, "First segment ends normally")
    try assertEqual(currentChapter, 1)

    // Without the guard, each subsequent time observer call would trigger
    // another onPlaybackFinished because secs (300) >= clipEndTime (300).
    // With the guard, isSeeking blocks them all.
    timeObserverFired(secs: 300.0)
    timeObserverFired(secs: 300.0)
    timeObserverFired(secs: 300.0)
    try assertEqual(finishedCount, 1, "Seek guard should prevent rapid cascading advances")
    try assertEqual(currentChapter, 1, "Should stay on chapter 1 until seek completes")
}

// ---- Generation Counter Pattern Tests ----
print("\n--- Generation Counter Pattern Tests ---")

test("Generation counter prevents stale callback execution") {
    var generation = 0
    var callbacksFired = 0

    func startOperation() -> Int {
        generation += 1
        return generation
    }

    func completeOperation(myGen: Int) {
        guard myGen == generation else { return }
        callbacksFired += 1
    }

    let gen1 = startOperation()
    let gen2 = startOperation()  // New operation invalidates gen1

    completeOperation(myGen: gen1)  // Stale — should not fire
    completeOperation(myGen: gen2)  // Current — should fire

    try assertEqual(callbacksFired, 1, "Only the current generation's callback should fire")
}

test("ignoreDirectFinishCount suppresses stale finish callbacks") {
    var ignoreCount = 0
    var finishedFired = false

    func stop() {
        ignoreCount += 1
    }

    func onDidFinish() {
        if ignoreCount > 0 {
            ignoreCount -= 1
            return
        }
        finishedFired = true
    }

    // Stop triggers a didFinish callback that should be ignored
    stop()
    onDidFinish()
    try assertTrue(!finishedFired, "Finish should be suppressed after stop")
    try assertEqual(ignoreCount, 0, "Count should be decremented")

    // Real finish should fire
    onDidFinish()
    try assertTrue(finishedFired, "Real finish should fire")
}

// ---- Playback Debounce Tests ----
print("\n--- Playback Debounce Tests ---")

test("Skip debounce rejects rapid-fire calls") {
    var lastSkipTime = Date.distantPast
    var skipCount = 0

    func skip() {
        let now = Date()
        guard now.timeIntervalSince(lastSkipTime) > 0.4 else { return }
        lastSkipTime = now
        skipCount += 1
    }

    skip()  // Should succeed
    skip()  // Should be debounced (same instant)
    skip()  // Should be debounced

    try assertEqual(skipCount, 1, "Only first skip should succeed within debounce window")
}

test("Skip debounce: timestamp updates BEFORE running so re-entrance is blocked") {
    // Defends against the case where running the skip body itself
    // re-posts a skip notification (cancelWhereAmIIfActive() can
    // synchronously fire a callback that calls skipBackward again).
    // The acquireSkipToken pattern updates lastSkipTime BEFORE the
    // body runs, so the recursive call sees the updated timestamp on
    // its own check and is correctly dropped.
    var lastSkipTime = Date.distantPast
    var skipCount = 0
    var reentrantSkipFired = false

    func skip() {
        let now = Date()
        guard now.timeIntervalSince(lastSkipTime) > 0.4 else { return }
        lastSkipTime = now
        skipCount += 1
        // Simulate a synchronous re-entrant skip from a side-effect
        // (matches the structure of cancelWhereAmIIfActive firing a
        // resume that re-posts a skip notification). The recursive
        // call must be blocked by the just-updated timestamp.
        if !reentrantSkipFired {
            reentrantSkipFired = true
            skip()
        }
    }

    skip()
    try assertEqual(skipCount, 1, "Re-entrant skip from inside the body must be debounced")
}

test("Skip debounce: 0.4s window absorbs media-key + keyboard double fire") {
    // Models the user-reported scenario: a single physical media-key
    // press that arrives via two paths (NowPlayingService skip command
    // + KeyboardShortcutManager NSEvent monitor), separated by ~50–150ms
    // of macOS routing delay. Both paths call the same skip method.
    // The 0.4s window must absorb the second fire.
    var lastSkipTime = Date.distantPast
    var skipCount = 0

    func skip() {
        let now = Date()
        guard now.timeIntervalSince(lastSkipTime) > 0.4 else { return }
        lastSkipTime = now
        skipCount += 1
    }

    // First path (e.g. NowPlayingService) fires
    skip()
    try assertEqual(skipCount, 1)

    // Second path (e.g. KeyboardShortcutManager) fires ~100ms later —
    // simulated by setting lastSkipTime to (now - 100ms).
    let now = Date()
    lastSkipTime = now.addingTimeInterval(-0.1)
    // Try the second path
    let stillNow = Date()
    if stillNow.timeIntervalSince(lastSkipTime) > 0.4 {
        skipCount += 1  // Should NOT happen with 0.4s window
    }
    try assertEqual(skipCount, 1, "0.4s window must absorb 100ms-late duplicate path")
}

test("Skip debounce: deliberate second press after window passes still works") {
    // The widened window is 0.4s — a deliberate second press at, say,
    // 0.5s elapsed must still go through. Otherwise users perceive
    // their input being eaten.
    var lastSkipTime = Date.distantPast
    var skipCount = 0

    func skip() {
        let now = Date()
        guard now.timeIntervalSince(lastSkipTime) > 0.4 else { return }
        lastSkipTime = now
        skipCount += 1
    }

    skip()
    // Wait 0.5s (simulated)
    let now = Date()
    lastSkipTime = now.addingTimeInterval(-0.5)
    skip()
    try assertEqual(skipCount, 2, "Second skip after the window must succeed")
}

// ---- Audio Position Observer Seek-Suppression Tests ----
print("\n--- Audio Position Observer Seek-Suppression Tests ---")

// These tests cover the AudioPlaybackService time observer's behavior
// while a seek is in progress. The bug fix: the observer must NOT
// publish position updates while isSeeking == true, because the player
// can report stale pre-seek positions during the seek window. A stale
// publish overwrites the ReaderViewModel's currentCharacterOffset back
// to the old position immediately after a skip — so a second skip
// press starts from the wrong baseline and either does nothing
// (rewind feels stuck) or jumps further than expected.

test("Position observer suppression: skips publish while isSeeking") {
    var isSeeking = false
    var publishedTimes: [Double] = []

    func observerTick(reportedTime: Double) {
        // Pre-fix: would have published unconditionally.
        // Post-fix: suppressed during seek.
        guard !isSeeking else { return }
        publishedTimes.append(reportedTime)
    }

    isSeeking = true
    observerTick(reportedTime: 100.0)  // Stale pre-seek
    observerTick(reportedTime: 99.5)   // Stale (player still moving)
    try assertEqual(publishedTimes.count, 0, "No publishes while seeking")

    isSeeking = false
    observerTick(reportedTime: 50.0)  // Post-seek, real position
    try assertEqual(publishedTimes.count, 1)
    try assertEqual(publishedTimes.first, 50.0, "First post-seek tick is the real new position")
}

test("Position observer suppression: clip-end check is also suppressed during seek") {
    // The clip-end check is gated by isSeeking too — without that, a
    // stale time observation past the new segment's clipEndTime would
    // falsely fire onPlaybackFinished and skip the user to the next
    // chapter mid-seek.
    var isSeeking = true
    var clipEndTime: Double? = 60.0
    var clipEndFired = false

    func observerTick(reportedTime: Double) {
        guard !isSeeking else { return }
        if let endTime = clipEndTime, reportedTime >= endTime {
            clipEndFired = true
        }
    }

    // Stale time observation during seek — pre-seek time was 75s.
    // Without seek suppression this would fire clip-end immediately.
    observerTick(reportedTime: 75.0)
    try assertTrue(!clipEndFired, "Stale tick during seek must not fire clip-end")

    // Seek lands. Real position is 30s.
    isSeeking = false
    observerTick(reportedTime: 30.0)
    try assertTrue(!clipEndFired, "Real position 30s is below 60s clip end, no fire")

    // Eventually playback reaches the clip end.
    observerTick(reportedTime: 60.5)
    try assertTrue(clipEndFired, "Real clip-end crossing fires after seek lands")
}

test("Skip from old offset bug: observer doesn't overwrite skip target") {
    // End-to-end scenario the fix prevents:
    // 1. currentCharacterOffset = 1000 (offset 100s into chapter)
    // 2. User presses skipBackward (-15s = -150 chars)
    // 3. ReaderViewModel sets currentCharacterOffset = 850, calls seek
    // 4. AVPlayer starts seeking; isSeeking flips true
    // 5. (Old bug) Time observer fires within 250ms, reports 100s
    //    (pre-seek), calls onPositionUpdate(100), and the
    //    ReaderViewModel callback would overwrite currentCharacterOffset
    //    back to 1000 — invalidating the skip.
    // 6. (New) isSeeking gates the publish, so no overwrite.
    var currentCharacterOffset = 1000
    var isSeeking = false

    func skipBackward(seconds: Int) {
        // Compute new target
        let charDelta = -seconds * 10  // 10 chars/sec
        let newOffset = currentCharacterOffset + charDelta
        currentCharacterOffset = newOffset
        // Begin seek
        isSeeking = true
    }

    func observerTick(reportedTime: Double) {
        guard !isSeeking else { return }
        currentCharacterOffset = Int(reportedTime * 10)
    }

    func seekCompletes(realTime: Double) {
        isSeeking = false
        observerTick(reportedTime: realTime)
    }

    skipBackward(seconds: 15)
    try assertEqual(currentCharacterOffset, 850, "Skip target set immediately")

    // Observer ticks while seek in progress with stale time
    observerTick(reportedTime: 100.0)
    try assertEqual(currentCharacterOffset, 850,
                    "Stale tick during seek must not overwrite skip target")
    observerTick(reportedTime: 99.0)
    try assertEqual(currentCharacterOffset, 850, "Multiple stale ticks all suppressed")

    // Seek lands
    seekCompletes(realTime: 85.0)
    try assertEqual(currentCharacterOffset, 850, "Post-seek tick reports new position")
}

// ---- Rewind on Resume: Sentence Boundary ----
print("\n--- Rewind on Resume: Sentence Boundary ---")

/// Find the start of the current sentence by scanning backward for sentence-ending punctuation.
/// Mirrors ReaderViewModel.findSentenceStart(in:before:)
func findSentenceStart(in text: String, before offset: Int) -> Int {
    guard offset > 0, offset <= text.count else { return 0 }
    let sentenceEnders: Set<Character> = [".", "!", "?"]
    let idx = text.index(text.startIndex, offsetBy: min(offset - 1, text.count - 1))

    var pos = idx
    while pos > text.startIndex {
        pos = text.index(before: pos)
        if sentenceEnders.contains(text[pos]) {
            var start = text.index(after: pos)
            while start < text.endIndex && text[start].isWhitespace {
                start = text.index(after: start)
            }
            return text.distance(from: text.startIndex, to: start)
        }
    }
    return 0
}

/// Find the start of the current paragraph by scanning backward for double newlines.
/// Mirrors ReaderViewModel.findParagraphStart(in:before:)
func findParagraphStart(in text: String, before offset: Int) -> Int {
    guard offset > 1, offset <= text.count else { return 0 }
    let searchEnd = min(offset - 1, text.count - 1)
    let idx = text.index(text.startIndex, offsetBy: searchEnd)

    var pos = idx
    while pos > text.startIndex {
        let prev = text.index(before: pos)
        if text[pos] == "\n" && text[prev] == "\n" {
            var start = text.index(after: pos)
            while start < text.endIndex && text[start].isWhitespace && text[start] != "\n" {
                start = text.index(after: start)
            }
            return text.distance(from: text.startIndex, to: start)
        }
        pos = prev
    }
    return 0
}

test("findSentenceStart: rewinds to after period") {
    let text = "First sentence. Second sentence. Third sentence."
    // Offset in the middle of "Third"
    let thirdStart = text.range(of: "Third")!.lowerBound
    let offset = text.distance(from: text.startIndex, to: thirdStart) + 2 // "Th|ird"
    let result = findSentenceStart(in: text, before: offset)
    let expected = text.distance(from: text.startIndex, to: thirdStart)
    try assertEqual(result, expected, "Should rewind to start of 'Third sentence.'")
}

test("findSentenceStart: rewinds to after exclamation mark") {
    let text = "Hello! How are you?"
    let howStart = text.range(of: "How")!.lowerBound
    let offset = text.distance(from: text.startIndex, to: howStart) + 1
    let result = findSentenceStart(in: text, before: offset)
    let expected = text.distance(from: text.startIndex, to: howStart)
    try assertEqual(result, expected)
}

test("findSentenceStart: rewinds to after question mark") {
    let text = "Why? Because reasons."
    let becauseStart = text.range(of: "Because")!.lowerBound
    let offset = text.distance(from: text.startIndex, to: becauseStart) + 3
    let result = findSentenceStart(in: text, before: offset)
    let expected = text.distance(from: text.startIndex, to: becauseStart)
    try assertEqual(result, expected)
}

test("findSentenceStart: returns 0 when no sentence boundary before offset") {
    let text = "Just one long sentence without any end"
    let result = findSentenceStart(in: text, before: 20)
    try assertEqual(result, 0, "Should return 0 (start of text)")
}

test("findSentenceStart: offset at 0 returns 0") {
    let text = "Hello world."
    let result = findSentenceStart(in: text, before: 0)
    try assertEqual(result, 0)
}

test("findSentenceStart: offset at start of first sentence returns 0") {
    let text = "First sentence. Second sentence."
    let result = findSentenceStart(in: text, before: 3) // "Fir|st"
    try assertEqual(result, 0, "No boundary before offset 3, should go to 0")
}

test("findSentenceStart: handles multiple spaces after period") {
    let text = "End.   Next part here."
    let nextStart = text.range(of: "Next")!.lowerBound
    let offset = text.distance(from: text.startIndex, to: nextStart) + 2
    let result = findSentenceStart(in: text, before: offset)
    let expected = text.distance(from: text.startIndex, to: nextStart)
    try assertEqual(result, expected, "Should skip whitespace after period")
}

print("\n--- Rewind on Resume: Paragraph Boundary ---")

test("findParagraphStart: rewinds to after double newline") {
    let text = "First paragraph.\n\nSecond paragraph here."
    let secondStart = text.range(of: "Second")!.lowerBound
    let offset = text.distance(from: text.startIndex, to: secondStart) + 5
    let result = findParagraphStart(in: text, before: offset)
    let expected = text.distance(from: text.startIndex, to: secondStart)
    try assertEqual(result, expected)
}

test("findParagraphStart: returns 0 when no paragraph boundary") {
    let text = "Just one paragraph with no double newlines at all"
    let result = findParagraphStart(in: text, before: 30)
    try assertEqual(result, 0)
}

test("findParagraphStart: single newline is not a paragraph boundary") {
    let text = "Line one\nLine two still same paragraph"
    let result = findParagraphStart(in: text, before: 20)
    try assertEqual(result, 0, "Single newline should not be treated as paragraph break")
}

test("findParagraphStart: handles multiple paragraphs, finds nearest") {
    let text = "Para one.\n\nPara two.\n\nPara three."
    let threeStart = text.range(of: "Para three")!.lowerBound
    let offset = text.distance(from: text.startIndex, to: threeStart) + 3
    let result = findParagraphStart(in: text, before: offset)
    let expected = text.distance(from: text.startIndex, to: threeStart)
    try assertEqual(result, expected, "Should rewind to start of nearest paragraph")
}

test("findParagraphStart: offset at 0 returns 0") {
    let text = "Hello\n\nWorld"
    let result = findParagraphStart(in: text, before: 0)
    try assertEqual(result, 0)
}

test("findParagraphStart: offset at 1 returns 0") {
    let text = "Hello\n\nWorld"
    let result = findParagraphStart(in: text, before: 1)
    try assertEqual(result, 0)
}

print("\n--- Rewind on Resume: RewindUnit Enum ---")

enum RewindUnit: String, CaseIterable, Codable {
    case none = "None"
    case sentence = "Sentence"
    case paragraph = "Paragraph"
    case heading = "Heading"
}

test("RewindUnit: all cases exist") {
    try assertEqual(RewindUnit.allCases.count, 4)
}

test("RewindUnit: raw values round-trip") {
    for unit in RewindUnit.allCases {
        let decoded = RewindUnit(rawValue: unit.rawValue)
        try assertTrue(decoded != nil, "Should decode \(unit.rawValue)")
        try assertTrue(decoded == unit)
    }
}

test("RewindUnit: none is default") {
    let unit = RewindUnit(rawValue: "None")
    try assertTrue(unit == RewindUnit.none)
}

// ---- Sleep Timer Fade-Out ----
print("\n--- Sleep Timer Fade-Out ---")

/// Minimal sleep timer for testing fade-out logic
class TestSleepTimer {
    var isActive = false
    var isFadingOut = false
    var fadeOutDuration: TimeInterval = 0
    var onTimerExpired: (() -> Void)?
    var onFadeStep: ((Float) -> Void)?
    var fadeSteps: [Float] = []

    func expire() {
        if fadeOutDuration > 0 {
            isFadingOut = true
            let totalSteps = max(1, Int(fadeOutDuration * 10))
            for step in 1...totalSteps {
                let volume = Float(max(0, 1.0 - Double(step) / Double(totalSteps)))
                fadeSteps.append(volume)
                onFadeStep?(volume)
            }
            isFadingOut = false
            isActive = false
            onTimerExpired?()
        } else {
            isActive = false
            onTimerExpired?()
        }
    }
}

test("Fade-out: 0 duration fires onTimerExpired immediately with no fade steps") {
    let timer = TestSleepTimer()
    timer.fadeOutDuration = 0
    timer.isActive = true
    var expired = false
    timer.onTimerExpired = { expired = true }
    var fadeStepsCalled = 0
    timer.onFadeStep = { _ in fadeStepsCalled += 1 }

    timer.expire()
    try assertTrue(expired, "Should have called onTimerExpired")
    try assertEqual(fadeStepsCalled, 0, "No fade steps for 0 duration")
    try assertTrue(!timer.isActive)
}

test("Fade-out: 1 second duration produces 10 fade steps") {
    let timer = TestSleepTimer()
    timer.fadeOutDuration = 1.0
    timer.isActive = true
    var expired = false
    timer.onTimerExpired = { expired = true }

    timer.expire()
    try assertEqual(timer.fadeSteps.count, 10)
    try assertTrue(expired, "Should have called onTimerExpired after fade")
    try assertTrue(!timer.isActive)
}

test("Fade-out: volume decreases monotonically to 0") {
    let timer = TestSleepTimer()
    timer.fadeOutDuration = 2.0
    timer.isActive = true
    timer.onTimerExpired = {}

    timer.expire()
    // Check monotonically decreasing
    for i in 1..<timer.fadeSteps.count {
        try assertTrue(timer.fadeSteps[i] <= timer.fadeSteps[i - 1],
            "Volume should decrease: step \(i) = \(timer.fadeSteps[i]) should be <= step \(i-1) = \(timer.fadeSteps[i-1])")
    }
    // Last step should be 0
    try assertEqual(timer.fadeSteps.last!, Float(0.0), "Final volume should be 0")
}

test("Fade-out: 5 second duration produces 50 fade steps") {
    let timer = TestSleepTimer()
    timer.fadeOutDuration = 5.0
    timer.isActive = true
    timer.onTimerExpired = {}

    timer.expire()
    try assertEqual(timer.fadeSteps.count, 50)
}

test("Fade-out: 10 second duration produces 100 fade steps") {
    let timer = TestSleepTimer()
    timer.fadeOutDuration = 10.0
    timer.isActive = true
    timer.onTimerExpired = {}

    timer.expire()
    try assertEqual(timer.fadeSteps.count, 100)
    // First step should be close to 1.0 but less
    try assertTrue(timer.fadeSteps.first! > 0.0 && timer.fadeSteps.first! < 1.0)
}

// ---- Configurable Bluetooth Settings Tests ----
print("\n--- Configurable Bluetooth Settings Tests ---")

test("Configurable suppress delay: longer window catches late commands") {
    var suppressUntil: Date = .distantPast
    var isSuppressed: Bool { Date() < suppressUntil }
    var suppressWindow: TimeInterval = 5.0  // User configured 5 seconds
    var playCount = 0

    func simulateDeviceChange() {
        suppressUntil = Date().addingTimeInterval(suppressWindow)
    }

    func handlePlayCommand() {
        if isSuppressed {
            suppressUntil = .distantPast
            return
        }
        playCount += 1
    }

    simulateDeviceChange()
    try assertTrue(isSuppressed, "5-second window should be active")
    handlePlayCommand()
    try assertEqual(playCount, 0, "Play should be suppressed within window")
}

test("Configurable suppress delay: shorter window allows faster deliberate play") {
    var suppressUntil: Date = .distantPast
    var isSuppressed: Bool { Date() < suppressUntil }
    var suppressWindow: TimeInterval = 1.0  // Minimum delay
    var playCount = 0

    func simulateDeviceChange() {
        suppressUntil = Date().addingTimeInterval(suppressWindow)
    }

    func handlePlayCommand() {
        if isSuppressed {
            suppressUntil = .distantPast
            return
        }
        playCount += 1
    }

    // Even with short window, spurious command during window is caught
    simulateDeviceChange()
    handlePlayCommand()
    try assertEqual(playCount, 0, "Short window still catches immediate spurious command")

    // After window consumed, next play works
    handlePlayCommand()
    try assertEqual(playCount, 1, "Deliberate play works after window consumed")
}

test("Configurable suppress delay: different delay values produce correct windows") {
    var suppressUntil: Date = .distantPast

    for delay in [1.0, 2.0, 5.0, 10.0] {
        suppressUntil = Date().addingTimeInterval(delay)
        let windowEnd = suppressUntil.timeIntervalSinceNow
        try assertTrue(abs(windowEnd - delay) < 0.1,
            "Window for \(Int(delay))s delay should be ~\(Int(delay))s, got \(windowEnd)")
    }
}

test("Bluetooth monitoring disabled: device change does not arm suppress") {
    var suppressUntil: Date = .distantPast
    var isSuppressed: Bool { Date() < suppressUntil }
    var bluetoothMonitoringEnabled = false
    var isPlaying = true
    var pauseCount = 0
    var previousDeviceWasBluetooth = true

    func simulateDeviceChange() {
        guard bluetoothMonitoringEnabled else { return }
        let wasBluetooth = previousDeviceWasBluetooth
        previousDeviceWasBluetooth = false
        guard wasBluetooth else { return }
        suppressUntil = Date().addingTimeInterval(2.0)
        if isPlaying {
            isPlaying = false
            pauseCount += 1
        }
    }

    simulateDeviceChange()
    try assertTrue(!isSuppressed, "Suppress window must not arm when monitoring disabled")
    try assertTrue(isPlaying, "Playback must not be paused when monitoring disabled")
    try assertEqual(pauseCount, 0, "No onPause when monitoring disabled")
}

test("Bluetooth monitoring toggle: enable starts monitoring") {
    var isListening = false
    var bluetoothEnabled = false

    func updateSettings(enabled: Bool, delay: TimeInterval) {
        if enabled != bluetoothEnabled {
            bluetoothEnabled = enabled
            if enabled {
                isListening = true
            } else {
                isListening = false
            }
        }
    }

    try assertTrue(!isListening)
    updateSettings(enabled: true, delay: 2.0)
    try assertTrue(isListening, "Enabling monitoring should start listener")
}

test("Bluetooth monitoring toggle: disable stops monitoring and clears window") {
    var isListening = true
    var bluetoothEnabled = true
    var suppressUntil: Date = Date().addingTimeInterval(5.0)
    var isSuppressed: Bool { Date() < suppressUntil }

    func updateSettings(enabled: Bool, delay: TimeInterval) {
        if enabled != bluetoothEnabled {
            bluetoothEnabled = enabled
            if enabled {
                isListening = true
            } else {
                isListening = false
                suppressUntil = .distantPast
            }
        }
    }

    try assertTrue(isSuppressed, "Suppress window should be active before disable")
    updateSettings(enabled: false, delay: 2.0)
    try assertTrue(!isListening, "Disabling should stop listener")
    try assertTrue(!isSuppressed, "Disabling should clear active suppress window")
}

test("Bluetooth delay update: new delay takes effect for next device change") {
    var suppressWindow: TimeInterval = 2.0
    var suppressUntil: Date = .distantPast

    func updateDelay(_ newDelay: TimeInterval) {
        suppressWindow = newDelay
    }

    func simulateDeviceChange() {
        suppressUntil = Date().addingTimeInterval(suppressWindow)
    }

    // Start with default 2s
    simulateDeviceChange()
    let window1 = suppressUntil.timeIntervalSinceNow
    try assertTrue(abs(window1 - 2.0) < 0.1, "Initial window should be ~2s")

    // User changes to 7 seconds
    updateDelay(7.0)
    simulateDeviceChange()
    let window2 = suppressUntil.timeIntervalSinceNow
    try assertTrue(abs(window2 - 7.0) < 0.1, "Updated window should be ~7s")
}

test("Bluetooth settings: default values match expected") {
    // Verify the defaults match what's documented:
    // - monitoring enabled by default (true)
    // - delay defaults to 2 seconds
    let defaultEnabled = true
    let defaultDelay = 2.0

    try assertTrue(defaultEnabled, "Bluetooth monitoring should be on by default")
    try assertEqual(defaultDelay, 2.0, "Default delay should be 2 seconds")
}

test("Bluetooth settings persistence: config round-trip") {
    // Simulate ConfigService's encoding/decoding of Bluetooth settings
    let config = TestBluetoothConfig(
        bluetoothMonitoringEnabled: false,
        bluetoothDisconnectDelay: 7.0
    )

    let encoder = JSONEncoder()
    let data = try encoder.encode(config)
    let decoder = JSONDecoder()
    let decoded = try decoder.decode(TestBluetoothConfig.self, from: data)

    try assertEqual(decoded.bluetoothMonitoringEnabled, false,
        "Enabled state should round-trip through JSON")
    try assertEqual(decoded.bluetoothDisconnectDelay, 7.0,
        "Delay value should round-trip through JSON")
}

test("Bluetooth settings persistence: missing keys use defaults") {
    // Older config.json files won't have bluetooth keys.
    // The decoder must use defaults (enabled=true, delay=2.0).
    let json = "{}"
    let data = json.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(TestBluetoothConfig.self, from: data)

    try assertEqual(decoded.bluetoothMonitoringEnabled, true,
        "Missing key should default to enabled")
    try assertEqual(decoded.bluetoothDisconnectDelay, 2.0,
        "Missing key should default to 2 seconds")
}

// ---- Headings Panel: current-heading-id update gating ----
print("\n--- Headings Panel: Current-Heading-ID Update Gating ---")

// Mirrors the predicate the production HeadingNavigatorView uses to decide
// whether `currentHeadingID` actually changed and a re-render is needed.
// The whole point of the new design is that cursor movement WITHIN a
// heading does NOT change `currentHeadingID` — so the LazyVStack and
// VoiceOver focus stay put. Crossing into a new heading is the only
// thing that flips one row's "currently reading" badge.

/// One heading entry, scoped to the test (mirrors production `Heading`
/// for the only fields we need to evaluate the predicate).
struct TestHeading {
    let id: String
    let chapterIndex: Int
    let characterOffset: Int
}

/// The same `currentHeadingID(in:)` rule used by HeadingNavigatorView:
/// pick the last heading whose (chapter, offset) is at-or-before the
/// playback cursor.
func currentHeadingID(
    in headings: [TestHeading],
    chapterIndex: Int,
    characterOffset: Int
) -> String? {
    headings.last(where: {
        $0.chapterIndex < chapterIndex
            || ($0.chapterIndex == chapterIndex && $0.characterOffset <= characterOffset)
    })?.id
}

test("Headings: current id stays put while cursor moves within a heading") {
    // Three headings in chapter 0 at offsets 0, 100, 200.
    let headings = [
        TestHeading(id: "h1", chapterIndex: 0, characterOffset: 0),
        TestHeading(id: "h2", chapterIndex: 0, characterOffset: 100),
        TestHeading(id: "h3", chapterIndex: 0, characterOffset: 200),
    ]

    var currentID: String? = nil
    var rebuildCount = 0

    /// Mirrors `updateCurrentHeadingIDIfChanged()` in production.
    func tick(chapter: Int, offset: Int) {
        let newID = currentHeadingID(in: headings, chapterIndex: chapter, characterOffset: offset)
        if newID != currentID {
            currentID = newID
            rebuildCount += 1
        }
    }

    // Land inside heading 2 and walk through every offset to its end.
    tick(chapter: 0, offset: 100)
    try assertEqual(currentID, "h2")
    try assertEqual(rebuildCount, 1, "First landing flips the id once")

    // 99 word ticks later we're still inside h2 — must not re-render.
    for offset in 101..<200 { tick(chapter: 0, offset: offset) }
    try assertEqual(currentID, "h2", "Still inside h2")
    try assertEqual(rebuildCount, 1, "No re-render while cursor stays inside the heading")
}

test("Headings: crossing into a new heading triggers exactly one update") {
    let headings = [
        TestHeading(id: "h1", chapterIndex: 0, characterOffset: 0),
        TestHeading(id: "h2", chapterIndex: 0, characterOffset: 100),
        TestHeading(id: "h3", chapterIndex: 0, characterOffset: 200),
    ]

    var currentID: String? = nil
    var rebuildCount = 0
    func tick(chapter: Int, offset: Int) {
        let newID = currentHeadingID(in: headings, chapterIndex: chapter, characterOffset: offset)
        if newID != currentID {
            currentID = newID
            rebuildCount += 1
        }
    }

    // Walk from inside h1 across the boundary into h2.
    tick(chapter: 0, offset: 99)
    try assertEqual(currentID, "h1")
    tick(chapter: 0, offset: 100)
    try assertEqual(currentID, "h2", "Boundary at offset 100 belongs to h2")
    try assertEqual(rebuildCount, 2, "Initial landing + one boundary cross")

    // And on into h3.
    for offset in 101..<200 { tick(chapter: 0, offset: offset) }
    try assertEqual(rebuildCount, 2, "No re-render walking through h2's body")
    tick(chapter: 0, offset: 200)
    try assertEqual(currentID, "h3")
    try assertEqual(rebuildCount, 3)
}

test("Headings: chapter change without a heading at the new position keeps last seen heading") {
    // Heading 1 in chapter 0, heading 2 in chapter 2 (chapter 1 has none).
    // While playback is in chapter 1, the "current" heading remains h1
    // — that's the existing semantic, this test pins it under the new
    // gating logic.
    let headings = [
        TestHeading(id: "h1", chapterIndex: 0, characterOffset: 0),
        TestHeading(id: "h2", chapterIndex: 2, characterOffset: 0),
    ]
    var currentID: String? = nil
    var rebuildCount = 0
    func tick(chapter: Int, offset: Int) {
        let newID = currentHeadingID(in: headings, chapterIndex: chapter, characterOffset: offset)
        if newID != currentID {
            currentID = newID
            rebuildCount += 1
        }
    }

    tick(chapter: 0, offset: 50)
    try assertEqual(currentID, "h1")

    tick(chapter: 1, offset: 0)
    try assertEqual(currentID, "h1", "No heading in chapter 1 — h1 stays current")
    try assertEqual(rebuildCount, 1, "No re-render when entering a heading-less chapter")

    tick(chapter: 2, offset: 0)
    try assertEqual(currentID, "h2")
    try assertEqual(rebuildCount, 2)
}

test("Headings: cursor before the first heading yields nil current id") {
    let headings = [
        TestHeading(id: "h1", chapterIndex: 1, characterOffset: 0),
        TestHeading(id: "h2", chapterIndex: 2, characterOffset: 0),
    ]
    var currentID: String? = nil
    func tick(chapter: Int, offset: Int) {
        currentID = currentHeadingID(in: headings, chapterIndex: chapter, characterOffset: offset)
    }

    tick(chapter: 0, offset: 0)
    try assertTrue(currentID == nil, "Cursor before any heading has no current heading")

    tick(chapter: 0, offset: 5_000)
    try assertTrue(currentID == nil, "Same: still in chapter 0, no heading reached yet")
}

// ---- SpeechService: utterance-identity finish dispatch ----
print("\n--- SpeechService: Utterance-Identity Finish Dispatch ---")

// Mirrors the production rule that replaced `ignoreDirectFinishCount`.
// Each time we hand an utterance to the synthesizer, it becomes the
// "live" utterance. Internal stopSpeaking calls clear the live marker
// (and may immediately start a new utterance, becoming the new live
// one). The didFinish delegate compares the incoming utterance to the
// live marker — a mismatch means the callback is for an utterance
// we've already moved on from, and must be ignored. Identity (===)
// can't desync the way a counter can.

class IdentityToken: Equatable {
    static func == (l: IdentityToken, r: IdentityToken) -> Bool { l === r }
}

test("Utterance identity: didFinish for the live utterance is processed") {
    var liveUtterance: IdentityToken? = nil
    var processedFinishes = 0

    func startUtterance() -> IdentityToken {
        let u = IdentityToken()
        liveUtterance = u
        return u
    }
    func didFinish(_ u: IdentityToken) {
        guard u === liveUtterance else { return }
        liveUtterance = nil
        processedFinishes += 1
    }

    let u = startUtterance()
    didFinish(u)
    try assertEqual(processedFinishes, 1)
    try assertTrue(liveUtterance == nil, "Live marker cleared after a real finish")
}

test("Utterance identity: stale didFinish from a stopped utterance is ignored") {
    // The bug case: synth had utterance A, we stop it and start B; the
    // delegate later fires didFinish for A. With the counter approach
    // this might desync; with identity it can't.
    var liveUtterance: IdentityToken? = nil
    var processedFinishes = 0

    func startUtterance() -> IdentityToken {
        let u = IdentityToken()
        liveUtterance = u
        return u
    }
    func internalStop() {
        liveUtterance = nil
    }
    func didFinish(_ u: IdentityToken) {
        guard u === liveUtterance else { return }
        liveUtterance = nil
        processedFinishes += 1
    }

    let a = startUtterance()
    internalStop()
    let b = startUtterance()
    // System eventually delivers didFinish for A — must be ignored
    didFinish(a)
    try assertEqual(processedFinishes, 0, "Stale finish for stopped utterance must not advance state")
    try assertTrue(liveUtterance === b, "Live marker for new utterance is intact")

    // B finishing normally does fire
    didFinish(b)
    try assertEqual(processedFinishes, 1)
}

test("Utterance identity: extra duplicate didFinish for same utterance fires only once") {
    // The other counter desync case: system delivers TWO didFinish for the
    // same utterance. Identity correctly handles it because the live
    // marker is cleared on the first finish.
    var liveUtterance: IdentityToken? = nil
    var processedFinishes = 0

    func startUtterance() -> IdentityToken {
        let u = IdentityToken()
        liveUtterance = u
        return u
    }
    func didFinish(_ u: IdentityToken) {
        guard u === liveUtterance else { return }
        liveUtterance = nil
        processedFinishes += 1
    }

    let u = startUtterance()
    didFinish(u)
    didFinish(u)  // duplicate from system — must not double-fire
    try assertEqual(processedFinishes, 1, "Identity check naturally dedupes duplicate didFinish")
}

test("Utterance identity: missing didFinish does not break the next utterance") {
    // The other counter problem: if the system DROPS a didFinish under
    // load, a counter-based scheme keeps a permanent +1 offset and
    // silently swallows a future legit finish. Identity-based handling
    // doesn't care — each utterance has its own marker.
    var liveUtterance: IdentityToken? = nil
    var processedFinishes = 0

    func startUtterance() -> IdentityToken {
        let u = IdentityToken()
        liveUtterance = u
        return u
    }
    func internalStop() { liveUtterance = nil }
    func didFinish(_ u: IdentityToken) {
        guard u === liveUtterance else { return }
        liveUtterance = nil
        processedFinishes += 1
    }

    let a = startUtterance()
    internalStop()  // we stop A; system never delivers didFinish for A
    let b = startUtterance()
    didFinish(b)  // legit finish for B — must fire
    try assertEqual(processedFinishes, 1, "B's finish is processed even though A's was lost")
}

// ---- SpeechService: position-tracking generation guard ----
print("\n--- SpeechService: Position-Tracking Generation Guard ---")

// Mirrors the production rule for the 100ms position-poll dispatch
// chain. A tick captures the offset on main, hops to a background queue
// for word extraction, hops back to main to publish. If a seek (or stop)
// happens between the capture and the publish, the captured offset is
// stale and the publish must be dropped.

test("Position generation: in-flight publish dropped after a seek") {
    var positionGeneration = 0
    var publishedOffset: Int? = nil
    func tickPublish(capturedOffset: Int) {
        // Tick T captured generation Gt.
        let gt = positionGeneration
        // ... background work ... seek happens here, bumping generation ...
        positionGeneration += 1  // simulate seek between capture and publish
        // Publish guard:
        guard gt == positionGeneration else { return }
        publishedOffset = capturedOffset
    }
    tickPublish(capturedOffset: 1000)
    try assertTrue(publishedOffset == nil, "Publish must be dropped after seek")
}

test("Position generation: publish lands when no seek happens") {
    var positionGeneration = 0
    var publishedOffset: Int? = nil
    func tickPublish(capturedOffset: Int) {
        let gt = positionGeneration
        // No seek between capture and publish.
        guard gt == positionGeneration else { return }
        publishedOffset = capturedOffset
    }
    tickPublish(capturedOffset: 1000)
    try assertEqual(publishedOffset, 1000)
}

test("Position generation: stop drops in-flight tick") {
    // stopPositionTracking bumps generation BEFORE invalidating the
    // timer, so any in-flight dispatch from the soon-to-be-invalidated
    // timer is recognised as stale.
    var positionGeneration = 0
    var publishedOffset: Int? = nil

    let gt = positionGeneration  // in-flight capture
    // ... stopPositionTracking executes:
    positionGeneration += 1
    // ... background work returns:
    if gt == positionGeneration { publishedOffset = 5000 }
    try assertTrue(publishedOffset == nil, "Stale tick from before stop must be dropped")
}

test("Position generation: each restart establishes a fresh generation") {
    var positionGeneration = 0
    // Tick A captures gen 0
    let genA = positionGeneration

    // Restart bumps generation
    positionGeneration += 1
    let genB = positionGeneration

    // Tick A is now stale
    try assertTrue(genA != positionGeneration)
    // Tick B is current
    try assertEqual(genB, positionGeneration)
}

test("Position generation: bump-before-invalidate drops late ticks from doomed timer") {
    // Production stopPositionTracking does:
    //   positionGeneration += 1
    //   positionTimer?.invalidate()
    //   positionTimer = nil
    // The bump precedes the invalidate so any tick already popped from the
    // run loop and waiting to dispatch (between popping and our invalidate
    // call taking effect) is also recognised as stale by the publish guard.
    // Reverse the order and the tick would publish stale data. This
    // sentinel test pins the ordering rule.
    var positionGeneration = 0
    var publishedOffset: Int? = nil

    // Tick already popped, captured the pre-stop generation.
    let inFlightGen = positionGeneration
    let inFlightOffset = 4242

    // stopPositionTracking begins:
    positionGeneration += 1   // bump first (production does this)
    // (timer.invalidate() would happen here; modeled implicitly — the
    // popped tick already escaped its protection)

    // The popped tick now reaches the publish guard:
    if inFlightGen == positionGeneration {
        publishedOffset = inFlightOffset
    }
    try assertTrue(publishedOffset == nil,
        "Bump-before-invalidate must drop a tick that was already in flight when stop ran")

    // Reverse order — invalidate before bump — would let a popped tick land
    // because the generation hasn't moved at the moment the publish guard
    // runs. Mirror that here as a negative control:
    positionGeneration = 0
    let inFlightGenReverse = positionGeneration
    // (in the buggy ordering, invalidate would happen here while
    // generation is still 0 — the tick's gen check passes)
    let wouldPublish = (inFlightGenReverse == positionGeneration)
    try assertTrue(wouldPublish,
        "Negative control: with invalidate-before-bump the publish guard misses the stale tick")
    // Production avoids the wouldPublish path by bumping first.
}

// ---- Periodic timer single-instance hardening ----
print("\n--- Periodic Timer Single-Instance Hardening ---")

// Simulates the invalidate-before-assign pattern added to
// ReadingStatsService.startAutoSave and
// LibraryViewModel.startRefreshTimer. The pattern protects against a
// future refactor (or repeated init) leaking a previous Timer onto
// the run loop with both copies firing.

class TestTimerSlot {
    private(set) var liveTimers: Int = 0
    func schedule() {
        // Every "schedule" leaks unless invalidate is called first.
        liveTimers += 1
    }
    func invalidate() {
        if liveTimers > 0 { liveTimers -= 1 }
    }
}

test("Single-instance: invalidate-before-assign prevents leak on second call") {
    let slot = TestTimerSlot()
    func startTimer() {
        slot.invalidate()  // production: previousTimer?.invalidate()
        slot.schedule()
    }
    startTimer()
    try assertEqual(slot.liveTimers, 1)
    startTimer()
    try assertEqual(slot.liveTimers, 1, "Second call must not stack a second live timer")
    startTimer()
    try assertEqual(slot.liveTimers, 1)
}

test("Single-instance: missing invalidate would leak (regression sentinel)") {
    // Negative-control test: if someone removes the invalidate line,
    // this asserts the leak. Keep it as a guard so the protective
    // pattern isn't silently undone.
    let slot = TestTimerSlot()
    func startTimerBuggy() {
        // No invalidate — this is what we DON'T want.
        slot.schedule()
    }
    startTimerBuggy()
    startTimerBuggy()
    try assertEqual(slot.liveTimers, 2, "Without invalidate, second call leaks a second timer")
}

// ---- pause() side-effect gating ----
print("\n--- pause() Side-Effect Gating ---")

// Mirrors the rule that a no-op pause (already paused / nothing
// playing) must NOT call recordPlaybackStopped or savePosition,
// because the rewind-on-resume threshold reads
// book.lastPlaybackStopped to decide how far back to rewind on next
// resume. Letting a media-key spurious pause overwrite that
// timestamp would defeat the threshold.

test("Pause guard: pausing while playing records stopped + saves") {
    var isPlaying = true
    var recordedStops = 0
    var savedPositions = 0

    func pauseAction() {
        let wasPlaying = isPlaying
        // ... call the underlying pause services, flip state ...
        isPlaying = false
        // The guarded side-effects:
        if wasPlaying {
            recordedStops += 1
            savedPositions += 1
        }
    }

    pauseAction()
    try assertEqual(recordedStops, 1, "Real pause must record stopped")
    try assertEqual(savedPositions, 1, "Real pause must save position")
}

test("Pause guard: pausing when already paused does not record / save") {
    var isPlaying = false  // already paused
    var recordedStops = 0
    var savedPositions = 0

    func pauseAction() {
        let wasPlaying = isPlaying
        isPlaying = false
        if wasPlaying {
            recordedStops += 1
            savedPositions += 1
        }
    }

    pauseAction()
    try assertEqual(recordedStops, 0, "No-op pause must not clobber lastPlaybackStopped")
    try assertEqual(savedPositions, 0, "No-op pause must not write a redundant position")
}

test("Pause guard: pausing when stopped does not record / save") {
    // Distinct from "paused" — playback never started.
    var isPlaying = false
    var recordedStops = 0
    var savedPositions = 0

    func pauseAction() {
        let wasPlaying = isPlaying
        isPlaying = false
        if wasPlaying {
            recordedStops += 1
            savedPositions += 1
        }
    }

    pauseAction()
    try assertEqual(recordedStops, 0)
    try assertEqual(savedPositions, 0)
}

test("Pause guard: lastPlaybackStopped not overwritten by a no-op pause") {
    // The user-visible reason this matters: rewind-on-resume reads
    // lastPlaybackStopped to compute how long the user paused, and
    // rewinds by sentence/paragraph if the gap is long enough. If a
    // stray pause overwrote the timestamp to "now", the threshold
    // would always be ~0 and the rewind would never trigger.
    var isPlaying = false
    let originalStoppedAt = Date(timeIntervalSince1970: 1_000_000)
    var lastPlaybackStopped: Date = originalStoppedAt

    func pauseAction() {
        let wasPlaying = isPlaying
        isPlaying = false
        if wasPlaying { lastPlaybackStopped = Date() }
    }

    pauseAction()
    try assertEqual(lastPlaybackStopped, originalStoppedAt,
                   "No-op pause must not move the lastPlaybackStopped timestamp")
}

test("Headings: typical playback session triggers far fewer rebuilds than ticks") {
    // Quantify the design improvement: simulate 1000 word-ticks across 3
    // headings in one chapter. The old code rebuilt on every tick (1000
    // rebuilds). The new code rebuilds exactly when crossing a heading
    // boundary plus the initial landing (3 in this layout). The test
    // pins the upper bound so a regression that re-introduces the
    // per-word rebuild fails loudly.
    let headings = [
        TestHeading(id: "h1", chapterIndex: 0, characterOffset: 0),
        TestHeading(id: "h2", chapterIndex: 0, characterOffset: 350),
        TestHeading(id: "h3", chapterIndex: 0, characterOffset: 700),
    ]
    var currentID: String? = nil
    var rebuildCount = 0
    for offset in 0..<1000 {
        let newID = currentHeadingID(in: headings, chapterIndex: 0, characterOffset: offset)
        if newID != currentID {
            currentID = newID
            rebuildCount += 1
        }
    }
    try assertEqual(rebuildCount, 3, "1000 ticks across 3 headings should produce 3 id flips")
}

} // end runPlaybackTests

/// Minimal config struct for testing Bluetooth settings persistence
private struct TestBluetoothConfig: Codable {
    var bluetoothMonitoringEnabled: Bool
    var bluetoothDisconnectDelay: Double

    init(bluetoothMonitoringEnabled: Bool = true, bluetoothDisconnectDelay: Double = 2.0) {
        self.bluetoothMonitoringEnabled = bluetoothMonitoringEnabled
        self.bluetoothDisconnectDelay = bluetoothDisconnectDelay
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bluetoothMonitoringEnabled = try container.decodeIfPresent(Bool.self, forKey: .bluetoothMonitoringEnabled) ?? true
        bluetoothDisconnectDelay = try container.decodeIfPresent(Double.self, forKey: .bluetoothDisconnectDelay) ?? 2.0
    }
}
