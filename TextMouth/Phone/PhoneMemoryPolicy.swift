import Foundation

/// What the iPhone's memory guard does about the memory left to TextMouth,
/// decided from each reading alone, so the Mac's test host tests it.
///
/// The Mac's guard (`MemoryGuardPolicy`) acts on TextMouth's footprint, at 3 GB
/// and 6 GB, written after a runaway inside Apple's Vorbis decoder on October 14,
/// 2026. On most iPhones the system ends an app long before either, so on iOS
/// the guard reads instead what `os_proc_available_memory()` gives, "the number
/// of bytes remaining ... before the current process will hit its current dirty
/// memory limit" (`usr/include/os/proc.h`). Under `stopPlaybackBelow` while a
/// book plays, it stops the book, which says why, and saves. It never quits:
/// only the system ends an iPhone app.
///
/// The SDK's header says the call returns 0 "if the calling process is not an
/// app, or the calling process exceeds its memory limit". A 0 at the first
/// reading is taken for the first, a process that can't be measured, as in the
/// Simulator, where it would otherwise stop every book: so a guard whose first
/// reading is 0 stays idle for the process. A 0 after a true reading is the
/// second, and stops the book.
///
/// The thresholds are guesses until a phone is measured: no figure for the limit
/// is published, and reports range from about 900 MB to 5 GB.
///
/// Plain and shared; only the guard's iOS branch (`PlaybackMemoryGuard`, under
/// `#if os(iOS)`) and the phone's render check use it.
struct PhoneMemoryPolicy: Equatable, Sendable {
    /// The memory left under which a playing book is stopped: about 150 MB.
    static let stopPlaybackBelow: UInt64 = 150 << 20

    /// The memory a look-ahead render wants left before it starts: about
    /// 300 MB. The largest render, 100,000 characters of speech, is about
    /// 37 minutes and 98 MB of audio, so this leaves the stop threshold and
    /// the render's own working memory between them.
    static let renderAheadNeeds: UInt64 = 300 << 20

    /// What the guard does about one reading.
    enum Action: Equatable, Sendable {
        /// Nothing: enough is left, or nothing plays to be stopped, or the
        /// guard is idle.
        case none
        /// The first reading was 0, so the process can't be measured: the
        /// guard stays idle, and reads no more.
        case goIdle
        /// Stop playback: only this many bytes were left.
        case stopPlayback(availableBytes: UInt64)
    }

    /// The threshold this policy stops playback at: the real one unless a test
    /// sets its own.
    let stopPlaybackBelow: UInt64

    /// Whether the guard is idle for the process, its first reading having
    /// been 0.
    private(set) var isIdle = false

    /// The memory the last reading found left, or nil before the first, and
    /// when idle.
    private(set) var lastAvailableBytes: UInt64?

    /// A policy stopping playback below `stopPlaybackBelow` bytes left, before
    /// any reading.
    init(stopPlaybackBelow: UInt64 = PhoneMemoryPolicy.stopPlaybackBelow) {
        self.stopPlaybackBelow = stopPlaybackBelow
    }

    /// Decide what to do about a reading of `available` bytes left. Only a
    /// playing book is stopped (`isAnythingPlaying`), as on the Mac, and a
    /// book played again while too little is left is stopped again at the
    /// next reading.
    mutating func act(onAvailable available: UInt64, isAnythingPlaying: Bool) -> Action {
        guard !isIdle else { return .none }
        if lastAvailableBytes == nil, available == 0 {
            isIdle = true
            return .goIdle
        }
        lastAvailableBytes = available
        guard isAnythingPlaying, available < stopPlaybackBelow else { return .none }
        return .stopPlayback(availableBytes: available)
    }

    /// Whether a look-ahead render may start, with `available` bytes left
    /// and the device at `thermalState`: not with less than `renderAheadNeeds`
    /// left, and not at `.serious` or `.critical` thermal state, for which the
    /// SDK's `NSProcessInfo.h` recommends that an app "reduce application's
    /// usage of CPU, GPU and I/O". A render that is skipped costs nothing
    /// heard: the next chapter starts the ordinary way, with direct speech.
    ///
    /// A reading of 0 says nothing about memory: the process isn't an app, as
    /// in the Simulator, or it is over its limit, when the guard's own reading
    /// stops the book. So 0 leaves the decision to the thermal state.
    static func mayRenderAhead(availableBytes available: UInt64, thermalState: ProcessInfo.ThermalState) -> Bool {
        switch thermalState {
        case .serious, .critical:
            return false
        default:
            return available == 0 || available >= renderAheadNeeds
        }
    }

    /// `bytes` in megabytes of 1,024 kilobytes, rounded down, for the log.
    static func megabytes(_ bytes: UInt64) -> UInt64 {
        bytes >> 20
    }
}
